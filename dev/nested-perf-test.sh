#!/usr/bin/env bash
# Launch a nested Hyprland running the SCRATCHPAD-built patched Hyprland
# binary (not ~/.local/bin/Hyprland-brolli — the real login session's
# binary is never touched by this), with the no_self_capture layer rules
# applied, for safely iterating on self-capture perf changes without any
# risk to the real desktop.
#
# Usage: dev/nested-perf-test.sh /path/to/scratchpad/Hyprland/build/Hyprland
set -euo pipefail

BIN="${1:?usage: nested-perf-test.sh /path/to/build/Hyprland}"
if [ ! -x "$BIN" ]; then
    echo "not executable: $BIN" >&2
    exit 1
fi

WLR_BACKENDS=wayland \
WLR_NO_HARDWARE_CURSORS=1 \
HYPRLAND_INSTANCE_SIGNATURE= \
BROLLI_HYPR_PATCHED=1 \
qsConfig=Brolli-Glass \
"$BIN" --config ~/.config/hypr-nested/brolli-perf-test.lua
