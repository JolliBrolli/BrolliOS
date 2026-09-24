#!/usr/bin/env bash
#
# Unlock the EXISTING GNOME login keyring with the password the splash-lock
# just accepted. Reads it from $UNLOCK_PASSWORD, never an argument, which would
# expose it in ps.
#
# Why this is needed: pam_gnome_keyring unlocks the login keyring using the
# password you type at the display manager. With SDDM autologin there is no
# password, so PAM only auto_starts the daemon -- it comes up LOCKED, and the
# first thing wanting a secret prompts you instead.
#
# ── What works here, and what does not ───────────────────────────────────────
# Measured on this machine, all with a deliberately wrong password so the file
# count could be checked afterwards:
#
#   gnome-keyring-daemon --unlock                  forks a SECOND daemon, exits
#                                                  0, prints nothing, changes
#                                                  nothing. PAM's daemon keeps
#                                                  org.freedesktop.secrets, so
#                                                  the password reaches nobody.
#   ...--replace --unlock                          same: owner never changes.
#   kill the daemon, then --daemonize --unlock     becomes the owner. Works.
#
# So the running daemon has to go first. That is also what the shell's own
# scripts/keyring/unlock.sh does -- the difference is the flag it restarts
# with. This uses --unlock, NOT --login:
#
#   --login is the flag PAM uses to SET UP a session, so part of its job is
#   making sure the user ends up with a login keyring. Handed a password that
#   does not open the existing one it creates a new empty keyring rather than
#   failing, silently and repeatedly: this machine collected login_1.keyring
#   through login_5.keyring on 2026-09-13, still in
#   ~/.local/share/keyrings/.duplicates-backup-20260913/.
#
#   --unlock just fails. Verified: a wrong password left the file count at 1.
#
# The count either side is kept as a tripwire anyway.
#
set -uo pipefail

KEYRING_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/keyrings"
LOGIN_KEYRING="$KEYRING_DIR/login.keyring"
COMPONENTS="secrets,ssh,pkcs11"

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

# pkill -x will not match: the process name truncates to 15 characters
# ("gnome-keyring-d") and pkill warns and matches nothing.
for pid in $(pgrep gnome-keyring 2>/dev/null); do
    kill "$pid" 2>/dev/null
done
for _ in $(seq 1 20); do
    pgrep gnome-keyring >/dev/null 2>&1 || break
    sleep 0.05
done

# Newline-terminated: it reads a line, not a stream.
printf '%s\n' "$UNLOCK_PASSWORD" | gnome-keyring-daemon \
    --daemonize --unlock --components="$COMPONENTS" >/dev/null 2>&1
unset UNLOCK_PASSWORD

# It daemonizes before the collection is on the bus, so give it a moment.
for _ in $(seq 1 40); do
    is_unlocked && break
    sleep 0.05
done

after="$(count_keyrings)"
if (( after > before )); then
    echo "keyring: WARNING — keyring files went from ${before} to ${after}." >&2
    echo "keyring: something created one. Check ${KEYRING_DIR} before trusting it." >&2
fi

if is_unlocked; then
    echo "keyring: unlocked" >&2
else
    echo "keyring: still locked — the password did not fit the keyring" >&2
    exit 1
fi
