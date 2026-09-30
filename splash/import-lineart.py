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
OUT_MASK = os.path.join(HERE, "wordmark-mask.png")
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

    # ── trim the two scallops the shaft comes down between ──────────────
    # They are not fill, they are LINE: the hem is an outline, so the tube
    # wraps it, and the two scallops beside the shaft hang below the hem with
    # the shaft dropping through the gap between them. That pair of notches is
    # the dimples, and they have to go before the tube is built, because after
    # that they are part of it.
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

    hem_full = solid[:split + 1].sum(axis=1)
    hem_y = int(np.nonzero(hem_full > hem_full.max() * 0.92)[0].max()) if hem_full.any() else split

    # The shaft, measured rather than guessed, and measured DOWN a column
    # rather than across a row.
    #
    # Across a row it cannot be told apart from the scallops that flank it,
    # and reading "the first row with two runs" as the shaft's two sides was
    # wrong twice over: the shaft is drawn as a single stroke, not an outlined
    # stick, and the row that test landed on still had the hem in it, which
    # put the answer 10px off the real shaft. A median x over the lower rows
    # is no better -- the hook curls away and drags it further still.
    #
    # Down a column, over the band where the shaft is the only thing there:
    # clear of the scallops, which dip only a few pixels past the hem, and
    # above the hook, which curls away at the bottom. Taking the whole depth
    # below the hem instead puts the hook's upstroke in the answer, and the
    # span of shaft-plus-hook is again 10px wide of the shaft.
    top, bot = hem_y + 8, hem_y + int((h - hem_y) * 0.45)
    rows = (np.arange(h)[:, None] > top) & (np.arange(h)[:, None] < bot)
    depth = (L & rows).sum(axis=0)
    tall = np.nonzero(depth > (bot - top) * 0.7)[0]
    if len(tall):
        shaft_x = int((tall.min() + tall.max()) // 2)
        shaft_half = max(4.0, (tall.max() - tall.min()) / 2.0)
    else:
        shaft_x, shaft_half = w // 2, max(6.0, stroke * 2)

    # From where the stick's own zone ends out to 6.5 shaft half-widths: past
    # the shaft's walls, and short of the next scallop along.
    #
    # The inner bound has to be exactly where `stick_zone` stops, not a
    # separate guess at it. At 1.5 half-widths it started 2.5px further out
    # than the zone reached, and the scallop line surviving in that gap grew a
    # 7px tube either side of the shaft -- a pair of tabs hanging under the
    # hem, which is the dimple in its last form.
    stick_pad = shaft_half + 4.0
    dx = np.abs(np.arange(w)[None, :] - shaft_x)
    band = (dx > stick_pad) & (dx < shaft_half * 6.5)

    # ...and only as far down as the canopy goes.
    #
    # Unbounded, this annulus reaches the bottom of the drawing -- and the
    # handle's tail turns back up through it, 60..79px out from the shaft.
    # So the trim was quietly eating the tail's returning limb and the U-bend
    # joining it, which is why the handle just stopped instead of hooking
    # round. The scallops hang a few rows under the hem; nothing below `split`
    # is canopy at all.
    below = ((np.arange(h)[:, None] > hem_y) & (np.arange(h)[:, None] <= split))
    doomed = L & band & below
    L &= ~doomed

    # Carry the hem straight across the gap, so the canopy still has an edge
    # for the flood fill to close against.
    span = dx < shaft_half * 6.5
    for d in range(-1, max(2, int(stroke) - 1)):
        yy = hem_y + d
        if 0 <= yy < h:
            L[yy] |= span[0]

    print(f"  shaft at x={shaft_x} (half {shaft_half:.0f}px), hem y={hem_y}; "
          f"trimmed {int(doomed.sum())}px of scallop beside it")
    outside, solid = flood(L)

    # ── the noodle: a tube around the drawn lines ───────────────────────
    # The lines are not meant to be drawn ON the glass, they are meant to BE
    # glass -- a rounded tube standing proud of the panels, which is what makes
    # the whole thing look like it is coming out of the screen rather than
    # printed on it.
    #
    # A tube's signed distance is exact: distance to the line, minus its
    # radius. d_line is already measured above for the stroke width.
    apex_y = int(np.nonzero(solid.any(axis=1))[0].min())
    apex_x = int(np.average(np.nonzero(solid[apex_y + 2])[0])) if solid[apex_y + 2].any() else w // 2

    # The handle is DRAWN as two parallel lines, so as line art it has an
    # inside. It should not: a handle is a stick, and a stick is one noodle.
    # Skeletonising the handle's silhouette collapses those two lines to the
    # single centreline running down it and round the hook.
    #
    # The canopy is left alone -- its lines are already single strokes, and
    # its enclosed panels are meant to stay open for the film.
    # The handle's silhouette, CLOSED before it is measured.
    #
    # The flood fill does not fill the stick: its interior escapes somewhere
    # round the hook, so below the hem all that survives in `solid` is the two
    # bare walls -- and the two walls are not even joined to each other down
    # there, the hem that joins them sitting above `split`. Measure a
    # centreline from that and you get one line per wall, which is why the
    # handle came out as two noodles 21px apart instead of one.
    #
    # A morphological closing fixes it without needing to find the leak: a
    # dilation welds anything less than 2r apart, and the matching erosion
    # gives back the original outline. The walls are 14px apart, so r = 9
    # closes the stick into a solid bar, and the hook's outline with it.
    r_close = max(4.0, shaft_half * 0.7)
    hl = L & (np.arange(h)[:, None] > hem_y)
    dil = shape_mod.edt(hl.ravel(), w, h).reshape(h, w) <= r_close
    closed = shape_mod.edt((~dil).ravel(), w, h).reshape(h, w) > r_close - 0.5
    # From the hem down, not from `split` down. The stick begins at the hem,
    # and `split` sits ~30 rows below it -- so restricting the closing to
    # `split` left that band of the stick as two bare walls, and the junction
    # kept a pair of noodles flaring out either side of where the single one
    # should be. That flare is the dimple.
    stick_top = hem_y
    handle_solid = (closed | hl) & (np.arange(h)[:, None] > stick_top)

    # Only the piece the shaft is actually in: the outer scallops dip below
    # the canopy too, and they are not part of the handle.
    seed = None
    for y in range(stick_top + 4, h):
        if handle_solid[y, shaft_x]:
            seed = y * w + shaft_x
            break
    if seed is not None:
        hs_flat = bytearray(int(v) for v in handle_solid.ravel())
        for comp in img_mod.components(hs_flat, w, h):
            if seed in set(comp):
                keep = np.zeros((h, w), dtype=bool)
                for idx in comp:
                    keep[idx // w, idx % w] = True
                handle_solid = keep
                break

    # The centreline by thinning -- now that there is something solid to thin.
    #
    # Thinning gave two parallel lines before, but that was the input's fault,
    # not the algorithm's: it was handed the stick's two bare walls and
    # faithfully thinned each one. On the closed silhouette it can only
    # produce the single line down the middle.
    #
    # A distance-transform ridge was tried in its place and is worse here: on
    # the straight shaft it is exact, but round the hook's curve the local
    # maximum test drops in and out and the noodle came apart, leaving the
    # hook as a detached blob. Thinning stays connected by construction, which
    # is what the pen-path walk downstream needs.
    skel = img_mod.skeletonise(bytearray(int(v) for v in handle_solid.ravel()), w, h)
    HS = np.zeros((h, w), dtype=bool)
    for idx in skel:
        HS[idx // w, idx % w] = True
    print(f"  handle centreline: {int(HS.sum())}px by thinning")

    # Thicken it by exactly one pixel, so the distance field has something
    # solid to measure. Reading and writing the same array while shifting it
    # compounds -- each shift grows what the next one reads, and a 1px dilation
    # turns into a dozen.
    grown = HS.copy()
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            grown |= np.roll(np.roll(HS, dy, 0), dx, 1)
    HS = grown

    # Run the shaft up to the apex.
    #
    # The handle is drawn as two lines meeting the hem, so collapsing it to a
    # centreline leaves the noodle stopping at the hem with a notch either
    # side of where those lines used to land. On a real umbrella the shaft
    # carries on up to the top, and drawing it that way closes the notches and
    # gives the ribs something to meet.
    if HS.any():
        hys, hxs = np.nonzero(HS)
        top = hys.min()
        for y in range(int(apex_y) + 2, top + 1):
            for dx in (-1, 0, 1):
                x = shaft_x + dx
                if 0 <= x < w:
                    HS[y, x] = True
        print(f"  shaft carried up from y={top} to the apex at y={apex_y}")

    # The canopy keeps every line it has -- including the outer scallops that
    # dip below the hem -- except the stick, which the handle now owns as a
    # single centreline. Without this exclusion both walls would be tubed
    # twice: once as canopy line, once as handle.
    stick_zone = ((np.arange(h)[:, None] > stick_top)
                  & (np.abs(np.arange(w)[None, :] - shaft_x) <= stick_pad))
    centreline = (L & (np.arange(h)[:, None] <= split) & ~stick_zone) | HS
    print(f"  centreline: {int(centreline.sum())}px")

    # edt() returns the distance TO the nearest True, so this is the distance
    # to the centreline. Inverting it would measure the distance to background
    # instead, which inside a 4px line is never more than 2 -- the tube then
    # swallows the entire image.
    d_centre = shape_mod.edt(centreline.ravel(), w, h).reshape(h, w)
    tube_r = args.tube + stroke * 0.5
    sd_tube = (d_centre - tube_r).astype(np.float32)
    half_tube = np.full((h, w), max(1.0, tube_r), dtype=np.float32)
    print(f"  noodle radius {tube_r:.1f}px")

    # ── what is actually covered ────────────────────────────────────────
    # The handle is DRAWN as an outlined stick, so its silhouette is the whole
    # 46px bar. Left alone, the noodle runs down the middle of it and the film
    # fills the rest -- a slab of glass sitting behind the handle, shaped like
    # the outline we were trying to get rid of.
    #
    # Below the canopy there is no "inside" to fill: the handle IS the noodle.
    # So coverage is the canopy's silhouette plus the tube, and nothing else.
    # It also means the tube's own edge becomes a real coverage edge, which is
    # what earns it the material's analytic antialiasing -- as a lighting
    # boundary it had none, which is why it looked jagged.
    rows0 = np.arange(h)[:, None]

    # The stick is excluded from the silhouette as well as from the
    # centreline. Its two drawn walls enclose a gap, and the flood fill counts
    # that gap as canopy -- which left a 6px sliver of film down either side of
    # the shaft for the rows between the hem and `split`. The scallops that
    # used to notch this junction are already gone, trimmed from the line art
    # before the tube was built; this is the last of it.
    solid = (solid & (rows0 <= split) & ~stick_zone) | (sd_tube < 0.0)

    full = solid[:split + 1].sum(axis=1)
    hem_base = int(np.nonzero(full > full.max() * 0.85)[0].max()) if full.any() else split
    print(f"  hem line at y={hem_base}")
    print(f"  coverage: canopy silhouette + noodle = {int(solid.sum())}px")

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

    handle = walk(HS)
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

    cov = np.clip(0.5 - sd, 0.0, 1.0)
    Image.merge("RGBA", (
        Image.fromarray(np.full((h, w), 255, np.uint8)),
        Image.fromarray(np.full((h, w), 255, np.uint8)),
        Image.fromarray(np.full((h, w), 255, np.uint8)),
        Image.fromarray(np.round(cov * 255).astype(np.uint8)))).save(OUT_MASK)

    with open(OUT_JSON, "w") as fh:
        json.dump({
            "text": "Brolli", "style": "image",
            "font": os.path.basename(args.image),
            "size": h, "width": w, "height": h,
            "ascent": h, "descent": 0.0, "top": 0.0,
            "mask": os.path.basename(OUT_MASK),
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
