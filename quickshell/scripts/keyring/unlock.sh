#!/usr/bin/env bash
#
# Unlock the existing GNOME login keyring. Password comes in through
# $UNLOCK_PASSWORD, never an argument, which would expose it in ps.
#
# ── Changed from upstream end-4, deliberately ────────────────────────────────
# The original did:
#
#     killall -q -u "$(whoami)" gnome-keyring-daemon
#     eval $(echo -n "$UNLOCK_PASSWORD" | gnome-keyring-daemon --daemonize --login | ...)
#
# --login is the flag PAM uses to SET UP a session, so part of its job is
# making sure the user ends up with a login keyring. Handed a password that
# does not open the existing one, it does not fail -- it creates a new empty
# keyring. That is silent, and it repeats: this machine accumulated
# login_1.keyring … login_5.keyring on 2026-09-13, real secrets orphaned in the
# original file. They are still in ~/.local/share/keyrings/.duplicates-backup-20260913/.
#
# The lock screen only calls this after PAM has accepted the password, so the
# password is right for the ACCOUNT -- but the keyring is encrypted with
# whatever password it was created with. Change your login password and those
# two disagree, with nothing to warn you.
#
# --unlock asks the running daemon to open the keyring that is already there. A
# password that does not fit fails and changes nothing. It also leaves the
# daemon alone, so SSH_AUTH_SOCK and GNOME_KEYRING_CONTROL stay valid for
# everything already running -- killing it invalidated them session-wide.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYRING_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/keyrings"

count_keyrings() {
    find "$KEYRING_DIR" -maxdepth 1 -name '*.keyring' 2>/dev/null | wc -l
}

# Skip if already unlocked
if "${SCRIPT_DIR}/is_unlocked.sh"; then
    exit 1
fi

# If there is no login keyring, this is not the thing that should make one:
# creating it blind, with whatever was typed, is how the duplicates started.
if [[ ! -f "$KEYRING_DIR/login.keyring" ]]; then
    echo 'No login.keyring — not creating one; set it up deliberately.' >&2
    exit 1
fi

# Prompt for password if not provided
if [[ -z "${UNLOCK_PASSWORD:-}" ]]; then
    echo -n 'Login password: ' >&2
    read -rs UNLOCK_PASSWORD || exit 1
    echo '' >&2
fi

before="$(count_keyrings)"

printf '%s' "${UNLOCK_PASSWORD}" | gnome-keyring-daemon --unlock >/dev/null 2>&1
unset UNLOCK_PASSWORD

after="$(count_keyrings)"
if (( after > before )); then
    echo "WARNING: keyring files went from ${before} to ${after}. Something created one;" >&2
    echo "         check ${KEYRING_DIR} before trusting it." >&2
fi

if "${SCRIPT_DIR}/is_unlocked.sh"; then
    exit 0
fi
echo 'Keyring still locked — password did not fit it. Nothing was changed.' >&2
exit 1
