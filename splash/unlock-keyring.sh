#!/usr/bin/env bash
#
# Unlock the EXISTING GNOME login keyring with the password the splash-lock
# just accepted. Reads it from $UNLOCK_PASSWORD, never an argument, which would
# expose it in ps.
#
# Why this is needed: pam_gnome_keyring unlocks the login keyring using the
# password you type at the display manager. With SDDM autologin there is no
# password, so the daemon comes up LOCKED and the first thing wanting a secret
# prompts you instead.
#
# ── Why this does NOT use --login ────────────────────────────────────────────
# The obvious implementation, and the one in the shell's own
# scripts/keyring/unlock.sh, is:
#
#     killall gnome-keyring-daemon
#     printf '%s' "$PASSWORD" | gnome-keyring-daemon --daemonize --login
#
# Do not do that. When --login is handed a password that does not open the
# existing keyring, gnome-keyring makes a NEW one rather than failing, and a
# few retries leave you with login_1.keyring … login_5.keyring and your real
# secrets orphaned. That happened on this machine on 2026-09-13; the wreckage
# is still in ~/.local/share/keyrings/.duplicates-backup-20260913/.
#
# --unlock unlocks the keyring that is already there, in the daemon that is
# already running. A wrong password fails and changes nothing.
#
# The file count either side is a tripwire: if a keyring file ever appears
# while this runs, it says so loudly rather than letting it accumulate quietly.
#
set -uo pipefail

KEYRING_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/keyrings"
LOGIN_KEYRING="$KEYRING_DIR/login.keyring"

count_keyrings() {
    find "$KEYRING_DIR" -maxdepth 1 -name '*.keyring' 2>/dev/null | wc -l
}

is_unlocked() {
    [[ "$(busctl --user get-property org.freedesktop.secrets \
        /org/freedesktop/secrets/collection/login \
        org.freedesktop.Secret.Collection Locked 2>/dev/null)" == "b false" ]]
}

# If there is no login keyring, this script is not the thing that should make
# one. Creating it blind, with whatever password happened to be typed, is how
# the duplicates above came to exist.
if [[ ! -f "$LOGIN_KEYRING" ]]; then
    echo "keyring: no login.keyring — not creating one; set it up deliberately" >&2
    exit 1
fi

if is_unlocked; then
    echo "keyring: already unlocked" >&2
    exit 0
fi

if [[ -z "${UNLOCK_PASSWORD:-}" ]]; then
    echo "keyring: no UNLOCK_PASSWORD in the environment, leaving it locked" >&2
    exit 1
fi

before="$(count_keyrings)"

printf '%s' "$UNLOCK_PASSWORD" | gnome-keyring-daemon --unlock >/dev/null 2>&1
unset UNLOCK_PASSWORD

after="$(count_keyrings)"
if (( after > before )); then
    echo "keyring: WARNING — keyring files went from $before to $after." >&2
    echo "keyring: something created one. Check $KEYRING_DIR before trusting it." >&2
fi

if is_unlocked; then
    echo "keyring: unlocked" >&2
else
    echo "keyring: wrong password or daemon not running; left locked, nothing changed" >&2
    exit 1
fi
