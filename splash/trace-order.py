#!/usr/bin/env python3
"""
Use a traced path to decide the order the wordmark is written in.

  qs -p splash/draw-wordmark.qml      trace over the wordmark, press s
  python3 splash/trace-order.py       rebuild the order map from that trace

Shape and order are separate problems, and this splits them:

  the SHAPE comes from the image -- every bit of the brush's weight and taper,
  exactly as drawn.

  the ORDER comes from your finger -- which stroke first, which direction, what
  the pen does at a crossing.

Order is the half no analysis can recover. Distance through the ink spreads
outward in all directions at once, so branches arrive together. Walking a
skeleton guesses a plausible route and reads like a machine tracing, because
that is what it is. A human tracing it is the only source of a human order.

Every ink pixel takes the position along your trace of the nearest traced
point, measured THROUGH the ink, so the full width of a stroke is written as
your finger passes over it.
"""
import argparse
import json
import math
import os
import sys
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
DRAWING = os.path.join(HERE, "drawing.json")
MASK = os.path.join(HERE, "wordmark-mask.png")
OUT_ORDER = os.path.join(HERE, "wordmark-order.png")
OUT_JSON = os.path.join(HERE, "wordmark.json")


def trace_points(data, mask_w, mask_h):
    """Traced points, mapped from canvas coordinates onto the mask's."""
    tr = data.get("trace") or {}
    tw, th = tr.get("width") or 0, tr.get("height") or 0
    if not tw or not th:
        sys.exit("that drawing has no trace geometry — retrace with the "
                 "current draw-wordmark.qml, which records where the image sat")

    ox = (tr.get("x") or 0) + (tr.get("ox") or 0)
    oy = (tr.get("y") or 0) + (tr.get("oy") or 0)
    sx, sy = mask_w / tw, mask_h / th

    out = []
    for flat in data.get("strokes", []):
        pts = []
        for i in range(0, len(flat) - 1, 2):
            x = (flat[i] - ox) * sx
            y = (flat[i + 1] - oy) * sy
            pts.append((x, y))
        if len(pts) >= 2:
            out.append(pts)
    return out


def smooth_stroke(pts, window=9, passes=2):
    """Average along the traced line.

    A finger does not move smoothly, and every wobble in the trace becomes a
    wobble in WHEN the ink appears -- the reveal stalls where the finger
    hesitated and lurches where it slipped. Your trace is the route, not a
    recording to play back frame for frame.
    """
    for _ in range(passes):
        if len(pts) <= 2:
            return pts
        out = [pts[0]]
        half = window // 2
        for i in range(1, len(pts) - 1):
            lo, hi = max(0, i - half), min(len(pts), i + half + 1)
            seg = pts[lo:hi]
            out.append((sum(q[0] for q in seg) / len(seg),
                        sum(q[1] for q in seg) / len(seg)))
        out.append(pts[-1])
        pts = out
    return pts


def smooth_order(order, ink, w, h, passes=6):
    """Blur the order field, within the ink only.

    Each pixel takes the time of the nearest traced point, which carves the
    ink into blocks with hard boundaries between them -- and the reveal edge
    then steps along those boundaries instead of sweeping. Averaging each
    pixel against its neighbours turns the blocks into a gradient, which is
    what makes the sweep smooth rather than jagged.
    """
    cur = list(order)
    for _ in range(passes):
        nxt = list(cur)
        for y in range(h):
            row = y * w
            for x in range(w):
                i = row + x
                if not ink[i] or cur[i] is None:
                    continue
                total, n = 0.0, 0
                for dy in (-1, 0, 1):
                    yy = y + dy
                    if yy < 0 or yy >= h:
                        continue
                    for dx in (-1, 0, 1):
                        xx = x + dx
                        if xx < 0 or xx >= w:
                            continue
                        j = yy * w + xx
                        if ink[j] and cur[j] is not None:
                            total += cur[j]
                            n += 1
                if n:
                    nxt[i] = total / n
        cur = nxt
    return cur


def densify(strokes, step=1.5):
    """Points every `step` px along the trace, each with its position 0..1.

    Sampled evenly so the reveal moves at a steady speed, rather than racing
    wherever your finger happened to move quickly.
    """
    lengths = [sum(math.dist(a, b) for a, b in zip(s, s[1:])) for s in strokes]
    total = sum(lengths) or 1.0
    # A pause between strokes, so the pen visibly lifts.
    gap = total * 0.02

    out, travelled = [], 0.0
    for s, length in zip(strokes, lengths):
        for a, b in zip(s, s[1:]):
            d = math.dist(a, b)
            if d <= 0:
                continue
            n = max(1, int(d / step))
            for k in range(n):
                f = k / n
                out.append(((a[0] + (b[0] - a[0]) * f,
                             a[1] + (b[1] - a[1]) * f),
                            travelled + d * f))
            travelled += d
        travelled += gap
    span = travelled or 1.0
    return [(p, t / span) for p, t in out]


def build_order(mask, points):
    w, h = mask.size
    px = mask.load()
    ink = bytearray(w * h)
    for y in range(h):
        for x in range(w):
            if px[x, y] > 40:
                ink[y * w + x] = 1

    order = [None] * (w * h)
    q = deque()
    seeded = 0
    for (x, y), t in points:
        xi, yi = int(round(x)), int(round(y))
        if 0 <= xi < w and 0 <= yi < h:
            i = yi * w + xi
            if order[i] is None or t < order[i]:
                order[i] = t
                q.append(i)
                seeded += 1

    if not seeded:
        sys.exit("none of the trace landed on the wordmark — retrace it")

    # Through the ink first: a stroke's whole width belongs to the moment the
    # finger crossed it.
    while q:
        i = q.popleft()
        x, y = i % w, i // w
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h:
                    j = ny * w + nx
                    if ink[j] and order[j] is None:
                        order[j] = order[i]
                        q.append(j)

    # Then a little way outside it. The material reaches past each letter, and
    # a fringe left at 0 would light up before anything was written.
    fringe = deque(i for i in range(w * h) if order[i] is not None)
    for _ in range(28):
        nxt = deque()
        while fringe:
            i = fringe.popleft()
            x, y = i % w, i // w
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h:
                        j = ny * w + nx
                        if order[j] is None:
                            order[j] = order[i]
                            nxt.append(j)
        fringe = nxt
        if not fringe:
            break

    unreached = sum(1 for i in range(w * h) if ink[i] and order[i] is None)

    # Smooth the field before it is used, so the reveal sweeps instead of
    # stepping between blocks of equal time.
    order = smooth_order(order, ink, w, h)

    return [(o if o is not None else 1.0) for o in order], unreached


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--drawing", default=DRAWING)
    ap.add_argument("--mask", default=MASK)
    args = ap.parse_args()

    from PIL import Image

    for path in (args.drawing, args.mask):
        if not os.path.exists(path):
            sys.exit(f"missing {path}")

    with open(args.drawing) as fh:
        data = json.load(fh)

    mask = Image.open(args.mask).convert("RGBA").split()[-1]
    strokes = trace_points(data, mask.width, mask.height)
    if not strokes:
        sys.exit("no strokes in that drawing")

    strokes = [smooth_stroke(s) for s in strokes]
    points = densify(strokes)
    order, unreached = build_order(mask, points)

    w, h = mask.size
    hi, lo = Image.new("L", mask.size), Image.new("L", mask.size)
    hp, lp = hi.load(), lo.load()
    for y in range(h):
        for x in range(w):
            v = int(round(min(1.0, order[y * w + x]) * 65535))
            hp[x, y] = (v >> 8) & 0xFF
            lp[x, y] = v & 0xFF
    Image.merge("RGBA", (hi, lo, Image.new("L", mask.size, 0),
                         Image.new("L", mask.size, 255))).save(OUT_ORDER)

    with open(OUT_JSON) as fh:
        meta = json.load(fh)
    meta["ordered"] = True
    meta["order"] = os.path.basename(OUT_ORDER)
    meta["orderSource"] = "traced"
    with open(OUT_JSON, "w") as fh:
        json.dump(meta, fh, indent=1)

    print(f"{len(strokes)} traced stroke(s), {len(points)} sampled positions")
    if unreached:
        print(f"WARNING: {unreached} ink pixels were never reached by the trace "
              f"— they will appear at the very end. Trace over every stroke.")
    print(f"order rebuilt from your trace -> {OUT_ORDER}")
    print("restart the splash preview to see it")


if __name__ == "__main__":
    main()
