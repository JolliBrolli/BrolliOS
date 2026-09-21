#version 300 es
precision highp float;
precision highp sampler2D;

// qt_Opacity has no meaning outside Qt's scene graph; the plugin
// composites with its own blend state.
const float qt_Opacity = 1.0;

uniform vec2 texSize;
uniform float radiusPx;

// Horizontal-only half of a separable Gaussian blur — paired with
// liquidglasstest.frag's own sampleBlurred, which does the vertical half.
// A single-pass NxN blur (the old approach) costs N² taps; splitting into
// two 1D passes costs N+N — for the existing 9x9 (81-tap) kernel, this pass
// plus the vertical half in the main shader is 9+9=18 taps total, ~4.5x
// fewer texture reads for the same Gaussian result. Runs on a LIVE capture
// (re-sampled continuously while any glass panel is open), so this is a
// real continuous saving, not a one-time cost.
//
// Kept as its own tiny render pass (a ShaderEffect + ShaderEffectSource in
// each consuming .qml file) rather than folded into the main shader, since
// separability fundamentally requires the horizontal blur's OUTPUT to be
// available as an actual pre-blurred texture before the vertical pass reads
// neighbouring pixels of it — a single fragment invocation has no way to
// "see" a neighbour's own blurred result within one pass.

in vec2 qt_TexCoord0;
out vec4 fragColor;



uniform sampler2D source;

void main() {
    if (radiusPx < 1.0) {
        fragColor = texture(source, qt_TexCoord0) * qt_Opacity;
        return;
    }
    float stepPx = radiusPx / max(texSize.x, 1.0);
    vec3 acc = vec3(0.0);
    float w = 0.0;
    for (int i = -4; i <= 4; ++i) {
        float o = float(i);
        float ww = exp(-o * o * 0.13);
        acc += texture(source, qt_TexCoord0 + vec2(o * stepPx, 0.0)).rgb * ww;
        w += ww;
    }
    fragColor = vec4(acc / max(w, 1e-4), 1.0) * qt_Opacity;
}
