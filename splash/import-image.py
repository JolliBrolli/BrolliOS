#!/usr/bin/env python3
"""
Turn a wordmark image into the splash's glass mask.

  python3 splash/import-image.py ~/Downloads/signature.png

Why this beats tracing it: the glass shader already takes its shape from a
MASK texture, and an image of a wordmark IS a mask. Vectorising would convert
the ink to outlines, which is the wrong shape entirely -- the outline of a
brush stroke is its boundary, not the stroke. Used directly, every bit of the
brush's weight and taper survives exactly as drawn.

What it does:
  · takes the alpha if the file has one, otherwise treats dark pixels as ink
  · crops to the ink, so the wordmark is not floating in a box of nothing
  · scales to the requested height
  · writes a white-on-transparent PNG, because the shader reads .a and does not
    care about colour

The reveal animation is handled in the shader as a wipe, since a raster mask
has no stroke order to follow. On cursive that reads as writing anyway: the
word is built left to right, which is the direction a wipe moves.
"""
import argparse
import heapq
import json
import math
import os
import sys
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_PNG = os.path.join(HERE, "wordmark-mask.png")
OUT_ORDER = os.path.join(HERE, "wordmark-order.png")
OUT_JSON = os.path.join(HERE, "wordmark.json")


def components(ink, w, h):
    """Connected blobs of ink, 8-connectivity, each as a list of indices."""
    seen = bytearray(w * h)
    blobs = []
    for start in range(w * h):
        if not ink[start] or seen[start]:
            continue
        q, blob = deque([start]), []
        seen[start] = 1
        while q:
            i = q.popleft()
            blob.append(i)
            x, y = i % w, i // w
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h:
                        j = ny * w + nx
                        if ink[j] and not seen[j]:
                            seen[j] = 1
                            q.append(j)
        blobs.append(blob)
    return blobs


def skeletonise(ink, w, h):
    """Zhang-Suen thinning: the ink reduced to a 1px centreline.

    This is the pen's path. Distance through the ink was never going to look
    like writing, because it spreads in every direction at once -- both bowls
    of a B fill together if they are the same distance from the start. A pen
    goes along a line. To order pixels the way a pen lays them down, you need
    the line.
    """
    import numpy as np
    img = np.frombuffer(bytes(ink), dtype=np.uint8).reshape(h, w).copy()

    def neighbours(P):
        p2 = np.roll(P, 1, 0)                      # N
        p6 = np.roll(P, -1, 0)                     # S
        p4 = np.roll(P, -1, 1)                     # E
        p8 = np.roll(P, 1, 1)                      # W
        p3 = np.roll(p2, -1, 1)                    # NE
        p5 = np.roll(p6, -1, 1)                    # SE
        p7 = np.roll(p6, 1, 1)                     # SW
        p9 = np.roll(p2, 1, 1)                     # NW
        return p2, p3, p4, p5, p6, p7, p8, p9

    for _ in range(200):
        changed = False
        for step in (0, 1):
            p2, p3, p4, p5, p6, p7, p8, p9 = neighbours(img)
            B = p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9
            seq = (p2, p3, p4, p5, p6, p7, p8, p9, p2)
            A = sum(((seq[k] == 0) & (seq[k + 1] == 1)).astype(np.uint8)
                    for k in range(8))
            if step == 0:
                m = (img == 1) & (B >= 2) & (B <= 6) & (A == 1) & \
                    (p2 * p4 * p6 == 0) & (p4 * p6 * p8 == 0)
            else:
                m = (img == 1) & (B >= 2) & (B <= 6) & (A == 1) & \
                    (p2 * p4 * p8 == 0) & (p2 * p6 * p8 == 0)
            if m.any():
                img[m] = 0
                changed = True
        if not changed:
            break

    return [int(y) * w + int(x) for y, x in zip(*np.nonzero(img))]


def walk_skeleton(skel, w, h):
    """Order the skeleton the way a nib would travel it.

    Starts at the leftmost free end -- where a stroke begins -- and at each
    junction carries STRAIGHT ON rather than turning off, which is what a pen
    does through a crossing. When a branch dead-ends it jumps to the nearest
    unvisited point: a pen lift. One stroke finishes before the next starts,
    which is the whole difference from a flood.
    """
    S = set(skel)
    if not S:
        return []

    def nbrs(i):
        x, y = i % w, i // w
        out = []
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx or dy:
                    j = (y + dy) * w + (x + dx)
                    if 0 <= x + dx < w and 0 <= y + dy < h and j in S:
                        out.append(j)
        return out

    degree = {i: len(nbrs(i)) for i in S}
    ends = [i for i in S if degree[i] == 1]
    unvisited = set(S)

    def leftmost(pool):
        return min(pool, key=lambda i: (i % w, i // w))

    start = leftmost(ends) if ends else leftmost(unvisited)
    order, cur, direction = [], start, (1.0, 0.0)

    while unvisited:
        if cur is None:
            # Pen lift: prefer a free end, else anything, leftmost first.
            pool = [i for i in ends if i in unvisited] or list(unvisited)
            cur = leftmost(pool)
            direction = (1.0, 0.0)

        order.append(cur)
        unvisited.discard(cur)
        cx, cy = cur % w, cur // w

        best, best_score = None, -2.0
        for j in nbrs(cur):
            if j not in unvisited:
                continue
            jx, jy = j % w, j // w
            dx, dy = jx - cx, jy - cy
            n = math.hypot(dx, dy) or 1.0
            # Straight on beats turning off.
            score = (dx / n) * direction[0] + (dy / n) * direction[1]
            if score > best_score:
                best, best_score = j, score

        if best is None:
            cur = None
            continue
        bx, by = best % w, best // w
        n = math.hypot(bx - cx, by - cy) or 1.0
        # Ease the heading round rather than snapping, so a curve stays a curve.
        direction = (direction[0] * 0.55 + (bx - cx) / n * 0.45,
                     direction[1] * 0.55 + (by - cy) / n * 0.45)
        cur = best

    return order


def order_map(mask, w, h):
    """When each pixel is written, 0..1, following a traversal of the skeleton."""
    px = mask.load()
    ink = bytearray(w * h)
    for y in range(h):
        for x in range(w):
            if px[x, y] > 40:
                ink[y * w + x] = 1

    blobs = components(ink, w, h)
    blobs.sort(key=lambda b: min(i % w for i in b))

    # Walk each blob in turn, left to right, building one global pen order.
    walk_index = {}
    idx = 0
    for blob in blobs:
        sub = bytearray(w * h)
        for i in blob:
            sub[i] = 1
        skel = skeletonise(sub, w, h)
        if not skel:
            skel = [min(blob, key=lambda i: (i % w, i // w))]
        for i in walk_skeleton(skel, w, h):
            walk_index[i] = idx
            idx += 1

    total = max(idx - 1, 1)

    # Every ink pixel takes the index of the skeleton point nearest through the
    # ink, so the full width of a brush stroke is written as the nib passes,
    # not smeared behind it.
    order = [None] * (w * h)
    q = deque()
    for i, v in walk_index.items():
        order[i] = v
        q.append(i)
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

    # And spread it a little way OUTSIDE the ink too. The material reaches past
    # the letter's edge, and if that fringe reads as order 0 it lights up from
    # the first frame -- the faint outline of unwritten letters.
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

    # Anything still unreached is far from any ink: written last, never seen.
    return [(o / total if o is not None else 1.0) for o in order], len(blobs), idx


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--size", type=float, default=170.0,
                    help="height of the finished wordmark, in px")
    ap.add_argument("--threshold", type=int, default=128,
                    help="for images with no alpha: luma below this is ink")
    ap.add_argument("--pad", type=int, default=2,
                    help="transparent margin kept around the ink, in px")
    ap.add_argument("--text", default="BrolliOS", help="label only")
    args = ap.parse_args()

    try:
        from PIL import Image
    except ImportError:
        sys.exit("needs Pillow: pacman -S python-pillow")

    if not os.path.exists(args.image):
        sys.exit(f"no such file: {args.image}")

    im = Image.open(args.image)
    src_size = im.size

    if im.mode in ("RGBA", "LA") or "transparency" in im.info:
        mask = im.convert("RGBA").split()[-1]
        how = "alpha channel"
    else:
        # Dark ink on a light ground: invert luma so ink becomes opaque.
        mask = im.convert("L").point(lambda v: 255 if v < args.threshold else 0)
        how = f"dark pixels (luma < {args.threshold})"

    box = mask.getbbox()
    if box is None:
        sys.exit("that image is empty — nothing to make a mask from")
    mask = mask.crop(box)

    scale = args.size / mask.height
    target = (max(1, round(mask.width * scale)), max(1, round(args.size)))
    mask = mask.resize(target, Image.LANCZOS)

    if args.pad:
        padded = Image.new("L", (mask.width + args.pad * 2,
                                 mask.height + args.pad * 2), 0)
        padded.paste(mask, (args.pad, args.pad))
        mask = padded

    # Shape in the alpha, reveal order packed 16-bit across R and G. One
    # texture, and 8 bits of order would band visibly across a whole word.
    w, h = mask.size
    print(f"computing reveal order for {w}x{h}...", flush=True)
    order, blob_count, steps = order_map(mask, w, h)

    hi = Image.new("L", mask.size)
    lo = Image.new("L", mask.size)
    hi_px, lo_px = hi.load(), lo.load()
    for y in range(h):
        for x in range(w):
            v = int(round(order[y * w + x] * 65535))
            hi_px[x, y] = (v >> 8) & 0xFF
            lo_px[x, y] = v & 0xFF

    # Shape and order go in SEPARATE files on purpose. Anything that renders
    # through a ShaderEffectSource comes out premultiplied, which would scale
    # the order values by coverage and corrupt them at every antialiased edge.
    # A fully opaque texture cannot be damaged that way.
    Image.merge("RGBA", (
        Image.new("L", mask.size, 255), Image.new("L", mask.size, 255),
        Image.new("L", mask.size, 255), mask)).save(OUT_PNG)

    Image.merge("RGBA", (
        hi, lo, Image.new("L", mask.size, 0),
        Image.new("L", mask.size, 255))).save(OUT_ORDER)

    print(f"{blob_count} stroke(s), {steps} nib positions along the skeleton")

    with open(OUT_JSON, "w") as fh:
        json.dump({
            "text": args.text,
            "style": "image",
            "font": os.path.basename(args.image),
            "size": args.size,
            "width": mask.width,
            "height": mask.height,
            "ascent": mask.height,
            "descent": 0.0,
            "top": 0.0,
            "mask": os.path.basename(OUT_PNG),
            "ordered": True,
            "order": os.path.basename(OUT_ORDER),
            "paths": [],
        }, fh, indent=1)

    print(f"{os.path.basename(args.image)} {src_size[0]}x{src_size[1]} "
          f"-> ink from {how}")
    print(f"cropped to {box[2]-box[0]}x{box[3]-box[1]}, scaled to "
          f"{mask.width}x{mask.height} -> {OUT_PNG}")
    print("restart the splash preview to see it")


if __name__ == "__main__":
    main()
