#!/usr/bin/env bash
#
# Unlock the GNOME login keyring with the password the splash-lock just
# accepted. Reads it from $UNLOCK_PASSWORD; never takes it as an argument,
# which would put it in the process list for anyone running ps.
#
# Why this is needed at all: pam_gnome_keyring unlocks the login keyring from
# the password you type at the display manager. With SDDM autologin there is no
# password, so the daemon starts LOCKED and everything that wants a secret
# prompts you later. The splash-lock has just taken a password, so it is the
# right place to hand one over.
#
# Adapted from the shell's scripts/keyring/unlock.sh (end-4 / illogical-impulse,
# itself from https://unix.stackexchange.com/a/602935). Kept as its own copy so
# the splash depends on nothing in the shell directory.
#
set -uo pipefail


is_unlocked() {
    [[ "$(busctl --user get-property org.freedesktop.secrets \
        /org/freedesktop/secrets/collection/login \
        org.freedesktop.Secret.Collection Locked 2>/dev/null)" == "b false" ]]
}

if is_unlocked; then
    echo "keyring: already unlocked" >&2
    exit 0
fi

if [[ -z "${UNLOCK_PASSWORD:-}" ]]; then
    echo "keyring: no UNLOCK_PASSWORD in the environment, leaving it locked" >&2
    exit 1
fi

# --login takes the password on stdin, but only ever at daemon start, so the
# already-running locked daemon has to go first.
killall -q -u "$(whoami)" gnome-keyring-daemon 2>/dev/null || true

printf '%s' "$UNLOCK_PASSWORD" | gnome-keyring-daemon --daemonize --login >/dev/null 2>&1
unset UNLOCK_PASSWORD

# --login leaves the daemon half-initialised waiting for this; without it the
# secrets component never registers on the bus.
gnome-keyring-daemon --start --components=secrets,ssh,pkcs11 >/dev/null 2>&1

if is_unlocked; then
    echo "keyring: unlocked" >&2
else
    echo "keyring: still locked after unlock attempt" >&2
    exit 1
fi
