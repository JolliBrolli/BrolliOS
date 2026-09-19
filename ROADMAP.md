# ROADMAP — Island Expansion

Scope: build out the full Dynamic-Island feature set seen in the Hyprfabricated
reference video. These are lettered phases **A–H**.

**Order rule:** finish + user-verify + commit each phase in the nested window
before the next.

Reference technique notes live in NOTES.md §3 (added with this roadmap). Pill bg
is now pure pitch black (`IslandStyle.pillColor = #000000`).

---

## Core architecture decision — the notch as a SURFACE HOST

Today the notch has 3 states: `idle`, `expanded` (transient OSDs: volume /
brightness / notification / media), `open` (empty 480×300 box).

The reference's expanded island is really a **named-surface stack**
(`notch.stack` + `open_notch(name)` / `close_notch()`). We mirror this:

- New shared singleton **`Island`** (`modules/ii/island/Island.qml`, `pragma Singleton`):
  - `property string openSurface: ""`  — `""` = closed; else one of
    `dashboard | power | tools | launcher | overview`.
  - `function open(name)` / `function close()` / `function toggle(name)`.
  - Lets pills in IslandLeft / IslandRight (separate PanelWindows) command the
    centre notch.
- Notch `islandState` becomes: `open` when `Island.openSurface !== ""`, else
  `expanded` when a transient source is active, else `idle`.
- In the `open` state the notch renders a `Loader` whose `sourceComponent`
  switches on `Island.openSurface`. Each surface is its own `.qml` file under
  `modules/ii/island/surfaces/`.
- **Per-surface target size** (starting guesses, tune in nested window):
  | surface   | w    | h   | notes |
  |-----------|------|-----|-------|
  | dashboard | 1000 | 290 | tabs: Widgets / Kanban / Coming soon |
  | overview  | 1100 | 300 | 5×2 workspace grid |
  | launcher  | 560  | 380 | search + scrollable results |
  | power     | 320  | 92  | 5 horizontal action buttons |
  | tools     | 440  | 84  | capture/record buttons |
- Keep the existing goey morph (`goeyCurve`, constant 18px bottom radius,
  shoulders). Open/close is animated by the same `Behavior on width/height`.
- Close on: click outside / Esc / re-click the trigger / action taken.
- Transient OSDs (volume etc.) keep working; precedence: an explicit
  `openSurface` outranks transient sources (matches CLAUDE precedence intent).

Left island final layout (5 pills, left→right): **search · workspaces(live, done)
· weather · workspace-overview · network**. (Open Q: keep the compact active-window
title? Reference left side shows none — see Phase H.)

Right island gains two trigger pills: **capture (pencil)** and the existing
**power** pill now opens the in-notch power surface (instead of `sessionOpen`).

---

## PHASE A — Open-state surface host + dashboard tab shell
Goal: clicking the notch opens a tabbed dashboard shell (empty panes); side pills
can open named surfaces. No real content yet — prove the architecture + morph.

- [ ] A1. Create `Island` singleton (openSurface + open/close/toggle).
- [ ] A2. Wire notch: `clickedOpen` → `Island.open("dashboard")`; `islandState`
      reads `Island.openSurface`; click-outside / Esc → `Island.close()`.
- [ ] A3. Refactor open state into a `Loader` surface host; per-surface target
      sizes (table above); keep goey morph + shoulders + constant radius.
- [ ] A4. `DashboardSurface.qml`: tab bar **Widgets | Kanban | Coming soon**
      (skip Pins, skip Wallpapers). Centered pill-style switcher like reference.
- [ ] A5. Tab switching: mouse + keyboard (Ctrl+Tab / Ctrl+Shift+Tab), slide
      transition between panes. Panes are empty placeholders for now.
- [ ] A6. `ComingSoonSurface`/tab = simple centered placeholder.
- [ ] A7. Verify: click notch → wide dashboard morphs open, tabs switch, Esc
      closes. Commit.

## PHASE B — Widgets tab content
Goal: fill the Widgets tab to match the reference composition.

- [ ] B1. Quick-toggle pills row: Wi-Fi, Bluetooth, Night Mode, Caffeine.
      Wi-Fi/BT via `Network` / `BluetoothStatus`; Night Mode = toggle
      `hyprsunset -t 4500` / `pkill hyprsunset` (pgrep for state); Caffeine =
      systemd-inhibit / `pkill` wakelock (pgrep for state). Each: icon + label +
      sub-state, themed, hover.
- [ ] B2. Speaker + Mic volume sliders (`Audio.sink` + `Audio.source`),
      live two-way.
- [ ] B3. Media player card — vinyl/record look: album art (reuse cover-art
      cache + downloader already in IslandNotch), title/artist, transport
      (prev/play-pause/next), progress + time. `MprisController.activePlayer`.
- [ ] B4. Calendar — month grid, current day highlighted, prev/next month.
      `DateTime` + `Qt.locale()`.
- [ ] B5. Notification center — list of `Notifications` history, clear-all,
      empty state (bell). Reuse end-4 notification widgets if usable.
- [ ] B6. System mode selector — normal / power-saver / performance via
      `powerprofilesctl get`/`set` (+ `list` for availability); 3-segment toggle.
- [ ] B7. Live stats bar charts (bottom-right): CPU / RAM / (swap/disk) vertical
      bars, live from `ResourceUsage`.
- [ ] B8. Compose Widgets layout to match reference (media left, calendar +
      notifications center, toggles + sliders top, stats bottom-right). Verify +
      commit.

## PHASE C — Kanban tab
Goal: a usable 3-column kanban with persistence.

- [ ] C1. JSON persistence model at `~/.local/share/openagentisland/kanban.json`
      (Quickshell `FileView`/`Io`). Load on start, save on change.
- [ ] C2. Three columns: To Do / In Progress / Done; card list per column.
- [ ] C3. Add card (+), inline edit (double-click → editor, Enter save / Esc
      cancel), delete card.
- [ ] C4. Drag-drop cards between columns; persist new column. Verify + commit.

## PHASE D — Power menu surface  (USECASE 1)
Goal: power pill opens in-notch power actions, mouse + keyboard.

- [ ] D1. Right-island power pill → `Island.open("power")` (replaces direct
      `GlobalStates.sessionOpen`).
- [ ] D2. `PowerSurface.qml`: 5 actions — Lock / Night-mode / Logout / Reboot /
      Poweroff — icon buttons, highlighted selection, reference layout.
- [ ] D3. Commands: Lock `loginctl lock-session`; Logout
      `loginctl terminate-user "$USER"` (or hyprctl dispatch exit); Reboot
      `systemctl reboot`; Poweroff `systemctl poweroff`; Night-mode = same
      hyprsunset toggle as B1.
      **SAFETY: these hit the REAL machine even from the nested window — wire
      them, but during testing only verify visuals + Lock; never click
      Logout/Reboot/Poweroff while developing.**
- [ ] D4. Keyboard nav: ←/→ move selection, Enter activate, Esc close; mouse
      hover/click too. Verify visuals + commit.

## PHASE E — Screen-capture toolbar  (USECASE 2)
Goal: pencil pill opens capture/record tools in the notch.

- [ ] E1. Right-island capture (pencil) pill → `Island.open("tools")`.
- [ ] E2. `ToolsSurface.qml`: buttons — region screenshot, fullscreen
      screenshot, window screenshot, screen-record toggle, (color picker
      optional). Icons per reference.
- [ ] E3. Commands (prefer tools already on system; detect): screenshots via
      `grim`+`slurp` (region: `grim -g "$(slurp)"`; full: `grim`; copy via
      `wl-copy`) or `hyprshot` if present. Record toggle via `wf-recorder` /
      `gpu-screen-recorder`; running state via `pgrep`; stop via SIGINT.
      Save to `~/Pictures/Screenshots` / `~/Videos/Recordings`.
- [ ] E4. Record state reflected in icon. Verify region screenshot in nested
      window + commit.

## PHASE F — App / settings launcher  (USECASE 4)
Goal: search pill opens fuzzy app+settings launcher with scrollable results.

- [ ] F1. Left-island search pill → `Island.open("launcher")`.
- [ ] F2. `LauncherSurface.qml`: search field (autofocus) + scrollable results
      (icon + name + comment), scrollbar. Enumerate via Quickshell
      `DesktopEntries` (apps AND system settings `.desktop`s). Fuzzy/substring
      filter on name+comment+generic.
- [ ] F3. Launch on Enter/click (`entry.execute()` / `app2unit` / hyprctl exec);
      keyboard nav ↑/↓, Enter launch, Esc close, auto-scroll to selection.
- [ ] F4. Verify launching an app + searching a setting; scrollbar works. Commit.

## PHASE G — Workspace overview  (USECASE 4)
Goal: workspace-overview pill opens a live WS 1–10 grid with drag-drop.

- [ ] G1. Left-island overview pill → `Island.open("overview")`.
- [ ] G2. `OverviewSurface.qml`: 5×2 grid of Workspace 1–10. Query Hyprland via
      Quickshell `Hyprland` service (`workspaces`, `toplevels`/clients). Per
      window: app icon (resolve from class via `DesktopEntries`), positioned in
      its workspace cell. Active workspace highlighted.
- [ ] G3. Click window → focus (`Hyprland.dispatch("focuswindow address:..")`);
      right-click → close (`closewindow address:..`); click empty WS → switch.
- [ ] G4. Drag-drop a window icon onto another WS cell →
      `movetoworkspacesilent N,address:..`; live-refresh on Hyprland events
      (openwindow/closewindow/movewindow). Verify drag a window across in nested
      + commit.

## PHASE H — Weather + network pills, final left/right assembly, polish
Goal: complete the side islands and polish all surfaces.

- [ ] H1. Weather pill (left): `curl wttr.in/?format=%c+%t&m` (m = metric/°C),
      IP-geolocated by wttr.in; 10-min refresh `Timer`; emoji + temp; hide on
      failure. (Use `Process`; cache last good value.)
- [ ] H2. Network pill (left): read `/proc/net/dev` (sum non-lo ifaces) every
      1 s; show status icon; hover (IslandPopup / revealer) → live ↑/↓ throughput
      formatted B/s · KB/s · MB/s.
- [ ] H3. Assemble final left island order: search · workspaces · weather ·
      overview · network. Decide active-window-title fate (Open Q). Mirror the
      pitch-black + spacing language across all new pills.
- [ ] H4. Polish pass: per-surface sizing/morph feel, surface open/close
      transitions, keyboard consistency (Esc everywhere), multi-monitor check
      via `Variants`. Final verify + commit.

---

## Open questions (resolve before/within the relevant phase)
1. **Active-window title on left island** — keep a compact title pill, or drop it
   to match the reference's 5-pill left side exactly? (Phase H.)
2. **Caffeine mechanism** — `systemd-inhibit` wrapper vs `hypridle` pause. Pick
   what's installed (Phase B1).
3. **Screenshot/record tooling** — detect `grim/slurp` vs `hyprshot`, and
   `wf-recorder` vs `gpu-screen-recorder` at build time (Phase E3).

## Risks / safety
- Power-surface commands are destructive and hit the real machine from the nested
  window — never trigger Logout/Reboot/Poweroff during development (Phase D3).
- Many large surfaces = more QML; watch the hot-reload watcher (atomic-write
  reload gotcha) — keep edits valid first-try, force-reload per memory procedure.
- wttr.in / ipinfo are network calls — must degrade gracefully offline.
