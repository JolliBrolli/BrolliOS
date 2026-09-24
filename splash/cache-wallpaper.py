#!/usr/bin/env python3
"""
Keep a screen-sized copy of the current wallpaper for the splash-lock.

The splash draws before the shell exists, so the wallpaper has to be on screen
almost immediately -- the glass lenses whatever is behind it, and behind it for
the first second was a black rectangle.

The wallpaper on this machine is 6016x6016: 36 megapixels for a 2880x1800
screen. Measured, decoding it takes ~340ms even with libjpeg's scaled path, and
Qt took 900ms to first frame. A pre-scaled copy decodes in 27ms.

Run with no arguments. It is idempotent: if the cache already matches the
current wallpaper it does nothing, so the splash can fire it on every start.

  ~/.cache/brollios-splash/wallpaper.jpg   the scaled copy
  ~/.cache/brollios-splash/stamp.json      which file it came from, and when

Nothing here writes a hyprpaper config: hyprpaper 0.8.4 does not apply
wallpapers from one (see splash/wallpaper-bridge.sh, which pushes over IPC
instead).
"""
import json
import os
import subprocess
import sys

CACHE_DIR = os.path.join(
    os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")),
    "brollios-splash")
CACHE_IMG = os.path.join(CACHE_DIR, "wallpaper.jpg")
STAMP = os.path.join(CACHE_DIR, "stamp.json")

STATE = os.path.join(
    os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
    "quickshell/user/generated/wallpaper/path.txt")


def current_wallpaper():
    try:
        with open(STATE) as fh:
            path = fh.read().strip()
    except OSError:
        return None
    return path if path and os.path.isfile(path) else None


def monitors():
    """Connected monitors as (name, width, height), or [] if Hyprland is not up."""
    try:
        out = subprocess.run(["hyprctl", "-j", "monitors"],
                             capture_output=True, text=True, timeout=5).stdout
        return [(m["name"], m["width"], m["height"]) for m in json.loads(out)]
    except Exception:
        return []


def screen_size():
    """Longest edge of the largest monitor, or a sane default.

    A square wallpaper cropped to cover needs the LONGER screen edge; scaling
    to the shorter one comes back soft.
    """
    mons = monitors()
    if not mons:
        return 2880
    return max(max(w, h) for _, w, h in mons)


def main():
    src = current_wallpaper()
    if not src:
        print("cache-wallpaper: no current wallpaper, nothing to do")
        return 0

    target = screen_size()
    st = os.stat(src)
    want = {"src": src, "mtime": int(st.st_mtime), "size": target}

    if os.path.exists(CACHE_IMG) and os.path.exists(STAMP):
        try:
            with open(STAMP) as fh:
                if json.load(fh) == want:
                    print("cache-wallpaper: already current")
                    return 0
        except (OSError, ValueError):
            pass

    try:
        from PIL import Image
    except ImportError:
        print("cache-wallpaper: Pillow not installed; the splash will read the "
              "full-size wallpaper and be slower", file=sys.stderr)
        return 1

    os.makedirs(CACHE_DIR, exist_ok=True)
    im = Image.open(src)
    # draft() lets libjpeg decode at 1/2, 1/4 or 1/8 scale directly, which is
    # most of the saving; thumbnail() then lands it exactly.
    im.draft("RGB", (target, target))
    im = im.convert("RGB")
    im.thumbnail((target, target), Image.LANCZOS)

    tmp = CACHE_IMG + ".new"
    im.save(tmp, "JPEG", quality=88, optimize=True)
    os.replace(tmp, CACHE_IMG)      # never a half-written file for the splash

    with open(STAMP, "w") as fh:
        json.dump(want, fh)

    print(f"cache-wallpaper: {os.path.basename(src)} {Image.open(src).size} -> "
          f"{im.size}, {os.path.getsize(CACHE_IMG) // 1024}KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
