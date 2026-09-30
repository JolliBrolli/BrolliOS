#!/usr/bin/env python3
"""
Build the wordmark from a line drawing.

  python3 splash/import-lineart.py ~/Downloads/umbrella.png

A line drawing is two things at once, and they want treating differently:

  the SILHOUETTE   everything the outline encloses -- the canopy panels, the
                   shaft. This is the body of glass.
  the LINES        the drawn strokes themselves. Same glass, but darker, so
                   the drawing still reads inside the material.

So the outline is not the shape. The shape is what the outline CONTAINS, found
by flooding inwards from the edge of the image: anything the flood cannot reach
is enclosed, and enclosed is what "inside the umbrella" means. The lines are
kept separately and handed to the shader to darken.

Drawing order comes from walking the lines, then spreading outwards into the
areas they enclose -- so a panel fills in behind the rib that bounds it, rather
than appearing whole.

Writes the same three textures everything downstream already reads.
"""
import argparse
import importlib.util
import json
import math
import os
import sys
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_SHAPE = os.path.join(HERE, "wordmark-shape.png")
OUT_ORDER = os.path.join(HERE, "wordmark-order.png")
OUT_TUBE = os.path.join(HERE, "wordmark-tube.png")
OUT_JSON = os.path.join(HERE, "wordmark.json")
SD_RANGE = 32.0


def load(name, filename):
    """Import a sibling script whose name has a hyphen in it."""
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--size", type=float, default=460.0, help="height in px")
    ap.add_argument("--threshold", type=int, default=128, help="luma below this is a line")
    ap.add_argument("--pad", type=int, default=40, help="margin around the shape")
    ap.add_argument("--fillet", type=float, default=0.5,
                    help="how much to round the joins, as a fraction of the radius")
    ap.add_argument("--tube", type=float, default=5.0,
                    help="how far the noodle swells beyond the drawn line, px. "
                         "0 leaves the drawing flat.")
    args = ap.parse_args()

    from PIL import Image
    import numpy as np

    shape_mod = load("make_shape", "make-shape.py")
    img_mod = load("import_image", "import-image.py")

    im = Image.open(args.image).convert("RGBA")
    a = np.asarray(im)
    lum = a[..., :3].mean(axis=2)
    opaque = a[..., 3] > 128
    lines = opaque & (lum < args.threshold)

    if not lines.any():
        sys.exit("no dark lines found — try --threshold")

    # Crop to the drawing before anything expensive.
    ys, xs = np.nonzero(lines)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    lines = lines[y0:y1, x0:x1]

    # Scale to the requested height, as a picture, so the strokes stay smooth.
    src_h, src_w = lines.shape
    scale = args.size / src_h
    tw, th = max(1, round(src_w * scale)), max(1, round(args.size))
    lines_img = Image.fromarray((lines * 255).astype(np.uint8)).resize(
        (tw, th), Image.LANCZOS)
    linef = np.asarray(lines_img).astype(np.float32) / 255.0
    lines = linef > 0.45

    # Pad, so the material has room to reach past the edge.
    p = args.pad
    w, h = tw + p * 2, th + p * 2
    L = np.zeros((h, w), dtype=bool)
    L[p:p + th, p:p + tw] = lines
    LF = np.zeros((h, w), dtype=np.float32)
    LF[p:p + th, p:p + tw] = linef

    # ── the silhouette: what the outline encloses ───────────────────────
    # Flood from the border through everything that is not a line. Whatever
    # the flood never reaches is enclosed by the drawing, and enclosed is what
    # "inside the umbrella" means. A function, because the drawing gets edited
    # below and the silhouette has to be worked out again afterwards.
    def flood(lines):
        L = lines
        outside = np.zeros((h, w), dtype=bool)
        q = deque()
        for x in range(w):
            for y in (0, h - 1):
                if not L[y, x] and not outside[y, x]:
                    outside[y, x] = True
                    q.append((x, y))
        for y in range(h):
            for x in (0, w - 1):
                if not L[y, x] and not outside[y, x]:
                    outside[y, x] = True
                    q.append((x, y))
        while q:
            x, y = q.popleft()
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h and not outside[ny, nx] and not L[ny, nx]:
                    outside[ny, nx] = True
                    q.append((nx, ny))

        return outside, ~outside

    outside, solid = flood(L)
    print(f"lines {int(L.sum())}px, enclosed {int(solid.sum() - L.sum())}px, "
          f"silhouette {int(solid.sum())}px")

    # Where the canopy ends and the handle begins, and how wide the pen is.
    # Both are needed before the noodle can be built, so they are measured
    # here rather than inside the ordering that also uses them.
    widths = solid.sum(axis=1)
    canopy_rows = widths > widths.max() * 0.30
    split = int(np.nonzero(canopy_rows)[0].max()) if canopy_rows.any() else h // 2

    # The PEN's stroke width, not the silhouette's thickness: half[] measures
    # how deep the shape is, which inside the canopy is tens of pixels.
    d_line = shape_mod.edt((~L).ravel(), w, h).reshape(h, w)
    stroke = max(2.0, float(np.median(d_line[L])) * 2.0)

    # ── the noodle: a tube on the drawing's own strokes ─────────────────
    # The drawing IS the shape. Nothing here edits it.
    #
    # Everything that used to stand between this point and the drawing has
    # been taken out, because every piece of it was a correction to artwork
    # that did not need correcting, and together they left a shape that no
    # longer matched it:
    #
    #   - a trim that deleted the two scallops beside the shaft, and with them
    #     the tail's bend and returning limb;
    #   - a hem drawn straight across the gap that trim left;
    #   - a morphological closing that welded the rod's two walls into one bar;
    #   - a centreline carried up to the apex, inventing a shaft the drawing
    #     does not have inside the canopy;
    #   - a stick zone that then had to exclude the rod from the canopy to
    #     stop it being tubed twice.
    #
    # What is left is the honest version. The centreline is the skeleton of
    # the ink: one pixel down the middle of every stroke, wherever the drawing
    # put it -- both walls of the rod, every rib, every scallop. The radius is
    # the one number that is ours rather than the drawing's, and it is uniform,
    # so the whole umbrella reads as one piece of glass.
    apex_y = int(np.nonzero(solid.any(axis=1))[0].min())
    apex_x = int(np.average(np.nonzero(solid[apex_y + 2])[0])) if solid[apex_y + 2].any() else w // 2

    # The one place the drawing is not followed literally: the handle.
    #
    # It is drawn as an OUTLINE -- two parallel lines with the rod's body
    # between them -- so a centreline through the ink is a centreline through
    # each line, and the handle comes out as two rails with a strip of film
    # down the middle. It is meant to be one rod, so the two lines are welded
    # before the centreline is taken.
    #
    # Welding is a morphological closing, and the radius is measured off the
    # drawing rather than guessed: below the canopy the rod is the only thing
    # there, so the gap between its two lines is the gap between the two runs
    # of ink on a row. A closing joins anything less than 2r apart, so half the
    # gap and a touch more welds the rod and nothing else -- the canopy's
    # panels are many times wider than that and stay open.
    def runs_in(row):
        out, i = [], 0
        while i < w:
            if row[i]:
                j = i
                while j < w and row[j]:
                    j += 1
                out.append((i, j - 1))
                i = j
            else:
                i += 1
        return out

    gaps = [rr[1][0] - rr[0][1] - 1 for rr in
            (runs_in(L[y]) for y in range(split + 4, h)) if len(rr) == 2]
    rod_gap = float(np.median(gaps)) if gaps else 0.0
    r_weld = rod_gap / 2.0 + 1.5

    welded = L
    if rod_gap > 1.0:
        dil = shape_mod.edt(L.ravel(), w, h).reshape(h, w) <= r_weld
        welded = (shape_mod.edt((~dil).ravel(), w, h).reshape(h, w) > r_weld - 0.5) | L
    print(f"  rod is {rod_gap:.0f}px across ({len(gaps)} rows), welded with r={r_weld:.1f}")

    skel = img_mod.skeletonise(bytearray(int(v) for v in welded.ravel()), w, h)
    centreline = np.zeros((h, w), dtype=bool)
    for idx in skel:
        centreline[idx // w, idx % w] = True
    print(f"  centreline: {int(centreline.sum())}px")

    # edt() returns the distance TO the nearest True, so this is the distance
    # to the centreline. Inverting it would measure the distance to background
    # instead, which inside a 4px line is never more than 2 -- the tube then
    # swallows the entire image.
    d_centre = shape_mod.edt(centreline.ravel(), w, h).reshape(h, w)
    tube_r = args.tube + stroke * 0.5
    tube_solid = d_centre <= tube_r

    # Round the joins.
    #
    # Two tubes meeting is a union of two cylinders, and a union has a sharp
    # concave crease down the inside of the angle -- which is why a rib landing
    # on the hem looked like two pieces overlapping rather than one piece
    # branching. A closing puts a fillet in exactly there: it rounds concave
    # corners and leaves convex ones alone, so the tubes keep their own width
    # and only the crotch between them fills in. Unioned back with the tube
    # afterwards, because an erosion may not give back everything it took.
    fillet = args.fillet * tube_r
    if fillet >= 1.0:
        grown = shape_mod.edt(tube_solid.ravel(), w, h).reshape(h, w) <= fillet
        tube_solid = (shape_mod.edt((~grown).ravel(), w, h).reshape(h, w)
                      > fillet - 0.5) | tube_solid

    # A real signed distance for the filleted tube, rather than `d_centre - r`,
    # which only describes the unfilleted one.
    dt_out = shape_mod.edt(tube_solid.ravel(), w, h).reshape(h, w)
    dt_in = shape_mod.edt((~tube_solid).ravel(), w, h).reshape(h, w)
    sd_tube = np.where(tube_solid, -dt_in, dt_out).astype(np.float32)
    half_tube = np.full((h, w), max(1.0, tube_r), dtype=np.float32)
    print(f"  noodle radius {tube_r:.1f}px on a {stroke:.1f}px stroke, "
          f"joins filleted at {fillet:.1f}px")

    # ── what is actually covered ────────────────────────────────────────
    # The drawing's silhouette -- its strokes and everything they enclose --
    # plus the tube where it stands proud of that. The enclosed parts are the
    # canopy's panels and the inside of the rod, which is what makes the rod
    # read as a rod rather than as two rails with a gap down it.
    #
    # ...except the rod. Having welded its two lines into one noodle, its
    # drawn outline must stop being film as well, or the shape it used to have
    # sits behind the noodle as a slab 22px wide with a 14px noodle down the
    # middle of it -- the drawing showing through its own replacement. So the
    # rod's body, and the two lines around it, come out of the silhouette and
    # the noodle is all the coverage there is there.
    filled = welded & ~L
    rod_zone = filled | (L & (shape_mod.edt(filled.ravel(), w, h).reshape(h, w)
                              <= stroke + 1.5))
    solid = (solid & ~rod_zone) | tube_solid
    # Any hole left inside the coverage is an artefact, so close it. Taking
    # the rod's outline out leaves a speck where its top cap sat inside the
    # canopy, and the panels are film already -- nothing that is genuinely
    # inside the umbrella should read as a gap.
    before = int(solid.sum())
    _, solid = flood(solid)
    print(f"  closed {int(solid.sum()) - before}px of holes in the coverage")

    # And any speck left floating is an artefact too. Taking the rod's outline
    # out leaves fragments of it wherever its body was too narrow to reach
    # them, and they read as bits of the drawing hanging beside the noodle.
    # The umbrella is one connected piece, so everything that is not joined to
    # the main body is debris.
    comps = img_mod.components(bytearray(int(v) for v in solid.ravel()), w, h)
    if len(comps) > 1:
        comps.sort(key=len, reverse=True)
        keep = np.zeros((h, w), dtype=bool)
        for idx in comps[0]:
            keep[idx // w, idx % w] = True
        print(f"  dropped {len(comps) - 1} floating fragments, "
              f"{sum(len(c) for c in comps[1:])}px")
        solid = keep
    print(f"  coverage: silhouette - rod outline ({int(rod_zone.sum())}px) "
          f"+ noodle = {int(solid.sum())}px")

    # ── signed distance + local half-thickness of the silhouette ────────
    print("distance field...", flush=True)
    d_out = shape_mod.edt(solid.ravel(), w, h)
    d_in = shape_mod.edt((~solid).ravel(), w, h)
    sd = np.where(solid, -d_in, d_out)

    di = d_in.reshape(h, w)
    ridge = np.zeros((h, w), dtype=bool)
    core = di[1:-1, 1:-1]
    is_max = np.ones_like(core, dtype=bool)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dx or dy:
                is_max &= core >= di[1 + dy:h - 1 + dy, 1 + dx:w - 1 + dx] - 1e-9
    ridge[1:-1, 1:-1] = is_max & (core > 1.0)

    half = np.zeros((h, w), dtype=np.float64)
    q = deque()
    for y, x in zip(*np.nonzero(ridge)):
        half[y, x] = di[y, x]
        q.append((int(x), int(y)))
    while q:
        x, y = q.popleft()
        v = half[y, x]
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h and solid[ny, nx] and half[ny, nx] == 0.0:
                    half[ny, nx] = v
                    q.append((nx, ny))
    half[half == 0.0] = max(1.0, float(di.max()))

    # ── drawing order: the way a hand draws an umbrella ─────────────────
    # Not a generic walk. Walking the line art from its leftmost point treats
    # every rib as just another branch, so it hops between them and the result
    # reads as a scatter of little lines rather than one drawing. An umbrella
    # is drawn in three moves: the canopy that keeps the rain off, then the
    # ribs on it, then the handle.
    print("drawing order...", flush=True)

    # Outline or rib? By distance from the silhouette's edge.
    #
    # Adjacency to the outside does not work: a stroke is several pixels wide
    # and only its outermost row touches, so the canopy outline came out as a
    # 1px sliver and the rest of the dome was counted as a rib. Distance does
    # work -- the outline strokes ARE the edge, so they sit within a stroke
    # width of it, while a rib is deep inside the shape.
    # Outline or rib? By how close the line is to the OUTSIDE.
    #
    # This used to measure against the silhouette's distance field, which no
    # longer works: the silhouette now swallows the tube, so every line sits a
    # tube-radius deep inside it and none of them read as outline. The outside
    # region is unaffected by that, and a few dilations of it is cheaper than
    # another distance transform anyway.
    near_out = outside.copy()
    for _ in range(int(stroke * 1.6) + 1):
        grown = near_out.copy()
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                grown |= np.roll(np.roll(near_out, dy, 0), dx, 1)
        near_out = grown
    boundary = L & near_out
    interior = L & ~boundary


    def walk(mask2d):
        """Order a piece of the drawing ALONG its own curve.

        Sorting by x or y looks fluid on a diagonal and falls apart on a turn:
        where the curve runs vertically, every pixel in that column shares an
        x and arrives at once, so the line appears in chunks. Walking the
        centreline follows the curve itself, so the speed is even whichever
        way it happens to be heading.
        """
        flat = bytearray(int(v) for v in mask2d.ravel())
        skel = img_mod.skeletonise(flat, w, h)
        if not skel:
            ys_, xs_ = np.nonzero(mask2d)
            return [int(y) * w + int(x) for y, x in zip(ys_, xs_)]
        return img_mod.walk_skeleton(skel, w, h)

    rows = np.arange(h)[:, None]
    phases = []

    # 1. the canopy outline, followed round rather than swept across
    canopy_edge = walk(boundary & (rows <= split))
    phases.append((canopy_edge, True))      # pause after: the canopy is done

    # 2. the ribs, one at a time, left to right, each followed from the apex
    #    outwards. They all meet at the apex, so as drawn they are a single
    #    connected component -- punch a small hole there and they separate.
    rib_area = interior & (rows <= split)
    yy, xx = np.ogrid[:h, :w]
    apex_hole = (xx - apex_x) ** 2 + (yy - apex_y) ** 2 < (stroke * 5.0) ** 2
    rib_mask = bytearray(int(v) for v in (rib_area & ~apex_hole).ravel())
    ribs = [r for r in img_mod.components(rib_mask, w, h) if len(r) > 12]
    ribs.sort(key=lambda b: sum(i % w for i in b) / len(b))
    for rib in ribs:
        m = np.zeros((h, w), dtype=bool)
        for i in rib:
            m[i // w, i % w] = True
        walked = walk(m)
        # Outwards from the apex, not inwards.
        if walked and ((walked[0] // w - apex_y) ** 2 + (walked[0] % w - apex_x) ** 2 >
                       (walked[-1] // w - apex_y) ** 2 + (walked[-1] % w - apex_x) ** 2):
            walked.reverse()
        # No pause between ribs: they are one movement, not eighteen.
        phases.append((walked, False))

    # 3. the handle: its centreline, followed down the shaft and round the hook
    if phases:
        last, _ = phases[-1]
        phases[-1] = (last, True)           # ...but pause once the ribs are all done

    # The welded centreline, not the drawn walls: the noodle runs down the
    # middle of the rod, so the pen has to as well, or the reveal creeps down
    # two lines that are no longer there.
    handle = walk(centreline & (rows > split))
    if handle and (handle[0] // w) > (handle[-1] // w):
        handle.reverse()        # start at the top, where it meets the canopy
    phases.append((handle, False))

    # Lay the phases end to end, with a pause between each so the pen lifts.
    walk_index, idx = {}, 0
    for phase, pause in phases:
        if not phase:
            continue
        for i in phase:
            walk_index[i] = idx
            idx += 1
        if pause:
            idx += max(8, len(phase) // 6)   # the pen lifts
    total = max(idx - 1, 1)
    print(f"  canopy {len(canopy_edge)}px -> {len(ribs)} ribs -> handle "
          f"{len(handle)}px  (stroke ~{stroke:.1f}px, 3 pen lifts)")

    order = [None] * (w * h)
    q = deque()
    for i, v in walk_index.items():
        order[i] = v / total
        q.append(i)
    solid_flat = solid.ravel()
    sdf_flat = sd.ravel()
    while q:
        i = q.popleft()
        x, y = i % w, i // w
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h:
                    j = ny * w + nx
                    if order[j] is None and (solid_flat[j] or abs(sdf_flat[j]) < 30):
                        order[j] = order[i]
                        q.append(j)
    order = np.array([o if o is not None else 1.0 for o in order],
                     dtype=np.float32).reshape(h, w)

    # The noodle is drawn, and THEN the film fills the openings -- like soap
    # across a wand rather than everything arriving together. The tube keeps
    # the first stretch of the timeline; each panel flows inwards from the
    # ribs that bound it through the last.
    TUBE_SHARE = 0.68
    in_tube = sd_tube < 0.0
    film = solid & ~in_tube
    order = order * TUBE_SHARE

    if film.any():
        # How deep into the opening a pixel is, 0 at its edge and 1 at the
        # middle -- so the film closes inwards.
        depth = shape_mod.edt((~film).ravel(), w, h).reshape(h, w)
        deep = depth[film].max() or 1.0
        order = np.where(film, TUBE_SHARE + (1.0 - TUBE_SHARE) * (depth / deep),
                         order)
        print(f"  film fills {int(film.sum())}px, up to {deep:.0f}px deep")

    # Blur it, hard, within the shape.
    #
    # Order is spread outwards from the centreline by a breadth-first flood,
    # and on a curve that is not symmetric: the outside of a bend is further
    # from the centreline than the inside, so first-arrival carves the tube
    # into wedges fanning off the bend. Each wedge holds one time, so the
    # reveal crosses them one after another -- which is exactly the row of
    # little segments that appears on every curve and never on a straight.
    #
    # Blurring across the tube evens them out. It needs to be wide relative to
    # the tube, not a token smoothing: 14 passes of a 3x3 is about 3px of
    # reach, against a tube 10px across, so it barely touched them.
    # The noodle and the film are blurred SEPARATELY. There is a deliberate
    # jump between them -- the tube finishes, then the film starts -- and
    # blurring across it would smear that away, which is the one boundary that
    # is supposed to be sharp.
    def smooth_within(field, mask, passes):
        out = field.copy()
        for _ in range(passes):
            acc = np.zeros_like(out)
            cnt = np.zeros_like(out)
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    acc += np.roll(np.roll(np.where(mask, out, 0.0), dy, 0), dx, 1)
                    cnt += np.roll(np.roll(mask.astype(np.float32), dy, 0), dx, 1)
            out = np.where(mask, np.where(cnt > 0, acc / np.maximum(cnt, 1), out), out)
        return out

    near = np.abs(sd) < 30
    order = smooth_within(order, in_tube | (near & ~solid), 60)
    order = smooth_within(order, film, 40)

    # Take the staircase out of the distance fields.
    #
    # Both are measured from a thresholded bitmap, so every edge is quantised
    # to whole pixels -- and the material derives its antialiasing from the
    # field's slope, so a staircase in the field IS a rough edge on screen.
    # Linear filtering cannot undo it: it interpolates between steps that are
    # already wrong. A couple of passes of averaging restores the sub-pixel
    # shape a distance field is supposed to have, and moves the edge by a
    # fraction of a pixel.
    def soften(field, passes=3):
        out = field.astype(np.float32)
        for _ in range(passes):
            acc = np.zeros_like(out)
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    acc += np.roll(np.roll(out, dy, 0), dx, 1)
            out = acc / 9.0
        return out

    sd = soften(sd)
    sd_tube = soften(sd_tube)

    # ── write the textures ──────────────────────────────────────────────
    enc = np.clip((sd + SD_RANGE) / (2.0 * SD_RANGE), 0.0, 1.0)
    Image.merge("RGBA", (
        Image.fromarray(np.round(enc * 255).astype(np.uint8)),
        Image.fromarray(np.clip(np.round(half), 0, 255).astype(np.uint8)),
        Image.fromarray(np.zeros((h, w), np.uint8)),
        Image.fromarray(np.full((h, w), 255, np.uint8)))).save(OUT_SHAPE)

    o16 = np.round(np.clip(order, 0, 1) * 65535).astype(np.uint32)
    Image.merge("RGBA", (
        Image.fromarray(((o16 >> 8) & 0xFF).astype(np.uint8)),
        Image.fromarray((o16 & 0xFF).astype(np.uint8)),
        Image.fromarray(np.zeros((h, w), np.uint8)),
        Image.fromarray(np.full((h, w), 255, np.uint8)))).save(OUT_ORDER)

    # No stroke texture any more. The shader used to darken the glass wherever
    # the drawing had ink, which put the original artwork back on top of the
    # noodle that replaced it -- and offset from it, since the noodle follows a
    # centreline derived from those strokes rather than the strokes themselves.

    enc_t = np.clip((sd_tube + SD_RANGE) / (2.0 * SD_RANGE), 0.0, 1.0)
    Image.merge("RGBA", (
        Image.fromarray(np.round(enc_t * 255).astype(np.uint8)),
        Image.fromarray(np.clip(np.round(half_tube), 0, 255).astype(np.uint8)),
        Image.fromarray(np.zeros((h, w), np.uint8)),
        Image.fromarray(np.full((h, w), 255, np.uint8)))).save(OUT_TUBE)

    # No coverage mask either. It was the last texture carrying a picture of
    # the drawing, and nothing read it -- the shell loaded it into a
    # ShaderEffectSource that was never bound to anything.

    with open(OUT_JSON, "w") as fh:
        json.dump({
            "text": "Brolli", "style": "image",
            "font": os.path.basename(args.image),
            "size": h, "width": w, "height": h,
            "ascent": h, "descent": 0.0, "top": 0.0,
            "shape": os.path.basename(OUT_SHAPE),
            "order": os.path.basename(OUT_ORDER),
            "tube": os.path.basename(OUT_TUBE),
            "ordered": True, "orderSource": "lineart",
            "sdRange": SD_RANGE,
            "paths": [],
        }, fh, indent=1)

    print(f"{w}x{h}px, sd {sd.min():.1f}..{sd.max():.1f}px, "
          f"half-thickness up to {half[solid].max():.0f}px")
    print(f"-> {OUT_SHAPE}, {OUT_ORDER}, {OUT_TUBE}")


if __name__ == "__main__":
    main()
