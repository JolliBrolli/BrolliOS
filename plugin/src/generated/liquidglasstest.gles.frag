#version 300 es
precision highp float;
precision highp sampler2D;

// qt_Opacity has no meaning outside Qt's scene graph; the plugin
// composites with its own blend state.
const float qt_Opacity = 1.0;

uniform vec2 panelSize;
uniform vec2 texSize;
uniform float pad;
uniform float power;
uniform float maxCornerRadius;
uniform float fPower;
uniform float fa;
uniform float fb;
uniform float fc;
uniform float fd;
uniform float rimGap;
uniform float refractStrength;
uniform float rimHighlightStrength;
uniform float rimHighlightWidth;
uniform float rimDiagonalReach;
uniform float chromaticAberration;
uniform float blurPx;
uniform vec4 base;
uniform float baseOpacity;
uniform vec4 textColor;
uniform vec4 tint;
uniform float frostSaturation;
uniform float frostDarken;
uniform float frostBlur;
uniform float minFloor;
uniform float busynessStrength;

// Test rig for the "true" continuous liquid-glass refraction technique
// (OverShifted/LiquidGlass's superellipse-SDF approach — see ~/LiquidGlass,
// assets/shaders/BatchRenderer2D.glsl's LiquidGlass() function), applied
// UNIFORMLY across the whole shape: one continuous formula, no rim/interior
// split, no per-region branching.
//
// Reverted from a self-reflection "guard" attempt (push outward + blend
// toward a static wallpaper-file fallback in the deep interior): the guard
// blend was mathematically continuous but still looked wrong — a live,
// reactive edge next to a dead, static-forever centre reads as broken
// regardless of how smooth the blend curve is. That's a structural
// liveness mismatch, not a tuning problem, and matches what the file's own
// prior history already found ("user didn't want a two-material look").
// Self-reflection is deliberately accepted here again; the harder problem
// goes to the compositor-level (HyprGlass) investigation instead.

in vec2 qt_TexCoord0;
out vec4 fragColor;



uniform sampler2D source;
// Same crop/coordinate space as `source`, but already horizontally blurred
// by a separate pre-pass (see liquidglasshblur.frag) — sampleBlurred below
// only needs to do the vertical half, making the full 2D blur a 9+9-tap
// separable pair instead of a single 9x9 (81-tap) pass.
uniform sampler2D sourceHBlur;

// Exact rounded-rectangle SDF (Inigo Quilez's formula) with a superellipse
// corner curve instead of a plain circular arc. p is pixel-space relative to
// the box centre, halfSize is the box's own half-extents, r is the corner
// radius (pixels, same units as halfSize). For a SQUARE box with r ==
// halfSize.x == halfSize.y this degenerates to the old plain superellipse
// (b-r == 0, no flat edge at all) — exactly GlassTest's shape, unchanged.
// For a wide/short box (a search-bar pill) this correctly gives flat
// top/bottom edges with the curve confined to the corners, instead of the
// old formula's true ellipse (which touched and curved along all 4 edges —
// fine for a square, wrong for anything else).
// qp normalized to [0,1] by the corner radius before any pow() call. Raising
// raw pixel values (e.g. up to a 200px corner radius) to a high exponent
// loses float precision fast and behaves inconsistently depending on the
// box's absolute size; normalizing first keeps pow() operating on [0,1]
// regardless of n or box size, so high `power` values (10+) stay numerically
// solid and the shape's sharpness reads consistently across any box size.
float sdSuperellipseRoundRect(vec2 p, vec2 halfSize, float r, float n) {
    vec2 q  = abs(p) - (halfSize - vec2(r));
    vec2 u  = max(q, vec2(0.0)) / max(r, 1e-4);
    return r * (pow(pow(u.x, n) + pow(u.y, n), 1.0 / n) - 1.0) + min(max(q.x, q.y), 0.0);
}

// |gradient(d)| at p. On a flat edge this SDF is a true Euclidean distance
// (gradient magnitude exactly 1), but the superellipse corner term
// (S = x^n + y^n)^(1/n) does NOT have unit gradient magnitude off-axis for
// n != 2 — it drifts below 1 (more so at higher n), which matters for
// anti-aliasing: fwidth()-based AA assumes "1 unit of d = ~1 pixel on
// screen", and dividing by this before computing the AA band corrects that
// assumption everywhere on the shape, not just on the axes. (The r's from
// the normalization above cancel out of this derivative algebraically, so
// it's still expressed directly in terms of the normalized u.)
float sdSuperellipseRoundRectGradMag(vec2 p, vec2 halfSize, float r, float n) {
    vec2 q = abs(p) - (halfSize - vec2(r));
    if (q.x <= 0.0 || q.y <= 0.0)
        return 1.0;
    vec2  u    = max(q, vec2(1e-6)) / max(r, 1e-4);
    float S    = pow(u.x, n) + pow(u.y, n);
    float Sinv = pow(max(S, 1e-8), 1.0 / n - 1.0);
    vec2  g    = Sinv * vec2(pow(u.x, n - 1.0), pow(u.y, n - 1.0));
    return max(length(g), 1e-4);
}

// Unit outward normal of the above SDF at p. Two regions: on a flat edge
// (q.x <= 0 or q.y <= 0, i.e. not in the corner box) the true gradient is
// just the axis-aligned outward direction; inside the corner region it's the
// superellipse gradient on the normalized corner-local coords u — same
// cancel-the-common-scale-factor trick as before (raw
// sign(x)*|x|^(n-1) direction, normalized). Pulling samples toward the
// shape's centre instead of along this normal is what produced a twisted,
// off-axis warp before; this generalizes that fix to non-square boxes.
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

// 0 on a dead-flat edge, 1 once genuinely inside the 2D corner region,
// smoothly ramped over roughly r px in between. Real specular rim
// highlights only appear where a surface actually curves toward the
// viewer — a flat pane doesn't get a bright line down a straight run — so
// this is what lets the SAME rim settings look correct on both a near-
// circular shape (almost entirely "corner", e.g. Spotlight) and a very
// elongated one (mostly flat with rounding only at the far ends, e.g. the
// dock): the highlight concentrates on the actual curved parts and fades
// out on straight ones.
//
// Uses the SAME exact box-distance construction as the real SDF above
// (length(max(q,0)) for the true 2D corner region, min(max(q.x,q.y),0) for
// the flat zone) rather than a plain min(q.x,q.y) — that simpler version's
// iso-contours (lines of equal "how much corner") are actually angular/
// kinked, not smoothly rounded, which is exactly what read as a visible
// seam where the emphasis kicked in. This formula's contours are properly
// round at the corner (same reason the visible shape itself has no seam
// there), so the emphasis blends in with no visible line where it starts.
float sdCornerFactor(vec2 p, vec2 halfSize, float r) {
    vec2 q = abs(p) - (halfSize - vec2(r));
    float signedDist = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0);
    return smoothstep(-max(r, 1e-4), 0.0, signedDist);
}

const float M_E = 2.718281828459045;

float f(float x) {
    return 1.0 - fb * pow(fc * M_E, -fd * x - fa);
}


vec2 toTex(vec2 pUV) {
    return (vec2(pad) + pUV * panelSize) / texSize;
}

// Separable Gaussian blur, vertical half. The horizontal half already ran
// as its own tiny pre-pass (liquidglasshblur.frag) into sourceHBlur, so
// this only needs a 1D loop along Y — 9 taps here plus 9 in that pre-pass
// is 18 total for the same 2D result the old single-pass 9x9 (81-tap) loop
// gave, at roughly a quarter of the texture reads. This runs on a LIVE
// capture (re-sampled continuously while any glass panel is open), so
// fewer taps is a real continuous saving, not a one-time cost.
vec3 sampleBlurred(vec2 pUV, float radiusPx) {
    if (radiusPx < 1.0)
        return texture(source, toTex(pUV)).rgb;
    float stepPx = radiusPx / max(texSize.y, 1.0);
    vec3 acc = vec3(0.0);
    float w = 0.0;
    for (int j = -4; j <= 4; ++j) {
        float o = float(j);
        float ww = exp(-o * o * 0.13);
        acc += texture(sourceHBlur, toTex(pUV) + vec2(0.0, o * stepPx)).rgb * ww;
        w += ww;
    }
    return acc / max(w, 1e-4);
}

void main() {
    vec2 halfSize = max(panelSize * 0.5, vec2(1.0));
    vec2 p = (qt_TexCoord0 - 0.5) * panelSize;
    // Fully rounded on the short axis by default (a 700x48 box gets a pill;
    // a square box gets the old fully-curved shape back exactly) — matches
    // this codebase's existing "full" rounding convention elsewhere, capped
    // by maxCornerRadius for surfaces (Spotlight) that need a small fixed
    // radius regardless of how tall/narrow the box gets.
    float radius = min(min(halfSize.x, halfSize.y), max(maxCornerRadius, 1.0));
    // The REFRACTION's own depth/reach, kept separate from the visible
    // corner radius above. Capping `radius` for Spotlight (so the corner
    // itself stays small enough not to curve into text) must NOT also
    // shrink how deep the glass appears to bend — that coupling is what
    // turned Spotlight's refraction into barely-there frosting: dist below
    // was saturating to "fully settled, no more pull" within just a
    // ~20-23px band of the edge instead of across the panel's own natural
    // scale. pullScale is the uncapped natural radius the shape would have
    // gotten with no cap at all — same value `radius` always was before
    // maxCornerRadius existed — so the refraction's reach and transition
    // zone stay exactly as strong/wide as before regardless of how tightly
    // the visible corner itself is capped.
    float pullScale = min(halfSize.x, halfSize.y);

    float d = sdSuperellipseRoundRect(p, halfSize, radius, power);
    // Anti-aliased edge: a hard `d > 0 -> discard` cutoff has zero
    // sub-pixel smoothing, which reads as a visibly stair-stepped/choppy
    // boundary on any diagonal or curve. Divide by the SDF's actual local
    // gradient magnitude first (see sdSuperellipseRoundRectGradMag) — off
    // the axes this isn't 1, so skipping that step gave an inconsistent,
    // too-thin AA band specifically at the corners (worse at higher
    // `power`), which is exactly the "still sharp at the corners" look.
    // fwidth() of the normalized distance is then a genuine ~1 screen pixel
    // everywhere on the shape, giving uniform, correct AA regardless of DPI.
    float gradMag = sdSuperellipseRoundRectGradMag(p, halfSize, radius, power);
    float dNorm = d / gradMag;
    float aa = clamp(0.5 - dNorm / max(fwidth(dNorm), 1e-4), 0.0, 1.0);
    if (aa <= 0.0) { fragColor = vec4(0.0); return; }

    // Normalized back to the old ~0..1-at-deepest-point convention so the
    // existing fa/fb/fc/fd falloff-curve tuning stays meaningful. Uses
    // pullScale (uncapped), not radius (capped) — normalizing by a tiny
    // capped radius made dist saturate to "fully settled" within a sliver
    // of the edge, collapsing the whole graded bending zone down to almost
    // nothing.
    float dist = -min(d, 0.0) / max(pullScale, 1.0);
    // Pull inward along the LOCAL surface normal, not the direction from the
    // shape's centre — see sdSuperellipseRoundRectNormal(). Scaled by
    // length(p) so it reduces to the old q*factor behaviour exactly on
    // axes/diagonals where the two directions already agree.
    //
    // The normal direction's own corner sharpness is capped independently
    // of the visible shape's `power` — at high power the outer corner curve
    // gets very tight, so the normal has to rotate through ~90 degrees
    // within a tiny sliver of space. Following that with the refraction pull
    // doesn't read as a smooth bend, it reads as the pull direction
    // "spinning" through that tight turn — concentric rolls/rings right at
    // the corner. Keeping the shape as sharp as requested but the pull
    // field's own rotation gentle fixes that without softening the visible
    // corner at all.
    const float REFRACT_POWER_CAP = 6.0;
    float refractPower = min(power, REFRACT_POWER_CAP);
    // CLAUDE/local, 2026-09-18: reworked per direct visual feedback — the
    // PREVIOUS version gated the decay curve below with an independent
    // smoothstep ramp (rimRamp, 0→1 over rimGap) multiplied against
    // f(dist), which is ALREADY falling the whole time regardless of the
    // ramp. Multiplying a rising ramp against an already-falling curve
    // creates a genuine local maximum — a real geometric bump in the bend
    // strength, not just a rough transition — and it got more pronounced
    // the larger rimGap was, exactly as reported ("a clear bump on the
    // edges of where it joins the glass" once rimGap moved off ~0).
    //
    // Fixed by shifting the SAME proven decay curve's own input by rimGap
    // instead of gating it with a second, independently-shaped ramp — one
    // curve, delayed, rather than two curves multiplied together. For
    // dist < rimGap this holds flat at the curve's own dist=0 strength (a
    // real "gap" — the bend doesn't get any STRONGER inside it, it just
    // doesn't fall off yet); at dist == rimGap it picks up EXACTLY the
    // original (already-tuned, already-correct) decay shape, just
    // starting later. No separate rise-then-fall feature exists to read
    // as a bump, structurally, not just via tuning.
    float distShifted = max(dist - rimGap, 0.0);
    float shrinkFrac = 1.0 - pow(f(distShifted), fPower);
    // pullScale here too, not radius — the direction field's own "corner
    // region" should span the panel's natural corner scale, not the tiny
    // capped visual radius, or the bend direction would snap abruptly at
    // that tiny boundary instead of turning smoothly across a natural-
    // feeling area.
    vec2  normalDir  = sdSuperellipseRoundRectNormal(p, halfSize, pullScale, refractPower);
    // Scaled by `pullScale` (the panel's own uncapped natural scale), NOT
    // length(p) (the point's distance from the box's CENTRE) and NOT the
    // visible-corner `radius` (which can be capped much smaller than the
    // panel, e.g. Spotlight). On a flat edge the normal is already purely
    // axial, so length(p) alone made the pull grow the farther a point sat
    // from centre along that edge — weak near the middle of a long flat
    // edge, strong near the ends — which visibly bulged the refracted
    // content outward toward the ends of a wide/short box (the dock) even
    // though the shape's own alpha edge is genuinely straight there.
    // pullScale is constant along the whole edge (same fix), but unlike
    // `radius` it doesn't collapse just because the visible corner was
    // capped down for text clearance.
    //
    // refractStrength: pullScale = min(halfSize.x, halfSize.y) is the
    // SMALLEST value length(p) ever took across the old shape — using it
    // alone makes the bend uniformly weaker than the old length(p)-scaled
    // version almost everywhere (that version's actual bug was the
    // variation ALONG a flat edge, not its typical magnitude). This scales
    // the depth back up without reintroducing that per-position variation.
    // Rim weight: a Gaussian centred right on the true edge (d=0), used
    // below to localize the chromatic aberration offset and the rim
    // brightness lift to a thin band at the boundary. Built on `d` itself
    // (raw pixels) rather than the normalized `dist` — dist is divided by
    // pullScale, which varies a lot between panels (the dock's is ~2-3x
    // Spotlight's), so the same "normalized" width used to translate into
    // very different actual pixel widths per panel: thin enough on
    // Spotlight to read as a soft halo, wide enough on the dock to read as
    // a harder, more defined ring. rimHighlightWidth is now a fixed PIXEL
    // width, so the same setting looks the same regardless of panel size.
    float rimWeight = exp(-d * d / max(2.0 * rimHighlightWidth * rimHighlightWidth, 1e-6));
    // Extra emphasis on actual curvature (see sdCornerFactor's own
    // comment), NOT a full on/off switch — a real specular rim is present
    // all the way around, just brighter where the surface genuinely bends
    // toward the viewer. Full on/off faded flat runs (the dock's long top/
    // bottom) to nothing, AND flipped to "the whole perimeter is a corner"
    // once a shape got tall/narrow enough to have barely any flat run left
    // (Spotlight expanded) — a floor keeps a solid baseline everywhere so
    // neither extreme happens; only the corner POP varies with shape.
    const float CORNER_EMPHASIS_FLOOR = 0.55;
    float cornerFactor = sdCornerFactor(p, halfSize, pullScale);
    rimWeight *= mix(CORNER_EMPHASIS_FLOOR, 1.0, cornerFactor);
    // Real macOS/iOS Liquid Glass isn't lit evenly all the way around — it
    // reads as catching a fixed light from the top-left: that corner (and,
    // dimmer, its opposite at bottom-right) pop, while the OTHER diagonal's
    // corners (top-right, bottom-left) actively fade toward nothing.
    //
    // Built from `normalDir` (the shape's own real outward-normal field,
    // already computed above for refraction) rather than a quadrant sign
    // test — a sign test is a genuinely HARD flip exactly at a shape's own
    // centreline, which is fine for two geometrically SEPARATE corners, but
    // on a shape fully rounded on its short axis (the dock — top-left and
    // bottom-left are literally the same continuous semicircular arc, not
    // two distinct corners) that flip lands right in the middle of ONE
    // corner's own curve, showing as a hard cut instead of a fade no matter
    // how wide the surrounding fade zone is made. normalDir sweeps smoothly
    // through every angle all the way around ANY shape (merged corners
    // included, since it's built from the true SDF gradient — the same
    // property that already makes refraction/pull artifact-free at any
    // aspect ratio), so a plain dot-product against a fixed light axis
    // varies continuously everywhere, with no seam possible.
    //
    // dot(normalDir, lightAxis) is +1 pointing exactly top-left, -1 exactly
    // bottom-right, 0 pointing along any flat edge (up/down/left/right) OR
    // exactly toward the OTHER diagonal's corners (top-right/bottom-left —
    // dot is 0 at both, since that direction is perpendicular to the light
    // axis both ways). abs() folds top-left and bottom-right (+1 and -1)
    // to the same "correct diagonal" reading of 1; flat edges land at
    // exactly 1/sqrt(2) (~0.707, an axis-aligned normal is always 45° off
    // the diagonal) — the natural split point between "ramp up toward the
    // boost" (above it) and "ramp down toward the fade" (below it) that
    // keeps flat edges sitting exactly at the old baseline, unchanged.
    // CLAUDE/local, 2026-09-18: corner-spike fix. DIAGONAL_BOOST/
    // cornerFactor above are both tuned against pullScale (the UNCAPPED
    // natural corner scale) rather than the actual VISIBLE radius — correct
    // for the dock, where maxCornerRadius is effectively unlimited
    // (9999px) so radius==pullScale and nothing here changes. But
    // Spotlight caps its visible radius hard (spotlightMaxCornerRadius,
    // ~23px) while pullScale — and therefore cornerFactor's own "how much
    // of my edge counts as corner" ramp — stays at the panel's full,
    // uncapped natural scale. Result: on a tall/narrow Spotlight panel,
    // cornerFactor reads close to 1.0 (full "corner emphasis") along
    // nearly its ENTIRE perimeter, not just near the true geometric
    // corners, so the SAME 2.5x DIAGONAL_BOOST that's a subtle accent on
    // the dock's brief actual corners becomes a much more prominent,
    // "spiky" jump on Spotlight — reported directly by the user testing
    // this. Fix: scale how much boost is allowed to apply at all by how
    // tightly the radius is actually capped relative to pullScale — a
    // heavily-capped panel (Spotlight) gets a proportionally gentler
    // boost; an uncapped one (the dock) is completely unaffected
    // (radiusCapRatio ≈ 1, boost stays exactly 2.5x as before).
    float radiusCapRatio    = clamp(radius / max(pullScale, 1.0), 0.0, 1.0);
    float effectiveDiagonalBoost = mix(1.0, 2.5, radiusCapRatio);
    const float OFF_DIAGONAL_FADE = 0.0; // top-right/bottom-left: die out as it curves
    const float FLAT_EDGE_ALIGN   = 0.70710678; // 1/sqrt(2) — an axis-aligned normal's alignment
    float diagAlign = abs(dot(normalDir, normalize(vec2(-1.0, -1.0))));
    // Raising the ramp fraction to rimDiagonalReach only stretches/
    // compresses where WITHIN each zone the transition happens — the
    // endpoints (1.0 at the flat-edge boundary, effectiveDiagonalBoost/
    // OFF_DIAGONAL_FADE at the true corners) never move.
    float diagRampAbove = pow(clamp((diagAlign - FLAT_EDGE_ALIGN) / (1.0 - FLAT_EDGE_ALIGN), 0.0, 1.0), rimDiagonalReach);
    float diagRampBelow = pow(clamp(diagAlign / FLAT_EDGE_ALIGN, 0.0, 1.0), rimDiagonalReach);
    float diagonalTarget = diagAlign >= FLAT_EDGE_ALIGN
        ? mix(1.0, effectiveDiagonalBoost, diagRampAbove)
        : mix(OFF_DIAGONAL_FADE, 1.0, diagRampBelow);
    rimWeight *= diagonalTarget;
    // Clamp the pull so it can never cross the shape's own centre along
    // this direction. Past that point, different screen positions `p`
    // start mapping to OVERLAPPING sample positions — the mapping folds
    // back on itself, which shows up as literal duplicated/repeated
    // content, most visible on regular repetitive patterns like text rows
    // (reported as "4 lines become 8-16 lines, same words"). This is a
    // property of the pull's raw MAGNITUDE, not of dist/shrinkFrac's shape
    // or of the floor/opacity logic further down — which is exactly why
    // two rounds of floor/busyness changes had zero effect on it, and why
    // it got easier to trigger once refractStrength was raised earlier to
    // make the bend more visible (a stronger pull is closer to folding).
    // dot(p, normalDir) is the true distance from p to the centre-plane
    // along this specific direction; stopping at 90% of that leaves a
    // solid margin before the fold point regardless of shape or tuning.
    float pullAmount = shrinkFrac * refractStrength * pullScale;
    float maxSafePull = max(dot(p, normalDir), 0.0);
    pullAmount = min(pullAmount, maxSafePull * 0.9);
    vec2  sp         = p - normalDir * pullAmount;
    vec2 pUV = 0.5 + sp / panelSize;

    vec3 col = sampleBlurred(pUV, max(blurPx, frostBlur));

    // REMOVED: a "busyness"/local-contrast mechanism used to live here
    // (comparing neighbour samples ~18px out to react to local contrast,
    // not just average brightness), plus a "textCollision" mechanism after
    // the floor mix below that pushed opacity up wherever the sample's
    // luminance got close to the real on-glass text colour. Both were
    // luma-THRESHOLD driven (smoothstep over a fixed luminance range), and
    // that turned out to be the actual cause of a "duplicate" look
    // reported around edges/lines: crossing the threshold ramps opacity up
    // over a band straddling the edge, on BOTH sides of it, and that band
    // can end up wider than the line itself — reading as a parallel ghost
    // flanking the original, worst specifically at luminance values near
    // the threshold (confirmed by the report: visible on dark-but-not-
    // black content, not on mid-grey). Reverted to the plain luma-only
    // floor below rather than trying to retune the thresholds — two
    // rounds of tuning attempts didn't fix it and this is a proven-good
    // baseline. busynessStrength/textColor uniforms are kept (harmless if
    // unused) rather than ripped out, in case a non-threshold-based
    // version of this idea is worth revisiting later.
    //
    // Chromatic aberration: real glass bends different wavelengths by
    // different amounts, most visible at the same sharp rim as above (same
    // rimWeight falloff) — offset red/blue oppositely along the local
    // normal there; green keeps the true sample.
    //
    // Reimplemented (2026-09-14) using sampleBlurred for all three channels
    // instead of a raw texture() tap for R/B — the earlier single-tap
    // version mixed a SHARP R/B sample with the already-BLURRED G channel
    // (`col`, from sampleBlurred above), a mismatch that reads as a
    // persistent colour cast (reported as "just purple") rather than a
    // clean spectral fringe, since any real detail near the rim shows up
    // sharply in R/B but smoothed in G. Was single-tap specifically because
    // the old sampleBlurred was a full 81-tap loop — two more of those,
    // every frame on a live capture, was a real sustained GPU cost, and a
    // full blurred resample at a visible offset was ALSO the actual cause
    // of a separate "duplicate text" bug (a coherent second copy of a whole
    // glyph, not just edge fringing). Both concerns are gone now that
    // sampleBlurred is a cheap separable pass (9 taps here, reusing the
    // already-blurred sourceHBlur) instead of the old 81-tap loop — sharing
    // it across all three channels is now affordable AND correct.
    // CLAUDE/local: perf, 2026-09-17. chromaOffset is scaled by rimWeight — a
    // Gaussian centred on the true edge (d=0) — so it's only ever non-
    // negligible in a thin band right at the panel's rim; everywhere else
    // (almost the entire panel's area, interior included) rimWeight decays
    // to ~0 regardless of the chromaticAberration slider, making colR/colB
    // mathematically indistinguishable from col already computed above.
    // Below that, sampleBlurred's own 9-tap loop (x2, for R and B) was pure
    // wasted GPU work for the vast majority of pixels every live frame.
    // 0.05px is conservative — well under a sixth of a screen pixel, so this
    // skip is exact everywhere it triggers, not a visual approximation; the
    // rim band itself (where the effect is actually visible) is completely
    // unaffected; and it holds at any chromaticAberration slider value
    // (0-10px) since it's the OFFSET magnitude gated here, not the slider.
    const float CHROMA_OFFSET_EPS_SQ = 0.0025; // 0.05px, squared
    if (chromaticAberration > 0.0) {
        vec2  chromaOffset = normalDir * chromaticAberration * rimWeight;
        if (dot(chromaOffset, chromaOffset) > CHROMA_OFFSET_EPS_SQ) {
            float blurRadius   = max(blurPx, frostBlur);
            vec3  colR         = sampleBlurred(pUV + chromaOffset / panelSize, blurRadius);
            vec3  colB         = sampleBlurred(pUV - chromaOffset / panelSize, blurRadius);
            col = vec3(colR.r, col.g, colB.b);
        }
    }

    // FrostedBackdrop.qml's exact recipe (the desktop widgets' frosted-card
    // material), applied here to the refracted sample the same way it
    // applies to its own blurred wallpaper copy: desaturate toward the
    // sample's own luminance, then darken slightly. This — not any kind of
    // grain — is what makes blurred content read as a matte frosted
    // material instead of a blurry mirror. Order matches that file: this
    // runs on the raw sample, BEFORE the floor/tint mix below.
    //
    // Scaled by how much frosting is actually dialed in (frostBlur=0 should
    // stay pure crisp refraction, not permanently grey/dark) — the widget
    // material always desaturates because its blur is fixed-on; ours isn't,
    // so this ramps in alongside it instead of applying unconditionally.
    float frostAmount = clamp(frostBlur / 10.0, 0.0, 1.0);
    float frostLuma = dot(col, vec3(0.299, 0.587, 0.114));
    col = mix(col, mix(vec3(frostLuma), col, frostSaturation), frostAmount);
    col -= frostDarken * frostAmount;

    // Apple's real Liquid Glass legibility mechanism (WWDC25 "Meet Liquid
    // Glass"): "the amount of tint... shift to always ensure buttons remain
    // legible, while letting as much of the content through as possible" —
    // a CONTENT-AWARE floor strength, not a fixed blend, and NOT a colored
    // tint doing the legibility work (their own guidance: be judicious with
    // color; tint here is a separate, purely cosmetic accent below). Bright
    // or busy content behind the glass gets a stronger neutral floor; content
    // that already has good contrast lets more of the real refraction
    // through. Rec.601 luminance weights.
    float luma = dot(col, vec3(0.299, 0.587, 0.114));
    // This theme's text on this material is fixed light-on-dark, not
    // adaptive itself (Apple's flips light/dark to match) — so the floor
    // colour stays dark, and only its STRENGTH adapts: bright backgrounds
    // need a much stronger floor to keep light text legible, already-dark
    // backgrounds need very little, letting the glass read as more authentic
    // (matches "let as much content through as possible").
    //
    // Real Liquid Glass is NEVER invisible, even over a black background —
    // Control Center/Notification Center keep a visible presence (and
    // actively dim the screen behind them + brighten themselves for
    // contrast) rather than fully disappearing over dark content. A floor
    // that scales all the way down to near-zero at low `baseOpacity` was
    // exactly that failure — clamped to `minFloor` so the panel always has
    // SOME real presence by default. Unlike the rest of this floor logic,
    // this minimum is deliberately a plain user-tunable value rather than
    // content-aware: turning it down trades that guaranteed presence for a
    // crisper, more refraction-dominant "pure glass" look.
    // Local contrast ("busyness") — reimplemented (2026-09-14) after being
    // fully removed earlier: the average-luma floor above can miss a
    // visually busy backdrop (e.g. a photo with both a dark bike and bright
    // sky) that averages to a middling luma without ever triggering a
    // strong floor, even though parts of it are genuinely hard to read
    // against. Samples 4 neighbours at a modest radius and uses their
    // luminance SPREAD (max-min) as a plain, CONTINUOUS contribution to the
    // floor — deliberately not a luma-threshold/smoothstep band (that was
    // the confirmed root cause of a "duplicate text" artifact last time: a
    // fixed-luminance threshold ramps opacity up over a band straddling
    // BOTH sides of any edge, wide enough to read as a parallel ghost).
    // This may still need further fixing (per-user-request, a known
    // follow-up, not resolved here) — it's the raw contrast signal only,
    // with none of the opacity-threshold logic that caused the striping.
    float busynessAmount = 0.0;
    if (busynessStrength > 0.0) {
        vec2 bStep = vec2(8.0) / texSize;
        vec3 sampL = texture(source, toTex(pUV) + vec2(-bStep.x, 0.0)).rgb;
        vec3 sampR = texture(source, toTex(pUV) + vec2(bStep.x, 0.0)).rgb;
        vec3 sampU = texture(source, toTex(pUV) + vec2(0.0, -bStep.y)).rgb;
        vec3 sampD = texture(source, toTex(pUV) + vec2(0.0, bStep.y)).rgb;
        vec3 lw = vec3(0.299, 0.587, 0.114);
        float lL = dot(sampL, lw), lR = dot(sampR, lw), lU = dot(sampU, lw), lD = dot(sampD, lw);
        float lMax = max(max(lL, lR), max(lU, lD));
        float lMin = min(min(lL, lR), min(lU, lD));
        busynessAmount = lMax - lMin;
    }
    float adaptiveBaseOpacity = clamp(mix(baseOpacity * 0.35, baseOpacity * 2.2, luma) + busynessAmount * busynessStrength, minFloor, 1.0);

    col = mix(col, base.rgb, adaptiveBaseOpacity);
    col = mix(col, tint.rgb, tint.a);

    // Rim highlight, applied LAST (after the floor/tint mix, not before) —
    // a plain brightness lift toward white in the same thin rim band as
    // the chromatic aberration above, deliberately NOT content-dependent.
    // Earlier attempt used this band to pull in MORE refracted content
    // instead (an extra bend on top of the normal one) — that read as
    // "just another reflection" (invisible over a flat colour, since it's
    // still literally sampling the same image) and the larger pull
    // magnitude could reach far enough to sample content from an unrelated
    // part of the shape, visibly "spreading" a change on one side across
    // to others. A real specular rim is consistently brighter than its
    // surroundings regardless of what's behind it — a reverse drop-shadow,
    // not a reflection — so this blends toward white by a small fixed
    // amount instead.
    col = mix(col, vec3(1.0), rimWeight * rimHighlightStrength);

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0) * qt_Opacity * aa;
}
