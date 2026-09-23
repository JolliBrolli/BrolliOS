# Keybinds

_What this rice binds on top of the end-4 defaults._

The end-4 base brings its own keybinds and this rice keeps them. What follows is
what `config/hypr/custom/keybinds.lua` adds or changes.

| Keys | Action |
| --- | --- |
| `Super + Space` | Vicinae launcher (Raycast/Spotlight style) |
| `Super + E` | Yazi file manager |
| `Super + Shift + E` | Dolphin |
| `Super + Shift + S` | Region snip — reopens with your last selection drawn |
| `Enter` in snip | Accept the restored region |
| `Shift + Enter` in snip | Accept, and send it to the annotation editor |
| `Ctrl + Super + Alt + /` | Open this keybinds file |

## One thing worth knowing

**Send-window-to-workspace was fixed.** Upstream registers both a keysym bind
(`SUPER+ALT+3`) and a keycode bind (`SUPER+ALT+code:12`) for the same physical
key. On some layouts both match a single press, so the dispatcher fired twice: it
moved the active window, focus fell to the next window, and the second firing
moved that one too. The redundant keysym variants are unbound; the layout-robust
keycode binds still fire exactly once.
