#!/usr/bin/env bash
#
# Unlock the GNOME login keyring with the password the splash-lock just
# accepted. Reads it from $UNLOCK_PASSWORD, never an argument, which would
# expose it in ps.
#
# Why this is needed: pam_gnome_keyring unlocks the login keyring using the
# password you type at the display manager. With SDDM autologin there is no
# password, so PAM only auto_starts the daemon -- it comes up LOCKED, and the
# first thing wanting a secret prompts you instead.
#
# ── Why --login, and not --unlock ────────────────────────────────────────────
# --unlock looks like the right flag and is not. Measured here:
#
#   --unlock                     forks a SECOND daemon, exits 0, prints
#                                nothing, changes nothing. PAM's daemon keeps
#                                org.freedesktop.secrets.
#   --replace --unlock           owner never changes. Same nothing.
#   kill first, --daemonize      becomes the owner, and STILL does not unlock:
#     --unlock                   verified with the real password, pw_len and
#                                stdin confirmed correct in the log.
#
# --login is what actually works, and is what the shell's own
# scripts/keyring/unlock.sh has always used.
#
# The catch, which is real: handed a password that does not open the existing
# keyring, --login does not fail -- it creates a new empty one. Silently, and
# again on every retry. That is where login_1.keyring through login_5.keyring
# came from on 2026-09-13; they are still in
# ~/.local/share/keyrings/.duplicates-backup-20260913/.
#
# So the check stays, as a tripwire rather than a veto: any keyring that
# appears while this runs is moved aside immediately, named for when it
# happened, and reported. Nothing is deleted, and login.keyring is never
# touched.
#
set -uo pipefail

KEYRING_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/keyrings"
LOGIN_KEYRING="$KEYRING_DIR/login.keyring"
COMPONENTS="secrets,ssh,pkcs11"
LOG="${XDG_CACHE_HOME:-$HOME/.cache}/brollios-splash/keyring.log"

mkdir -p "$(dirname "$LOG")" 2>/dev/null
# Diagnostics only. The password's LENGTH, never the password.
note() { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG"; }

list_keyrings() {
    find "$KEYRING_DIR" -maxdepth 1 -name '*.keyring' -printf '%f\n' 2>/dev/null | sort
}

is_unlocked() {
    [[ "$(busctl --user get-property org.freedesktop.secrets \
        /org/freedesktop/secrets/collection/login \
        org.freedesktop.Secret.Collection Locked 2>/dev/null)" == "b false" ]]
}

# If there is no login keyring, this script is not the thing that should make
# one -- and with --login it certainly would.
if [[ ! -f "$LOGIN_KEYRING" ]]; then
    note "--- run: no login.keyring, refusing"
    echo "keyring: no login.keyring — not creating one; set it up deliberately" >&2
    exit 1
fi

if is_unlocked; then
    note "--- run: already unlocked, nothing to do"
    echo "keyring: already unlocked" >&2
    exit 0
fi

if [[ -z "${UNLOCK_PASSWORD:-}" ]]; then
    note "--- run: NO PASSWORD in the environment"
    echo "keyring: no UNLOCK_PASSWORD in the environment, leaving it locked" >&2
    exit 1
fi

note "--- run: pw_len=${#UNLOCK_PASSWORD}"
BEFORE="$(list_keyrings)"

# pkill -x will not match: the process name truncates to 15 characters
# ("gnome-keyring-d"), so pkill warns and matches nothing.
for pid in $(pgrep gnome-keyring 2>/dev/null); do
    kill "$pid" 2>/dev/null
done
for _ in $(seq 1 20); do
    pgrep gnome-keyring >/dev/null 2>&1 || break
    sleep 0.05
done

# No trailing newline: this is what the shell's version sends, and it is the
# form known to work here.
ENV_OUT="$(printf '%s' "$UNLOCK_PASSWORD" | gnome-keyring-daemon --daemonize --login 2>/dev/null)"
unset UNLOCK_PASSWORD

# --login leaves the daemon waiting; --start finishes bringing the components
# up so the secrets service actually lands on the bus.
gnome-keyring-daemon --start --components="$COMPONENTS" >/dev/null 2>&1

# The daemon prints GNOME_KEYRING_CONTROL and SSH_AUTH_SOCK on stdout. The
# shell's version evals them into a subshell that exits immediately, so they
# reach nothing. Push them somewhere the rest of the session can see instead.
if [[ -n "$ENV_OUT" ]]; then
    while IFS= read -r line; do
        [[ "$line" =~ ^[A-Z_]+=.*$ ]] || continue
        systemctl --user set-environment "$line" 2>/dev/null
        dbus-update-activation-environment --systemd "${line%%=*}" 2>/dev/null
    done <<< "$ENV_OUT"
fi

for _ in $(seq 1 40); do
    is_unlocked && break
    sleep 0.05
done

# Tripwire: anything that appeared is moved aside, never deleted.
AFTER="$(list_keyrings)"
NEW="$(comm -13 <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"
if [[ -n "$NEW" ]]; then
    QUARANTINE="$KEYRING_DIR/.brolli-orphaned-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$QUARANTINE"
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        mv "$KEYRING_DIR/$f" "$QUARANTINE/" 2>/dev/null
        note "    QUARANTINED new keyring: $f"
        echo "keyring: WARNING — '$f' was created; moved to $QUARANTINE" >&2
    done <<< "$NEW"
    echo "keyring: that means the password does not open your existing keyring." >&2
fi

if is_unlocked; then
    note "    RESULT: unlocked"
    echo "keyring: unlocked" >&2
else
    note "    RESULT: still locked"
    echo "keyring: still locked" >&2
    exit 1
fi
