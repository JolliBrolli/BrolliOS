// Compositor-side liquid glass for Quickshell layer surfaces.
//
// NO BLUR. The target is Apple's Liquid Glass, which reads as transparent and
// refractive rather than frosted -- the glass character comes from lensing at
// the edges, not from blurring what is behind. So the backdrop is sampled
// SHARP, and the material's job is to bend it.
//
// That also means we do not borrow Hyprland's blur (blurMainFramebuffer): it
// only ever returns a blurred texture, only exists when decoration:blur is
// enabled, and uses whatever radius the user's config happens to set. We take
// our own copy instead -- a glBlitFramebuffer straight out of the framebuffer
// this frame is being composited into, the technique ShojiWM uses
// (src/shojiwm/src/backend/shader_effect.rs, capture_framebuffer).
//
// Glass the ACTUAL VISIBLE SHAPE of a layer surface, not its (much larger)
// layer box.
//
// The dock's layer is 2880x178 — full screen width — while the visible dock is
// a small centred pill. So the shape has to come from the layer's own alpha,
// the same way ShojiWM's island-glass uses layerSource() as a silhouette.
//
// Shape/silhouette: layer alpha, thresholded.
// Distance to edge: marched along the alpha gradient (cheap stand-in for the
//                   reference's jump-flood distance field — good enough for a
//                   rim of a few tens of px, which is all the lens needs).
// Backdrop: blurMainFramebuffer(), the live mid-frame composite.

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/PassElement.hpp>
#include <hyprland/src/render/Texture.hpp>
#include <hyprland/src/debug/log/Logger.hpp>
#include <hyprland/src/managers/EventManager.hpp>
#include <hyprland/src/managers/SessionLockManager.hpp>
#include <hyprland/src/helpers/time/Time.hpp>
#include <hyprland/src/desktop/state/LayerState.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/protocols/wlr-layer-shell-unstable-v1.hpp> // ZWLR_LAYER_SHELL_V1_LAYER_* (layer levels)
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <GLES3/gl32.h>
#include <algorithm>
#include <fstream>
#include <sstream>
#include <unordered_map>
#include <vector>
#include <string>
#include <format>
#include <hyprland/src/helpers/varlist/VarList.hpp>

inline HANDLE              PHANDLE = nullptr;
inline CHyprSignalListener g_renderListener;
inline CFunctionHook*       g_renderLayerHook = nullptr; // see hkRenderLayer

// Runtime switches, flipped with `hyprctl glassopt ...` (registered below) so
// each optimisation can be measured on and off without rebuilding or
// reloading the plugin. Handhold for the handoff doc's "one variable at a
// time" rule (section 20A).

// Per-frame shared backdrop. Rebuilt once per render pass and reused by every
// glass element in that same frame.
//
// Safe because our elements are queued back-to-back at RENDER_POST_WINDOWS and
// therefore draw consecutively — nothing else runs a blur in between to claim
// the monitor work buffers this texture lives in. If the dock's glass ever
// goes stale or flickers while Spotlight is open, THIS is the first thing to
// suspect: something started drawing between our elements.
inline uint64_t             g_frameSerial      = 0;
inline uint64_t             g_backdropSerial   = 0;
inline SP<Render::ITexture> g_backdropTexture  = nullptr;
inline CRegion              g_frameGlassRegion = {};

// Capture padding around each glass panel, physical px. The material samples
// outside the visible shape (refraction, blur taps); a capture smaller than
// that reach clamps and smears at its edge. Also the margin used when growing
// damage around a panel, so the two always agree.
static constexpr float kPadPx = 48.F;

// Where the glass goes, sent by the shell (hyprctl glassrect ...).
//
// The compositor only knows a layer's BOX, and that is not the glass: the dock's
// layer is the full 2880px-wide strip while its glass is a centred pill. The
// material draws its whole shape across whatever panel it is given, so handing
// it the layer box drew one enormous slab across the bottom of the screen.
// Only the shell knows the real rect, so the shell sends it -- in the layer's
// own logical coordinates, keyed by an id so one layer can carry several.
struct SGlassRect {
    std::string ns;
    CBox        rect;          // layer-local, logical px
    float       radius = -1.F; // per-panel maxCornerRadius; <0 = the global value
};
static std::unordered_map<std::string, SGlassRect> g_rects;

// Damage one panel's padded area on every monitor where its layer is mapped.
//
// Needed because the listener only redraws a panel when real damage touches it.
// Two things change the glass WITHOUT producing any screen damage: new uniform
// values (a settings slider), and a rect update that lands after the surface's
// own last repaint (the shell throttles rect sends, so the final dock-
// magnification rect can arrive a frame late). Without this the glass would
// stay at its old look or old shape until something unrelated moved behind it.
// damageBox (unlike the listener) is the right call here: these are real,
// one-off changes, so scheduling a frame is exactly what should happen.
static void damageRect(const SGlassRect& r) {
    for (const auto& LS : Desktop::layerState()->layers()) {
        if (!LS || !LS->m_mapped || LS->m_namespace != r.ns)
            continue;
        const Vector2D POS = LS->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
        g_pHyprRenderer->damageBox(CBox{POS.x + r.rect.x - kPadPx, POS.y + r.rect.y - kPadPx, r.rect.w + kPadPx * 2.F, r.rect.h + kPadPx * 2.F});
    }
}

// The material is NOT authored here. These are Joel's shaders from
// quickshell/modules/common/widgets/glass/, mechanically translated to GLES by
// port_shader.py (dialect only -- the body is verbatim). Loaded from disk so
// tuning the .frag and re-running the converter needs a plugin reload, not a
// rebuild.
static const char* VERT = R"(#version 300 es
precision highp float;
in vec2 pos;
in vec2 uv;
out vec2 qt_TexCoord0;   // Qt's meaning, preserved: panel-local UV, 0..1
void main() {
    qt_TexCoord0 = uv;
    gl_Position  = vec4(pos, 0.0, 1.0);
}
)";

static std::string readShaderFile(const std::string& path) {
    std::ifstream f(path);
    if (!f)
        return "";
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

// Uniform values pushed in by the shell (hyprctl glassuniform <name> <v...>).
//
// They are NOT read from config.json here: several of them (base, textColor,
// tint) are derived Material You theme colours computed in Appearance.qml, and
// reproducing that derivation in C++ would be re-authoring the material a
// layer down. The shell already has the exact values.
static std::unordered_map<std::string, std::vector<float>> g_uniformValues;

// Set every uniform the linked program actually declares, from the map above.
// Introspected rather than hardcoded, so a uniform added to the .frag needs no
// change here -- only that the shell starts sending it.
static void applyUniformValues(GLuint prog) {
    GLint count = 0;
    glGetProgramiv(prog, GL_ACTIVE_UNIFORMS, &count);
    for (GLint i = 0; i < count; ++i) {
        char  name[128];
        GLint size = 0;
        GLenum type = 0;
        GLsizei len = 0;
        glGetActiveUniform(prog, i, sizeof(name), &len, &size, &type, name);
        if (type == GL_SAMPLER_2D)
            continue;
        const auto IT = g_uniformValues.find(std::string(name, len));
        if (IT == g_uniformValues.end())
            continue;
        const GLint LOC = glGetUniformLocation(prog, name);
        if (LOC < 0)
            continue;
        const auto& V = IT->second;
        switch (V.size()) {
            case 1: glUniform1f(LOC, V[0]); break;
            case 2: glUniform2f(LOC, V[0], V[1]); break;
            case 3: glUniform3f(LOC, V[0], V[1], V[2]); break;
            case 4: glUniform4f(LOC, V[0], V[1], V[2], V[3]); break;
            default: break;
        }
    }
}

static GLuint g_prog = 0, g_vbo = 0;

// Our own capture target. One texture, sharp, sized to the padded glass box.
static GLuint g_capFbo = 0, g_capTex = 0, g_hblurTex = 0;
static int    g_capW = 0, g_capH = 0;
static float  g_capScale = 1.0F; // 1.0 = full res; 0.5 = a quarter of the pixels
// Damage gating (hyprctl glassopt gate on|off). On: a panel is only redrawn in
// frames where real damage touches it. Off: redrawn every rendered frame, the
// previous behaviour -- kept switchable purely to measure the difference.
static bool g_optGate = true;

// Total panel draws since load -- sample it twice to get a rate. At an idle
// desktop with gating on this must not move.
static uint64_t g_drawCount = 0;
static std::unordered_map<std::string, uint64_t> g_drawsByPanel; // panel id -> draws

static void ensureCaptureTexture(int w, int h) {
    if (g_capW == w && g_capH == h && g_capTex)
        return;
    if (!g_capFbo)
        glGenFramebuffers(1, &g_capFbo);
    if (g_capTex) {
        glDeleteTextures(1, &g_capTex);
        glDeleteTextures(1, &g_hblurTex);
    }
    GLuint made[2] = {0, 0};
    glGenTextures(2, made);
    for (GLuint t : made) {
        glBindTexture(GL_TEXTURE_2D, t);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    }
    g_capTex = made[0], g_hblurTex = made[1];
    g_capW = w, g_capH = h;
    Log::logger->log(Log::INFO, "[glass] capture texture {}x{}", w, h);
}
static GLint  uBackdrop = -1, uLayerTex = -1, uScreen = -1, uBox = -1, uRim = -1, uRefract = -1, uAlphaT = -1, aPos = -1;
static GLint  uCapOrigin = -1, uCapSize = -1;

static GLuint compile(GLenum type, const char* src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, nullptr);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[2048];
        glGetShaderInfoLog(s, sizeof(log), nullptr, log);
        Log::logger->log(Log::ERR, "[glass4] shader compile failed: {}", log);
        glDeleteShader(s);
        return 0;
    }
    return s;
}

static GLuint g_hblurProg = 0;
static GLint  aPosH = -1, aUvH = -1;
static GLint  aUv = -1;
static std::string g_shaderDir = "/home/Joel/Projects/Brolli-Glass/plugin/src/generated";

static GLuint link(const char* vertSrc, const std::string& fragSrc, const char* label) {
    GLuint v = compile(GL_VERTEX_SHADER, vertSrc), f = compile(GL_FRAGMENT_SHADER, fragSrc.c_str());
    if (!v || !f)
        return 0;
    GLuint prog = glCreateProgram();
    glAttachShader(prog, v);
    glAttachShader(prog, f);
    glLinkProgram(prog);
    GLint ok = 0;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    glDeleteShader(v);
    glDeleteShader(f);
    if (!ok) {
        char log[4096];
        glGetProgramInfoLog(prog, sizeof(log), nullptr, log);
        Log::logger->log(Log::ERR, "[glass] {} link failed: {}", label, log);
        glDeleteProgram(prog);
        return 0;
    }
    return prog;
}

static bool ensureProgram() {
    if (g_prog)
        return true;

    const std::string MAIN  = readShaderFile(g_shaderDir + "/liquidglasstest.gles.frag");
    const std::string HBLUR = readShaderFile(g_shaderDir + "/liquidglasshblur.gles.frag");
    if (MAIN.empty()) {
        Log::logger->log(Log::ERR, "[glass] no material at {} -- run port_shader.py", g_shaderDir);
        return false;
    }

    g_prog = link(VERT, MAIN, "material");
    if (!g_prog)
        return false;
    g_hblurProg = link(VERT, HBLUR, "hblur");

    uBackdrop  = glGetUniformLocation(g_prog, "source");
    uLayerTex  = glGetUniformLocation(g_prog, "sourceHBlur");
    aPos       = glGetAttribLocation(g_prog, "pos");
    aUv        = glGetAttribLocation(g_prog, "uv");
    if (g_hblurProg) {
        aPosH = glGetAttribLocation(g_hblurProg, "pos");
        aUvH  = glGetAttribLocation(g_hblurProg, "uv");
    }
    glGenBuffers(1, &g_vbo);
    Log::logger->log(Log::INFO, "[glass] material loaded from {} ({} bytes)", g_shaderDir, MAIN.size());
    return true;
}

class CGlassElement : public IPassElement {
  public:
    CGlassElement(const CBox& box, float radius, const std::string& id) : m_box(box), m_radius(radius), m_id(id) {}
    virtual ~CGlassElement() = default;

    virtual bool needsLiveBlur() {
        return true;
    }
    virtual bool needsPrecomputeBlur() {
        return false;
    }
    virtual const char* passName() {
        return "CGlassElement";
    }
    virtual ePassElementType type() {
        return EK_CUSTOM;
    }
    // Monitor-local LOGICAL coordinates, per PassElement.hpp -- CRenderPass::render
    // multiplies it by m_scale itself. m_box is physical, so divide here; at
    // scale 1 the two coincide, which is why this went unnoticed.
    virtual std::optional<CBox> boundingBox() {
        const auto  PMONITOR = g_pHyprRenderer->m_renderData.pMonitor;
        const float SCALE    = PMONITOR ? PMONITOR->m_scale : 1.F;
        return CBox{m_box.x / SCALE, m_box.y / SCALE, m_box.width / SCALE, m_box.height / SCALE};
    }

    virtual std::vector<UP<IPassElement>> draw() {
        if (!ensureProgram())
            return {};
        ++g_drawCount;
        ++g_drawsByPanel[m_id];

        const auto PMONITOR = g_pHyprRenderer->m_renderData.pMonitor;
        if (!PMONITOR)
            return {};

        const float SW = PMONITOR->m_transformedSize.x, SH = PMONITOR->m_transformedSize.y;

        // Padding around the visible box: refraction samples outside the shape,
        // and a capture smaller than that reach clamps at its edge and smears.
        const float PAD = kPadPx;

        // The capture's ORIGIN is always exactly PAD above and left of the panel,
        // even when that lands off-screen. The material locates the panel inside
        // the texture with a single `vec2(pad)` offset (toTex), so clamping the
        // origin to the screen edge would shift every sample for a panel near
        // the top or left. Instead only the on-screen part is copied, at its
        // correct offset, and whatever lies off-screen stays cleared.
        const float ux0 = (float)m_box.x - PAD, uy0 = (float)m_box.y - PAD;
        const float UW  = (float)m_box.width + PAD * 2.F, UH = (float)m_box.height + PAD * 2.F;
        const float px0 = std::max(0.F, ux0), py0 = std::max(0.F, uy0);
        const float px1 = std::min(SW, ux0 + UW), py1 = std::min(SH, uy0 + UH);

        // Allocated in 64px steps and only ever grown. The dock's rect changes
        // width on every frame of icon magnification; sizing the texture exactly
        // meant a delete/create/upload per frame (visible in the log as
        // 2866x222 -> 2880x224 -> 2880x225 ...). Same resize lesson as Spotlight.
        const int STEP = 64;
        const int AW   = std::max(g_capW, ((int)std::ceil(UW * g_capScale) + STEP - 1) / STEP * STEP);
        const int AH   = std::max(g_capH, ((int)std::ceil(UH * g_capScale) + STEP - 1) / STEP * STEP);
        const int CW   = AW, CH = AH;
        const float bx = m_box.x, by = m_box.y, bw = m_box.width, bh = m_box.height;

        const float x0 = (bx / SW) * 2.F - 1.F, x1 = ((bx + bw) / SW) * 2.F - 1.F;
        const float y0 = (by / SH) * 2.F - 1.F, y1 = ((by + bh) / SH) * 2.F - 1.F;
        // pos + uv interleaved. uv is Qt's qt_TexCoord0: 0..1 across the VISIBLE
        // panel, which is what the material's toTex()/sdf maths expects.
        const float verts[24] = {x0, y0, 0.F, 0.F, x1, y0, 1.F, 0.F, x1, y1, 1.F, 1.F,
                                 x0, y0, 0.F, 0.F, x1, y1, 1.F, 1.F, x0, y1, 0.F, 1.F};

        GLint prevProg = 0, prevVbo = 0, prevTex0 = 0, prevTex1 = 0, prevActive = 0;
        glGetIntegerv(GL_CURRENT_PROGRAM, &prevProg);
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &prevVbo);
        glGetIntegerv(GL_ACTIVE_TEXTURE, &prevActive);
        glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &prevTex0);
        glActiveTexture(GL_TEXTURE1);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &prevTex1);
        const GLboolean prevBlend = glIsEnabled(GL_BLEND), prevScissor = glIsEnabled(GL_SCISSOR_TEST);

        glDisable(GL_SCISSOR_TEST);

        // ---- capture: copy the region straight out of the frame in progress ----
        //
        // Read explicitly from THIS frame's draw framebuffer. Never rely on the
        // ambient READ binding: other passes leave it pointing at their own
        // offscreen targets, and a blit from there captures a stale composite --
        // including this element itself.
        GLint prevDrawFbo = 0, prevReadFbo = 0;
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevDrawFbo);
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prevReadFbo);

        ensureCaptureTexture(CW, CH);

        glBindFramebuffer(GL_READ_FRAMEBUFFER, prevDrawFbo);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g_capFbo);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, g_capTex, 0);
        glDisable(GL_BLEND);
        glViewport(0, 0, CW, CH);
        glClearColor(0.F, 0.F, 0.F, 0.F);
        glClear(GL_COLOR_BUFFER_BIT);
        if (px1 > px0 && py1 > py0) {
            const GLint DX0 = (GLint)((px0 - ux0) * g_capScale), DY0 = (GLint)((py0 - uy0) * g_capScale);
            const GLint DX1 = (GLint)((px1 - ux0) * g_capScale), DY1 = (GLint)((py1 - uy0) * g_capScale);
            glBlitFramebuffer((GLint)px0, (GLint)py0, (GLint)px1, (GLint)py1, DX0, DY0, DX1, DY1, GL_COLOR_BUFFER_BIT, GL_LINEAR);
        }

        glBindFramebuffer(GL_READ_FRAMEBUFFER, prevReadFbo);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prevDrawFbo);
        // Restore here, not only after the H-blur pass: if that program failed
        // to link the main draw would otherwise run with the capture's viewport.
        glViewport(0, 0, (GLint)SW, (GLint)SH);

        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

        glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STREAM_DRAW);

        // The material's geometry uniforms. These are the plugin's to compute --
        // they describe where the glass is and how the capture maps onto it --
        // unlike the look uniforms, which the shell owns.
        //
        //   panelSize : the visible panel, in px
        //   texSize   : the captured texture, panel + padding on each side
        //   pad       : that padding
        // which is exactly what toTex() assumes:
        //   (vec2(pad) + pUV * panelSize) / texSize
        const float CAPW = (float)CW / g_capScale, CAPH = (float)CH / g_capScale;

        // ---- sourceHBlur: the horizontal half of the material's separable blur,
        // ---- running Joel's own liquidglasshblur shader over our capture.
        if (g_hblurProg) {
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g_capFbo);
            glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, g_hblurTex, 0);
            glViewport(0, 0, CW, CH);
            glDisable(GL_BLEND);
            glUseProgram(g_hblurProg);
            glEnableVertexAttribArray(aPosH);
            glEnableVertexAttribArray(aUvH);
            const float FULL[24] = {-1, -1, 0, 0, 1, -1, 1, 0, 1, 1, 1, 1, -1, -1, 0, 0, 1, 1, 1, 1, -1, 1, 0, 1};
            glBufferData(GL_ARRAY_BUFFER, sizeof(FULL), FULL, GL_STREAM_DRAW);
            glVertexAttribPointer(aPosH, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), nullptr);
            glVertexAttribPointer(aUvH, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)(2 * sizeof(float)));
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D, g_capTex);
            glUniform1i(glGetUniformLocation(g_hblurProg, "source"), 0);
            glUniform2f(glGetUniformLocation(g_hblurProg, "texSize"), CAPW, CAPH);
            applyUniformValues(g_hblurProg); // radiusPx comes from the shell
            glDrawArrays(GL_TRIANGLES, 0, 6);
            glDisableVertexAttribArray(aPosH);
            glDisableVertexAttribArray(aUvH);
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prevDrawFbo);
            glViewport(0, 0, (GLint)SW, (GLint)SH);
        }

        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

        glUseProgram(g_prog);
        glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STREAM_DRAW);
        glEnableVertexAttribArray(aPos);
        glEnableVertexAttribArray(aUv);
        glVertexAttribPointer(aPos, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), nullptr);
        glVertexAttribPointer(aUv, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)(2 * sizeof(float)));

        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, g_capTex);
        glUniform1i(uBackdrop, 0);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, g_hblurProg ? g_hblurTex : g_capTex);
        glUniform1i(uLayerTex, 1); // uLayerTex is the material's sourceHBlur slot

        glUniform2f(glGetUniformLocation(g_prog, "panelSize"), bw, bh);
        glUniform2f(glGetUniformLocation(g_prog, "texSize"), CAPW, CAPH);
        glUniform1f(glGetUniformLocation(g_prog, "pad"), PAD);
        applyUniformValues(g_prog); // everything else: the shell's values
        // The one uniform that differs per panel in the original material: the
        // dock is uncapped, Spotlight caps its corners at spotlightMaxCornerRadius.
        if (m_radius >= 0.F)
            glUniform1f(glGetUniformLocation(g_prog, "maxCornerRadius"), m_radius);

        glDrawArrays(GL_TRIANGLES, 0, 6);

        glDisableVertexAttribArray(aPos);
        glDisableVertexAttribArray(aUv);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, prevTex1);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, prevTex0);
        glActiveTexture(prevActive);
        glBindBuffer(GL_ARRAY_BUFFER, prevVbo);
        glUseProgram(prevProg);
        if (!prevBlend)
            glDisable(GL_BLEND);
        if (prevScissor)
            glEnable(GL_SCISSOR_TEST);

        return {};
    }

  private:
    CBox        m_box;
    float       m_radius = -1.F;
    std::string m_id;
};


// Queue the glass for every panel belonging to one layer surface, at the point
// in the render pass where it is called. Used by the renderLayer hook (just
// before that layer's own surface is queued) and, if the hook could not be
// installed, by the stage listener as a fallback.
static void queueGlassFor(const PHLLS& LS, const PHLMONITOR& PMONITOR) {
    if (!LS || !PMONITOR || !LS->m_mapped || LS->m_monitor.get() != PMONITOR.get())
        return;

    // Where renderLayer actually draws this surface this frame: the
    // animated CURRENT position, not the arranged target (m_geometry).
    const Vector2D POS   = LS->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
    const float    SCALE = PMONITOR->m_scale;

    for (const auto& [ID, R] : g_rects) {
        if (R.ns != LS->m_namespace)
            continue;

        // The panel the material should draw across: the shell's rect,
        // placed inside the layer. Global logical, then monitor-physical.
        const CBox LOGICAL{POS.x + R.rect.x, POS.y + R.rect.y, R.rect.w, R.rect.h};
        const CBox BOX{(LOGICAL.x - PMONITOR->m_position.x) * SCALE, (LOGICAL.y - PMONITOR->m_position.y) * SCALE, LOGICAL.w * SCALE, LOGICAL.h * SCALE};
        if (BOX.w < 1 || BOX.h < 1)
            continue;

        // Only redraw a panel when real damage touches it this frame.
        //
        // The render damage for this frame already includes the
        // swapchain's buffer-age repair (getBufferDamage). If it does not
        // touch the padded panel, this buffer still holds correct glass
        // from the last time the panel was drawn -- skip it entirely.
        // That is what makes an idle desktop idle.
        //
        // If it DOES touch it, add the WHOLE padded region to the render
        // damage, so everything behind is repainted there before the
        // capture reads it. Hyprland's pass does the same for its own blur
        // (Pass.cpp: blurRegion.intersect(m_damage).expand(...)), but only
        // by the blur radius; this material's refraction can pull samples
        // from across the whole panel, so a partial repaint would leave
        // the capture reading our own previous glass in the undamaged part.
        //
        // Added to RENDER damage only, never to the damage ring -- so it
        // cannot feed itself. The previous approach called damageBox()
        // every frame, which schedules the next frame, which ran this
        // again: a permanent 120 fps loop while any glass was visible,
        // ~25% GPU at idle.
        const CBox PADDED{BOX.x - kPadPx, BOX.y - kPadPx, BOX.w + kPadPx * 2.F, BOX.h + kPadPx * 2.F};
        auto&      DMG = g_pHyprRenderer->m_renderData.damage;
        if (g_optGate && DMG.copy().intersect(PADDED).empty())
            continue;
        DMG.add(PADDED);

        g_pHyprRenderer->m_renderPass.add(makeUnique<CGlassElement>(BOX, R.radius, ID));
    }
}

// ---- per-surface ordering ----
//
// Glass belongs to a surface, so it is queued immediately before that surface,
// exactly where Hyprland decides its OWN layer blur (inside renderLayer:
// `renderdata.blur = shouldBlur(pLayer)`). Queuing at a render stage instead
// put every top layer's glass beneath ALL top layers -- so Spotlight's glass sat
// under its own dim scrim and was darkened by it. Hyprland has no hook between
// individual layers, hence the function hook. No source is modified: the hook
// wraps the original and always calls it.
typedef void (*origRenderLayer)(void*, PHLLS, PHLMONITOR, const Time::steady_tp&, bool, bool);

static void hkRenderLayer(void* thisptr, PHLLS pLayer, PHLMONITOR pMonitor, const Time::steady_tp& time, bool popups, bool lockscreen) {
    // Mirror renderLayer's own early returns so glass is never queued for a
    // surface that then does not draw. The popups pass calls this a second time
    // for every layer; glass belongs to the main pass only. While locked, the
    // lock surface covers everything, so glass is skipped entirely.
    if (pLayer && pMonitor && !popups && !lockscreen && pLayer->visible() && !g_pSessionLockManager->isSessionLocked())
        queueGlassFor(pLayer, pMonitor);

    ((origRenderLayer)g_renderLayerHook->m_original)(thisptr, pLayer, pMonitor, time, popups, lockscreen);
}

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    g_renderListener = Event::bus()->m_events.render.stage.listen([](eRenderStage stage) {
        // Glass has to be queued at the point in the frame where everything
        // BEHIND its layer has been drawn and the layer itself has not:
        //
        //   bottom layers (desktop widgets) -> RENDER_POST_WALLPAPER
        //       after the background layer, before any bottom layer.
        //   top/overlay layers (dock, Spotlight) -> RENDER_POST_WINDOWS
        //       after windows, before top/overlay layers.
        //
        // Queuing a bottom layer's glass at POST_WINDOWS would paint it OVER
        // every window covering that widget. Both stages fire once per frame
        // (Renderer.cpp: the two POST_WALLPAPER sites are mutually exclusive
        // branches). Known gap: with no workspace on a monitor, Hyprland renders
        // top/overlay layers without emitting POST_WINDOWS, so top-layer glass
        // does not draw in that state.
        uint32_t wantLo = 0, wantHi = 0;
        if (stage == RENDER_POST_WALLPAPER)
            wantLo = wantHi = ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM;
        else if (stage == RENDER_POST_WINDOWS)
            wantLo = ZWLR_LAYER_SHELL_V1_LAYER_TOP, wantHi = ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY;
        else
            return;

        const auto PMONITOR = g_pHyprRenderer->m_renderData.pMonitor;
        if (!PMONITOR)
            return;

        // New frame for this monitor: invalidate the shared backdrop and start
        // a fresh union of the glass boxes we are about to queue.
        ++g_frameSerial;
        g_backdropTexture = nullptr;
        g_frameGlassRegion = CRegion{};

        // Normal path: the renderLayer hook queues each layer's glass directly
        // before that layer is drawn, so nothing is done here. This stage-based
        // queueing is only the fallback for when the hook could not be installed.
        if (g_renderLayerHook)
            return;

        for (const auto& LS : Desktop::layerState()->layers()) {
            if (!LS || LS->m_layer < wantLo || LS->m_layer > wantHi)
                continue;
            queueGlassFor(LS, PMONITOR.lock());
        }
    });

    // exact=false is required, not cosmetic: with exact=true the request has
    // to equal "glassopt" character for character, so `hyprctl glassopt` works
    // and `hyprctl glassopt region on` comes back "unknown request".
    HyprlandAPI::registerHyprCtlCommand(PHANDLE, SHyprCtlCommand{"glassopt", false, [](eHyprCtlOutputFormat, std::string request) -> std::string {
        // `hyprctl glassopt`            -> report
        // `hyprctl glassopt region off` -> full-screen blur again
        // `hyprctl glassopt shared off` -> one blur per element again
        auto        args = CVarList(request, 0, ' ');
        std::string key = args.size() > 1 ? args[1] : "", val = args.size() > 2 ? args[2] : "";

        if (key == "values") {
            std::string out;
            for (const auto& [NAME, V] : g_uniformValues) {
                out += "  " + NAME + " =";
                for (float f : V)
                    out += std::format(" {:.4f}", f);
                out += "\n";
            }
            return out.empty() ? "no uniforms received\n" : out;
        }

        if (!key.empty() && !val.empty()) {
            const bool ON = (val == "on" || val == "1" || val == "true");
            if (key == "gate")
                g_optGate = ON;
            else if (key == "scale")
                g_capScale = std::clamp((float)std::atof(val.c_str()), 0.25F, 1.F);
            else
                return "unknown option '" + key + "' (expected: gate, scale)\n";
        }

        std::string rects;
        for (const auto& [ID, R] : g_rects)
            rects += std::format("    {} [{}] {:.0f},{:.0f} {:.0f}x{:.0f} r={:.0f}  draws={}\n", ID, R.ns, R.rect.x, R.rect.y, R.rect.w, R.rect.h, R.radius, g_drawsByPanel[ID]);
        return std::format("glass options:\n  ordering: {}\n  draws since load: {}\n  gate (redraw only when damage touches a panel): {}\n  scale (capture resolution): {:.2f}\n  material uniforms received: {}\n  panels:\n{}",
                           g_renderLayerHook ? "per-surface (renderLayer hook)" : "stage fallback", g_drawCount, g_optGate ? "on" : "off", g_capScale, g_uniformValues.size(), rects.empty() ? "    (none -- is the shell sending glassrect?)\n" : rects);
    }});

    // The shell sends each glass panel's rect through this.
    //
    //   hyprctl glassrect <id> <namespace> <x> <y> <w> <h> <radius>
    //   hyprctl glassrect <id> remove
    //
    // x/y/w/h are logical px relative to the layer surface's own origin;
    // radius < 0 means "use the global maxCornerRadius uniform".
    HyprlandAPI::registerHyprCtlCommand(PHANDLE, SHyprCtlCommand{"glassrect", false, [](eHyprCtlOutputFormat, std::string request) -> std::string {
        auto args = CVarList(request, 0, ' ');
        if (args.size() >= 3 && args[2] == "remove") {
            if (const auto IT = g_rects.find(args[1]); IT != g_rects.end()) {
                damageRect(IT->second);
                g_rects.erase(IT);
            }
            return "removed\n";
        }
        // `glassrect reset <session>`: drop every rect NOT owned by <session>.
        //
        // A shell that is killed never gets to send its `remove`s, so its rects
        // would otherwise live on here as ghosts, drawing glass at stale
        // positions -- and a restarted shell then adds a second copy of each,
        // which draws the material twice in one spot and captures its own
        // first pass. Each shell sends this once on startup; rect ids are
        // prefixed "<session>:".
        if (args.size() >= 3 && args[1] == "reset") {
            const std::string PREFIX = args[2] + ":";
            size_t            dropped = 0;
            for (auto it = g_rects.begin(); it != g_rects.end();) {
                if (!it->first.starts_with(PREFIX)) {
                    damageRect(it->second);
                    it = g_rects.erase(it);
                    ++dropped;
                } else
                    ++it;
            }
            return std::format("reset: dropped {} rect(s) from other sessions\n", dropped);
        }
        if (args.size() < 8)
            return "usage: hyprctl glassrect <id> <namespace> <x> <y> <w> <h> <radius> | <id> remove\n";
        SGlassRect r;
        r.ns     = args[2];
        r.rect   = CBox{std::atof(args[3].c_str()), std::atof(args[4].c_str()), std::atof(args[5].c_str()), std::atof(args[6].c_str())};
        r.radius = (float)std::atof(args[7].c_str());
        if (const auto IT = g_rects.find(args[1]); IT != g_rects.end())
            damageRect(IT->second); // where it was
        g_rects[args[1]] = r;
        damageRect(r); // where it is now
        return "ok\n";
    }});

    // The shell pushes the material's look uniforms in through this.
    //
    //   hyprctl glassuniform power 17.5
    //   hyprctl glassuniform tint 0.8 0.7 0.9 0.35
    //
    // Names are the shader's own; values are 1-4 floats. Nothing is hardcoded
    // on this side -- whatever the .frag declares and the shell sends gets
    // applied (see applyUniformValues), so adding a uniform to the material
    // needs no plugin change.
    HyprlandAPI::registerHyprCtlCommand(PHANDLE, SHyprCtlCommand{"glassuniform", false, [](eHyprCtlOutputFormat, std::string request) -> std::string {
        auto args = CVarList(request, 0, ' ');
        if (args.size() < 3)
            return "usage: hyprctl glassuniform <name> <v> [v v v]\n";
        std::vector<float> vals;
        for (size_t i = 2; i < args.size() && vals.size() < 4; ++i) {
            if (!args[i].empty())
                vals.push_back((float)std::atof(args[i].c_str()));
        }
        if (vals.empty())
            return "no values\n";
        g_uniformValues[args[1]] = vals;
        for (const auto& [ID, R] : g_rects)
            damageRect(R);
        return std::format("{} = {} value(s)\n", args[1], vals.size());
    }});

    // Install the per-surface hook. Match the member function by its demangled
    // name; if it is missing or ambiguous (a Hyprland update changed it), leave
    // g_renderLayerHook null and the stage-based fallback carries on as before.
    {
        const auto FNS   = HyprlandAPI::findFunctionsByName(PHANDLE, "renderLayer");
        void*      FOUND = nullptr;
        int        hits  = 0;
        for (const auto& F : FNS) {
            if (F.demangled.contains("IHyprRenderer::renderLayer(")) {
                FOUND = F.address;
                ++hits;
            }
        }
        if (hits == 1) {
            g_renderLayerHook = HyprlandAPI::createFunctionHook(PHANDLE, FOUND, (void*)&hkRenderLayer);
            if (g_renderLayerHook && !g_renderLayerHook->hook())
                g_renderLayerHook = nullptr;
        }
        Log::logger->log(Log::INFO, "[glass] renderLayer hook: {} ({} candidate(s))", g_renderLayerHook ? "installed" : "NOT installed, using stage fallback", hits);
    }

    // Announce ourselves. Everything this plugin draws comes from state the
    // shell pushes (rects, uniforms), and a freshly loaded plugin starts with
    // none of it -- so without this, any plugin reload left the screen with no
    // glass until the shell happened to restart. Arrives in Quickshell as
    // Hyprland.rawEvent, name "glassplugin".
    g_pEventManager->postEvent(SHyprIPCEvent{"glassplugin", "loaded"});

    HyprlandAPI::addNotification(PHANDLE, "[glass4] loaded", CHyprColor{0.2, 1.0, 0.2, 1.0}, 3000);
    return {"glass4", "layer-shaped glass via alpha silhouette", "brolli", "0.1"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    g_renderListener.reset();
    if (g_pHyprRenderer)
        g_pHyprRenderer->m_renderPass.removeAllOfType("CGlassElement");
    Log::logger->log(Log::INFO, "[glass4] unloaded");
}
