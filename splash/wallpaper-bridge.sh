#!/usr/bin/env bash
#
# Put the wallpaper on screen before anything else can, then get out of the way.
#
# The gap this fills: Hyprland comes up, and for ~0.2s there is nothing to look
# at but misc:background_color -- a flat colour, because Hyprland has no
# built-in image wallpaper. The splash-lock draws over that almost immediately,
# and its glass lenses whatever is behind it, so "behind it" had better not be
# a black rectangle. The shell's own wallpaper is seconds away.
#
# ── Why IPC and not a config file ────────────────────────────────────────────
# hyprpaper 0.8.4 does not apply wallpapers from ~/.config/hyprpaper.conf. With
# a valid config, passed explicitly with -c, it starts, reads it, and logs:
#
#     Monitor eDP-1 has no target: no wp will be created
#
# ...and draws nothing. Tested with and without `preload`, with and without a
# space after the comma, with `=` spaced and unspaced, and with the documented
# all-monitors form `wallpaper = ,path`. None of them produce a layer.
#
# The same wallpaper pushed over IPC to the running instance works first time.
# So the config is skipped entirely and every monitor is set by hand.
#
# hyprpaper costs ~18MB of its own memory (the rest of its RSS is shared GL
# libraries), which is worth paying for a few seconds and not for a session --
# so it is killed the moment the shell paints its own wallpaper.
#
set -uo pipefail

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/brollios-splash/wallpaper.jpg"
SHELL_LAYER="quickshell:background"
TIMEOUT_SECONDS=30

command -v hyprpaper >/dev/null || { echo "wallpaper-bridge: hyprpaper not installed" >&2; exit 0; }
[[ -f "$CACHE" ]] || { echo "wallpaper-bridge: no cached wallpaper yet, nothing to show" >&2; exit 0; }

# Someone else's hyprpaper is not ours to manage.
if pgrep -x hyprpaper >/dev/null; then
    echo "wallpaper-bridge: hyprpaper already running, leaving it alone" >&2
    exit 0
fi

hyprpaper >/dev/null 2>&1 &
PAPER=$!

# One push per connected monitor: hyprpaper wants a name, and the
# all-monitors shorthand is part of the config path that does not work.
mapfile -t MONITORS < <(hyprctl -j monitors 2>/dev/null \
    | grep -oP '"name"\s*:\s*"\K[^"]+' || true)
(( ${#MONITORS[@]} )) || echo "wallpaper-bridge: could not list monitors" >&2

# Push until it sticks, rather than waiting a fixed time for the socket.
# `listactive` is the confirmation -- and it is also the ONLY list command this
# version accepts: `listloaded` and `status` both answer "invalid hyprpaper
# request", so probing with those just burns the timeout and then pushes late.
for _ in $(seq 1 250); do
    for m in "${MONITORS[@]}"; do
        hyprctl hyprpaper wallpaper "${m},${CACHE}" >/dev/null 2>&1
    done
    if hyprctl hyprpaper listactive 2>/dev/null | grep -qF "$CACHE"; then
        break
    fi
    sleep 0.02
done

deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
while (( $(date +%s) < deadline )); do
    if hyprctl layers 2>/dev/null | grep -q "namespace: ${SHELL_LAYER}"; then
        echo "wallpaper-bridge: shell wallpaper is up, stepping aside" >&2
        break
    fi
    sleep 0.25
done

# Kill our own child, not every hyprpaper on the system: the user may have
# started one deliberately after we did.
kill "$PAPER" 2>/dev/null
wait "$PAPER" 2>/dev/null
exit 0
