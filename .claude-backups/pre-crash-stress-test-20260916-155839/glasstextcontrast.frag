#version 440

// Glyph color pass for AdaptiveGlassText — reads the 1x1 hysteresis decision
// texture produced by glasstextdecision.frag (see that file for why the
// decision itself lives in a separate stateful pass) and paints this text
// item's own rendered glyphs (from `source`, this item's own layer texture)
// strictly black or white accordingly. No blending here — the decision pass
// already handled avoiding flicker; this pass just applies a hard, fully
// legible color once that decision is made.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
};

// This text item's own rendered glyphs (alpha coverage) — auto-bound by Qt's
// layer.effect mechanism to the layer's texture, same convention as every
// other layer.effect in this codebase (OpacityMask/MultiEffect's `source`).
layout(binding = 1) uniform sampler2D source;
// The 1x1 hysteresis decision texture (see glasstextdecision.frag).
layout(binding = 2) uniform sampler2D decisionSource;

void main() {
    vec4 glyph = texture(source, qt_TexCoord0);
    if (glyph.a < 0.001) {
        fragColor = vec4(0.0);
        return;
    }

    float decision = texture(decisionSource, vec2(0.5)).r;
    vec3 textColor = decision > 0.5 ? vec3(0.05) : vec3(0.97);

    // Premultiplied alpha, matching Qt Quick's scenegraph convention.
    fragColor = vec4(textColor * glyph.a, glyph.a) * qt_Opacity;
}
