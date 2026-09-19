#version 440

// Hysteresis decision pass for AdaptiveGlassText — a tiny 1x1 render target
// that remembers its OWN previous decision (fed back via a `recursive: true`
// ShaderEffectSource in AdaptiveGlassText.qml) so the black/white call has
// real memory across frames, not just a stateless per-frame threshold.
//
// Without this, a hard `lum > 0.5` cut in a stateless shader flickers
// whenever the average sits near the boundary (a busy backdrop, e.g. a
// browser tab, keeps landing right around 0.5, so ordinary frame-to-frame
// noise flips it back and forth). A blended/gray output avoids the flicker
// but isn't acceptable — text must stay strictly black or white. Real
// hysteresis needs to know what the PREVIOUS decision was, which requires
// state a stateless shader doesn't have on its own — hence this separate
// feedback pass: only flip once the new reading clears well past the
// opposite side of the boundary (0.42/0.58), otherwise keep whatever it was
// already showing.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    // This item's own rect within backdropSource's UV space: (u0, v0, u1, v1).
    vec4  backdropRect;
};

layout(binding = 1) uniform sampler2D backdropSource;
// This pass's own previous frame's output (1x1) — 0.0 means "was dark
// backdrop -> white text", 1.0 means "was light backdrop -> black text".
layout(binding = 2) uniform sampler2D prevDecision;

void main() {
    // Same whole-element 3x3 average as before.
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

    float prev = texture(prevDecision, vec2(0.5)).r;
    float decision = prev;
    if (prev < 0.5 && lum > 0.58)
        decision = 1.0;
    else if (prev > 0.5 && lum < 0.42)
        decision = 0.0;

    fragColor = vec4(decision, decision, decision, 1.0) * qt_Opacity;
}
