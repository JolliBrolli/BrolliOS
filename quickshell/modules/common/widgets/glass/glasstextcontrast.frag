#version 440

// Whole-element adaptive text color: this text item's own layer.effect
// shader (see AdaptiveGlassText.qml). Matches how Apple's own adaptive/
// Liquid Glass materials actually work — the decision granularity is the
// WHOLE ELEMENT, not per-pixel or per-glyph. Earlier versions of this shader
// sampled the backdrop at each fragment's own position (a glyph straddling a
// light/dark edge rendered half black, half white) and then tried snapping
// to an approximate per-character grid (still imprecise — no real glyph
// metrics exist in a fragment shader, proportional fonts don't have uniform
// character width). Averaging one decision across the whole text item is
// both simpler and correct: every fragment samples the SAME small grid of
// points spread across this item's own backdropRect (not just its own
// position) and averages them, so every fragment in this draw computes an
// identical result — one consistent color for the whole label.
//
// REVERTED (2026-09-16) from a two-pass stateful-hysteresis design (a
// recursive ShaderEffectSource feeding its own previous decision back into
// itself, to avoid flicker when the average sits near the 0.5 threshold on
// a busy backdrop) — that recursive feedback texture holding a persistent
// reference into the glass's shared capture pipeline made a pre-existing
// Quickshell item-lifecycle race (QQuickItem::update() firing on a
// already-destroyed item during rapid open/close) drastically easier to
// hit, and it crashed the real shell on completely ordinary open→close→open
// use, not just under spam. Back to this single-pass, non-recursive
// version — a hard threshold can flicker on a busy/varied backdrop, but
// that's a cosmetic issue, not a crash. Proper hysteresis needs a design
// that doesn't hold a live recursive reference across item teardown.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    // This item's own rect within backdropSource's UV space: (u0, v0, u1, v1).
    vec4  backdropRect;
};

// This text item's own rendered glyphs (alpha coverage) — auto-bound by Qt's
// layer.effect mechanism to the layer's texture, same convention as every
// other layer.effect in this codebase (OpacityMask/MultiEffect's `source`).
layout(binding = 1) uniform sampler2D source;
// The glass's already-rendered blurred crop — reused, not recaptured.
layout(binding = 2) uniform sampler2D backdropSource;

void main() {
    vec4 glyph = texture(source, qt_TexCoord0);
    if (glyph.a < 0.001) {
        fragColor = vec4(0.0);
        return;
    }

    // 3x3 grid of sample points spread across the WHOLE item rect — same for
    // every fragment in this draw, since backdropRect doesn't vary per-
    // fragment, so every fragment arrives at the same decision.
    const int N = 3;
    float lumSum = 0.0;
    for (int i = 0; i < N; ++i) {
        for (int j = 0; j < N; ++j) {
            vec2 t = (vec2(float(i), float(j)) + 0.5) / float(N);
            vec2 uv = clamp(mix(backdropRect.xy, backdropRect.zw, t), vec2(0.0), vec2(1.0));
            lumSum += dot(texture(backdropSource, uv).rgb, vec3(0.299, 0.587, 0.114));
        }
    }
    float lum = lumSum / float(N * N);
    vec3 textColor = lum > 0.5 ? vec3(0.05) : vec3(0.97);

    // Premultiplied alpha, matching Qt Quick's scenegraph convention.
    fragColor = vec4(textColor * glyph.a, glyph.a) * qt_Opacity;
}
