#!/usr/bin/env python3
"""
Turn a drawing from draw-wordmark.qml into the splash's wordmark.

  qs -p splash/draw-wordmark.qml      draw it, press s
  python3 splash/import-drawing.py    convert it

Raw stylus input is dense and shaky: hundreds of points a second, each one
becoming geometry the shader has to refract through. Three passes fix that,
in order, because each depends on the last:

  smooth      a moving average along each stroke, so the line stops wobbling
  simplify    Ramer-Douglas-Peucker, dropping points that sit on a line their
              neighbours already describe
  fit         a Catmull-Rom spline through what survives, emitted as cubic
              Beziers -- straight segments between simplified points would
              show as faceting once the stroke is 13px wide

Then it is scaled to the requested size and written as wordmark.json, in the
same shape generate-wordmark.py produces, so the splash needs no changes.
"""
import argparse
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DRAWING = os.path.join(HERE, "drawing.json")
OUT = os.path.join(HERE, "wordmark.json")


def resample(points, step):
    """Re-space the points evenly along the stroke.

    A finger moves in fits and starts: slow in the curves, fast on the
    straights, so raw points bunch up exactly where the shakiness is worst and
    thin out where detail is wanted. Averaging over a fixed window then smooths
    unevenly. Re-spacing first makes every later pass behave the same
    everywhere along the line.
    """
    if len(points) < 2:
        return points
    out = [points[0]]
    carry = 0.0
    for a, b in zip(points, points[1:]):
        seg = math.dist(a, b)
        if seg <= 0:
            continue
        t0 = step - carry
        while t0 <= seg:
            f = t0 / seg
            out.append((a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f))
            t0 += step
        carry = (carry + seg) % step
    if math.dist(out[-1], points[-1]) > step * 0.4:
        out.append(points[-1])
    return out


def chaikin(points, passes=1):
    """Corner cutting. Rounds off the angular joins a finger leaves behind."""
    for _ in range(passes):
        if len(points) < 3:
            return points
        out = [points[0]]
        for a, b in zip(points, points[1:]):
            out.append((a[0] * 0.75 + b[0] * 0.25, a[1] * 0.75 + b[1] * 0.25))
            out.append((a[0] * 0.25 + b[0] * 0.75, a[1] * 0.25 + b[1] * 0.75))
        out.append(points[-1])
        points = out
    return points


def smooth(points, window=3):
    """Moving average. Endpoints are left alone so the stroke keeps its ends."""
    if len(points) <= 2 or window < 2:
        return points
    out = [points[0]]
    half = window // 2
    for i in range(1, len(points) - 1):
        lo, hi = max(0, i - half), min(len(points), i + half + 1)
        seg = points[lo:hi]
        out.append((sum(p[0] for p in seg) / len(seg),
                    sum(p[1] for p in seg) / len(seg)))
    out.append(points[-1])
    return out


def rdp(points, epsilon):
    """Ramer-Douglas-Peucker."""
    if len(points) < 3:
        return points
    ax, ay = points[0]
    bx, by = points[-1]
    dx, dy = bx - ax, by - ay
    norm = math.hypot(dx, dy)

    worst, index = 0.0, 0
    for i in range(1, len(points) - 1):
        px, py = points[i]
        if norm == 0:
            d = math.hypot(px - ax, py - ay)
        else:
            d = abs(dy * px - dx * py + bx * ay - by * ax) / norm
        if d > worst:
            worst, index = d, i

    if worst <= epsilon:
        return [points[0], points[-1]]
    return rdp(points[:index + 1], epsilon)[:-1] + rdp(points[index:], epsilon)


def catmull_rom_to_bezier(pts):
    """Catmull-Rom through the points, as SVG cubic segments.

    The curve passes through every point (unlike a plain Bezier hull), which
    matters here: these points are where the pen actually went.
    """
    if len(pts) < 2:
        return ""
    if len(pts) == 2:
        return "M %.2f %.2f L %.2f %.2f" % (*pts[0], *pts[1])

    d = ["M %.2f %.2f" % pts[0]]
    ext = [pts[0]] + list(pts) + [pts[-1]]
    for i in range(1, len(ext) - 2):
        p0, p1, p2, p3 = ext[i - 1], ext[i], ext[i + 1], ext[i + 2]
        c1 = (p1[0] + (p2[0] - p0[0]) / 6.0, p1[1] + (p2[1] - p0[1]) / 6.0)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6.0, p2[1] - (p3[1] - p1[1]) / 6.0)
        d.append("C %.2f %.2f %.2f %.2f %.2f %.2f" % (*c1, *c2, *p2))
    return " ".join(d)


def polyline_length(pts):
    return sum(math.dist(a, b) for a, b in zip(pts, pts[1:]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default=DRAWING)
    ap.add_argument("--size", type=float, default=150.0,
                    help="height of the finished wordmark, in px")
    ap.add_argument("--hand", choices=["finger", "stylus"], default="finger",
                    help="how hard to clean up. finger is the rougher input "
                         "and gets more of everything.")
    ap.add_argument("--smooth", type=int, default=None, help="moving-average window")
    ap.add_argument("--simplify", type=float, default=None,
                    help="RDP tolerance in source px; higher = fewer points")
    ap.add_argument("--resample", type=float, default=None,
                    help="even spacing between points, in source px")
    ap.add_argument("--round", dest="rounding", type=int, default=None,
                    help="corner-cutting passes")
    ap.add_argument("--text", default="BrolliOS", help="label only")
    args = ap.parse_args()

    # Finger drawing is coarse: wide averaging, aggressive simplification, and
    # a corner-cutting pass on top. The point is the shape you meant, not the
    # path your finger actually took.
    preset = {"finger": dict(smooth=9, simplify=3.0, resample=4.0, rounding=2),
              "stylus": dict(smooth=5, simplify=1.2, resample=2.0, rounding=1)}[args.hand]
    smooth_w = args.smooth if args.smooth is not None else preset["smooth"]
    simplify_t = args.simplify if args.simplify is not None else preset["simplify"]
    resample_s = args.resample if args.resample is not None else preset["resample"]
    rounding = args.rounding if args.rounding is not None else preset["rounding"]

    if not os.path.exists(args.input):
        sys.exit(f"no drawing at {args.input} — run draw-wordmark.qml and press s")

    with open(args.input) as fh:
        data = json.load(fh)

    strokes = []
    for flat in data.get("strokes", []):
        pts = [(flat[i], flat[i + 1]) for i in range(0, len(flat) - 1, 2)]
        if len(pts) < 2:
            continue
        pts = resample(pts, resample_s)   # even spacing first, so the rest is even
        pts = smooth(pts, smooth_w)
        pts = rdp(pts, simplify_t)
        pts = chaikin(pts, rounding)
        pts = smooth(pts, 3)              # tidy what corner-cutting left
        if len(pts) >= 2:
            strokes.append(pts)

    if not strokes:
        sys.exit("no usable strokes in the drawing")

    # Normalise: move to the origin and scale so the height is --size.
    xs = [p[0] for s in strokes for p in s]
    ys = [p[1] for s in strokes for p in s]
    minx, maxx, miny, maxy = min(xs), max(xs), min(ys), max(ys)
    height = max(maxy - miny, 1.0)
    scale = args.size / height

    scaled = [[((x - minx) * scale, (y - miny) * scale) for x, y in s]
              for s in strokes]

    d = " ".join(catmull_rom_to_bezier(s) for s in scaled)
    length = sum(polyline_length(s) for s in scaled)
    width = (maxx - minx) * scale

    with open(OUT, "w") as fh:
        json.dump({
            "text": args.text,
            "style": "script",          # the splash draws it as one pen stroke
            "font": "hand-drawn",
            "size": args.size,
            "width": round(width, 1),
            "ascent": args.size,
            "descent": 0.0,
            "top": 0.0,
            "paths": [{"d": d, "len": round(length, 1),
                       "box": [0, 0, round(width, 1), args.size]}],
        }, fh, indent=1)

    raw = sum(len(s) for s in data.get("strokes", [])) // 2
    kept = sum(len(s) for s in strokes)
    print(f"{len(strokes)} stroke(s), {raw} raw points -> {kept} after cleanup "
          f"({args.hand}: resample {resample_s}, smooth {smooth_w}, "
          f"simplify {simplify_t}, round {rounding})")
    print(f"{width:.0f}x{args.size:.0f}px, {length:.0f}px of stroke -> {OUT}")
    print("restart the splash preview to see it")


if __name__ == "__main__":
    main()
