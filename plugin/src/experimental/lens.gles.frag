#version 300 es
precision highp float;
precision highp sampler2D;

// "lens" -- the Aghajari look, driven by ShojiWM's edge logic.
//     hyprctl glassopt material lens
// Faithful Aghajari original for comparison: experimental/aghajari.gles.frag
// Shoji reference: true-liquid-glass-shojiwm/shojiwm/src/island-refract.frag
//                  (+ island-smooth.frag, island-glass.ts for its defaults)
//
// LOOK, from Aghajari (sliders; defaults = the recreation's values):
//   circular lens profile       1 - sqrt(1 - x^2)
//   RGB split                   lensChroma  3.0 px
//   5x5 softening               lensBlur    1.2 px * (1 - x * 0.5)
//   tint                        lensTint    0.90
//
// EDGE LOGIC, from Shoji -- replaces "pull toward the centre", which is what
// showed content from the wrong side on our (much larger than the demo) panels:
//   rim        a fixed width in px (lensRimPx, Shoji's default 30), NOT a
//              fraction of the panel as in Aghajari. Measured on a real widget
//              (480x205, 22px corners): up to ~30px the direction field has no
//              sideways jump over 1.1px; at Aghajari's 0.3 * 205 = 61px it
//              folds along the corner diagonals (7.3px jumps) -- the
//              four-triangle split. A rim deeper than the corner radius must
//              either fold there or round the corners off; macOS and Shoji
//              both keep the lensing rim thin, and so does this.
//   distance   exact distance to the REAL outline, smoothed by Shoji's
//              island-smooth kernel (binomial 1-4-6-4-1, 3px spacing,
//              horizontal then vertical = one 5x5 product kernel)
//   direction  gradient of that smoothed field. Shoji takes it with a Sobel
//              over a jump-flooded texture; we know the shape exactly, so the
//              same kernel is applied to the exact gradient instead (the
//              gradient of a blurred field is the blurred gradient).
//   coherence  smoothstep(0.15, 0.85, |gradient|): where edge directions
//              disagree the averaged gradient shrinks and the bend FADES,
//              never flips direction
//   pull       lensStrength * rim width, capped at the rim width (Shoji:
//              "bound excursion to the rim width")
//   edges      circular profile softened over edge_softness_px (2) and
//              filtered over one pixel, as in Shoji's circularLens()
//   RGB split  outer half of the rim only, on its own circular falloff

in vec2 qt_TexCoord0;   // panel-local UV, 0..1 (top-left origin)
out vec4 fragColor;

uniform sampler2D source;
uniform vec2  panelSize;
uniform vec2  texSize;
uniform float pad;
uniform float maxCornerRadius;

uniform float lensRimPx;      // rim width, px
uniform float lensStrength;   // pull, fraction of the rim width (<= 1)
uniform float lensBlur;
uniform float lensChroma;
uniform float lensTint;

const float EDGE_SOFTNESS_PX = 2.0;   // Shoji ISLAND_GLASS_OPTIONS.edgeSoftness
const float SMOOTHING_PX     = 3.0;   // Shoji ISLAND_GLASS_OPTIONS.normalSmoothing
                                      // (6px measured no better at hiding folds)

vec3 getTextureColorAt(vec2 c) {   // c = panel-local px, origin top-left
    return texture(source, (vec2(pad) + c) / texSize).rgb;
}

// Rounded-rectangle signed distance (negative inside) and its exact gradient.
float sdf(vec2 p, vec2 b, float r) {
    vec2 d = abs(p) - b + vec2(r);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
}
vec2 sdfGrad(vec2 p, vec2 b, float r) {
    vec2 s = vec2(p.x < 0.0 ? -1.0 : 1.0, p.y < 0.0 ? -1.0 : 1.0);
    vec2 d = abs(p) - b + vec2(r);
    if (d.x > 0.0 || d.y > 0.0) {
        vec2 m = max(d, 0.0);
        return s * m / max(length(m), 1e-6);
    }
    return d.x > d.y ? vec2(s.x, 0.0) : vec2(0.0, s.y);
}

// Shoji's circularLens / filteredCircularLens, same behaviour.
float circularLens(float distancePx, float widthPx) {
    float x = 1.0 - clamp(distancePx / widthPx, 0.0, 1.0);
    float epsilon = clamp(EDGE_SOFTNESS_PX / widthPx, 0.0001, 0.5);
    float top = sqrt(1.0 + epsilon);
    return (top - sqrt(max(1.0 - x * x, 0.0) + epsilon)) / (top - sqrt(epsilon));
}
float filteredCircularLens(float distancePx, float widthPx) {
    return 0.25 * (circularLens(distancePx - 0.375, widthPx)
                 + circularLens(distancePx - 0.125, widthPx)
                 + circularLens(distancePx + 0.125, widthPx)
                 + circularLens(distancePx + 0.375, widthPx));
}

vec3 getBlurredColor(vec2 coord, float blurRadius) {
    if (blurRadius < 0.01)            // slider at 0: one tap, not 25
        return getTextureColorAt(coord);
    vec3 color = vec3(0.0);
    float totalWeight = 0.0;
    for (int x = -2; x <= 2; x++) {
        for (int y = -2; y <= 2; y++) {
            vec2 offset = vec2(float(x), float(y)) * blurRadius;
            float weight = exp(-0.5 * (float(x * x + y * y)) / 2.0);
            color += getTextureColorAt(coord + offset) * weight;
            totalWeight += weight;
        }
    }
    return color / totalWeight;
}

void main() {
    vec2  fragCoord  = qt_TexCoord0 * panelSize;
    vec2  glassCoord = fragCoord - panelSize * 0.5;
    vec2  halfSize   = panelSize * 0.5;

    float size = min(panelSize.x, panelSize.y);
    float r    = min(size * 0.5, maxCornerRadius);

    float sdEdge = sdf(glassCoord, halfSize, r);
    float aa = clamp(0.5 - sdEdge / max(fwidth(sdEdge), 1e-4), 0.0, 1.0);
    if (aa <= 0.0) { fragColor = vec4(0.0); return; }

    // Smoothed distance + direction (Shoji's island-smooth, H then V).
    const float W[5] = float[5](0.0625, 0.25, 0.375, 0.25, 0.0625);
    float distance = 0.0;
    vec2  inward   = vec2(0.0);
    for (int i = 0; i < 5; i++) {
        for (int j = 0; j < 5; j++) {
            vec2  q = glassCoord + vec2(float(i - 2), float(j - 2)) * SMOOTHING_PX;
            float w = W[i] * W[j];
            distance -= w * sdf(q, halfSize, r);
            inward   -= w * sdfGrad(q, halfSize, r);
        }
    }
    distance = max(distance, 0.0);
    float magnitude = length(inward);
    inward /= max(magnitude, 1e-4);
    float coherence = smoothstep(0.15, 0.85, magnitude);

    float rimWidth = max(lensRimPx, 1.0);
    float profile  = filteredCircularLens(distance, rimWidth);
    float pull     = min(max(lensStrength, 0.0), 1.0) * rimWidth;
    vec2  glassColorCoord = fragCoord + inward * profile * coherence * pull;

    float x = 1.0 - clamp(distance / rimWidth, 0.0, 1.0);
    float blurRadius = lensBlur * (1.0 - x * 0.5);

    float chromaticProfile = filteredCircularLens(distance, max(rimWidth * 0.5, 1.0));
    vec2  dispersion = inward * coherence * chromaticProfile * lensChroma;
    vec3  glassColor = vec3(
        getBlurredColor(glassColorCoord + dispersion, blurRadius).r,
        getBlurredColor(glassColorCoord, blurRadius).g,
        getBlurredColor(glassColorCoord - dispersion, blurRadius).b
    );

    glassColor *= vec3(lensTint);
    fragColor = vec4(glassColor, 1.0) * aa;
}
