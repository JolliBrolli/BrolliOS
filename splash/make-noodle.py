#!/usr/bin/env python3
"""
Build the wordmark as a NOODLE: a tube of glass extruded along a path.

  python3 splash/make-noodle.py                 umbrella + OS
  python3 splash/make-noodle.py --trace         from splash/drawing.json

Apple's "hello" is not lettering with a material on it. It is a ribbon with
thickness that flows, passes over and under itself, and is made of glass. This
builds the same thing, and most of the pipeline is unchanged -- it produces the
exact two textures the letter material already reads:

  wordmark-shape.png   signed distance in R, local half-thickness in G
  wordmark-order.png   when each pixel is drawn, 16-bit across R and G

The signed distance of a tube is exact rather than measured: it is simply
    distance to the path, minus the radius
so there is no distance transform here and no staircase anywhere -- the field
is analytic, which is the cleanest input the antialiasing can get.

Over and under falls out for free. Where the path crosses itself, two stretches
are near the same pixel; the one further ALONG the path is the one drawn later,
so it passes on top. That is painter's algorithm, and "position along the path"
is the number the order map already stores.

The umbrella is generated, not drawn. A canopy is an arc, a shaft is a line and
a hook is a curve, so it can be exact -- no tracing, nothing to smooth.
"""
import argparse
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_SHAPE = os.path.join(HERE, "wordmark-shape.png")
OUT_ORDER = os.path.join(HERE, "wordmark-order.png")
OUT_MASK = os.path.join(HERE, "wordmark-mask.png")
OUT_JSON = os.path.join(HERE, "wordmark.json")
SD_RANGE = 32.0


# ── path building blocks ────────────────────────────────────────────────────

def bezier(p0, p1, p2, p3, n):
    out = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        x = u*u*u*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t*t*t*p3[0]
        y = u*u*u*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t*t*t*p3[1]
        out.append((x, y))
    return out


def arc(cx, cy, rx, ry, a0, a1, n):
    return [(cx + rx * math.cos(a0 + (a1 - a0) * i / n),
             cy + ry * math.sin(a0 + (a1 - a0) * i / n)) for i in range(n + 1)]


def umbrella(scale=1.0, scallops=4):
    """An umbrella, as a pen would draw it.

    Three strokes, in the order a hand takes them: the canopy over the top,
    the scalloped hem beneath it, then the shaft down into its hook.
    """
    s = scale
    cx, cy = 150 * s, 120 * s          # apex of the canopy
    rx, ry = 130 * s, 78 * s

    canopy = arc(cx, cy, rx, ry, math.pi, 2 * math.pi, 96)

    # The hem: small arcs between the canopy's two tips, so it reads as fabric
    # rather than a bowl.
    hem = []
    x0, x1 = cx - rx, cx + rx
    step = (x1 - x0) / scallops
    for k in range(scallops):
        a = (x0 + k * step, cy)
        b = (x0 + (k + 1) * step, cy)
        mid = ((a[0] + b[0]) / 2, cy + 26 * s)
        hem += bezier(a, (a[0] + step * 0.25, mid[1]),
                      (b[0] - step * 0.25, mid[1]), b, 14)

    # Shaft from the apex, then the hook.
    shaft = [(cx, cy), (cx, cy + 150 * s)]
    hook = bezier((cx, cy + 150 * s),
                  (cx, cy + 205 * s),
                  (cx - 62 * s, cy + 205 * s),
                  (cx - 58 * s, cy + 158 * s), 40)

    return [canopy, hem, shaft + hook[1:]]


def hershey_word(text, size, jhf="scriptc"):
    """"OS" and friends, from the single-stroke Hershey hand."""
    sys.path.insert(0, HERE)
    from importlib import import_module
    gen = import_module("generate-wordmark".replace("-", "_")) \
        if os.path.exists(os.path.join(HERE, "generate_wordmark.py")) else None
    # generate-wordmark.py is not importable by that name; parse inline instead.
    path = os.path.join(HERE, "hershey", jhf + ".jhf")
    glyphs = {}
    with open(path) as fh:
        for i, line in enumerate(fh):
            line = line.rstrip("\n")
            if len(line) < 10:
                continue
            data = line[8:]
            vals = [ord(c) - ord("R") for c in data]
            left, right = vals[0], vals[1]
            strokes, cur, j = [], [], 2
            while j + 1 < len(vals):
                if data[j] == " " and data[j + 1] == "R":
                    if cur:
                        strokes.append(cur)
                        cur = []
                else:
                    cur.append((vals[j], vals[j + 1]))
                j += 2
            if cur:
                strokes.append(cur)
            glyphs[32 + i] = (left, right, strokes)

    scale = size / 32.0
    out, x = [], 0.0
    for ch in text:
        e = glyphs.get(ord(ch))
        if e is None:
            sys.exit(f"{ch!r} not in {jhf}")
        left, right, strokes = e
        for st in strokes:
            out.append([((px - left) * scale + x, py * scale) for px, py in st])
        x += (right - left) * scale
    return out, x


def resample(strokes, step=1.0):
    out = []
    for s in strokes:
        if len(s) < 2:
            continue
        pts = [s[0]]
        carry = 0.0
        for a, b in zip(s, s[1:]):
            d = math.dist(a, b)
            if d <= 0:
                continue
            t = step - carry
            while t <= d:
                f = t / d
                pts.append((a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f))
                t += step
            carry = (carry + d) % step
        pts.append(s[-1])
        out.append(pts)
    return out


# ── rasterising the tube ────────────────────────────────────────────────────

def rasterise(strokes, radius, pad, taper):
    """Signed distance to the tube, plus how far along the path each pixel is.

    Walks the path once, and for every pixel within reach of a sample keeps the
    nearest one. Ties go to the LATER position, which is what puts the later
    stretch of the noodle on top where it crosses itself.
    """
    import numpy as np

    xs = [p[0] for s in strokes for p in s]
    ys = [p[1] for s in strokes for p in s]
    minx, maxx = min(xs) - radius - pad, max(xs) + radius + pad
    miny, maxy = min(ys) - radius - pad, max(ys) + radius + pad
    w = int(math.ceil(maxx - minx))
    h = int(math.ceil(maxy - miny))

    best = np.full((h, w), 1e9, dtype=np.float32)      # distance to the path
    order = np.zeros((h, w), dtype=np.float32)          # position along it
    rad = np.zeros((h, w), dtype=np.float32)            # radius at that point

    lengths = [sum(math.dist(a, b) for a, b in zip(s, s[1:])) for s in strokes]
    total = sum(lengths) or 1.0
    gap = total * 0.03                                  # a visible pen lift
    grand = total + gap * max(0, len(strokes) - 1)

    reach = radius + pad + 2.0
    travelled = 0.0
    for s, length in zip(strokes, lengths):
        run = 0.0
        for a, b in zip(s, s[1:]):
            d = math.dist(a, b)
            run += d
            px, py = b[0] - minx, b[1] - miny
            t = (travelled + run) / grand

            # Taper the ends of each stroke, so the noodle has a drawn-on
            # start and finish rather than two flat cuts.
            u = run / max(length, 1e-6)
            r = radius * (1.0 - taper * (1.0 - math.sin(math.pi * min(1.0, max(0.0, u)))))

            x0, x1 = max(0, int(px - reach)), min(w, int(px + reach) + 1)
            y0, y1 = max(0, int(py - reach)), min(h, int(py + reach) + 1)
            if x0 >= x1 or y0 >= y1:
                continue
            gy, gx = np.ogrid[y0:y1, x0:x1]
            dist = np.sqrt((gx - px) ** 2 + (gy - py) ** 2).astype(np.float32)

            win = best[y0:y1, x0:x1]
            # Strictly nearer, OR equally near and later along the path.
            closer = dist < win
            np.copyto(win, dist, where=closer)
            np.copyto(order[y0:y1, x0:x1], np.float32(t), where=closer)
            np.copyto(rad[y0:y1, x0:x1], np.float32(r), where=closer)
        travelled += length + gap

    # Pixels no sample ever reached are far outside by definition; clamp them
    # so the encoding and the reporting both stay honest.
    import numpy as np
    sd = np.where(best > 1e8, SD_RANGE, best - rad)
    return sd, order, rad, (w, h)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", action="store_true",
                    help="use splash/drawing.json instead of the umbrella")
    ap.add_argument("--text", default="OS", help="what follows the umbrella")
    ap.add_argument("--radius", type=float, default=17.0, help="noodle half-width, px")
    ap.add_argument("--taper", type=float, default=0.35,
                    help="0 = flat ends, 1 = fully tapered")
    ap.add_argument("--scale", type=float, default=1.0)
    args = ap.parse_args()

    try:
        from PIL import Image
        import numpy as np
    except ImportError:
        sys.exit("needs Pillow and numpy")

    if args.trace:
        src = os.path.join(HERE, "drawing.json")
        if not os.path.exists(src):
            sys.exit("no drawing.json — trace one first")
        with open(src) as fh:
            data = json.load(fh)
        strokes = []
        for flat in data.get("strokes", []):
            pts = [(flat[i], flat[i + 1]) for i in range(0, len(flat) - 1, 2)]
            if len(pts) >= 2:
                strokes.append(pts)
        label = "traced"
    else:
        strokes = umbrella(args.scale)
        if args.text:
            word, wide = hershey_word(args.text, 150 * args.scale)
            # Sit it to the right of the umbrella, on the shaft's baseline.
            ox = 300 * args.scale
            oy = 150 * args.scale
            strokes += [[(x + ox, y + oy) for x, y in s] for s in word]
        label = f"umbrella + {args.text!r}"

    strokes = resample(strokes, 1.0)
    sd, order, rad, (w, h) = rasterise(strokes, args.radius, 6.0, args.taper)

    import numpy as np
    enc = np.clip((sd + SD_RANGE) / (2.0 * SD_RANGE), 0.0, 1.0)
    r8 = np.round(enc * 255).astype(np.uint8)
    g8 = np.clip(np.round(rad), 0, 255).astype(np.uint8)
    Image.merge("RGBA", (
        Image.fromarray(r8), Image.fromarray(g8),
        Image.fromarray(np.zeros((h, w), np.uint8)),
        Image.fromarray(np.full((h, w), 255, np.uint8)))).save(OUT_SHAPE)

    o16 = np.round(np.clip(order, 0, 1) * 65535).astype(np.uint32)
    Image.merge("RGBA", (
        Image.fromarray(((o16 >> 8) & 0xFF).astype(np.uint8)),
        Image.fromarray((o16 & 0xFF).astype(np.uint8)),
        Image.fromarray(np.zeros((h, w), np.uint8)),
        Image.fromarray(np.full((h, w), 255, np.uint8)))).save(OUT_ORDER)

    # A coverage mask too, so anything expecting one still works.
    cov = np.clip(0.5 - sd, 0.0, 1.0)
    Image.merge("RGBA", (
        Image.fromarray(np.full((h, w), 255, np.uint8)),
        Image.fromarray(np.full((h, w), 255, np.uint8)),
        Image.fromarray(np.full((h, w), 255, np.uint8)),
        Image.fromarray(np.round(cov * 255).astype(np.uint8)))).save(OUT_MASK)

    with open(OUT_JSON, "w") as fh:
        json.dump({
            "text": "BrolliOS", "style": "image", "font": label,
            "size": h, "width": w, "height": h,
            "ascent": h, "descent": 0.0, "top": 0.0,
            "mask": os.path.basename(OUT_MASK),
            "shape": os.path.basename(OUT_SHAPE),
            "order": os.path.basename(OUT_ORDER),
            "ordered": True, "orderSource": "noodle",
            "sdRange": SD_RANGE,
            "paths": [],
        }, fh, indent=1)

    print(f"{label}: {len(strokes)} stroke(s), {w}x{h}px, radius {args.radius}")
    print(f"sd {sd.min():.1f}..{sd.max():.1f}px  ->  {OUT_SHAPE}")
    print("order and mask written; nothing else in the pipeline changes")


if __name__ == "__main__":
    main()
