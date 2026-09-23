#version 300 es
precision highp float;
precision highp sampler2D;

// TEMPORARY EXPERIMENT -- this is NOT the Brolli material.
//
// A faithful port of a third-party Liquid Glass recreation (Aghajari-style,
// the same algorithm as ShojiWM's older liquid-glass.frag), pasted by Joel so
// it can be judged on the real panels next to his own material. Switch with:
//     hyprctl glassopt material aghajari
//     hyprctl glassopt material main
//
// Its constants are uniforms, driven by the "Pasted lens" sliders in
// Settings > Liquid glass. Defaults are the original values, so at defaults
// this is pixel-for-pixel the pasted shader:
//     aghDepth 0.3   aghStrength 1.0   aghBlur 1.2
//     aghChroma 3.0  aghEdge 0.02      aghTint 0.90
// aghStrength multiplies the glassSize * 0.5 pull, like distortion_strength
// in ShojiWM's copy of this same shader (shojiwm/src/liquid-glass.frag).
//
// aghStretch (0 = the paste, exactly): the paste bends every pixel away from
// ONE centre point, by glassSize * 0.5 per axis. Right on a circle; on the
// 998x93 dock a pixel on the long top edge 400px from the middle bends ~6 deg
// off horizontal -- sideways along the edge, scaled by the 499px half-width
// -- so content smears toward the middle instead of lensing at the rim.
// At 1 the centre point becomes a centre LINE along the long axis (the panel
// = that segment swept by a disc of half the short side): pixels bend away
// from the nearest point on it, by half the short side. Circles/squares have
// no segment, so they are unchanged; on a pill every cross-section of the
// straight part bends exactly as a cut through a circle's centre does under
// the paste (same 0.3 depth vs 0.5 pull, so the rim still shows content from
// the middle -- a thick glass rod, not a thin ring hugging the edge).
//
// RIM OUTLINE: Joel's white rim from his own material (liquidglasstest.frag),
// copied verbatim -- a thin white line on the edge, fuller on the curved
// parts, boosted at the top-left/bottom-right and fading out at the
// top-right/bottom-left. Driven by that material's existing sliders
// (rimHighlightStrength / rimHighlightWidth / rimDiagonalReach, plus power
// for the normal's corner shape), so both materials share one outline.
// Only change: the line sits on THIS shape's edge (sd) -- the outline drawn.
//
// The optics are copied verbatim: distortion depth 0.3, circular lens profile,
// radial offset from the panel centre scaled by glassSize * 0.5, 5x5 Gaussian
// blur with radius 1.2 * (1 - dist * 0.5), 3px chromatic shift, 0.90 tint.
//
// Adapted plumbing only:
//   - samples the plugin's padded capture instead of a full-screen texture
//   - glass size / centre are the real panel's, not a fixed 120x80 at the mouse
//   - corner radius is the panel's own (was a fixed 16px)
// Two small safety changes, both NOT in the original:
//   - anti-aliased outer edge (the original cuts hard: a jagged edge would make
//     the comparison unfair)
//   - safe normalize at the exact centre (normalize(vec2(0)) is NaN, and
//     0 * NaN is still NaN -- the original produces a bad pixel there)

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
