#version 300 es
precision highp float;
precision highp sampler2D;

// TEMPORARY EXPERIMENT -- this is NOT the Brolli material.
//
// A port of ShojiWM's island-refract.frag (bea4dev/true-liquid-glass-shojiwm,
// shojiwm/src/island-refract.frag) so it can be judged on the real panels.
//     hyprctl glassopt material shoji
//
// The shader BODY is Shoji's, unchanged apart from GLES 3.00 dialect
// (texture2D -> texture). Parameters are Shoji's own ISLAND_GLASS_OPTIONS from
// island-glass.ts. What is substituted, and why:
//
//   sharp_scene / soft_scene / edge_scene -> all the plugin's sharp capture.
//       Shoji pre-blurs soft/edge with dual-Kawase. No blur was asked for, so
//       all three are the same texture and backgroundAt()'s mixing is a no-op.
//
//   silhouette / distance_field -> computed analytically.
//       Shoji derives them from the layer's alpha with jump-flood passes,
//       because its compositor cannot see the shape. These panels are known
//       rounded rectangles, so the same signed distance (positive inside,
//       clamped to Shoji's distance_limit_px of 120) is evaluated exactly.
//       Shoji's own 3px Sobel normal estimate below is kept unchanged, which
//       preserves its "coherence" attenuation near the middle of thin shapes.
//       Not reproduced: Shoji's extra 5-tap smoothing of the field.

in vec2 qt_TexCoord0;   // panel-local UV, 0..1
out vec4 fragColor;

uniform sampler2D source;
uniform vec2  panelSize;
uniform vec2  texSize;
uniform float pad;
uniform float maxCornerRadius;

// ---- Shoji's parameters (island-glass.ts, ISLAND_GLASS_OPTIONS) ----
const float rim_width_px       = 30.0;
const float refraction_px      = 30.0;
const float chromatic_shift_px = 0.90;
const float highlight_strength = 1.0;
uniform float debug_view;               // Shoji's debug views, live: hyprctl glassuniform debug_view 0..3
const float blur_mix           = 1.0;
const float edge_softness_px   = 2.0;
const float bevel_width_px     = 10.0;
const float bevel_shadow       = 0.0;
const float distance_limit_px  = 120.0; // island-height.frag

// ---- substitutions (see header) ----
float sdRoundRect(vec2 p, vec2 b, float r) {
    vec2 d = abs(p) - b + vec2(r);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
}
float cornerRadius() { return min(min(panelSize.x, panelSize.y) * 0.5, maxCornerRadius); }
// capture-texture UV -> signed distance to the panel edge, positive inside
float distanceAt(vec2 uv) {
    vec2 p = uv * texSize - vec2(pad) - panelSize * 0.5;
    return clamp(-sdRoundRect(p, panelSize * 0.5, cornerRadius()), -distance_limit_px, distance_limit_px);
}
vec3 sceneAt(vec2 uv) { return texture(source, uv).rgb; }

// ============ below: Shoji's island-refract.frag, unchanged ============

// Circular lens profile from Aghajari's Liquid Glass article:
// https://www.aghajari.com/publications/liquid-glass/
// t is distance FROM the boundary; x = 1-t in the article.
float circularLens(float distancePx, float widthPx) {
    float x = 1.0 - clamp(distancePx / widthPx, 0.0, 1.0);
    // A small finite lens thickness rounds off the singular derivative.
    // Preserve both endpoints and the circular character of the profile.
    float epsilon = clamp(edge_softness_px / widthPx, 0.0001, 0.5);
    float top = sqrt(1.0 + epsilon);
    return (top - sqrt(max(1.0 - x * x, 0.0) + epsilon))
        / (top - sqrt(epsilon));
}

float filteredCircularLens(float distancePx, float widthPx) {
    // Average over one framebuffer pixel: the ideal circle has an infinite
    // slope at the rim. Subpixel filtering softens only that last pixel,
    // reducing shimmer without replacing the circular profile by smoothstep.
    return 0.25 * (circularLens(distancePx - 0.375, widthPx)
                 + circularLens(distancePx - 0.125, widthPx)
                 + circularLens(distancePx + 0.125, widthPx)
                 + circularLens(distancePx + 0.375, widthPx));
}

vec3 backgroundAt(vec2 uv, vec2 size, float edgeBlur) {
    uv = clamp(uv, 0.5 / size, 1.0 - 0.5 / size);
    vec3 soft = mix(sceneAt(uv), sceneAt(uv), edgeBlur);          // soft_scene, edge_scene
    return mix(sceneAt(uv), soft, clamp(blur_mix, 0.0, 1.0));      // sharp_scene
}

void main() {
    vec2 size = texSize;
    vec2 uv = (vec2(pad) + qt_TexCoord0 * panelSize) / texSize;    // effect.texture_uv

    // silhouette: Shoji thresholds layer alpha; here, the shape's own coverage
    float dCenter = -sdRoundRect(qt_TexCoord0 * panelSize - panelSize * 0.5, panelSize * 0.5, cornerRadius());
    float mask = clamp(0.5 + dCenter / max(fwidth(dCenter), 1e-4), 0.0, 1.0);
    if (mask <= 0.001) {
        fragColor = vec4(0.0);
        return;
    }

    vec2 dx = vec2(3.0 / size.x, 0.0);
    vec2 dy = vec2(0.0, 3.0 / size.y);
    // Sobel estimate: merge three parallel differences instead of trusting
    // a single pair of samples on a changing rasterized corner.
    float tl = distanceAt(uv - dx - dy);
    float tr = distanceAt(uv + dx - dy);
    float bl = distanceAt(uv - dx + dy);
    float br = distanceAt(uv + dx + dy);
    vec2 gradient = vec2(tr + 2.0 * distanceAt(uv + dx) + br
                         - tl - 2.0 * distanceAt(uv - dx) - bl,
                         bl + 2.0 * distanceAt(uv + dy) + br
                         - tl - 2.0 * distanceAt(uv - dy) - tr) / 24.0;
    float magnitude = length(gradient);
    vec2 inward = gradient / max(magnitude, 0.0001);
    float distance = max(distanceAt(uv), 0.0);
    float rimWidth = max(rim_width_px, 1.0);
    // Gentle in the interior, steeply curved close to the boundary.
    float profile = filteredCircularLens(distance, rimWidth);
    // Opposing normals cancel at a neck: attenuate rather than flip direction.
    float coherence = smoothstep(0.15, 0.85, magnitude);
    vec2 bend = inward * profile * coherence;
    float strength = min(max(refraction_px, 0.0), rimWidth);
    vec2 offset = bend * strength / size;
    // Separate RGB around the refracted coordinate along the same normal.
    float chromaticProfile = filteredCircularLens(distance, max(rimWidth * 0.5, 1.0));
    vec2 dispersion = inward * coherence * chromaticProfile * chromatic_shift_px / size;
    float edgeBlur = 0.8 * profile;
    vec3 color = vec3(backgroundAt(uv + offset + dispersion, size, edgeBlur).r,
                      backgroundAt(uv + offset, size, edgeBlur).g,
                      backgroundAt(uv + offset - dispersion, size, edgeBlur).b);

    float light = dot(-inward, normalize(vec2(-0.45, -0.89)));
    float bevel = max(bevel_width_px, 1.0);
    float rim = exp(-distance / 1.6) * coherence;
    float innerBand = exp(-pow((distance - bevel * 0.5) / (bevel * 0.45), 2.0)) * coherence;
    // Thin reflection plus a broader inset shadow communicate a rounded lip.
    // Use mostly neutral light, avoiding a colored outline on bright backdrops.
    color *= 1.0 - clamp(bevel_shadow, 0.0, 0.6) * innerBand * (0.5 + 0.5 * max(-light, 0.0));
    color += vec3(0.94, 0.97, 1.0) * highlight_strength
        * (rim * (0.3 + 0.7 * max(light, 0.0)) + innerBand * 0.22 * max(light, 0.0));

    if (debug_view > 2.5) color = vec3(0.5 + bend * 0.5, 0.5);
    else if (debug_view > 1.5) color = vec3(clamp(distance / rimWidth, 0.0, 1.0));
    else if (debug_view > 0.5) color = vec3(1.0);
    fragColor = vec4(color * mask, mask);
}
