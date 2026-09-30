#!/usr/bin/env python3
"""
Turn a word into SVG path data for the splash animation.

The paths are GENERATED, never committed: they are glyph outlines, and the
fonts this reads (Google Sans Flex, SF Pro) are proprietary. Shipping the
generator and running it against whatever is installed keeps the repo clean.

Run: python3 splash/generate-wordmark.py [text] [--font NAME] [--size PX]
Writes splash/wordmark.json, which splash.qml reads at startup.
"""
import argparse
import json
import math
import os
import re
import subprocess
import sys

from fontTools.misc.transform import Transform
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont


def outline_length(recording):
    """Approximate perimeter, for the stroke-draw animation.

    The control polygon of a curve is never shorter than the curve, so this
    over-estimates a little. That is the safe direction: the dash offset runs
    slightly past the end rather than stopping short of it.
    """
    total, cur, start = 0.0, (0.0, 0.0), (0.0, 0.0)
    for op, args in recording.value:
        if op == "moveTo":
            cur = start = args[0]
        elif op in ("lineTo", "qCurveTo", "curveTo"):
            for pt in args:
                if pt is None:
                    continue
                total += math.dist(cur, pt)
                cur = pt
        elif op == "closePath":
            total += math.dist(cur, start)
            cur = start
    return total


# ── single-stroke (handwriting) ──────────────────────────────────────────────
# A font gives OUTLINES. Apple's "hello" is not an outline -- it is one
# continuous pen stroke, trimmed on and stroked with a round cap. You cannot
# get that from a normal font: the centreline of a glyph is a hard geometric
# problem, not something the file contains.
#
# The Hershey fonts do contain centrelines. They were drawn at the US National
# Bureau of Standards for pen plotters, they are public domain, and scriptc is
# a cursive hand. splash/hershey/*.jhf are those files, unmodified.

def parse_jhf(path):
    """Hershey .jhf -> {codepoint: (left, right, [stroke, ...])}.

    Each line is one glyph: 5 chars of number, 3 of vertex count, then pairs of
    coordinates stored as characters offset from 'R'. A literal " R" pair means
    pen up, which is what separates one stroke from the next.
    """
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
    return glyphs


def script_paths(text, jhf, size):
    """One continuous SVG path for the whole word, plus its length.

    Every stroke is appended to a single path with a moveTo between, so a dash
    animation walks the whole word in writing order -- pen lifts included --
    exactly like trim() over one Shape.
    """
    glyphs = parse_jhf(jhf)
    scale = size / 32.0          # Hershey units are ~32 tall for caps
    parts, length, x = [], 0.0, 0.0
    prev = None

    for ch in text:
        entry = glyphs.get(ord(ch))
        if entry is None:
            sys.exit(f"{ch!r} is not in {os.path.basename(jhf)}")
        left, right, strokes = entry
        for stroke in strokes:
            pts = [((px - left) * scale + x, py * scale) for px, py in stroke]
            if not pts:
                continue
            parts.append("M %.2f %.2f" % pts[0])
            if prev is not None:
                length += math.dist(prev, pts[0]) * 0.0   # pen-up costs nothing
            for a, b in zip(pts, pts[1:]):
                parts.append("L %.2f %.2f" % b)
                length += math.dist(a, b)
            prev = pts[-1]
        x += (right - left) * scale
    return " ".join(parts), length, x


def find_font(family):
    """Ask fontconfig for the file backing a family name."""
    out = subprocess.run(["fc-match", "-f", "%{file}", family],
                         capture_output=True, text=True).stdout.strip()
    if not out:
        sys.exit(f"no font file for {family!r}")
    return out


def outlines(font_path, text, size):
    font = TTFont(font_path, fontNumber=0)
    upem = font["head"].unitsPerEm
    scale = size / upem
    cmap = font.getBestCmap()
    glyphs = font.getGlyphSet()
    hmtx = font["hmtx"]

    ascent = font["hhea"].ascender * scale
    paths, x = [], 0.0
    for ch in text:
        name = cmap.get(ord(ch))
        if name is None:
            sys.exit(f"{ch!r} is not in this font")

        # Font space is Y-up from the baseline; QML is Y-down from the top.
        # Bake scale and flip in here so the QML side draws the numbers as-is.
        xform = Transform(scale, 0, 0, -scale, x * scale, ascent)

        svg = SVGPathPen(glyphs)
        glyphs[name].draw(TransformPen(svg, xform))
        d = svg.getCommands()

        if d:
            rec = RecordingPen()
            glyphs[name].draw(TransformPen(rec, xform))

            # Real bounds, not control bounds: each glyph gets its own glass
            # panel, and a box that overshoots the ink shows as a halo.
            bounds = BoundsPen(glyphs)
            glyphs[name].draw(TransformPen(bounds, xform))
            x0, y0, x1, y1 = bounds.bounds or (0, 0, 0, 0)

            paths.append({
                "d": d,
                "len": round(outline_length(rec), 1),
                "box": [round(x0, 1), round(y0, 1),
                        round(x1 - x0, 1), round(y1 - y0, 1)],
            })
        x += hmtx[name][0]
    return paths, x * scale, ascent, -font["hhea"].descender * scale


def here_dir():
    return os.path.dirname(os.path.abspath(__file__))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("text", nargs="?", default="BrolliOS")
    ap.add_argument("--font", default="Google Sans Flex")
    ap.add_argument("--size", type=float, default=160.0)
    ap.add_argument("--style", choices=["outline", "script"], default="outline",
                    help="outline: glyph outlines from --font. "
                         "script: one continuous pen stroke (Hershey), which is "
                         "what the drawn-on handwriting needs.")
    ap.add_argument("--hershey", default="scriptc",
                    help="scriptc (cursive), scripts (lighter), futural (sans)")
    args = ap.parse_args()

    if args.style == "script":
        jhf = os.path.join(here_dir(), "hershey", args.hershey + ".jhf")
        d, length, width = script_paths(args.text, jhf, args.size)
        ys = [float(v) for v in re.findall(r"[ML] [-\d.]+ ([-\d.]+)", d)]
        top, bottom = (min(ys), max(ys)) if ys else (0.0, 0.0)
        out = os.path.join(here_dir(), "wordmark.json")
        with open(out, "w") as fh:
            json.dump({
                "text": args.text, "style": "script",
                "font": os.path.basename(jhf), "size": args.size,
                "width": width, "ascent": -top, "descent": bottom,
                "top": top,
                "paths": [{"d": d, "len": round(length, 1),
                           "box": [0, top, width, bottom - top]}],
            }, fh, indent=1)
        print(f"{args.text!r} in {os.path.basename(jhf)}: one continuous stroke, "
              f"{length:.0f}px long, {width:.0f}x{bottom - top:.0f}px -> {out}")
        return

    path = find_font(args.font)
    paths, width, ascent, descent = outlines(path, args.text, args.size)

    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, "wordmark.json")
    with open(out, "w") as fh:
        json.dump({
            "text": args.text,
            "font": os.path.basename(path),
            "size": args.size,
            "width": width,
            "ascent": ascent,
            "descent": descent,
            "paths": paths,
        }, fh, indent=1)
    print(f"{args.text!r} from {os.path.basename(path)}: "
          f"{len(paths)} glyph path(s), {width:.0f}x{ascent + descent:.0f}px -> {out}")


if __name__ == "__main__":
    main()
