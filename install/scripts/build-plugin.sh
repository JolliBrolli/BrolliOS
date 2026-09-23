#!/usr/bin/env bash
# Build the Brolli-Glass Hyprland plugin and install it to ~/brolli-glass.so.
#
# The plugin is pinned to the exact Hyprland build it is compiled against, so
# it is built here rather than shipped. custom/execs.lua loads that path at
# startup (hl.plugin.load).
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../plugin/src" && pwd)"
OUT="$HOME/brolli-glass.so"

command -v g++ >/dev/null || { echo "brolli-glass: g++ not found" >&2; exit 1; }
pkg-config --exists hyprland || { echo "brolli-glass: hyprland headers not found (install hyprland-devel/hyprland)" >&2; exit 1; }

echo "brolli-glass: building against $(pkg-config --modversion hyprland)"
# The material is read from disk at load time, so the plugin has to be told
# where to find it. Two paths are baked in: this checkout, so editing the .frag
# and reloading works; and a copy outside the repo, so the glass survives the
# clone being deleted after install.
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/brolli-glass"
mkdir -p "$DATA"
cp "$SRC/brolliglass.frag" "$DATA/brolliglass.frag"

g++ -shared -fPIC --no-gnu-unique -std=c++26 -O2 -DWLR_USE_UNSTABLE \
    -DBROLLI_SHADER_PATH="\"$SRC/brolliglass.frag\"" \
    -DBROLLI_SHADER_FALLBACK="\"$DATA/brolliglass.frag\"" \
    $(pkg-config --cflags hyprland pixman-1 libdrm) \
    "$SRC/brolli-glass.cpp" -o "$SRC/brolli-glass.so"

# Never overwrite the file in place: a running Hyprland has it mapped, and the
# next unload would crash the session. Write beside it and rename.
hyprctl plugin unload "$OUT" >/dev/null 2>&1 || true
cp "$SRC/brolli-glass.so" "$OUT.new" && mv "$OUT.new" "$OUT"
echo "brolli-glass: installed $OUT"
echo "brolli-glass: load it now with: hyprctl plugin load $OUT"
