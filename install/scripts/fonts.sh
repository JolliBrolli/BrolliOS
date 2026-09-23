#!/usr/bin/env bash
#
# Fonts. This repo ships none of them, because none of them may be
# redistributed:
#
#   Google Sans Flex   Google's. Already installed by the end-4 base, which
#                      this rice requires anyway — nothing to do here.
#   SF Pro Display     Apple's. AUR: otf-san-francisco
#   Liga SF Mono NF    Apple's SF Mono, Nerd-Font-patched.
#                      AUR: nerd-fonts-sf-mono-ligatures
#   PP Editorial New   Pangram Pangram, commercial. Free for personal use from
#                      the foundry; there is no package. Used only as the
#                      serif face, so the desktop is fine without it.
#
# Drop your own copies in assets/fonts-local/ and they are installed as-is.
# That directory is gitignored, which is the point: keep the files locally,
# never in the repo.
#
# Nothing here is fatal. A missing font falls back through fontconfig; the
# desktop still runs.
set -uo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL_DIR="$REPO_DIR/assets/fonts-local"
FONT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/fonts/brolli-glass"

changed=0

have_family() { fc-list : family 2>/dev/null | grep -qiF -- "$1"; }

aur_helper() {
    for h in yay paru; do command -v "$h" >/dev/null 2>&1 && { echo "$h"; return; }; done
}

# Install one AUR package, but only if the family it provides is missing.
want_aur() {
    local family="$1" pkg="$2" helper
    if have_family "$family"; then
        echo "fonts: $family — already installed"
        return
    fi
    helper="$(aur_helper)"
    if [[ -z "$helper" ]]; then
        echo "fonts: $family is missing; no AUR helper found."
        echo "fonts:   install it with:  yay -S $pkg"
        return
    fi
    echo "fonts: installing $pkg ($family) with $helper"
    if "$helper" -S --needed --noconfirm "$pkg"; then
        changed=1
    else
        echo "fonts: $pkg failed to install — carry on without it, or run: $helper -S $pkg"
    fi
}

# ── your own copies, if you have any ──────────────────────────────────
if [[ -d "$LOCAL_DIR" ]] && find "$LOCAL_DIR" -type f \( -iname '*.otf' -o -iname '*.ttf' \) -print -quit | grep -q .; then
    echo "fonts: installing your local copies from assets/fonts-local/"
    mkdir -p "$FONT_DIR"
    cp -r -- "$LOCAL_DIR"/. "$FONT_DIR"/
    changed=1
fi

# ── the packaged ones ─────────────────────────────────────────────────
want_aur "SF Pro Display"            otf-san-francisco
want_aur "LigaSFMono Nerd Font"      nerd-fonts-sf-mono-ligatures

# ── the ones nobody packages ──────────────────────────────────────────
have_family "Google Sans Flex" \
    || echo "fonts: Google Sans Flex missing — it comes with the end-4 base; run that installer."
have_family "PP Editorial New" \
    || echo "fonts: PP Editorial New missing (serif only) — free for personal use at pangrampangram.com"

(( changed )) && fc-cache -f >/dev/null 2>&1

echo "fonts: done"
