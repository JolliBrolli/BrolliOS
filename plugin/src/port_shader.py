#!/usr/bin/env python3
"""Translate the project's Qt/QML .frag shaders into GLES 3.00 for the plugin.

The MATERIAL is not authored here. These shaders are Joel's, in
quickshell/modules/common/widgets/glass/, and they stay the single source of
truth -- re-run this after tuning them. Only the dialect changes:

  * `#version 440` -> `#version 300 es` + a precision qualifier
  * Qt's std140 uniform block -> individual uniforms
  * `layout(...)` in/out/binding decorations -> plain in/out/uniform
  * qt_Matrix dropped (the plugin supplies its own quad), qt_Opacity := 1.0

The shader BODY is copied verbatim. qt_TexCoord0 keeps its Qt meaning --
panel-local UV, 0..1 across the visible panel -- and the plugin's vertex
shader supplies exactly that, so toTex()/sampleBlurred() need no changes.
"""
import re, sys, pathlib

def convert(src: str) -> str:
    out, body = [], src

    # uniform block -> individual uniforms
    m = re.search(r"layout\(std140,\s*binding\s*=\s*0\)\s*uniform\s+buf\s*\{(.*?)\};", body, re.S)
    uniforms = []
    if m:
        for line in m.group(1).splitlines():
            line = line.split("//")[0].strip()
            if not line or not line.endswith(";"):
                continue
            decl = line[:-1].strip()
            parts = decl.split()
            if len(parts) < 2:
                continue
            ty, name = parts[0], parts[1]
            if name in ("qt_Matrix", "qt_Opacity"):
                continue
            uniforms.append(f"uniform {ty} {name};")
        body = body[:m.start()] + body[m.end():]

    body = re.sub(r"layout\(location\s*=\s*\d+\)\s*in\s+", "in ", body)
    body = re.sub(r"layout\(location\s*=\s*\d+\)\s*out\s+", "out ", body)
    body = re.sub(r"layout\(binding\s*=\s*\d+\)\s*uniform\s+", "uniform ", body)
    body = body.replace("#version 440", "")

    out.append("#version 300 es")
    out.append("precision highp float;")
    out.append("precision highp sampler2D;")
    out.append("")
    out.append("// qt_Opacity has no meaning outside Qt's scene graph; the plugin")
    out.append("// composites with its own blend state.")
    out.append("const float qt_Opacity = 1.0;")
    out.append("")
    out.extend(uniforms)
    out.append("")
    out.append(body.strip())
    return "\n".join(out) + "\n"

if __name__ == "__main__":
    srcdir = pathlib.Path("../../quickshell/modules/common/widgets/glass")
    for name in ("liquidglasstest.frag", "liquidglasshblur.frag"):
        text = (srcdir / name).read_text()
        dest = pathlib.Path("generated") / (name.replace(".frag", ".gles.frag"))
        dest.parent.mkdir(exist_ok=True)
        dest.write_text(convert(text))
        print(f"{name} -> {dest}  ({len(text.splitlines())} -> {len(dest.read_text().splitlines())} lines)")
