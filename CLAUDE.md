# CLAUDE.md — Brolli-Glass

## What this is

**Brolli-Glass** is a macOS-style desktop for Hyprland: a **BrolliOS** Quickshell
shell (menubar, dock, desktop widgets, Spotlight) plus a **Hyprland plugin** that
draws the shell's liquid glass compositor-side.

The glass is the point of the project. The shell used to capture the screen with
screencopy and refract it in QML, which cost ~16 W and needed a patched Hyprland
(`no_self_capture`). That is gone: the shell now tells the plugin where each
panel is and what the material's uniforms are, and the plugin draws it mid-frame
on **stock Hyprland**. Measured cost: ~0.1 W idle, ~1 W worst case.

A notch/Dynamic Island and a Claude-agent monitor used to live here. Both were
removed. Do not rebuild either unless asked.

---

## Layout

- **Repo:** `~/Projects/Brolli-Glass` (git, branch `master`). Commit after each
  working change.
  - `quickshell/` — the shell (config name **BrolliOS**)
  - `plugin/src/brolli-glass.cpp` — the Hyprland plugin
  - `plugin/src/brolliglass.frag` — the material, read from disk at plugin load
  - `install.sh` + `manifest.toml` + `install/` — the installer
  - `PROGRESS.md` — work log, newest first. Keep it current.
- **Runtime:** `~/.config/quickshell/BrolliOS`. On this machine it is a
  **symlink** to `quickshell/` (installed with `--link`), so edits to the repo
  hot-reload. Edit the repo, never through the symlink. A plain install
  **copies** instead, so deleting the clone cannot break someone's desktop.
- **Shell config file:** `~/.config/brollios/config.json` (separate from ii's).
- **Plugin binary:** `~/.local/share/brolli-glass/brolli-glass.so`, with the
  material beside it. Loaded from `custom/execs.lua`.

### Hard rules

1. **Never touch `~/.config/quickshell/ii/`** — the user's other, live desktop.
2. **Never modify Hyprland itself.** Plugin hooks and its public API are fine;
   patching or building Hyprland is not.
3. **Never `cp` over a loaded `.so`.** Hyprland has it mapped; the next unload
   crashes the session. Always: `hyprctl plugin unload`, then copy to a temp
   name and `mv`, then load. Each as its own step.
4. **The user is on fish.** No `<<EOF` heredocs in fish — use the file tools or
   `bash -c '...'`.
5. **Ask before destructive or outward-facing actions.**
6. **Measure, never guess.** Claims about cost, cause or behaviour need numbers
   or a source. If something cannot be verified, say so.

---

## How the glass works

```
shell (BrolliOS)                        plugin (Brolli-Glass)
  GlassRegion      -- hyprctl glassrect  -->  where each panel is
  GlassUniformBridge -- glassuniform --> the material's values (one --batch)
  GlassSample      -- hyprctl glasssample -->  regions to measure
                   <-- glasssample>>id,r,g,b   backdrop colour (adaptive text)
                   <-- glassstats>>id,busy     how busy a backdrop is
```

- The plugin hooks `renderLayer` and queues its own pass element directly under
  each surface, so glass sits under the panel it belongs to. It also handles a
  layer's **popups** (the menubar dropdowns).
- The backdrop is a `glBlitFramebuffer` out of the frame being composited.
- Which panels redraw is decided **once per frame** at `RENDER_BEGIN`.
- Useful: `hyprctl glassopt` (state, panels, draw counts), `glassopt gate off`.

## Testing

- The shell hot-reloads on save; check `qs log -c BrolliOS` for
  "Configuration Loaded" or errors.
- Restart the shell only with an exact-cmdline match (`qs -c BrolliOS`), never
  `pkill -f qs` — that kills the settings app and any session doing the killing.
- Power: paired runs, same action with and without the plugin, GPU package
  power from `/sys/class/drm/card1/device/hwmon/*/power1_average`. Hand-driven
  runs vary by ~0.4 W, so nudge a uniform in a loop for a repeatable load when
  comparing shader changes.
