#!/usr/bin/env bash
#
# Put the wallpaper on screen before anything else can, then get out of the way.
#
# The gap this fills: Hyprland comes up, and for ~0.2s there is nothing to look
# at but misc:background_color -- a flat colour, because Hyprland has no
# built-in image wallpaper. The splash-lock draws over it almost immediately,
# but the shell's own wallpaper is seconds away, and the splash's glass lenses
# whatever is behind it.
#
# So hyprpaper shows the cached wallpaper for those first seconds and is killed
# the moment the shell paints its own. Waiting for that layer rather than
# sleeping a fixed number of seconds means it is never killed early on a slow
# boot, and never lingers on a fast one.
#
# hyprpaper costs ~18MB of its own memory (the rest of its RSS is shared GL
# libraries), which is worth paying for a few seconds and not worth paying for
# a session.
#
set -uo pipefail

SHELL_LAYER="quickshell:background"
TIMEOUT_SECONDS=30

command -v hyprpaper >/dev/null || { echo "wallpaper-bridge: hyprpaper not installed" >&2; exit 0; }

# Someone else's hyprpaper is not ours to manage.
if pgrep -x hyprpaper >/dev/null; then
    echo "wallpaper-bridge: hyprpaper already running, leaving it alone" >&2
    exit 0
fi

hyprpaper >/dev/null 2>&1 &
PAPER=$!

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
