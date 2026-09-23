// Compositor-side liquid glass for Quickshell layer surfaces.
//
// The shell draws no glass: it sends the plugin each panel's rect
// (hyprctl glassrect) and the material's uniforms (hyprctl glassuniform), and
// the plugin draws the material under that surface, mid-frame.
//
// No blur. The look is Apple's Liquid Glass: transparent and refractive, the
// character coming from lensing at the edges. So the backdrop is sampled
// SHARP -- a glBlitFramebuffer straight out of the framebuffer this frame is
// being composited into (ShojiWM's technique), not Hyprland's own blur, which
// only exists when decoration:blur is on and uses the user's radius.
//
// Nothing in Hyprland is patched; this is a plugin with two hooks into it:
// renderLayer (to queue glass immediately under each surface) and the render
// stage bus (frame bookkeeping).
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/PassElement.hpp>
#include <hyprland/src/render/Texture.hpp>
#include <hyprland/src/debug/log/Logger.hpp>
#include <hyprland/src/managers/EventManager.hpp>
#include <hyprland/src/managers/SessionLockManager.hpp>
#include <hyprland/src/helpers/time/Time.hpp>
#include <hyprland/src/desktop/state/LayerState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/Popup.hpp>
#include <hyprland/protocols/wlr-layer-shell-unstable-v1.hpp> // ZWLR_LAYER_SHELL_V1_LAYER_* (layer levels)
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <hyprland/src/config/ConfigValue.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <unordered_set>
#include <GLES3/gl32.h>
#include <algorithm>
#include <cmath>
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
// The compositor only knows a layer's BOX, which is not the glass: the dock's
// layer is the full-width strip while its glass is a centred pill. Only the
// shell knows the real rect, so it sends it, in the layer's own logical
// coordinates, keyed by an id so one layer can carry several panels.
struct SGlassRect {
    std::string ns;
    CBox        rect;          // layer-local, logical px
    float       radius = -1.F; // per-panel maxCornerRadius; <0 = the global value
    // Which way the material's readability layer pushes this panel: +1 when
    // its text is dark (push the glass lighter), -1 when light (darker). From
    // the shell's own text-colour decision (GlassSample), sent with the rect.
    float       dir = -1.F;
};
static std::unordered_map<std::string, SGlassRect> g_rects;

// Damage one panel's padded area wherever its layer is mapped.
//
// A panel is only redrawn when damage touches it, and two things change the
// glass without producing any: new uniform values (a settings slider), and a
// rect update that lands after the surface's last repaint. Both are real
// one-off changes, so scheduling a frame here is correct.
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
// Per-panel overrides, by layer namespace: `glassuniform tint@quickshell:macDock
// ...` sets `tint` for the dock only. Applied after the global values, so a
// panel without an override keeps the global one.
static std::unordered_map<std::string, std::unordered_map<std::string, std::vector<float>>> g_nsUniformValues;

// Set every uniform the linked program actually declares, from the map above.
// Introspected rather than hardcoded, so a uniform added to the .frag needs no
// change here -- only that the shell starts sending it.
static void applyUniformValues(GLuint prog, const std::unordered_map<std::string, std::vector<float>>& values = g_uniformValues) {
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
        const auto IT = values.find(std::string(name, len));
        if (IT == values.end())
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
static GLuint g_capFbo = 0, g_capTex = 0;

// ---- panel statistics for the readability layer ----
// One average per PANEL, never per pixel: per-pixel floors (the original
// material's luma/busyness floor) change strength at text-stroke scale and
// striped busy backdrops ("zebra"). A small pass writes (luma, luma^2) of the
// backdrop capture over the panel; the GPU averages it down its mip chain to
// one texel -- mean brightness and, via E[l^2]-E[l]^2, its spread. The
// material reads that texel (texelFetch at the top level); no CPU readback.
// Runs only when the active material declares `panelStats`.
static const char* STATS_FRAG = R"(#version 300 es
precision highp float;
in vec2 qt_TexCoord0;
out vec4 fragColor;
uniform sampler2D source;
uniform vec2  panelSize;
uniform vec2  texSize;
uniform float pad;
uniform vec2  gridSize;   // the stats texture's size, texels
void main() {
    // This texel's patch of the panel, sampled on an even 4x4 grid across the
    // whole patch -- so the average is taken over the panel's full area at
    // any panel size, and grows smoothly as the panel does.
    vec2  cell = panelSize / gridSize;
    vec2  c    = vec2(pad) + qt_TexCoord0 * panelSize;
    float s = 0.0, s2 = 0.0;
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            vec2  o = (vec2(float(i), float(j)) + 0.5) / 4.0 - 0.5;
            float l = dot(texture(source, (c + o * cell) / texSize).rgb, vec3(0.299, 0.587, 0.114));
            s += l;
            s2 += l * l;
        }
    }
    fragColor = vec4(s / 16.0, s2 / 16.0, 0.0, 1.0);
}
)";
static GLuint g_statsProg = 0, g_statsTex = 0, g_statsFbo = 0;
static int    g_statsW = 0, g_statsH = 0, g_statsLevels = 0;
// Half-float, not RGBA8: busyness is sqrt(E[l^2] - E[l]^2), a difference of
// two near-equal numbers. At 8 bits each is only good to ~1/255, and through
// the sqrt that became busyness jumps of up to ~0.35 whenever the panel
// changed size -- a visible flicker of the squash while Spotlight expanded.
// Falls back to RGBA8 if the driver will not render to RGBA16F.
static bool   g_statsFloat = true;

// Each panel's busyness, reported to the shell (glassstats>><rect id>,<0..1>)
// so things drawn ON the glass -- Spotlight's chips -- can strengthen with
// the squash. Same formula as the shader. Read at most every 100ms per panel
// and posted only on a change of >= 0.02.
struct SStatsReport {
    Time::steady_tp last{};
    float           busy = -1.F;
};
static std::unordered_map<std::string, SStatsReport> g_statsReports;
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
    if (g_capTex)
        glDeleteTextures(1, &g_capTex);
    glGenTextures(1, &g_capTex);
    glBindTexture(GL_TEXTURE_2D, g_capTex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    g_capW = w, g_capH = h;
    Log::logger->log(Log::INFO, "[brolli-glass] capture texture {}x{}", w, h);
}
static GLint  uBackdrop = -1, aPos = -1;
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
        Log::logger->log(Log::ERR, "[brolli-glass] shader compile failed: {}", log);
        glDeleteShader(s);
        return 0;
    }
    return s;
}

static GLint       aUv = -1;
// Read from disk, so tuning the material needs a plugin reload, not a rebuild.
static std::string g_shaderPath = "/home/Joel/Projects/Brolli-Glass/plugin/src/brolliglass.frag";

static GLuint link(const char* vertSrc, const std::string& fragSrc, const char* label) {
    GLuint v = compile(GL_VERTEX_SHADER, vertSrc), f = compile(GL_FRAGMENT_SHADER, fragSrc.c_str());
    if (!v || !f)
        return 0;
    GLuint prog = glCreateProgram();
    glAttachShader(prog, v);
    glAttachShader(prog, f);
    // Pin attribute locations before linking. With more than one material
    // program, the compiler is free to assign `pos`/`uv` differently in each,
    // and the draw path sets them up once -- so they must agree.
    glBindAttribLocation(prog, 0, "pos");
    glBindAttribLocation(prog, 1, "uv");
    glLinkProgram(prog);
    GLint ok = 0;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    glDeleteShader(v);
    glDeleteShader(f);
    if (!ok) {
        char log[4096];
        glGetProgramInfoLog(prog, sizeof(log), nullptr, log);
        Log::logger->log(Log::ERR, "[brolli-glass] {} link failed: {}", label, log);
        glDeleteProgram(prog);
        return 0;
    }
    return prog;
}

static bool ensureProgram() {
    if (g_prog)
        return true;

    const std::string SRC = readShaderFile(g_shaderPath);
    if (SRC.empty()) {
        Log::logger->log(Log::ERR, "[brolli-glass] no material at {}", g_shaderPath);
        return false;
    }

    g_prog = link(VERT, SRC, "material");
    if (!g_prog)
        return false;
    g_statsProg = link(VERT, STATS_FRAG, "panel stats");

    uBackdrop = glGetUniformLocation(g_prog, "source");
    aPos      = glGetAttribLocation(g_prog, "pos");
    aUv       = glGetAttribLocation(g_prog, "uv");
    glGenBuffers(1, &g_vbo);
    Log::logger->log(Log::INFO, "[brolli-glass] material loaded from {} ({} bytes)", g_shaderPath, SRC.size());
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

        // Draw where the surface after us draws. Hyprland renders a workspace
        // into a smaller box (Hyprtasking's overview tiles; renderWorkspace with
        // a scaled geometry) by putting a translate/scale render modifier in the
        // pass, which every later element applies to its own box. Surfaces get
        // it inside the texture draw; this element is plain GL, so it has to
        // apply it itself -- otherwise the glass lands full-size at the panel's
        // desktop position, on top of the overview.
        CBox  box      = m_box;
        float modScale = 1.F;
        auto& MODIF    = g_pHyprRenderer->m_renderData.renderModif;
        if (MODIF.enabled && !MODIF.modifs.empty()) {
            MODIF.applyToBox(box);
            modScale = MODIF.combinedScale();
        }

        // Padding around the visible box: refraction samples outside the shape,
        // and a capture smaller than that reach clamps at its edge and smears.
        const float PAD = kPadPx;

        // The capture's ORIGIN is always exactly PAD above and left of the panel,
        // even when that lands off-screen. The material locates the panel inside
        // the texture with a single `vec2(pad)` offset (toTex), so clamping the
        // origin to the screen edge would shift every sample for a panel near
        // the top or left. Instead only the on-screen part is copied, at its
        // correct offset, and whatever lies off-screen stays cleared.
        const float ux0 = (float)box.x - PAD, uy0 = (float)box.y - PAD;
        const float UW  = (float)box.width + PAD * 2.F, UH = (float)box.height + PAD * 2.F;
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
        const float bx = box.x, by = box.y, bw = box.width, bh = box.height;

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

        // Glass on glass: this panel sits over glass already drawn this frame
        // (the menubar's dropdowns hang over the desktop widgets), so its
        // backdrop is ALREADY bent, blurred and tinted. Apple's guidance is not
        // to stack the material -- "avoid applying the material to both
        // layers... double translucency, layered blur" -- so the top one drops
        // its own softening. One value for the whole panel: no seams.
        const bool OVER_GLASS = !g_frameGlassRegion.copy().intersect(box).empty();

        const GLuint PROG = g_prog;

        // ---- panelStats: backdrop mean + spread, for the readability layer ----
        const GLint UPANELSTATS = glGetUniformLocation(PROG, "panelStats");
        GLint       prevTex2    = 0;
        if (UPANELSTATS >= 0 && g_statsProg) {
            // FIXED grid, not sized from the panel. It used to be
            // pow2(panel / 4): while Spotlight expanded, that jumped
            // 32 -> 64 -> 128 rows, the sampled points changed all at once
            // and the measured busyness -- so the squash -- flickered.
            const int TW = 64, TH = 64;
            if (TW != g_statsW || TH != g_statsH || !g_statsTex) {
                if (g_statsTex)
                    glDeleteTextures(1, &g_statsTex);
                if (!g_statsFbo)
                    glGenFramebuffers(1, &g_statsFbo);
                glActiveTexture(GL_TEXTURE2);
                glGenTextures(1, &g_statsTex);
                glBindTexture(GL_TEXTURE_2D, g_statsTex);
                g_statsLevels = (int)std::floor(std::log2((float)std::max(TW, TH))) + 1;
                glTexStorage2D(GL_TEXTURE_2D, g_statsLevels, g_statsFloat ? GL_RGBA16F : GL_RGBA8, TW, TH);
                g_statsW = TW;
                g_statsH = TH;
            }
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g_statsFbo);
            glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, g_statsTex, 0);
            if (g_statsFloat && glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
                Log::logger->log(Log::WARN, "[brolli-glass] RGBA16F not renderable here; panel stats fall back to RGBA8");
                g_statsFloat = false;
                glDeleteTextures(1, &g_statsTex);
                glGenTextures(1, &g_statsTex);
                glActiveTexture(GL_TEXTURE2);
                glBindTexture(GL_TEXTURE_2D, g_statsTex);
                glTexStorage2D(GL_TEXTURE_2D, g_statsLevels, GL_RGBA8, TW, TH);
                glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, g_statsTex, 0);
            }
            glViewport(0, 0, TW, TH);
            glDisable(GL_BLEND);
            glUseProgram(g_statsProg);
            glEnableVertexAttribArray(0);
            glEnableVertexAttribArray(1);
            const float FULL[24] = {-1, -1, 0, 0, 1, -1, 1, 0, 1, 1, 1, 1, -1, -1, 0, 0, 1, 1, 1, 1, -1, 1, 0, 1};
            glBufferData(GL_ARRAY_BUFFER, sizeof(FULL), FULL, GL_STREAM_DRAW);
            glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), nullptr);
            glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)(2 * sizeof(float)));
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D, g_capTex);
            glUniform1i(glGetUniformLocation(g_statsProg, "source"), 0);
            glUniform2f(glGetUniformLocation(g_statsProg, "panelSize"), bw, bh);
            glUniform2f(glGetUniformLocation(g_statsProg, "texSize"), CAPW, CAPH);
            glUniform1f(glGetUniformLocation(g_statsProg, "pad"), PAD);
            glUniform2f(glGetUniformLocation(g_statsProg, "gridSize"), (float)TW, (float)TH);
            glDrawArrays(GL_TRIANGLES, 0, 6);
            glActiveTexture(GL_TEXTURE2);
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &prevTex2);
            glBindTexture(GL_TEXTURE_2D, g_statsTex);
            glGenerateMipmap(GL_TEXTURE_2D);

            // Report this panel's busyness to the shell (see SStatsReport).
            auto&      REP = g_statsReports[m_id];
            const auto NOW = Time::steadyNow();
            if (NOW - REP.last >= std::chrono::milliseconds(100)) {
                REP.last = NOW;
                glBindFramebuffer(GL_READ_FRAMEBUFFER, g_statsFbo);
                glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, g_statsTex, g_statsLevels - 1);
                GLint prevPack = 0;
                glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &prevPack);
                glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
                float mean = 0.F, meanSq = 0.F;
                if (g_statsFloat) {
                    float px[4] = {0, 0, 0, 0};
                    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_FLOAT, px);
                    mean   = px[0];
                    meanSq = px[1];
                } else {
                    uint8_t px[4] = {0, 0, 0, 0};
                    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
                    mean   = px[0] / 255.F;
                    meanSq = px[1] / 255.F;
                }
                glBindBuffer(GL_PIXEL_PACK_BUFFER, prevPack);
                glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, g_statsTex, 0);
                glBindFramebuffer(GL_READ_FRAMEBUFFER, prevReadFbo);
                const float BUSY = std::clamp(std::sqrt(std::max(meanSq - mean * mean, 0.F)) / 0.25F, 0.F, 1.F);
                if (REP.busy < 0.F || std::abs(BUSY - REP.busy) >= 0.02F) {
                    REP.busy = BUSY;
                    g_pEventManager->postEvent(SHyprIPCEvent{"glassstats", std::format("{},{:.3f}", m_id, BUSY)});
                }
            }
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prevDrawFbo);
            glViewport(0, 0, (GLint)SW, (GLint)SH);
        }

        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

        glUseProgram(PROG);
        glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STREAM_DRAW);
        glEnableVertexAttribArray(aPos);
        glEnableVertexAttribArray(aUv);
        glVertexAttribPointer(aPos, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), nullptr);
        glVertexAttribPointer(aUv, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)(2 * sizeof(float)));

        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, g_capTex);
        glUniform1i(glGetUniformLocation(PROG, "source"), 0);

        glUniform2f(glGetUniformLocation(PROG, "panelSize"), bw, bh);
        glUniform2f(glGetUniformLocation(PROG, "texSize"), CAPW, CAPH);
        glUniform1f(glGetUniformLocation(PROG, "pad"), PAD);
        applyUniformValues(PROG); // everything else: the shell's values
        // ...then this panel's own overrides, if the shell sent any.
        if (const auto R = g_rects.find(m_id); R != g_rects.end()) {
            if (const auto NS = g_nsUniformValues.find(R->second.ns); NS != g_nsUniformValues.end())
                applyUniformValues(PROG, NS->second);
        }
        // The one uniform that differs per panel in the original material: the
        // dock is uncapped, Spotlight caps its corners at spotlightMaxCornerRadius.
        // Scaled with the panel under a render modifier (see above).
        if (m_radius >= 0.F)
            glUniform1f(glGetUniformLocation(PROG, "maxCornerRadius"), m_radius * modScale);
        else if (modScale != 1.F) {
            const auto IT = g_uniformValues.find("maxCornerRadius");
            if (IT != g_uniformValues.end() && !IT->second.empty())
                glUniform1f(glGetUniformLocation(PROG, "maxCornerRadius"), IT->second[0] * modScale);
        }

        if (UPANELSTATS >= 0 && g_statsProg) {
            glActiveTexture(GL_TEXTURE2);
            glBindTexture(GL_TEXTURE_2D, g_statsTex);
            glUniform1i(UPANELSTATS, 2);
            glUniform1i(glGetUniformLocation(PROG, "panelStatsLevel"), g_statsLevels - 1);
            const auto R = g_rects.find(m_id);
            glUniform1f(glGetUniformLocation(PROG, "glassDir"), R != g_rects.end() ? R->second.dir : -1.F);
        }

        glUniform1f(glGetUniformLocation(PROG, "glassOverGlass"), OVER_GLASS ? 1.F : 0.F);

        glDrawArrays(GL_TRIANGLES, 0, 6);
        g_frameGlassRegion.add(box);

        glDisableVertexAttribArray(aPos);
        glDisableVertexAttribArray(aUv);
        if (UPANELSTATS >= 0 && g_statsProg) {
            glActiveTexture(GL_TEXTURE2);
            glBindTexture(GL_TEXTURE_2D, prevTex2);
        }
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


// Where one panel is this frame, in monitor-physical px: the shell's rect placed
// inside its layer's animated CURRENT position (not the arranged target).
static CBox panelBox(const PHLLS& LS, const SGlassRect& R, const PHLMONITOR& PMONITOR) {
    const Vector2D POS   = LS->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
    const float    SCALE = PMONITOR->m_scale;
    const CBox     LOGICAL{POS.x + R.rect.x, POS.y + R.rect.y, R.rect.w, R.rect.h};
    return CBox{(LOGICAL.x - PMONITOR->m_position.x) * SCALE, (LOGICAL.y - PMONITOR->m_position.y) * SCALE, LOGICAL.w * SCALE, LOGICAL.h * SCALE};
}

// How far outside its panel the material ever reads. This, not the capture
// padding, decides whether a nearby change can affect the glass.
//
// The material only pulls INWARD, so the only outside reads are the softening
// taps (+-2 x blur) and the colour split (+- chroma). Using the full 48px
// padding instead had a terminal 6px clear of the dock redrawing it ~24
// times a second.
static float uniformOr(const char* name, float fallback) {
    const auto IT = g_uniformValues.find(name);
    return IT == g_uniformValues.end() || IT->second.empty() ? fallback : IT->second[0];
}
static float materialReachPx() {
    const float AA_AND_FILTER_PX = 2.F; // edge anti-aliasing + bilinear tap
    const float REACH = 2.F * std::abs(uniformOr("aghBlur", 1.2F)) + std::abs(uniformOr("aghChroma", 3.F)) + AA_AND_FILTER_PX;
    return std::clamp(REACH, AA_AND_FILTER_PX, kPadPx);
}

// The panel plus the material's reach: changes here can alter its glass.
static CBox paddedBox(const CBox& b) {
    const float R = materialReachPx();
    return CBox{b.x - R, b.y - R, b.w + R * 2.F, b.h + R * 2.F};
}

// Where a rect is this frame, if it belongs to this layer at all.
//
// A namespace is either the layer's own, placing the rect relative to the
// layer surface, or "popup:" + the layer's, placing it in that layer's open
// xdg-popup (the menubar dropdowns are popups, drawn in renderLayer's separate
// popups pass -- hence popupPass). Only the compositor knows where a popup
// lands after edge-sliding, so its position comes from coordsGlobal().
static std::optional<CBox> resolveBox(const PHLLS& LS, const SGlassRect& R, const PHLMONITOR& PMONITOR, bool popupPass) {
    if (!popupPass)
        return R.ns == LS->m_namespace ? std::optional<CBox>{panelBox(LS, R, PMONITOR)} : std::nullopt;
    if (!R.ns.starts_with("popup:") || R.ns.substr(6) != LS->m_namespace || !LS->m_popupHead)
        return std::nullopt;
    std::optional<Vector2D> found;
    LS->m_popupHead->breadthfirst(
        [&R, &found, &LS](SP<Desktop::View::CPopup> P, void*) {
            if (found || !P || P == LS->m_popupHead || !P->visible() || !P->wlSurface() || !P->wlSurface()->resource())
                return;
            const Vector2D SZ = P->size();
            if (R.rect.x + R.rect.w <= SZ.x + 1.0 && R.rect.y + R.rect.h <= SZ.y + 1.0)
                found = P->coordsGlobal();
        },
        nullptr);
    if (!found)
        return std::nullopt;
    const float SCALE = PMONITOR->m_scale;
    return CBox{(found->x + R.rect.x - PMONITOR->m_position.x) * SCALE, (found->y + R.rect.y - PMONITOR->m_position.y) * SCALE, R.rect.w * SCALE, R.rect.h * SCALE};
}

// ---- backdrop colour samples (adaptive text) ----
//
// The shell picks black or white text from the colour behind it, and only the
// plugin can see that now. Regions are registered like glass rects
// (hyprctl glasssample <id> <ns> x y w h | <id> remove | reset <session>) and
// the measured colour is posted back as glasssample>><id>,<r>,<g>,<b>.
//
// Measured just before the region's own layer draws: for a glass panel that is
// the finished glass, since its glass is queued first. The region is copied to
// a small texture, averaged down its mip chain to one pixel, and read back.
// Only when damage touches it, at most every kSampleInterval, posted only on
// a change.
struct SSample {
    SGlassRect      r; // ns + layer-local logical rect (radius unused)
    GLuint          tex = 0, fbo = 0;
    int             tw = 0, th = 0, levels = 0;
    Time::steady_tp last{};
    bool            pending = true; // needs a fresh measurement
    bool            have    = false;
    int             cr = 0, cg = 0, cb = 0;
};
static std::unordered_map<std::string, SSample> g_samples;
static std::unordered_set<std::string>          g_frameSamples; // decided at RENDER_BEGIN
static std::vector<GLuint>                      g_deadSampleTex, g_deadSampleFbo;
static SP<CEventLoopTimer>                      g_sampleTimer;
static constexpr auto                           kSampleInterval = std::chrono::milliseconds(100);
// Each monitor's NEW damage this frame (getBufferDamage(1) = the ring's
// m_current alone), snapshotted at RENDER_PRE before beginRender rotates the
// ring. Samples trigger on this, never on the frame's full damage: that also
// carries the buffer-age repair, which replays the previous 2-3 frames'
// damage -- so the trailing-sample timer fed itself and ran the whole screen
// at ~63 fps, ~10% GPU idle (2026-09-22).
static std::unordered_map<const Monitor::CMonitor*, CRegion> g_newDamage;

static void damageSample(const SGlassRect& r) {
    for (const auto& LS : Desktop::layerState()->layers()) {
        if (!LS || !LS->m_mapped || LS->m_namespace != r.ns)
            continue;
        const Vector2D POS = LS->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT);
        g_pHyprRenderer->damageBox(CBox{POS.x + r.rect.x, POS.y + r.rect.y, r.rect.w, r.rect.h});
    }
}

// One-shot: a region changed inside the rate limit, so its final colour has
// not been measured. Ask for one more frame once the limit has passed. Not a
// loop -- that frame measures it and clears `pending`.
static void armSampleTimer(Time::steady_dur delay) {
    if (!g_sampleTimer) {
        g_sampleTimer = makeShared<CEventLoopTimer>(std::nullopt, [](SP<CEventLoopTimer>, void*) {
            for (auto& [ID, S] : g_samples) {
                if (S.pending)
                    damageSample(S.r);
            }
        }, nullptr);
        g_pEventLoopManager->addTimer(g_sampleTimer);
    }
    if (!g_sampleTimer->armed() || g_sampleTimer->leftUs() > std::chrono::duration_cast<std::chrono::microseconds>(delay).count())
        g_sampleTimer->updateTimeout(delay);
}

class CSampleElement : public IPassElement {
  public:
    CSampleElement(const CBox& box, const std::string& id) : m_box(box), m_id(id) {}
    virtual ~CSampleElement() = default;
    virtual bool needsLiveBlur() {
        return false;
    }
    virtual bool needsPrecomputeBlur() {
        return false;
    }
    virtual bool undiscardable() {
        return true; // its box is in the damage anyway; never drop a measurement
    }
    virtual const char* passName() {
        return "CSampleElement";
    }
    virtual ePassElementType type() {
        return EK_CUSTOM;
    }
    virtual std::optional<CBox> boundingBox() {
        return std::nullopt;
    }
    virtual std::vector<UP<IPassElement>> draw() {
        const auto IT = g_samples.find(m_id);
        if (IT == g_samples.end())
            return {};
        auto& S = IT->second;

        for (GLuint t : g_deadSampleTex)
            glDeleteTextures(1, &t);
        for (GLuint f : g_deadSampleFbo)
            glDeleteFramebuffers(1, &f);
        g_deadSampleTex.clear();
        g_deadSampleFbo.clear();

        // Inside a scaled render (overview tiles) the region is not where the
        // box says; measure on the next normal frame instead.
        const auto& MODIF = g_pHyprRenderer->m_renderData.renderModif;
        if (MODIF.enabled && !MODIF.modifs.empty()) {
            return {};
        }
        const auto PMONITOR = g_pHyprRenderer->m_renderData.pMonitor;
        if (!PMONITOR)
            return {};
        const float SW = PMONITOR->m_transformedSize.x, SH = PMONITOR->m_transformedSize.y;
        const float X0 = std::max(0.F, (float)m_box.x), Y0 = std::max(0.F, (float)m_box.y);
        const float X1 = std::min(SW, (float)(m_box.x + m_box.w)), Y1 = std::min(SH, (float)(m_box.y + m_box.h));
        if (X1 - X0 < 1.F || Y1 - Y0 < 1.F) {
            return {};
        }

        // Copy at up to 2:1 so the average is over (nearly) every pixel, not a
        // sparse subset -- a GL_LINEAR blit only reads 2x2 per output texel.
        auto pow2 = [](float v) { int p = 1; while (p < (int)std::ceil(v) && p < 2048) p <<= 1; return p; };
        const int TW = pow2((X1 - X0) / 2.F), TH = pow2((Y1 - Y0) / 2.F);
        if (TW != S.tw || TH != S.th || !S.tex) {
            if (S.tex)
                glDeleteTextures(1, &S.tex);
            if (!S.fbo)
                glGenFramebuffers(1, &S.fbo);
            GLint prevTex = 0;
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &prevTex);
            glGenTextures(1, &S.tex);
            glBindTexture(GL_TEXTURE_2D, S.tex);
            S.levels = (int)std::floor(std::log2((float)std::max(TW, TH))) + 1;
            glTexStorage2D(GL_TEXTURE_2D, S.levels, GL_RGBA8, TW, TH);
            glBindTexture(GL_TEXTURE_2D, prevTex);
            S.tw = TW;
            S.th = TH;
        }

        GLint prevDraw = 0, prevRead = 0, prevTex = 0, prevPack = 0;
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevDraw);
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prevRead);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &prevTex);
        glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &prevPack);
        const GLboolean prevScissor = glIsEnabled(GL_SCISSOR_TEST);
        glDisable(GL_SCISSOR_TEST);

        glBindFramebuffer(GL_READ_FRAMEBUFFER, prevDraw);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, S.fbo);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, S.tex, 0);
        glBlitFramebuffer((GLint)X0, (GLint)Y0, (GLint)X1, (GLint)Y1, 0, 0, TW, TH, GL_COLOR_BUFFER_BIT, GL_LINEAR);

        glBindTexture(GL_TEXTURE_2D, S.tex);
        glGenerateMipmap(GL_TEXTURE_2D);

        glBindFramebuffer(GL_READ_FRAMEBUFFER, S.fbo);
        glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, S.tex, S.levels - 1);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        uint8_t px[4] = {0, 0, 0, 0};
        glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);

        glBindBuffer(GL_PIXEL_PACK_BUFFER, prevPack);
        glBindTexture(GL_TEXTURE_2D, prevTex);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, prevRead);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prevDraw);
        if (prevScissor)
            glEnable(GL_SCISSOR_TEST);

        S.last    = Time::steadyNow();
        S.pending = false;
        const bool CHANGED = !S.have || std::abs(px[0] - S.cr) >= 3 || std::abs(px[1] - S.cg) >= 3 || std::abs(px[2] - S.cb) >= 3;
        if (CHANGED) {
            S.have = true;
            S.cr   = px[0];
            S.cg   = px[1];
            S.cb   = px[2];
            g_pEventManager->postEvent(SHyprIPCEvent{"glasssample", std::format("{},{},{},{}", m_id, S.cr, S.cg, S.cb)});
        }
        return {};
    }

  private:
    CBox        m_box;
    std::string m_id;
};

// ---- which panels to draw this frame ----
//
// Decided once per frame at RENDER_BEGIN, for every panel on the monitor
// together, because deciding panel by panel at queue time left "cut-outs":
// CRenderPass::render grows the damage by 2.5 x oneBlurRadius around every
// live-blur element (ours are) AFTER everything is queued, repainting the
// wallpaper there even with blur disabled. At blur size 10 / 3 passes that is
// 200px, and the widgets are 16px apart, so drawing one wiped the glass off a
// skipped neighbour (measured 363 times; 0 after this).
//
// A panel is drawn if damage touches its padded box, or it lies inside that
// late growth around a panel already being drawn -- repeated until the set
// stops growing. With Hyprland's blur on, damaged blurred windows grow the
// same way, so the damage itself is widened before testing.
static std::unordered_set<std::string> g_frameDraw;
static bool                            g_frameDrawValid = false;

static float lateBlurGrowth() {
    // CRenderPass::oneBlurRadius() is private; same formula (Pass.cpp:313).
    static auto PBLURSIZE   = CConfigValue<Config::INTEGER>("decoration:blur:size");
    static auto PBLURPASSES = CConfigValue<Config::INTEGER>("decoration:blur:passes");
    const auto  PASSES      = std::clamp(*PBLURPASSES, (int64_t)1, (int64_t)8);
    const float ONE         = std::clamp(*PBLURSIZE, (int64_t)1, (int64_t)40) * std::pow(2.F, (float)PASSES);
    return ONE * 2.5F; // expand(one) into finalDamage, then expand(one * 1.5)
}

static void computeFrameDrawSet(const PHLMONITOR& PMONITOR) {
    static auto PBLUR = CConfigValue<Config::INTEGER>("decoration:blur:enabled");

    g_frameDraw.clear();
    g_frameSamples.clear();
    g_frameDrawValid = true;
    if (!PMONITOR)
        return;

    // Colour samples first: a sample adds its region to this frame's damage
    // (so it measures fresh pixels), and that has to be known before the glass
    // decision below, or it would repaint over a skipped glass panel.
    CRegion    sampleBoxes;
    const auto NOW = Time::steadyNow();
    for (const auto& LEVEL : PMONITOR->m_layerSurfaceLayers) {
        for (const auto& REF : LEVEL) {
            const auto LS = REF.lock();
            if (!LS || !LS->m_mapped || LS->m_monitor.get() != PMONITOR.get())
                continue;
            for (auto& [ID, S] : g_samples) {
                auto OPT = resolveBox(LS, S.r, PMONITOR, false);
                if (!OPT)
                    OPT = resolveBox(LS, S.r, PMONITOR, true);
                if (!OPT)
                    continue;
                const CBox BOX = *OPT;
                if (const auto ND = g_newDamage.find(PMONITOR.get()); ND != g_newDamage.end() && !ND->second.copy().intersect(BOX).empty())
                    S.pending = true;
                if (!S.pending)
                    continue;
                const auto SINCE = NOW - S.last;
                if (SINCE < kSampleInterval) {
                    armSampleTimer(kSampleInterval - SINCE);
                    continue;
                }
                g_frameSamples.insert(ID);
                sampleBoxes.add(BOX);
            }
        }
    }

    // Glass hidden behind an opaque window is still drawn: our elements ask
    // for live blur, and Hyprland deliberately stops opaque surfaces occluding
    // anything near a live-blur element (Pass.cpp simplify). So a widget under
    // a fullscreen terminal kept running the material for nothing. Skip those
    // panels here instead -- only ones BELOW the windows (background/bottom
    // layers); top/overlay panels draw above windows and are never hidden by
    // them. Rounded corners are not covered, so each window is shrunk by its
    // own rounding before counting as cover.
    CRegion opaqueWindows;
    for (const auto& W : Desktop::windowState()->windows()) {
        if (!W || !W->m_isMapped || W->isHidden() || !W->visible() || W->m_monitor.get() != PMONITOR.get() || !W->opaque())
            continue;
        // Only windows actually on screen right now: visible() is true for a
        // mapped window on another workspace too, which had the widgets
        // counted as covered from every workspace.
        if (!W->m_workspace || !(W->m_workspace == PMONITOR->m_activeWorkspace || W->m_workspace->m_visible))
            continue;
        CBox        b = W->getWindowMainSurfaceBox();
        const float R = W->rounding();
        b = CBox{b.x + R, b.y + R, std::max(0.0, b.w - R * 2.0), std::max(0.0, b.h - R * 2.0)};
        if (b.w < 1 || b.h < 1)
            continue;
        opaqueWindows.add(CBox{(b.x - PMONITOR->m_position.x) * PMONITOR->m_scale, (b.y - PMONITOR->m_position.y) * PMONITOR->m_scale, b.w * PMONITOR->m_scale, b.h * PMONITOR->m_scale});
    }

    struct SCandidate {
        std::string id;
        CBox        box;
    };
    std::vector<SCandidate> cands;
    for (size_t level = 0; level < PMONITOR->m_layerSurfaceLayers.size(); ++level) {
        const bool BELOW_WINDOWS = level <= ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM;
        for (const auto& REF : PMONITOR->m_layerSurfaceLayers[level]) {
            const auto LS = REF.lock();
            if (!LS || !LS->m_mapped || LS->m_monitor.get() != PMONITOR.get())
                continue;
            for (const auto& [ID, R] : g_rects) {
                auto OPT = resolveBox(LS, R, PMONITOR, false);
                if (!OPT)
                    OPT = resolveBox(LS, R, PMONITOR, true);
                if (!OPT)
                    continue;
                if (BELOW_WINDOWS && !opaqueWindows.empty() && CRegion{*OPT}.subtract(opaqueWindows).empty())
                    continue; // fully hidden behind an opaque window
                cands.push_back({ID, *OPT});
            }
        }
    }

    const float GROWTH = lateBlurGrowth();
    CRegion     touched = g_pHyprRenderer->m_renderData.damage.copy();
    if (*PBLUR)
        touched.expand(GROWTH);
    touched.add(sampleBoxes);
    CRegion grown; // late growth around the panels drawn so far

    bool changed = true;
    while (changed) {
        changed = false;
        for (const auto& C : cands) {
            if (g_frameDraw.contains(C.id))
                continue;
            const CBox PADDED = paddedBox(C.box);
            if (touched.copy().intersect(PADDED).empty() && grown.copy().intersect(C.box).empty())
                continue;
            g_frameDraw.insert(C.id);
            touched.add(PADDED);
            grown.add(CRegion{C.box}.expand(GROWTH));
            changed = true;
        }
    }
}

// Queue the glass for every panel belonging to one layer surface, at the point
// in the render pass where it is called. Used by the renderLayer hook (just
// before that layer's own surface is queued) and, if the hook could not be
// installed, by the stage listener as a fallback.
static void queueGlassFor(const PHLLS& LS, const PHLMONITOR& PMONITOR, bool popupPass = false) {
    if (!LS || !PMONITOR || !LS->m_mapped || LS->m_monitor.get() != PMONITOR.get())
        return;

    for (const auto& [ID, R] : g_rects) {
        // The panel the material should draw across: the shell's rect,
        // placed inside the layer (or inside its open popup).
        const auto OPT = resolveBox(LS, R, PMONITOR, popupPass);
        if (!OPT)
            continue;
        const CBox BOX = *OPT;
        if (BOX.w < 1 || BOX.h < 1)
            continue;

        // Skipping a panel leaves the last frame's glass in this buffer,
        // which is still correct -- that is what makes an idle desktop idle.
        // Drawing one adds its WHOLE padded region to the render damage, so
        // everything behind is repainted before the capture reads it: the
        // material can pull samples from across the panel, and a partial
        // repaint would capture our own previous glass.
        //
        // RENDER damage only, never the damage ring: adding to the ring
        // schedules another frame, which ran this again -- a permanent
        // 120 fps loop, ~25% GPU idle.
        //
        // Which panels is decided for the whole frame in
        // computeFrameDrawSet; renders that never emit RENDER_BEGIN (a
        // screencopy into a buffer) fall back to this panel's own test.
        const CBox PADDED = paddedBox(BOX);
        auto&      DMG    = g_pHyprRenderer->m_renderData.damage;
        const bool SKIP   = g_frameDrawValid ? !g_frameDraw.contains(ID) : DMG.copy().intersect(PADDED).empty();
        if (g_optGate && SKIP)
            continue;
        DMG.add(PADDED);

        g_pHyprRenderer->m_renderPass.add(makeUnique<CGlassElement>(BOX, R.radius, ID));
    }
}

// Queue this layer's colour samples, after its glass and before its surface.
static void queueSamplesFor(const PHLLS& LS, const PHLMONITOR& PMONITOR, bool popupPass = false) {
    if (!LS || !PMONITOR || !LS->m_mapped || LS->m_monitor.get() != PMONITOR.get() || !g_frameDrawValid)
        return;
    for (const auto& [ID, S] : g_samples) {
        if (!g_frameSamples.contains(ID))
            continue;
        const auto OPT = resolveBox(LS, S.r, PMONITOR, popupPass);
        if (!OPT)
            continue;
        const CBox BOX = *OPT;
        g_pHyprRenderer->m_renderData.damage.add(BOX);
        g_pHyprRenderer->m_renderPass.add(makeUnique<CSampleElement>(BOX, ID));
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
    // for every layer: the layer's own rects go in the main pass, its
    // "popup:" rects (dropdowns) in the popups pass, each just before the
    // surfaces it sits under. While locked, the lock surface covers
    // everything, so glass is skipped entirely.
    if (pLayer && pMonitor && !lockscreen && pLayer->visible() && !g_pSessionLockManager->isSessionLocked()) {
        queueGlassFor(pLayer, pMonitor, popups);
        queueSamplesFor(pLayer, pMonitor, popups);
    }

    ((origRenderLayer)g_renderLayerHook->m_original)(thisptr, pLayer, pMonitor, time, popups, lockscreen);
}

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    g_renderListener = Event::bus()->m_events.render.stage.listen([](eRenderStage stage) {
        if (stage == RENDER_PRE) {
            // Not yet told which monitor is about to render: snapshot all.
            // Each monitor's own RENDER_PRE refreshes its entry just before
            // its own render, so the value read at its RENDER_BEGIN is fresh.
            for (const auto& M : State::monitorState()->monitors())
                g_newDamage[M.get()] = M->m_damage.getBufferDamage(1);
            return;
        }
        if (stage == RENDER_BEGIN) {
            g_frameGlassRegion = CRegion{}; // glass drawn so far this frame
            computeFrameDrawSet(g_pHyprRenderer->m_renderData.pMonitor.lock());
            return;
        }
        if (stage == RENDER_POST) {
            g_frameDrawValid = false;
            return;
        }
        // Fallback only (the renderLayer hook normally queues each panel).
        // Glass must be queued where everything behind its layer is drawn and
        // the layer itself is not: bottom layers at RENDER_POST_WALLPAPER,
        // top/overlay at RENDER_POST_WINDOWS -- queuing a bottom layer's glass
        // at POST_WINDOWS would paint it over the windows covering it. Known
        // gap: with no workspace on a monitor, POST_WINDOWS never fires, so
        // top-layer glass does not draw in that state.
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
            for (const auto& [NS, MAP] : g_nsUniformValues) {
                for (const auto& [NAME, V] : MAP) {
                    out += "  " + NAME + "@" + NS + " =";
                    for (float f : V)
                        out += std::format(" {:.4f}", f);
                    out += "\n";
                }
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
        return std::format("glass options:\n  material: {}\n  ordering: {}\n  draws since load: {}\n  gate (redraw only when damage touches a panel): {}\n  scale (capture resolution): {:.2f}\n  material uniforms received: {}\n  panels:\n{}",
                           g_shaderPath, g_renderLayerHook ? "per-surface (renderLayer hook)" : "stage fallback", g_drawCount, g_optGate ? "on" : "off", g_capScale, g_uniformValues.size(), rects.empty() ? "    (none -- is the shell sending glassrect?)\n" : rects);
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
            return "usage: hyprctl glassrect <id> <namespace> <x> <y> <w> <h> <radius> [darkText 0|1] | <id> remove\n";
        SGlassRect r;
        r.ns     = args[2];
        r.rect   = CBox{std::atof(args[3].c_str()), std::atof(args[4].c_str()), std::atof(args[5].c_str()), std::atof(args[6].c_str())};
        r.radius = (float)std::atof(args[7].c_str());
        if (args.size() > 8 && !args[8].empty())
            r.dir = args[8] == "1" ? 1.F : -1.F; // 1 = the panel's text is dark
        if (const auto IT = g_rects.find(args[1]); IT != g_rects.end())
            damageRect(IT->second); // where it was
        g_rects[args[1]] = r;
        damageRect(r); // where it is now
        return "ok\n";
    }});

    // Colour-sample regions for adaptive text (see SSample).
    //
    //   hyprctl glasssample <id> <namespace> <x> <y> <w> <h>
    //   hyprctl glasssample <id> remove
    //   hyprctl glasssample reset <session>
    HyprlandAPI::registerHyprCtlCommand(PHANDLE, SHyprCtlCommand{"glasssample", false, [](eHyprCtlOutputFormat, std::string request) -> std::string {
        auto args = CVarList(request, 0, ' ');
        auto drop = [](SSample& S) {
            if (S.tex)
                g_deadSampleTex.push_back(S.tex);
            if (S.fbo)
                g_deadSampleFbo.push_back(S.fbo);
        };
        if (args.size() >= 3 && args[2] == "remove") {
            if (const auto IT = g_samples.find(args[1]); IT != g_samples.end()) {
                drop(IT->second);
                g_samples.erase(IT);
            }
            return "removed\n";
        }
        if (args.size() >= 3 && args[1] == "reset") {
            const std::string PREFIX = args[2] + ":";
            size_t            dropped = 0;
            for (auto it = g_samples.begin(); it != g_samples.end();) {
                if (!it->first.starts_with(PREFIX)) {
                    drop(it->second);
                    it = g_samples.erase(it);
                    ++dropped;
                } else
                    ++it;
            }
            return std::format("reset: dropped {} sample(s) from other sessions\n", dropped);
        }
        if (args.size() < 7)
            return "usage: hyprctl glasssample <id> <namespace> <x> <y> <w> <h> | <id> remove | reset <session>\n";
        SGlassRect r;
        r.ns   = args[2];
        r.rect = CBox{std::atof(args[3].c_str()), std::atof(args[4].c_str()), std::atof(args[5].c_str()), std::atof(args[6].c_str())};
        auto& S = g_samples[args[1]];
        if (S.r.ns != r.ns || S.r.rect != r.rect) {
            S.r       = r;
            S.pending = true;
            S.have    = false; // a (re)registered region always gets its colour posted
            damageSample(r);
        }
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
            return "usage: hyprctl glassuniform <name>[@<layer namespace>] <v> [v v v]\n";
        std::vector<float> vals;
        for (size_t i = 2; i < args.size() && vals.size() < 4; ++i) {
            if (!args[i].empty())
                vals.push_back((float)std::atof(args[i].c_str()));
        }
        if (vals.empty())
            return "no values\n";
        const std::string NAME = args[1];
        if (const auto AT = NAME.find('@'); AT != std::string::npos)
            g_nsUniformValues[NAME.substr(AT + 1)][NAME.substr(0, AT)] = vals;
        else
            g_uniformValues[NAME] = vals;
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
        Log::logger->log(Log::INFO, "[brolli-glass] renderLayer hook: {} ({} candidate(s))", g_renderLayerHook ? "installed" : "NOT installed, using stage fallback", hits);
    }

    // Announce ourselves. Everything this plugin draws comes from state the
    // shell pushes (rects, uniforms), and a freshly loaded plugin starts with
    // none of it -- so without this, any plugin reload left the screen with no
    // glass until the shell happened to restart. Arrives in Quickshell as
    // Hyprland.rawEvent, name "glassplugin".
    g_pEventManager->postEvent(SHyprIPCEvent{"glassplugin", "loaded"});

    HyprlandAPI::addNotification(PHANDLE, "[brolli-glass] loaded", CHyprColor{0.2, 1.0, 0.2, 1.0}, 3000);
    return {"Brolli-Glass", "liquid glass for Quickshell layer surfaces", "brolli", "1.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    g_renderListener.reset();
    if (g_pHyprRenderer)
        g_pHyprRenderer->m_renderPass.removeAllOfType("CGlassElement");
    if (g_pHyprRenderer)
        g_pHyprRenderer->m_renderPass.removeAllOfType("CSampleElement");
    if (g_sampleTimer) {
        g_sampleTimer->cancel();
        g_pEventLoopManager->removeTimer(g_sampleTimer);
        g_sampleTimer.reset();
    }
    Log::logger->log(Log::INFO, "[brolli-glass] unloaded");
}
