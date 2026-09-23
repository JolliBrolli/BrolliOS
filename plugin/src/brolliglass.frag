#version 300 es
precision highp float;
precision highp sampler2D;

// The Brolli-Glass material.
//
// Based on Aghajari's Liquid Glass recreation
// (https://www.aghajari.com/publications/liquid-glass/, the same algorithm as
// ShojiWM's liquid-glass.frag): circular lens profile, radial offset, a small
// Gaussian softening, chromatic split at the rim, and a tint. Its constants
// are the agh* uniforms, and at their defaults this is that shader.
//
// What this adds on top:
//   aghStretch      the paste bends every pixel away from ONE centre point,
//                   which smears sideways along a long panel like the dock
//                   (a pixel 400px along the top edge bends ~6 deg off
//                   horizontal, scaled by the half-WIDTH). At 1 the centre
//                   becomes a LINE along the long axis, so long edges bend
//                   straight across; circles and squares are unchanged.
//   readability     panel-wide contrast squash + brightness push + body,
//                   from panelStats -- see the block above the code.
//   rim outline     the white rim from the shell's original material,
//                   verbatim, on this shape's edge.
//   glassOverGlass  drops the softening when this panel sits on glass.
//   9-tap blur      the paste's 5x5 Gaussian taken in 9 samples using the
//                   GPU's blending between pixels: 75 backdrop reads per
//                   pixel -> 27, worth ~0.26 W while dragging.
//
// Plumbing differences from the paste: it samples the plugin's padded capture
// (not a full-screen texture), the size/centre/radius are the real panel's,
// the outer edge is anti-aliased, and normalize() is guarded at the centre.

in vec2 qt_TexCoord0;   // panel-local UV, 0..1 (top-left origin)
out vec4 fragColor;

uniform sampler2D source;
uniform vec2  panelSize;
uniform vec2  texSize;
uniform float pad;
uniform float maxCornerRadius;

uniform float aghDepth;      // was 0.3
uniform float aghStrength;   // was 1.0 (implicit)
uniform float aghBlur;       // was blurIntensity = 1.2
uniform float aghChroma;     // was 3.0
uniform float aghEdge;       // was 0.02
uniform float aghTint;       // was 0.90
uniform float aghStretch;    // 0 = centre point (the paste), 1 = centre line

// Readability -- Apple's "the amount of tint and the dynamic range shift to
// always ensure buttons remain legible" (WWDC25 Meet Liquid Glass), done per
// PANEL: the plugin measures the backdrop under the whole panel once
// (panelStats: mean luma, mean luma^2) and every pixel gets the SAME
// transform, so nothing varies at text-stroke scale (the old per-pixel floor
// striped busy backdrops) and, with k > 0, brighter always stays brighter.
//   out = target + (colour - mean) * k
//   k      = 1 - aghSquash * busyness   (busyness = luma spread / 0.25)
//   target = mean + glassDir * aghPush * need   (glassDir: +1 dark text, -1 light)
// `need` is 0 while the backdrop already contrasts with the text (a dark
// backdrop under white text is left alone -- pushing it darker is what
// turned glass over dark wallpaper black) and ramps in only as the backdrop's
// brightness approaches the text's. The push is a bounded nudge from the real
// mean, not a fixed level, so a panel cannot lock on the wrong side.
// aghSquash = aghPush = 0 is off.
//
// Glass body (aghBody): the lens only MOVES backdrop pixels -- it adds no
// light -- so over a dark backdrop it was exactly as dark as the backdrop:
// a black shape with a rim. Apple's glass adds light of its own (WWDC25:
// highlights, illumination "from within", "a softer scattering of light").
// This is a faint uniform lift toward white across the panel: the same
// amount everywhere, so it cannot stripe.
uniform sampler2D panelStats;
uniform int   panelStatsLevel;
uniform float glassDir;
uniform float aghSquash;
uniform float aghPush;
uniform float aghBody;
// 1 when this panel is drawn over glass already drawn this frame (a dropdown
// over a widget). Its backdrop is already softened, so softening it again is
// blur on blur -- Apple: avoid the material on both layers.
uniform float glassOverGlass;

// Tint -- liquidglasstest.frag's own uniform: rgb = colour (the shell sends
// the dark-mode colour, or white in light mode), a = strength. Per panel via
// the plugin's namespace overrides (tint@quickshell:macDock, ...).
uniform vec4 tint;

// Rim outline -- liquidglasstest.frag's own uniforms, same values.
uniform float power;
uniform float rimHighlightStrength;
uniform float rimHighlightWidth;
uniform float rimDiagonalReach;

// c is panel-local pixels, origin at the panel's top-left
vec3 getTextureColorAt(vec2 c) {
    return texture(source, (vec2(pad) + c) / texSize).rgb;
}

float sdf(vec2 p, vec2 b, float r) {
    vec2 d = abs(p) - b + vec2(r);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
}

// ---- verbatim from liquidglasstest.frag ----
vec2 sdSuperellipseRoundRectNormal(vec2 p, vec2 halfSize, float r, float n) {
    vec2 s = sign(p);
    vec2 q = abs(p) - (halfSize - vec2(r));
    if (q.x <= 0.0 || q.y <= 0.0)
        return (q.x > q.y) ? vec2(s.x, 0.0) : vec2(0.0, s.y);
    vec2 u  = max(q, vec2(1e-6)) / max(r, 1e-4);
    vec2 g  = s * pow(u, vec2(n - 1.0));
    float len = length(g);
    return len > 1e-6 ? g / len : vec2(0.0);
}

float sdCornerFactor(vec2 p, vec2 halfSize, float r) {
    vec2 q = abs(p) - (halfSize - vec2(r));
    float signedDist = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0);
    return smoothstep(-max(r, 1e-4), 0.0, signedDist);
}
// ---- end verbatim ----

// The recreation's 5x5 Gaussian (weights exp(-0.5*(x*x+y*y)/2)), taken in 9
// samples instead of 25. The GPU blends between neighbouring pixels for free,
// so one sample placed between two of the original ones can carry both: the
// 1D weights 0.7788 (at 1) and 0.3679 (at 2) become a single sample at
// 1.32087 with their combined weight 1.14668, and the same in both axes.
// Exact when the spacing is one pixel; a close approximation otherwise (the
// blended pair is not quite the sum of two separate samples). 75 backdrop
// reads per pixel -> 27; measured worth ~0.5 W of the ~1.5 W the glass costs
// while dragging a window (2026-09-23).
vec3 getBlurredColor(vec2 coord, float blurRadius) {
    if (blurRadius < 0.01)            // slider at 0: one tap (same result)
        return getTextureColorAt(coord);
    const float O  = 1.32087;   // paired sample offset, in blurRadius units
    const float W1 = 1.14668;   // its weight (0.778801 + 0.367879)
    float o = O * blurRadius;
    vec3  color = getTextureColorAt(coord);
    color += (getTextureColorAt(coord + vec2(o, 0.0)) + getTextureColorAt(coord - vec2(o, 0.0))
            + getTextureColorAt(coord + vec2(0.0, o)) + getTextureColorAt(coord - vec2(0.0, o))) * W1;
    color += (getTextureColorAt(coord + vec2(o, o)) + getTextureColorAt(coord + vec2(o, -o))
            + getTextureColorAt(coord + vec2(-o, o)) + getTextureColorAt(coord - vec2(o, o))) * (W1 * W1);
    return color / (1.0 + 4.0 * W1 + 4.0 * W1 * W1);
}

void main() {
    vec2  glassSize   = panelSize;
    vec2  fragCoord   = qt_TexCoord0 * panelSize;
    vec2  glassCenter = panelSize * 0.5;
    vec2  glassCoord  = fragCoord - glassCenter;

    float size = min(glassSize.x, glassSize.y);
    float r    = min(size * 0.5, maxCornerRadius);
    float sd   = sdf(glassCoord, glassSize * 0.5, r);
    float inversedSDF = -sd / size;

    float aa = clamp(0.5 - sd / max(fwidth(sd), 1e-4), 0.0, 1.0);
    if (aa <= 0.0) { fragColor = vec4(0.0); return; }

    // The "centre": a point in the paste, stretched into a segment along the
    // long axis by aghStretch. Both the direction and the pull are measured
    // from the nearest point on it; at aghStretch 0 coreHalf is 0 and every
    // line below reduces to the original.
    vec2  halfSize  = glassSize * 0.5;
    vec2  coreHalf  = max(halfSize - vec2(min(halfSize.x, halfSize.y)), 0.0) * clamp(aghStretch, 0.0, 1.0);
    vec2  fromCore  = glassCoord - clamp(glassCoord, -coreHalf, coreHalf);
    float coreDist  = length(fromCore);
    vec2  normalizedGlassCoord = fromCore / max(coreDist, 1e-4);
    float distFromCenter = 1.0 - clamp(inversedSDF / max(aghDepth, 1e-4), 0.0, 1.0);
    float distortion = 1.0 - sqrt(1.0 - pow(distFromCenter, 2.0));
    vec2  offset = distortion * normalizedGlassCoord * (halfSize - coreHalf) * aghStrength;
    vec2  glassColorCoord = fragCoord - offset;

    float blurIntensity = aghBlur * (glassOverGlass > 0.5 ? 0.0 : 1.0);
    float blurRadius = blurIntensity * (1.0 - distFromCenter * 0.5);

    float edge  = smoothstep(0.0, max(aghEdge, 1e-4), inversedSDF);
    // The paste splits colour across the whole interior, pointing away from
    // the centre. Around a point that direction turns smoothly; across a
    // centre LINE it flips, which would leave a 2 x aghChroma seam along the
    // middle of the dock. Fade the split in over a few px from the line --
    // scaled by aghStretch, so at 0 it is exactly the paste.
    float lineFadePx = 8.0 * clamp(aghStretch, 0.0, 1.0);
    float lineFade   = lineFadePx > 1e-3 ? smoothstep(0.0, lineFadePx, coreDist) : 1.0;
    vec2  shift = normalizedGlassCoord * edge * aghChroma * lineFade;
    vec3  glassColor = vec3(
        getBlurredColor(glassColorCoord - shift, blurRadius).r,
        getBlurredColor(glassColorCoord, blurRadius).g,
        getBlurredColor(glassColorCoord + shift, blurRadius).b
    );

    glassColor *= vec3(aghTint); // glass tint

    if (aghSquash > 0.0 || aghPush > 0.0) {
        vec2  st   = texelFetch(panelStats, ivec2(0), panelStatsLevel).rg;
        float mean = st.x * aghTint;                       // same scale as glassColor
        float busy = clamp(sqrt(max(st.y - st.x * st.x, 0.0)) / 0.25, 0.0, 1.0);
        float k      = 1.0 - clamp(aghSquash, 0.0, 1.0) * busy;
        float need   = glassDir < 0.0 ? smoothstep(0.30, 0.50, mean) : 1.0 - smoothstep(0.50, 0.70, mean);
        float target = clamp(mean + glassDir * aghPush * need, 0.0, 1.0);
        glassColor = vec3(target) + (glassColor - vec3(mean)) * k;
    }

    glassColor = mix(glassColor, vec3(1.0), clamp(aghBody, 0.0, 1.0));

    // Colour tint, exactly as liquidglasstest.frag applies it: after the
    // glass colour, before the rim highlight.
    glassColor = mix(glassColor, tint.rgb, tint.a);

    // Rim outline, as liquidglasstest.frag computes it (see its comments for
    // why each factor is there). pullScale/radius/refractPower/normalDir are
    // that material's own definitions.
    {
        vec2  halfSz    = max(glassSize * 0.5, vec2(1.0));
        float pullScale = min(halfSz.x, halfSz.y);
        float radius    = min(min(halfSz.x, halfSz.y), max(maxCornerRadius, 1.0));
        const float REFRACT_POWER_CAP = 6.0;
        float refractPower = min(power, REFRACT_POWER_CAP);
        vec2  normalDir = sdSuperellipseRoundRectNormal(glassCoord, halfSz, pullScale, refractPower);

        float rimWeight = exp(-sd * sd / max(2.0 * rimHighlightWidth * rimHighlightWidth, 1e-6));
        const float CORNER_EMPHASIS_FLOOR = 0.55;
        float cornerFactor = sdCornerFactor(glassCoord, halfSz, pullScale);
        rimWeight *= mix(CORNER_EMPHASIS_FLOOR, 1.0, cornerFactor);

        float radiusCapRatio    = clamp(radius / max(pullScale, 1.0), 0.0, 1.0);
        float effectiveDiagonalBoost = mix(1.0, 2.5, radiusCapRatio);
        const float OFF_DIAGONAL_FADE = 0.0;
        const float FLAT_EDGE_ALIGN   = 0.70710678;
        float diagAlign = abs(dot(normalDir, normalize(vec2(-1.0, -1.0))));
        float diagRampAbove = pow(clamp((diagAlign - FLAT_EDGE_ALIGN) / (1.0 - FLAT_EDGE_ALIGN), 0.0, 1.0), rimDiagonalReach);
        float diagRampBelow = pow(clamp(diagAlign / FLAT_EDGE_ALIGN, 0.0, 1.0), rimDiagonalReach);
        float diagonalTarget = diagAlign >= FLAT_EDGE_ALIGN
            ? mix(1.0, effectiveDiagonalBoost, diagRampAbove)
            : mix(OFF_DIAGONAL_FADE, 1.0, diagRampBelow);
        rimWeight *= diagonalTarget;

        glassColor = mix(glassColor, vec3(1.0), rimWeight * rimHighlightStrength);
    }
    fragColor = vec4(glassColor, 1.0) * aa;
}
