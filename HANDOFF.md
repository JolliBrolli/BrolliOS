# HANDOFF — read this first

Quick orientation for a new session. Full detail lives in NOTES.md (design) and
PROGRESS.md (log) — this is just the "what's going on and why" summary.

## What this project is
A personal fork of **OpenAgentIsland** (original: github.com/patheonsceo, built on
end-4/illogical-impulse + techniques studied from Hyprfabricated). Plan: keep the
macOS-style Dynamic Island desktop shape, drop the Claude Code agent-monitor
feature, reskin it as **"Brolli-Glass"** — a liquid-glass visual direction — with
its own install script and branding. GPL-3.0 (inherited from end-4, must stay
GPL-3.0 on redistribution); credit the original author/repo in the README.

## Repo location — READ THIS
**Canonical repo root is `~/Projects/Brolli-Glass/`.** It used to live directly at
`~/.config/quickshell/Brolli-Glass/`, which was wrong: the installer's `shell`
artifact needs to *symlink* `~/.config/quickshell/Brolli-Glass` → this repo's
`quickshell/` subfolder, and with the repo sitting at that same path, running
the installer would `rmtree` the whole repo to make room for the symlink.

Fixed by moving the repo out and creating the symlink:
```
~/.config/quickshell/Brolli-Glass -> ~/Projects/Brolli-Glass/quickshell
```
That symlink now exists. **Always edit files under `~/Projects/Brolli-Glass/`,
never through the symlink.** This also fixed a standing bug: `qs -c Brolli-Glass`
previously failed outright ("Could not find config directory") because
`shell.qml` was one level too deep when `Brolli-Glass` was a real directory
instead of a symlink straight to `quickshell/`.

## What's been done
- Removed the Claude Code agent-monitor feature entirely: `bridge/`,
  `services/AgentService.qml`, the notch's agent surface/spinner, the
  standalone `agentIsland.qml` dashboard app, the "Claude Code Here" context
  menu item. Do not rebuild any of this unless explicitly asked again.
- Renamed the install identity from `openagentisland` → `Brolli-Glass`
  throughout: `manifest.toml` symlink dest, `install/blocks/hypr-qsconfig.lua`,
  `install.sh` banner/messages, `install/engine.py` inject markers and the
  backup dir (now `~/.local/share/brolli-glass-backups`). An orphaned backup
  from an earlier real install/uninstall test still sits at
  `~/.local/share/openagentisland-backups` — harmless, user's to delete.
- Live desktop currently still runs `ii` (untouched, safe). Switching it over
  to Brolli-Glass for real is a deliberate future step, not yet done.

## Known unresolved issue — do not run `install.sh` (no `--dry-run`) without this fix
`manifest.toml`'s `hypr-custom` artifact (`profile = ["full"]` only, so
`--profile island` is unaffected) does a blind `copytree` of this repo's
`config/hypr/custom/` over `~/.config/hypr/custom/`. The repo's checked-in
`general.lua` is a stale single-monitor stub (wrong refresh rate, position,
scale, and missing the user's second monitor entirely) that already caused one
real black-screen incident — recovered via `install.sh --uninstall`. Needs
either: (a) update the repo's `config/hypr/custom/` to match the user's real,
current Hyprland config, or (b) have the installer skip/never ship monitor
config since it's inherently per-machine. **Not fixed yet.**

## Dev workflow — READ THIS, corrected 2026-09-12
**We iterate directly on the live desktop. No nested Hyprland window.** The
user's live `~/.config` *is* the working "riced ii" setup this project builds
on top of — not a separate pristine thing to protect from it. Install/test
changes live with `install.sh` (use `--profile island` unless you've verified
`hypr-custom` is safe — see the unresolved issue above), reload with
`hyprctl reload`, restart the shell with
`pkill -x qs; setsid -f qs -c <name> > ~/.cache/qs-<name>.log 2>&1 </dev/null`
(don't use `hyprctl dispatch exec` on this machine — it errors on this
Hyprland/Lua-config build; use `setsid -f` directly instead), then check
`~/.cache/qs-<name>.log` for errors.

A nested harness (`dev/nested.sh` from the 2026-09-08 entry below, or the
`~/.config/hypr-nested/brolli.lua` config) still exists in the repo as an
*option* if isolation is ever wanted for something risky, but it is not the
default flow — don't assume it's how you're supposed to work here.

**Before running any install live**, be aware `~/.config/hypr` and
`~/.config/quickshell/ii` are NOT git repos — there's no diff/undo trail
beyond each installer's own `--uninstall` backup and whatever you manually
back up yourself (pattern: copy to `~/.config/hypr/.backups/<file>.pre-fix-<timestamp>`
before editing anything live). See PROGRESS.md's 2026-09-12 entry for a full
account of what got contaminated last time and how it was found/fixed —
worth reading before assuming a "differs" in `install.sh --status` means the
repo is wrong rather than the live file being leftover cruft from an earlier
session.
