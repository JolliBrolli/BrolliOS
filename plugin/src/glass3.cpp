// Step-3 spike: run OUR OWN fragment shader on Hyprland's live backdrop,
// from a plugin, with zero Hyprland source changes.
//
// Custom IPassElement (ePassElementType EK_CUSTOM, which upstream provides
// for exactly this) -> blurMainFramebuffer() for the live mid-frame composite
// -> our GLSL -> quad. Throwaway: fixed geometry, no config, no layer lookup.

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/PassElement.hpp>
#include <hyprland/src/render/Texture.hpp>
#include <hyprland/src/debug/log/Logger.hpp>
#include <GLES3/gl32.h>

inline HANDLE              PHANDLE = nullptr;
inline CHyprSignalListener g_renderListener;

static const char* VERT = R"(#version 300 es
precision highp float;
in vec2 pos;
void main() { gl_Position = vec4(pos, 0.0, 1.0); }
)";

// Everything works in gl_FragCoord space, and the backdrop texture shares the
// target framebuffer's own orientation, so sampling at the raw fragment
// coordinate is exactly "the pixel currently underneath this one". That
// sidesteps every y-flip/transform question for a first test.
static const char* FRAG = R"(#version 300 es
precision highp float;
uniform sampler2D backdrop;
uniform vec2  screenSize;
uniform vec4  boxPx;      // x, y, w, h  (gl_FragCoord space)
uniform float radius;
uniform float rimWidth;
uniform float refractPx;
out vec4 fragColor;

float sdRoundRect(vec2 p, vec2 halfSize, float r) {
    vec2 q = abs(p) - (halfSize - vec2(r));
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

// Aghajari's circular lens profile, as used by the ShojiWM liquid-glass
// reference: near-flat across the interior, steeply curved in the last few
// pixels before the edge. Deliberately NOT a smoothstep.
float circularLens(float distPx, float widthPx) {
    float x   = 1.0 - clamp(distPx / widthPx, 0.0, 1.0);
    float eps = clamp(2.0 / widthPx, 0.0001, 0.5);
    float top = sqrt(1.0 + eps);
    return (top - sqrt(max(1.0 - x * x, 0.0) + eps)) / (top - sqrt(eps));
}

void main() {
    vec2  center   = boxPx.xy + boxPx.zw * 0.5;
    vec2  halfSize = boxPx.zw * 0.5;
    vec2  p        = gl_FragCoord.xy - center;

    float d = sdRoundRect(p, halfSize, radius);
    if (d > 0.0) { fragColor = vec4(0.0); return; }

    // Inward normal of the SDF, by gradient.
    vec2  e = vec2(1.0, 0.0);
    vec2  grad = vec2(sdRoundRect(p + e.xy, halfSize, radius) - sdRoundRect(p - e.xy, halfSize, radius),
                      sdRoundRect(p + e.yx, halfSize, radius) - sdRoundRect(p - e.yx, halfSize, radius));
    vec2  inward = -normalize(grad + vec2(1e-6));

    float dist    = -d;
    float profile = circularLens(dist, max(rimWidth, 1.0));
    vec2  offset  = inward * profile * refractPx;

    vec2 uv = (gl_FragCoord.xy + offset) / screenSize;
    vec3 col = texture(backdrop, clamp(uv, vec2(0.001), vec2(0.999))).rgb;

    // Thin specular rim, brightest where the lens is steepest.
    float rim = exp(-dist / 2.0);
    col = mix(col, vec3(1.0), rim * 0.35);
    col = mix(col, vec3(1.0), 0.06);
    col *= 1.04; // slight lift, so it reads as a lit surface not a hole

    float aa = clamp(-d, 0.0, 1.0);
    fragColor = vec4(col, 1.0) * aa;
}
)";

static GLuint g_prog = 0, g_vbo = 0;
static GLint  uBackdrop = -1, uScreen = -1, uBox = -1, uRadius = -1, uRim = -1, uRefract = -1;
static GLint  aPos = -1;

static GLuint compile(GLenum type, const char* src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, nullptr);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[2048];
        glGetShaderInfoLog(s, sizeof(log), nullptr, log);
        Log::logger->log(Log::ERR, "[glass3] shader compile failed: {}", log);
        glDeleteShader(s);
        return 0;
    }
    return s;
}

static bool ensureProgram() {
    if (g_prog)
        return true;
    GLuint v = compile(GL_VERTEX_SHADER, VERT);
    GLuint f = compile(GL_FRAGMENT_SHADER, FRAG);
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
        Log::logger->log(Log::ERR, "[glass3] link failed: {}", log);
        glDeleteProgram(g_prog);
        g_prog = 0;
        return false;
    }
    uBackdrop = glGetUniformLocation(g_prog, "backdrop");
    uScreen   = glGetUniformLocation(g_prog, "screenSize");
    uBox      = glGetUniformLocation(g_prog, "boxPx");
    uRadius   = glGetUniformLocation(g_prog, "radius");
    uRim      = glGetUniformLocation(g_prog, "rimWidth");
    uRefract  = glGetUniformLocation(g_prog, "refractPx");
    aPos      = glGetAttribLocation(g_prog, "pos");
    glGenBuffers(1, &g_vbo);
    Log::logger->log(Log::INFO, "[glass3] program built, prog {}", g_prog);
    return true;
}

class CGlassElement : public IPassElement {
  public:
    CGlassElement(const CBox& box) : m_box(box) {}
    virtual ~CGlassElement() = default;

    // Tells the render pass this element reads what's under it, so the
    // renderer keeps the live backdrop available for us.
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
        if (!ensureProgram())
            return {};

        const auto PMONITOR = g_pHyprRenderer->m_renderData.pMonitor;
        if (!PMONITOR)
            return {};

        // The live mid-frame composite of everything drawn so far — i.e.
        // exactly what is behind this element. No capture, no screencopy.
        CRegion    dmg{0, 0, (int)PMONITOR->m_transformedSize.x, (int)PMONITOR->m_transformedSize.y};
        const auto BACKDROP = g_pHyprRenderer->blurMainFramebuffer(1.F, &dmg);
        if (!BACKDROP || !BACKDROP->m_texID)
            return {};

        const float SW = PMONITOR->m_transformedSize.x;
        const float SH = PMONITOR->m_transformedSize.y;

        // Our box in gl_FragCoord space (origin bottom-left).
        const float bx = m_box.x;
        const float by = SH - m_box.y - m_box.height;
        const float bw = m_box.width;
        const float bh = m_box.height;

        // Quad in NDC covering the box.
        const float x0 = (bx / SW) * 2.F - 1.F;
        const float x1 = ((bx + bw) / SW) * 2.F - 1.F;
        const float y0 = (by / SH) * 2.F - 1.F;
        const float y1 = ((by + bh) / SH) * 2.F - 1.F;
        const float verts[12] = {x0, y0, x1, y0, x1, y1, x0, y0, x1, y1, x0, y1};

        // Save every piece of shared GL state we touch. This is the part that
        // matters: leaving any of it dirty breaks whatever draws next.
        GLint prevProg = 0, prevVbo = 0, prevTex = 0, prevActive = 0;
        glGetIntegerv(GL_CURRENT_PROGRAM, &prevProg);
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &prevVbo);
        glGetIntegerv(GL_ACTIVE_TEXTURE, &prevActive);
        glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &prevTex);
        const GLboolean prevBlend   = glIsEnabled(GL_BLEND);
        const GLboolean prevScissor = glIsEnabled(GL_SCISSOR_TEST);

        glDisable(GL_SCISSOR_TEST);
        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

        glUseProgram(g_prog);
        glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STREAM_DRAW);
        glEnableVertexAttribArray(aPos);
        glVertexAttribPointer(aPos, 2, GL_FLOAT, GL_FALSE, 0, nullptr);

        glBindTexture(GL_TEXTURE_2D, BACKDROP->m_texID);
        glUniform1i(uBackdrop, 0);
        glUniform2f(uScreen, SW, SH);
        glUniform4f(uBox, bx, by, bw, bh);
        glUniform1f(uRadius, 48.F);
        glUniform1f(uRim, 40.F);
        glUniform1f(uRefract, 34.F);

        glDrawArrays(GL_TRIANGLES, 0, 6);

        glDisableVertexAttribArray(aPos);
        glBindTexture(GL_TEXTURE_2D, prevTex);
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
    CBox m_box;
};

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    const auto RUNNING = HyprlandAPI::getHyprlandVersion(handle);
    Log::logger->log(Log::INFO, "[glass3] built against '{}', running '{}' tag '{}'", __hyprland_api_get_hash(), RUNNING.hash, RUNNING.tag);

    g_renderListener = Event::bus()->m_events.render.stage.listen([](eRenderStage stage) {
        if (stage != RENDER_POST_WINDOWS)
            return;

        // Centre the demo panel on whatever monitor is currently being
        // rendered, rather than fixed coordinates — this fires once per
        // monitor per frame, so a multi-monitor setup gets one panel each,
        // correctly placed, instead of one arbitrary rectangle.
        const auto PMONITOR = g_pHyprRenderer->m_renderData.pMonitor;
        if (!PMONITOR)
            return;

        // Sized/placed in PHYSICAL pixels (m_transformedSize), matching the
        // space draw() works in. Using logical size here would misplace and
        // mis-size the panel on any scaled monitor.
        const float W = 900.F, H = 460.F;
        const float X = (PMONITOR->m_transformedSize.x - W) / 2.F;
        const float Y = (PMONITOR->m_transformedSize.y - H) / 2.F;
        g_pHyprRenderer->m_renderPass.add(makeUnique<CGlassElement>(CBox{X, Y, W, H}));
    });

    HyprlandAPI::addNotification(PHANDLE, "[glass3] loaded", CHyprColor{0.2, 1.0, 0.2, 1.0}, 3000);
    return {"glass3", "step-3: own shader on live backdrop", "brolli", "0.1"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    // Order matters, and getting it wrong segfaults the compositor.
    //
    // Elements we queued live in m_renderPass and their vtable pointers point
    // INTO THIS .so. dlclose() unmaps that memory; the next frame's
    // m_renderPass.render() then calls a virtual through a dangling vtable.
    // Confirmed the hard way: the first version of this plugin crashed the
    // nested session on unload, not on load.
    //
    // So: stop queueing new ones, then drop any already queued, BEFORE we
    // are unmapped. removeAllOfType matches on passName().
    g_renderListener.reset();
    if (g_pHyprRenderer)
        g_pHyprRenderer->m_renderPass.removeAllOfType("CGlassElement");

    // Deliberately NOT calling glDeleteProgram/glDeleteBuffers here: plugin
    // teardown has no guaranteed current GL context. Leaking one program per
    // load cycle is the lesser evil in a spike; a real plugin would tear these
    // down from inside a render callback instead.
    Log::logger->log(Log::INFO, "[glass3] unloaded");
}
