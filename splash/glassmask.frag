#version 440

// Glass in the shape of whatever is in the mask.
//
// The panel material (brolliglass.frag, ported by port-material.py) builds its
// edges from a rounded-rect SDF, so it can only ever be a rounded rectangle.
// Letters are not rectangles, and masking a rectangle into an S throws away
// every edge -- which is where the entire character of the material lives.
//
// So this takes the shape from a MASK texture instead: the letters, rendered
// white. The mask's own gradient becomes the surface normal, so refraction,
// dispersion and the rim all happen at the letter's edge. Same ideas as the
// panel material, different source of shape.
//
//   thickness   a smoothed read of the mask. 1 deep inside a stroke, falling
//               to 0 at its edge. This is the "how much glass is here" term.
//   normal      the mask's gradient. Points out of the letter, so it is what
//               the backdrop gets bent along.
//
// Everything else follows the panel material: bend the backdrop by the normal,
// split the colour channels slightly more at the edge than the middle, add a
// specular rim where the surface turns most sharply, and lift the whole thing
// a touch so it reads as a body rather than a hole.

layout(location = 0) in  vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;

    vec2  panelSize;      // the wordmark box, in px
    vec2  texSize;        // backdrop texture, padded
    float pad;            // padding on each side of the backdrop

    float edgeSoftness;   // px over which the edge fades
    float thickness;      // how far in the "deep" part starts
    float refractStrength;// how hard the backdrop bends at the edge
    float chroma;         // channel separation, px at full edge
    float rimStrength;    // specular rim
    float rimWidth;       // px
    float bodyLift;       // flat lightening, so glass is not a hole
    float innerShade;     // darkening just inside the edge, for depth
    float revealEdge;     // px: everything left of this is drawn
    float revealSoft;     // px: how sharp that boundary is
    float revealSlant;    // shifts the boundary with height, for a pen angle
    float useOrder;       // 1 = a reveal-order map is supplied
    float debugView;      // 0 off, 1 order as grey, 2 mask alpha, 3 wipe
    vec4  tint;
};

layout(binding = 1) uniform sampler2D source;   // the backdrop
layout(binding = 2) uniform sampler2D mask;      // the shape, in alpha
layout(binding = 3) uniform sampler2D orderTex;  // when each pixel is written

// Backdrop sample in panel pixels, mapped into the padded texture.
vec3 backdrop(vec2 px) {
    return texture(source, (vec2(pad) + px) / texSize).rgb;
}

float maskAt(vec2 px) {
    return texture(mask, px / panelSize).a;
}

// A smoothed read of the mask. Plain alpha is a hard 0/1 step at this size, so
// it is averaged over a small disc -- that average IS the thickness field, and
// its gradient is the normal. One sampling pattern gives both.
float smoothMask(vec2 px, float r) {
    const vec2 K[8] = vec2[8](
        vec2( 1.0,  0.0), vec2(-1.0,  0.0), vec2( 0.0,  1.0), vec2( 0.0, -1.0),
        vec2( 0.707,  0.707), vec2(-0.707,  0.707),
        vec2( 0.707, -0.707), vec2(-0.707, -0.707));
    float a = maskAt(px) * 2.0;
    float w = 2.0;
    for (int i = 0; i < 8; ++i) {
        a += maskAt(px + K[i] * r);
        w += 1.0;
    }
    return a / w;
}

void main() {
    vec2 px = qt_TexCoord0 * panelSize;

    // Debug views. Guessing at why a shader looks wrong is how the last hour
    // went; these show the inputs directly.
    if (debugView > 0.5) {
        vec4 om = texture(orderTex, qt_TexCoord0);
        float ord = (om.r * 255.0 * 256.0 + om.g * 255.0) / 65535.0;
        float a = texture(mask, qt_TexCoord0).a;
        if (debugView < 1.5)        fragColor = vec4(vec3(ord), 1.0);          // order
        else if (debugView < 2.5)   fragColor = vec4(vec3(a), 1.0);            // shape
        else {
            float wv = clamp((revealEdge - ord) / max(revealSoft, 0.0001), 0.0, 1.0);
            fragColor = vec4(wv * a, a * 0.25, (1.0 - wv) * a, 1.0);           // wipe
        }
        return;
    }

    float alpha = maskAt(px);
    float near  = smoothMask(px, edgeSoftness);
    float far   = smoothMask(px, edgeSoftness * 2.5);

    // Nothing here and nothing nearby: cheapest possible exit.
    if (alpha < 0.002 && near < 0.002) {
        fragColor = vec4(0.0);
        return;
    }

    // TWO gradients, at different scales, because they do different jobs.
    //
    // The narrow one hugs the edge and is what a rim would ride on. The wide
    // one still has a direction in the MIDDLE of a stroke, where the narrow
    // one has gone flat -- and a flat normal means no bend, which is why the
    // middle of every letter looked like plain wallpaper. Refracting along the
    // wide gradient makes the whole stroke behave like a rod of glass instead
    // of a hole with a bright edge.
    float e = max(edgeSoftness, 0.75);
    vec2 grad = vec2(
        smoothMask(px + vec2(e, 0.0), edgeSoftness) - smoothMask(px - vec2(e, 0.0), edgeSoftness),
        smoothMask(px + vec2(0.0, e), edgeSoftness) - smoothMask(px - vec2(0.0, e), edgeSoftness));

    float wr = max(edgeSoftness * 4.0, 4.0);
    vec2 gradWide = vec2(
        smoothMask(px + vec2(wr, 0.0), wr) - smoothMask(px - vec2(wr, 0.0), wr),
        smoothMask(px + vec2(0.0, wr), wr) - smoothMask(px - vec2(0.0, wr), wr));

    float slope = length(grad);
    vec2  normal = slope > 0.0001 ? grad / slope : vec2(0.0);
    float slopeWide = length(gradWide);
    vec2  bodyNormal = slopeWide > 0.0001 ? gradWide / slopeWide : normal;

    // 0 at the edge, 1 well inside. The lens is strongest where the surface
    // turns, which is exactly where this is changing fastest.
    float depth = clamp((far - (1.0 - thickness)) / max(thickness, 0.001), 0.0, 1.0);
    float edge  = 1.0 - depth;

    // Bend along the BODY normal, across the whole stroke. The edge still
    // bends hardest -- that is where a real surface turns most -- but the
    // middle is no longer left flat.
    float bend = mix(0.35, 1.0, edge * edge);
    vec2 offset = -bodyNormal * refractStrength * bend;
    vec2 sampleAt = px + offset;

    // Dispersion: the channels take slightly different paths, and only
    // noticeably so near the edge.
    float split = chroma * edge;
    vec3 col;
    col.r = backdrop(sampleAt + normal * split).r;
    col.g = backdrop(sampleAt).g;
    col.b = backdrop(sampleAt - normal * split).b;

    // Just inside the edge the glass is deepest and reads darker.
    col *= 1.0 - innerShade * edge * (1.0 - edge) * 4.0;   // gentle, see QML

    // No rim. At this stroke width ANY specular term along the edge traces
    // every letter in white, and the eye reads that as lettering with a
    // border rather than as glass. The refraction and the dispersion are what
    // make it read as a material; the rim was only ever decorating an outline.
    // rimStrength and rimWidth stay in the block so the uniforms still line up.

    // A little body, so it is glass rather than a hole in the wallpaper.
    col = mix(col, vec3(1.0), bodyLift);
    col = mix(col, tint.rgb, tint.a);

    // Coverage comes from the letter's OWN alpha and nothing else.
    //
    // This used to add a fraction of `near`, the smoothed mask -- which is
    // non-zero OUTSIDE the ink by design, since that is what makes it smooth.
    // So every letter got a band of glass around it, and no amount of
    // removing highlights was ever going to shift it, because it was not a
    // highlight: it was glass drawn where there is no letter.
    //
    // The mask is already antialiased, so its alpha is the right edge.
    float cover = smoothstep(0.0, 0.85, alpha);

    // How it gets drawn rather than faded.
    //
    // The mask's R and G carry, 16-bit, WHEN each pixel should appear:
    // distance from the pen-down point measured through the ink, not across
    // the image. Comparing that against progress makes the reveal travel
    // along the strokes -- into a stem, along it, around a loop -- which is
    // what reads as handwriting. A wipe cannot: it crosses a vertical stroke
    // all at once, and the eye sees a fade.
    //
    // Without an order map it falls back to the slanted wipe.
    float wipe;
    if (useOrder > 0.5) {
        vec4 m = texture(orderTex, px / panelSize);
        float order = (m.r * 255.0 * 256.0 + m.g * 255.0) / 65535.0;
        // revealEdge is 0..1 here, and the soft band is a fraction of the word.
        wipe = clamp((revealEdge - order) / max(revealSoft, 0.0001), 0.0, 1.0);
    } else {
        float wipeX = px.x + (px.y - panelSize.y * 0.5) * revealSlant;
        wipe = clamp((revealEdge - wipeX) / max(revealSoft, 0.001), 0.0, 1.0);
    }

    fragColor = vec4(col, 1.0) * cover * wipe * qt_Opacity;
}
