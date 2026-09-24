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
import subprocess
import sys

from fontTools.misc.transform import Transform
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
            paths.append({"d": d, "len": round(outline_length(rec), 1)})
        x += hmtx[name][0]
    return paths, x * scale, ascent, -font["hhea"].descender * scale


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("text", nargs="?", default="BrolliOS")
    ap.add_argument("--font", default="Google Sans Flex")
    ap.add_argument("--size", type=float, default=160.0)
    args = ap.parse_args()

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
