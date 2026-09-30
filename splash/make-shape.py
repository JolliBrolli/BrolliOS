#!/usr/bin/env python3
"""
Turn the wordmark mask into a shape field the real material can read.

  python3 splash/make-shape.py

The plugin's material derives everything from one number: sd, the signed
distance to the edge of the panel. Depth, the lens profile, the blur radius,
the chromatic split and the antialiasing all come out of it:

    float sd   = sdf(glassCoord, glassSize * 0.5, r);
    float aa   = clamp(0.5 - sd / max(fwidth(sd), 1e-4), 0.0, 1.0);
    float dist = 1.0 - clamp(-sd / size / aghDepth, 0.0, 1.0);

sdf() is a rounded rectangle, which is why the material can only be a panel.
Give it the same number sampled from a texture and every line after it runs
unchanged -- so the letters are drawn by the same material, not by something
that resembles it.

Three channels, because the rounded-rect formula produces three things
implicitly that a letter has to be told:

  sd            signed distance, negative inside. Depth and antialiasing.
  gradient      which way is "out". The shader takes this from sd itself, by
                central differences -- a distance field is smooth, so this is
                exact and costs two extra samples.
  half-thickness  how far it is from the middle of a stroke to its edge. In
                the panel this is (halfSize - coreHalf); for a letter it
                varies along every stroke, so it is measured and stored.

Antialiasing comes free and analytic from sd, which is why the edges stop
looking like a resized bitmap.
"""
import json
import math
import os
import sys
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
MASK = os.path.join(HERE, "wordmark-mask.png")
OUT = os.path.join(HERE, "wordmark-shape.png")
META = os.path.join(HERE, "wordmark.json")

# Narrow on purpose. This is stored in ONE 8-bit channel so it can be sampled
# with linear filtering, and a distance field must be filtered linearly -- it
# is a smooth function, and nearest-neighbour sampling turns it into a
# staircase. fwidth() of a staircase is what jagged antialiasing looks like.
# 32px over 256 levels is 0.125px per step, far below anything visible, and
# the reconstruction between texels is continuous regardless.
SD_RANGE = 32.0


def edt(binary, w, h):
    """Exact Euclidean distance to the nearest True, by Felzenszwalb.

    Two separable passes of a 1D squared-distance transform. Exact, and linear
    in the number of pixels -- a naive nearest-neighbour search over a 1562px
    wordmark would not finish in reasonable time.
    """
    import numpy as np
    INF = 1e20
    f = np.where(binary, 0.0, INF).astype(np.float64).reshape(h, w)

    def pass1d(arr):
        n = arr.shape[0]
        out = np.empty_like(arr)
        v = np.zeros(n, dtype=np.int64)
        z = np.zeros(n + 1)
        k = 0
        v[0] = 0
        z[0], z[1] = -INF, INF
        for q in range(1, n):
            while True:
                s = ((arr[q] + q * q) - (arr[v[k]] + v[k] * v[k])) / (2.0 * q - 2.0 * v[k])
                if s <= z[k]:
                    k -= 1
                    if k < 0:
                        k = 0
                        break
                else:
                    break
            k += 1
            v[k] = q
            z[k] = s
            z[k + 1] = INF
        k = 0
        for q in range(n):
            while z[k + 1] < q:
                k += 1
            d = q - v[k]
            out[q] = d * d + arr[v[k]]
        return out

    for x in range(w):
        f[:, x] = pass1d(f[:, x])
    for y in range(h):
        f[y, :] = pass1d(f[y, :])
    return np.sqrt(f)


def main():
    try:
        from PIL import Image
        import numpy as np
    except ImportError:
        sys.exit("needs Pillow and numpy")

    if not os.path.exists(MASK):
        sys.exit(f"no {MASK} — run import-image.py first")

    alpha = Image.open(MASK).convert("RGBA").split()[-1]
    w, h = alpha.size
    a = np.asarray(alpha, dtype=np.uint8)
    ink = a > 127

    print(f"distance field for {w}x{h}...", flush=True)
    d_out = edt(ink.ravel(), w, h)        # distance to ink, for pixels outside
    d_in = edt(~ink.ravel(), w, h)        # distance to background, inside

    # Negative inside, positive outside: the same sign convention the panel's
    # sdf() uses, so nothing downstream has to change.
    sd = np.where(ink, -d_in, d_out)

    # Half-thickness: the distance-to-edge at the middle of the stroke. The
    # ridge of d_in IS the middle, so find it and carry its value out to the
    # pixels that belong to it.
    print("local thickness...", flush=True)
    ridge = np.zeros((h, w), dtype=bool)
    di = d_in.reshape(h, w)
    core = di[1:-1, 1:-1]
    is_max = np.ones_like(core, dtype=bool)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dx or dy:
                is_max &= core >= di[1 + dy:h - 1 + dy, 1 + dx:w - 1 + dx] - 1e-9
    ridge[1:-1, 1:-1] = is_max & (core > 1.0)

    half = np.zeros((h, w), dtype=np.float64)
    q = deque()
    ys, xs = np.nonzero(ridge)
    for y, x in zip(ys, xs):
        half[y, x] = di[y, x]
        q.append((int(x), int(y)))
    inkm = ink.reshape(h, w)
    while q:
        x, y = q.popleft()
        v = half[y, x]
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h and inkm[ny, nx] and half[ny, nx] == 0.0:
                    half[ny, nx] = v
                    q.append((nx, ny))
    half[half == 0.0] = max(1.0, float(di.max()))

    # One channel each, so both can be sampled with linear filtering.
    enc = np.clip((sd + SD_RANGE) / (2.0 * SD_RANGE), 0.0, 1.0)
    r = np.round(enc * 255).astype(np.uint8).reshape(h, w)
    g = np.clip(np.round(half), 0, 255).astype(np.uint8)

    out = Image.merge("RGBA", (
        Image.fromarray(r),
        Image.fromarray(g),
        Image.fromarray(np.zeros((h, w), dtype=np.uint8)),
        Image.fromarray(np.full((h, w), 255, dtype=np.uint8))))
    out.save(OUT)

    with open(META) as fh:
        meta = json.load(fh)
    meta["shape"] = os.path.basename(OUT)
    meta["sdRange"] = SD_RANGE
    with open(META, "w") as fh:
        json.dump(meta, fh, indent=1)

    print(f"sd range {sd.min():.1f}..{sd.max():.1f}px, "
          f"stroke half-thickness {half[inkm].min():.1f}..{half[inkm].max():.1f}px")
    print(f"-> {OUT}")


if __name__ == "__main__":
    main()
