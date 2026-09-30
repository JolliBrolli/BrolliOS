#!/usr/bin/env python3
"""
Port the plugin's material to run on letters instead of a rounded rectangle.

  python3 splash/port-letters.py

This is not a shader that imitates the panel material. It IS the panel
material, with three lines changed -- the three that assume the shape is a
rectangle. Everything else, every constant and every curve, is the file the
plugin draws every panel with. Edit brolliglass.frag and re-run; the lock
screen follows, including whatever the Settings sliders did to it.

What the rounded rect provides implicitly, and a letter has to be told:

    sd        the signed distance to the edge. From sdf() there; sampled from
              wordmark-shape.png here. Depth, blur radius, chroma and the
              antialiasing all hang off it, so substituting it is enough to
              move the whole material onto a new shape.

    direction which way is "out" from the middle of the form. The panel takes
              it from its own centre line; here it is the gradient of sd,
              two extra samples, exact because a distance field is smooth.

    reach     how far it is from the middle to the edge. (halfSize - coreHalf)
              in the panel, constant across it. Along a letter it varies with
              every stroke, so it is measured and stored per pixel.

The rim block is dropped: it is built from sdSuperellipseRoundRectNormal and
sdCornerFactor, which are rectangle maths with no meaning on a letterform --
and at this stroke width it drew a white outline around every glyph anyway.
"""
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), "plugin", "src", "brolliglass.frag")
OUT_GLSL = os.path.join(HERE, "glassletters.frag")
OUT_QSB = os.path.join(HERE, "glassletters.frag.qsb")

SCALARS = [
    ("vec2", "panelSize"), ("vec2", "texSize"),
    ("float", "pad"), ("float", "maxCornerRadius"),
    ("float", "aghDepth"), ("float", "aghStrength"), ("float", "aghBlur"),
    ("float", "aghChroma"), ("float", "aghEdge"), ("float", "aghTint"),
    ("float", "aghStretch"),
    ("vec2", "panelStat"),
    ("float", "glassDir"), ("float", "aghSquash"), ("float", "aghPush"),
    ("float", "aghBody"), ("float", "glassOverGlass"),
    ("vec4", "tint"),
    ("float", "power"),
    ("float", "rimHighlightStrength"), ("float", "rimHighlightWidth"),
    ("float", "rimDiagonalReach"),
    # letters only
    ("float", "sdRange"), ("vec2", "shapeTexel"),
    ("float", "revealEdge"), ("float", "revealSoft"),
    ("float", "tubeLight"), ("float", "tubeSpec"), ("float", "tubeShine"),
    ("float", "bloom"), ("float", "bloomWidth"),
]


def find_qsb():
    for c in (shutil.which("qsb"), "/usr/lib/qt6/bin/qsb", "/usr/lib/qt/bin/qsb"):
        if c and os.path.exists(c):
            return c
    sys.exit("qsb not found — install qt6-shadertools")


def port(text):
    text = re.sub(r"#version 300 es\n", "", text)
    text = re.sub(r"precision highp (float|sampler2D);\n", "", text)
    text = re.sub(r"^uniform .*\n", "", text, flags=re.MULTILINE)
    text = re.sub(r"^in vec2 qt_TexCoord0;.*\n", "", text, flags=re.MULTILINE)
    text = re.sub(r"^out vec4 fragColor;\n", "", text, flags=re.MULTILINE)

    # ── the shape ────────────────────────────────────────────────────────
    old_shape = """    float size = min(glassSize.x, glassSize.y);
    float r    = min(size * 0.5, maxCornerRadius);
    float sd   = sdf(glassCoord, glassSize * 0.5, r);"""
    new_shape = """    // Sampled, not computed: the only reason the material can be a drawing
    // rather than a rectangle. Everything below is unchanged.
    //
    // TWO shapes. sdCov is the silhouette, and decides what is covered at all
    // -- the panels, as a broad shallow film. sd is what the light sees, and
    // along every drawn line it becomes a fat rounded tube instead. Keeping
    // them apart is what lets the noodle stand proud of the film without
    // cutting a hole in it: coverage from one, curvature from the other.
    float sdCov = sdAt(qt_TexCoord0);
    float sd    = sdLensAt(qt_TexCoord0);
    float tubeW = tubeMix(qt_TexCoord0);
    float localHalf = mix(max(texture(shapeTex, qt_TexCoord0).g * 255.0, 1.0),
                          max(texture(tubeTex,  qt_TexCoord0).g * 255.0, 1.0),
                          tubeW);
    float size = localHalf * 2.0;"""
    if old_shape not in text:
        sys.exit("brolliglass.frag's shape block has changed — port-letters.py needs updating")
    text = text.replace(old_shape, new_shape)

    # ── the centre line becomes the distance field's gradient ────────────
    old_core = """    vec2  halfSize  = glassSize * 0.5;
    vec2  coreHalf  = max(halfSize - vec2(min(halfSize.x, halfSize.y)), 0.0) * clamp(aghStretch, 0.0, 1.0);
    vec2  fromCore  = glassCoord - clamp(glassCoord, -coreHalf, coreHalf);
    float coreDist  = length(fromCore);
    vec2  normalizedGlassCoord = fromCore / max(coreDist, 1e-4);"""
    new_core = """    // The panel measures direction and distance from its own centre line.
    // A letter has no centre line, but it has a distance field, and the
    // gradient of that field points the same way the centre line did: out of
    // the form, perpendicular to the nearest edge.
    vec2  halfSize  = vec2(localHalf);
    vec2  coreHalf  = vec2(0.0);
    vec2  grad      = sdGradient(qt_TexCoord0);
    float gradLen   = length(grad);
    vec2  normalizedGlassCoord = gradLen > 1e-5 ? grad / gradLen : vec2(0.0, -1.0);
    // 0 in the middle of a stroke, localHalf at its edge -- the same range
    // coreDist covers on a panel.
    float coreDist  = clamp(localHalf + sd, 0.0, localHalf);"""
    if old_core not in text:
        sys.exit("brolliglass.frag's centre-line block has changed — port-letters.py needs updating")
    text = text.replace(old_core, new_core)

    # ── stats come in as a uniform; there is no reduce pass here ─────────
    text = text.replace(
        "float aa = clamp(0.5 - sd / max(fwidth(sd), 1e-4), 0.0, 1.0);",
        "float aa = clamp(0.5 - sdCov / max(fwidth(sdCov), 1e-4), 0.0, 1.0);")

    text = text.replace(
        "vec2  st   = texelFetch(panelStats, ivec2(0), panelStatsLevel).rg;",
        "vec2  st   = panelStat;   // ported: no mipmap-reduce pass on the lock screen")

    # ── drop the rim: rectangle maths, and an outline on a letterform ────
    start = text.find("    // Rim outline, as liquidglasstest.frag computes it")
    end = text.find("    fragColor = vec4(glassColor, 1.0) * aa;")
    if start < 0 or end < 0:
        sys.exit("could not find the rim block to remove")
    text = text[:start] + text[end:]

    # ── reveal, and Qt's opacity ─────────────────────────────────────────
    text = text.replace(
        "    fragColor = vec4(glassColor, 1.0) * aa;",
        """    // ── the noodle, lit as a cylinder ────────────────────────────────
    // What makes the reference look like something rather than a drawing:
    // the tube is ROUND, and rounded things catch light along their length.
    //
    // A tube of radius r at distance d from its centre stands sqrt(r^2 - d^2)
    // proud of the surface, so its 3D normal is known exactly -- the flat
    // gradient we already have, with that height as the third component. No
    // faked highlight; this is the real surface.
    if (tubeW > 0.001) {
        float rTube = max(texture(tubeTex, qt_TexCoord0).g * 255.0, 1.0);
        float u     = clamp(1.0 + sdTubeAt(qt_TexCoord0) / rTube, 0.0, 1.0);
        float hgt   = sqrt(max(1.0 - u * u, 0.0));
        vec3  N     = normalize(vec3(normalizedGlassCoord * u, hgt));
        vec3  Ldir  = normalize(vec3(-0.45, -0.75, 0.55));   // up and to the left

        float diff = max(dot(N, Ldir), 0.0);
        float spec = pow(max(dot(reflect(-Ldir, N), vec3(0.0, 0.0, 1.0)), 0.0),
                         max(tubeShine, 1.0));

        vec3 lit = glassColor * mix(1.0, 0.45 + 0.85 * diff, tubeLight)
                 + vec3(spec * tubeSpec);
        // Darker right at the edge, which is what reads as roundness.
        lit *= mix(1.0, 0.55, smoothstep(0.75, 1.0, u) * tubeLight);
        glassColor = mix(glassColor, lit, tubeW);
    }

    // The drawing's own strokes are NOT darkened here any more.
    //
    // They used to be: before the noodle existed the outline had to read as
    // darker glass, because nothing else marked where it was. Now the noodle
    // IS the outline, and the two cannot agree -- the noodle follows a
    // centreline derived from the drawing (the shaft's two walls collapse to
    // one line between them, the scallops are trimmed, the bend is thinned),
    // while the stroke texture is the untouched artwork. Darkening by it drew
    // the original drawing back on top of the glass, offset from the noodle
    // that replaced it: grey outlines showing through, following nothing.

    // Written on: revealEdge walks 0..1 through the order map, which
    // carries when each pixel was traced.
    vec4 om = texture(orderTex, qt_TexCoord0);
    float order = (om.r * 255.0 * 256.0 + om.g * 255.0) / 65535.0;
    float wipe = clamp((revealEdge - order) / max(revealSoft, 0.0001), 0.0, 1.0);

    // Bloom. The reference glows into the black around it, and that halo is
    // most of why it looks lit from within rather than printed. It reaches
    // BEYOND the silhouette, so it has to add its own coverage -- aa alone
    // stops at the shape's edge.
    // The glow has to reach zero, and an exponential never does. Worse, the
    // field it reads is clamped to sdRange, so past that it stops decaying
    // entirely and settles at a constant -- which painted a faint wash over
    // the whole texture rectangle, visible as a grey square around everything.
    float outside = max(sdTubeAt(qt_TexCoord0), 0.0);
    float halo = exp(-outside / max(bloomWidth, 0.5)) * bloom;
    halo *= 1.0 - smoothstep(bloomWidth * 2.0, bloomWidth * 4.0, outside);
    float cover = clamp(max(aa, halo * 0.85), 0.0, 1.0);
    glassColor += vec3(halo * 0.5) * (1.0 - aa);

    fragColor = vec4(glassColor, 1.0) * cover * wipe * qt_Opacity;""")

    block = "\n".join(f"    {t:<5} {n};" for t, n in SCALARS)
    header = f"""#version 440

// GENERATED by splash/port-letters.py from plugin/src/brolliglass.frag.
// Do not edit: edit the material and re-run.

layout(location = 0) in  vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {{
    mat4  qt_Matrix;
    float qt_Opacity;
{block}
}};

layout(binding = 1) uniform sampler2D source;     // the backdrop
layout(binding = 2) uniform sampler2D shapeTex;   // sd in R, half-thickness in G
layout(binding = 3) uniform sampler2D orderTex;   // when each pixel is written
layout(binding = 4) uniform sampler2D tubeTex;   // the noodle: sd in R, radius in G

// Signed distance, decoded from a shape field.
float decode(vec4 s) {{ return (s.r * 2.0 - 1.0) * sdRange; }}
float sdAt(vec2 uv)   {{ return decode(texture(shapeTex, uv)); }}
float sdTubeAt(vec2 uv) {{ return decode(texture(tubeTex, uv)); }}

// How much of this pixel is noodle rather than film.
float tubeMix(vec2 uv) {{
    return smoothstep(1.0, -1.5, sdTubeAt(uv));
}}

// The surface the LIGHT sees. Two shapes in one field: a broad shallow film
// across the panels, and a fat rounded tube along every drawn line. Blended
// rather than switched, or the seam between them would read as a crack.
float sdLensAt(vec2 uv) {{
    return mix(sdAt(uv), sdTubeAt(uv), tubeMix(uv));
}}

// Its gradient. Central differences -- a distance field is smooth, so this is
// the real surface direction rather than an estimate off a jagged mask.
vec2 sdGradient(vec2 uv) {{
    return vec2(
        sdLensAt(uv + vec2(shapeTexel.x, 0.0)) - sdLensAt(uv - vec2(shapeTexel.x, 0.0)),
        sdLensAt(uv + vec2(0.0, shapeTexel.y)) - sdLensAt(uv - vec2(0.0, shapeTexel.y)));
}}
"""
    return header + text


def main():
    with open(SRC) as fh:
        ported = port(fh.read())
    with open(OUT_GLSL, "w") as fh:
        fh.write(ported)

    res = subprocess.run([find_qsb(), "--glsl", "120,150", "--hlsl", "50",
                          "--msl", "12", "-o", OUT_QSB, OUT_GLSL],
                         capture_output=True, text=True)
    if res.returncode != 0:
        print(res.stdout)
        print(res.stderr, file=sys.stderr)
        sys.exit("qsb failed")
    print(f"brolliglass.frag -> glassletters.frag -> {os.path.basename(OUT_QSB)} "
          f"({os.path.getsize(OUT_QSB)} bytes)")


if __name__ == "__main__":
    main()
