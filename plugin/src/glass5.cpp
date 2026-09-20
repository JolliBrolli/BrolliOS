// Step-4 spike: glass the ACTUAL VISIBLE SHAPE of a Quickshell layer surface,
// not its (much larger) layer box.
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
#include <hyprland/src/desktop/state/LayerState.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <GLES3/gl32.h>
#include <algorithm>

inline HANDLE              PHANDLE = nullptr;
inline CHyprSignalListener g_renderListener;

static bool isTargeted(const std::string& ns) {
    return ns == "quickshell:macDock" || ns == "quickshell:overview";
}

static const char* VERT = R"(#version 300 es
precision highp float;
in vec2 pos;
void main() { gl_Position = vec4(pos, 0.0, 1.0); }
)";

static const char* FRAG = R"(#version 300 es
precision highp float;
uniform sampler2D backdrop;   // live composite behind this layer
uniform sampler2D layerTex;   // the layer's own content — used as silhouette
uniform vec2  screenSize;
uniform vec4  boxPx;          // layer box: x, y, w, h in gl_FragCoord space
uniform float rimWidth;
uniform float refractPx;
uniform float alphaThreshold;
out vec4 fragColor;

// Layer-local UV. Wayland buffers are top-left origin, gl_FragCoord is
// bottom-left, hence the v flip.
vec2 layerUV(vec2 frag) {
    return vec2((frag.x - boxPx.x) / boxPx.z,
                (frag.y - boxPx.y) / boxPx.w);
}

float maskAt(vec2 frag) {
    vec2 uv = layerUV(frag);
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0))))
        return 0.0;
    return step(alphaThreshold, texture(layerTex, uv).a);
}

float circularLens(float distPx, float widthPx) {
    float x   = 1.0 - clamp(distPx / widthPx, 0.0, 1.0);
    float eps = clamp(2.0 / widthPx, 0.0001, 0.5);
    float top = sqrt(1.0 + eps);
    return (top - sqrt(max(1.0 - x * x, 0.0) + eps)) / (top - sqrt(eps));
}

void main() {
    vec2 frag = gl_FragCoord.xy;

    float m = maskAt(frag);
    if (m < 0.5) { fragColor = vec4(0.0); return; }   // outside the real shape

    // Inward direction, from the silhouette's own gradient.
    float gx = maskAt(frag + vec2(2.0, 0.0)) - maskAt(frag - vec2(2.0, 0.0));
    float gy = maskAt(frag + vec2(0.0, 2.0)) - maskAt(frag - vec2(0.0, 2.0));
    vec2  g  = vec2(gx, gy);

    // March outward along -gradient to find how far the edge is. Saturates at
    // rimWidth, which is exactly where the lens profile goes flat anyway.
    float dist = rimWidth;
    vec2  dir  = length(g) > 0.001 ? -normalize(g) : vec2(0.0, -1.0);
    const int STEPS = 24;
    for (int i = 1; i <= STEPS; ++i) {
        float t = (float(i) / float(STEPS)) * rimWidth;
        if (maskAt(frag + dir * t) < 0.5) { dist = t; break; }
    }

    vec2  inward  = -dir;
    float profile = circularLens(dist, max(rimWidth, 1.0));
    vec2  offset  = inward * profile * refractPx;

    vec2 uv  = clamp((frag + offset) / screenSize, vec2(0.001), vec2(0.999));
    vec3 col = texture(backdrop, uv).rgb;

    float rim = exp(-dist / 2.0);
    col = mix(col, vec3(1.0), rim * 0.35);
    col = mix(col, vec3(1.0), 0.06);
    col *= 1.04;

    fragColor = vec4(col, 1.0);
}
)";

static GLuint g_prog = 0, g_vbo = 0;
static GLint  uBackdrop = -1, uLayerTex = -1, uScreen = -1, uBox = -1, uRim = -1, uRefract = -1, uAlphaT = -1, aPos = -1;

static GLuint compile(GLenum type, const char* src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, nullptr);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[2048];
        glGetShaderInfoLog(s, sizeof(log), nullptr, log);
        Log::logger->log(Log::ERR, "[glass5] shader compile failed: {}", log);
        glDeleteShader(s);
        return 0;
    }
    return s;
}

static bool ensureProgram() {
    if (g_prog)
        return true;
    GLuint v = compile(GL_VERTEX_SHADER, VERT), f = compile(GL_FRAGMENT_SHADER, FRAG);
    if (!v || !f)
        return false;
    g_prog = glCreateProgram();
    glAttachShader(g_prog, v);
    glAttachShader(g_prog, f);
    glLinkProgram(g_prog);
    GLint ok = 0;
    glGetProgramiv(g_prog, GL_LINK_STATUS, &ok);
    glDeleteShader(v);
    glDeleteShader(f);
    if (!ok) {
        char log[2048];
        glGetProgramInfoLog(g_prog, sizeof(log), nullptr, log);
        Log::logger->log(Log::ERR, "[glass5] link failed: {}", log);
        glDeleteProgram(g_prog);
        g_prog = 0;
        return false;
    }
    uBackdrop = glGetUniformLocation(g_prog, "backdrop");
    uLayerTex = glGetUniformLocation(g_prog, "layerTex");
    uScreen   = glGetUniformLocation(g_prog, "screenSize");
    uBox      = glGetUniformLocation(g_prog, "boxPx");
    uRim      = glGetUniformLocation(g_prog, "rimWidth");
    uRefract  = glGetUniformLocation(g_prog, "refractPx");
    uAlphaT   = glGetUniformLocation(g_prog, "alphaThreshold");
    aPos      = glGetAttribLocation(g_prog, "pos");
    glGenBuffers(1, &g_vbo);
    Log::logger->log(Log::INFO, "[glass5] program built");
    return true;
}

class CGlassElement : public IPassElement {
  public:
    CGlassElement(const CBox& box, SP<Render::ITexture> layerTex) : m_box(box), m_layerTex(layerTex) {}
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
    virtual std::optional<CBox> boundingBox() {
        return m_box;
    }

    virtual std::vector<UP<IPassElement>> draw() {
        if (!ensureProgram() || !m_layerTex || !m_layerTex->m_texID)
            return {};

        const auto PMONITOR = g_pHyprRenderer->m_renderData.pMonitor;
        if (!PMONITOR)
            return {};

        CRegion    dmg{0.0, 0.0, PMONITOR->m_transformedSize.x, PMONITOR->m_transformedSize.y};
        const auto BACKDROP = g_pHyprRenderer->blurMainFramebuffer(1.F, &dmg);
        if (!BACKDROP || !BACKDROP->m_texID)
            return {};

        const float SW = PMONITOR->m_transformedSize.x, SH = PMONITOR->m_transformedSize.y;
        const float bx = m_box.x, by = m_box.y, bw = m_box.width, bh = m_box.height;

        const float x0 = (bx / SW) * 2.F - 1.F, x1 = ((bx + bw) / SW) * 2.F - 1.F;
        const float y0 = (by / SH) * 2.F - 1.F, y1 = ((by + bh) / SH) * 2.F - 1.F;
        const float verts[12] = {x0, y0, x1, y0, x1, y1, x0, y0, x1, y1, x0, y1};

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
        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

        glUseProgram(g_prog);
        glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STREAM_DRAW);
        glEnableVertexAttribArray(aPos);
        glVertexAttribPointer(aPos, 2, GL_FLOAT, GL_FALSE, 0, nullptr);

        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, BACKDROP->m_texID);
        glUniform1i(uBackdrop, 0);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, m_layerTex->m_texID);
        glUniform1i(uLayerTex, 1);

        glUniform2f(uScreen, SW, SH);
        glUniform4f(uBox, bx, by, bw, bh);
        glUniform1f(uRim, 26.F);
        glUniform1f(uRefract, 22.F);
        glUniform1f(uAlphaT, 0.1F);

        glDrawArrays(GL_TRIANGLES, 0, 6);

        glDisableVertexAttribArray(aPos);
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
    CBox                 m_box;
    SP<Render::ITexture> m_layerTex;
};

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    g_renderListener = Event::bus()->m_events.render.stage.listen([](eRenderStage stage) {
        if (stage != RENDER_LAST_MOMENT)
            return;

        const auto PMONITOR = g_pHyprRenderer->m_renderData.pMonitor;
        if (!PMONITOR)
            return;

        for (const auto& LS : Desktop::layerState()->layers()) {
            if (!LS || !LS->m_mapped || LS->m_monitor.get() != PMONITOR.get())
                continue;
            if (!isTargeted(LS->m_namespace))
                continue;
            if (!LS->wlSurface() || !LS->wlSurface()->resource())
                continue;

            const auto TEX = LS->wlSurface()->resource()->m_current.texture;
            if (!TEX)
                continue;

            // m_geometry is GLOBAL LOGICAL (matches `hyprctl layers`).
            const auto& G     = LS->m_geometry;
            const float SCALE = PMONITOR->m_scale;
            const CBox  BOX{(G.x - PMONITOR->m_position.x) * SCALE, (G.y - PMONITOR->m_position.y) * SCALE, G.w * SCALE, G.h * SCALE};
            if (BOX.w < 1 || BOX.h < 1)
                continue;

            g_pHyprRenderer->m_renderPass.add(makeUnique<CGlassElement>(BOX, TEX));
        }
    });

    HyprlandAPI::addNotification(PHANDLE, "[glass5] loaded", CHyprColor{0.2, 1.0, 0.2, 1.0}, 3000);
    return {"glass4", "OVER-draw proof: same pipeline, drawn on top", "brolli", "0.1"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    g_renderListener.reset();
    if (g_pHyprRenderer)
        g_pHyprRenderer->m_renderPass.removeAllOfType("CGlassElement");
    Log::logger->log(Log::INFO, "[glass5] unloaded");
}
