#!/usr/bin/env bash
#
# Build the shadow XDG_CONFIG_HOME that Nautilus runs against.
#
# GTK4 reads its user CSS from $XDG_CONFIG_HOME/gtk-4.0/gtk.css, and that user
# CSS beats GTK_THEME. So there is no way to theme one GTK4 app differently
# from the rest without giving it its own config home.
#
# The directory is therefore mostly passthrough: every entry in ~/.config is
# symlinked through, so Nautilus still sees the real dconf, mimeapps, bookmarks
# and everything else. Only gtk-4.0 is ours.
#
# The links are generated here rather than shipped, because a shipped link
# would carry the absolute path of the machine it was made on.
#
set -euo pipefail

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
SHADOW="$CONFIG/nautilus-glass"

[[ -d "$SHADOW" ]] || { echo "nautilus-glass: $SHADOW missing, skipping" >&2; exit 0; }

# The override imports the matugen-generated GTK4 theme so Material You colors
# keep tracking the wallpaper. GTK4 CSS has no ~ or variable expansion, so that
# import must be an absolute path -- which means it cannot be shipped, for the
# same reason the symlinks below cannot. Point it at this machine.
CSS="$SHADOW/gtk-4.0/gtk.css"
if [[ -f "$CSS" ]]; then
    sed -i -E "s|@import url\(\"file://[^\"]*/gtk-4\.0/gtk\.css\"\);|@import url(\"file://$CONFIG/gtk-4.0/gtk.css\");|" "$CSS"
    echo "nautilus-glass: theme import -> $CONFIG/gtk-4.0/gtk.css"
fi

linked=0
for entry in "$CONFIG"/*; do
    name="$(basename "$entry")"
    # Never link the shadow into itself, and never shadow our own override.
    [[ "$name" == "nautilus-glass" || "$name" == "gtk-4.0" ]] && continue
    target="$SHADOW/$name"
    [[ -e "$target" || -L "$target" ]] && continue
    ln -s "$entry" "$target"
    linked=$((linked + 1))
done
echo "nautilus-glass: linked $linked passthrough entries"
