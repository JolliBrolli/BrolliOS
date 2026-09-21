# Brolli-Glass Hyprland plugin — compositor-side liquid glass

A Hyprland **plugin** that renders the existing liquid-glass material inside
the compositor, sampling the live frame directly instead of capturing the
screen and feeding it back into Quickshell.

**It modifies zero lines of Hyprland source.** It builds against the stock
distro headers, loads into stock `/usr/bin/Hyprland` with
`hyprctl plugin load`, and unloads in about two seconds with no restart. No
`no_self_capture` patch, no `Hyprland-brolli` binary, no screencopy.

**The plugin does not author the material.** Its job is purely the data path:
it hands Joel's existing `liquidglasstest.frag` the same inputs the old QML
pipeline used to build by screencopy. The look is unchanged — confirmed by eye
against the original.

---

## Measured cost

Paired runs on the laptop, battery power, same action with and without the
plugin, back to back. 20s averages of GPU package power
(`/sys/class/drm/card1/device/hwmon/hwmon5/power1_average`). **Δ is the glass.**

| scenario | with glass | without | **Δ GPU** | GPU busy |
|---|---|---|---|---|
| Idle, dock + widgets up | 3.37 W | 3.28 W | **+0.09 W** | 5.7% vs 5.0% |
| Spotlight open, still | 3.48 W | 3.26 W | **+0.22 W** | 7.2% vs 5.8% |
| Spotlight expanded, window dragged behind | 5.47 W | 4.96 W | **+0.51 W** | 28.6% vs 22.4% |
| Window dragged behind the dock | 4.96 W | 4.69 W | **+0.27 W** | 21.1% vs 18.1% |

The worst case redrew the glass **216 times a second** (plugin's own draw
counter), so the low figure is not the glass quietly not running. The old
capture pipeline was ~16 W (historical measurement on the patched build; not
re-run side by side). Target was 1–2 W for the glass itself.

Caveats: single 20s samples, human drag speed — treat as ±0.2 W. Whole-system
battery power was also recorded but its run-to-run drift is at least ±0.8 W
(one pair came out negative), too noisy for sub-watt differences.

**Why it is this cheap:** the old cost was never the shader. It was getting the
pixels — a whole extra scene render per flagged layer, a screencopy round
trip, and a Qt upload/crop/blur chain. Now the backdrop is a blit of a small
region out of a frame the compositor has already rendered, the material runs
only over the panel's own pixels, and a panel is only redrawn in frames where
something behind it actually changed.

---

## Data path

```
per layer, immediately before Hyprland draws it  (renderLayer hook)
   for each glass panel the shell registered on that layer:
     damage gate    skip unless this frame's render damage touches the panel
     capture        glBlitFramebuffer of panel + 48px padding, out of the
                    framebuffer this frame is being composited into  -> source
     hblur          Joel's liquidglasshblur.frag over the capture   -> sourceHBlur
     material       Joel's liquidglasstest.frag, drawn across the panel
```

| input the material expects | supplied by |
|---|---|
| `source` | the blit — sharp, no blur stage (see *No blur* below) |
| `sourceHBlur` | Joel's own H-blur pass, run in the plugin |
| `panelSize`, `texSize`, `pad` | the plugin, from the panel rect and capture size |
| the other 21 look uniforms | the shell, via `hyprctl glassuniform` |
| panel rects | the shell, via `hyprctl glassrect` |

### The material is ported, not rewritten

`src/port_shader.py` translates the project's Qt `.frag` files to GLES 3.00:
`#version 440` → `#version 300 es`, Qt's std140 uniform block → individual
uniforms, `layout(...)` decorations dropped, `qt_Opacity := 1.0`. **Shader
bodies are copied verbatim.** The vertex shader supplies `qt_TexCoord0` with
its Qt meaning (panel-local UV, 0..1), so `toTex()` and `sampleBlurred()` need
no changes. Output goes to `src/generated/`, which the plugin loads from disk —
tune the `.frag`, re-run the script, reload the plugin. No rebuild.

### Geometry and uniforms come from the shell

The compositor only sees a layer's **box**, and that is not the glass: the
dock's layer is the full 2880px-wide strip while its glass is a centred pill.
The material draws its whole shape across whatever panel it is handed, so
giving it the layer box drew one slab across the bottom of the screen.

- `GlassRegion.qml` — attached to each glass item, sends its rect (relative to
  the layer's own origin) plus a per-panel corner cap. Spotlight's 23px cap is
  the only per-panel uniform the original material ever varied.
- `GlassUniformBridge.qml` — sends the 21 look uniforms from
  `Config.options.appearance.liquidGlass` and the theme. Several (`base`,
  `textColor`, `tint`) are Material You colours derived in `Appearance.qml`;
  re-deriving them in C++ would be re-authoring the material a layer down.

The plugin applies uniforms by **introspecting its linked program**, so a
uniform added to the `.frag` needs no plugin change, only that the shell sends
it. The existing settings sliders drive the plugin live.

### Ordering: per surface

Glass is queued immediately before its own layer, via a function hook on
`IHyprRenderer::renderLayer` — the same place Hyprland decides its own layer
blur (`renderdata.blur = shouldBlur(pLayer)`). Hyprland has no event between
individual layers; queuing at a render stage put all top-level glass beneath
every top layer. The hook mirrors `renderLayer`'s early returns (so glass is
never queued for a surface that then does not draw), skips the popups pass and
the locked state, and always calls the original.

If the symbol is missing or ambiguous after a Hyprland update, the plugin falls
back to stage-based queuing (`RENDER_POST_WALLPAPER` for bottom layers,
`RENDER_POST_WINDOWS` for top/overlay) instead of failing. `hyprctl glassopt`
reports which is active.

### Damage gating

A panel is redrawn only in frames where the render damage already touches it.
When it does, the whole padded panel is added to the **render** damage, so
everything behind is repainted there before the capture reads it. This is the
pattern Hyprland's own pass uses for live blur (`Pass.cpp`,
`blurRegion.intersect(m_damage).expand(...)`), except the whole panel is added
rather than a blur-radius margin, because the refraction pulls samples from
across the panel.

It is added to render damage only, never the damage ring — verified in
`Renderer.cpp`/`DamageRing.cpp`: render damage goes to
`m_output->state->addDamage()`, and `rotate()` only stores `m_current`. So it
cannot feed itself. Changes that produce no screen damage (a uniform push, a
rect arriving a frame late) damage the affected panels explicitly.

### Shell ↔ plugin state is robust to either side restarting

- **Ownership:** each shell process tags its rect ids with a session id and
  sends `glassrect reset <session>` on startup, dropping rects left by a shell
  that was killed (and so never sent its `remove`s).
- **Resync:** a freshly loaded plugin holds nothing. It posts a
  `glassplugin>>loaded` IPC event; the shell resends all rects and uniforms.

---

## The shell side

`shell-plugin/` is a copy of `quickshell/` with the old glass removed:
`LiquidGlassBackground.qml` reduced from 990 lines to a transparent item that
hosts a `GlassRegion`, both capture services gutted to no-ops, Spotlight's
shader chain deleted, `GlassTest` unregistered. No `ScreencopyView`, no
`ShaderEffect`, no settle timers, no static-wallpaper fallback anywhere in the
glass path.

Nothing is drawn under the content — a fill would sit **on top of** the glass,
since the plugin draws beneath the surface.

Opted in: the dock, Spotlight, and the desktop widgets (bottom layer — their
glass sits under any window covering them, not over it).

---

## Commands

```bash
hyprctl glassopt                    # state, draw counts per panel, registered panels
hyprctl glassopt values             # every uniform value received from the shell
hyprctl glassopt gate on|off        # damage gating (off = redraw every rendered frame)
hyprctl glassrect <id> <ns> x y w h radius | <id> remove | reset <session>
hyprctl glassuniform <name> <v> [v v v]
```

## Build

```bash
cd plugin/src
python3 port_shader.py          # after changing either .frag
g++ -shared -fPIC --no-gnu-unique -std=c++26 -O2 -DWLR_USE_UNSTABLE \
    $(pkg-config --cflags hyprland pixman-1 libdrm) glass4.cpp -o glass4.so
hyprctl plugin load "$PWD/glass4.so"
```

Pinned to the exact Hyprland build; rebuild after every update. **Never load a
build made against stock headers into the patched `Hyprland-brolli` binary** —
that patch changes the struct layouts the plugin is compiled against, and the
failure mode is memory corruption, not a clean error.

---

## No blur

Decided 2026-09-20. The target reads as transparent and refractive, not
frosted; the glass character comes from lensing at the edges. So the capture
is sharp and there is no blur stage in the plugin. The material's own
`blurPx`/`frostBlur` still apply through its built-in separable blur.

An earlier attempt built a full H+V Gaussian into the plugin before checking
what the material consumed — the material already blurs internally, so it
blurred twice, and with 9 taps across a 20px radius it rendered as visible
blocks. Removed.

## Known gaps

- **Untested:** multi-monitor, a scaled display, lock/unlock, cursor over
  glass. Needed before this replaces the real shell (handoff doc Rule 9).
- A monitor with no workspace renders top/overlay layers without emitting
  `RENDER_POST_WINDOWS`; only matters for the stage fallback.
- **Resolution downscaling is not pursued.** `hyprctl glassopt scale` exists
  (it shrinks the blit of an already-rendered frame, not the scene render that
  failed four times in `hyprland-patch/README.md`) but has never been
  validated visually, and the history there warrants treating it as unproven.
- Rect updates are a process spawn each (`hyprctl`), throttled to one per 16ms.
  No visible lag measured; if it ever appears, write to Hyprland's socket
  directly instead.

---

## Gotchas already paid for

- **Unload crashed the compositor.** Queued pass elements have vtable pointers
  into the `.so`; `dlclose()` unmaps it and the next frame calls through a
  dangling vtable. `PLUGIN_EXIT` must `removeAllOfType()` first.
- **Hyprland's render target is top-down** — `gl_FragCoord.y == 0` is the top
  of the screen. A vertically centred test rectangle hides a flip perfectly.
- **Self-scheduling render loop.** Calling `damageBox()` every frame to keep
  the capture fresh schedules the next frame, which calls it again: ~25% idle
  GPU. Grow render damage instead; never create new damage from inside a frame.
- **Swapchain self-capture.** Hyprland repairs reused buffers by age from the
  damage ring; drawing glass without accounting for it lets the capture read
  back our own glass from a few frames earlier.
- **Any layer-shell resize produces wrong frames.** Hyprland advances the
  geometry to the size it requested, then falls back to the committed buffer's
  size until the client catches up — measured on both sides of the boundary,
  with the client's requests strictly monotonic throughout. Quantising and
  monotonic sizing both failed; **not resizing** works. Spotlight's window has
  a floor at its maximum size, with one step of headroom (the exact figure
  landed on a step boundary and a full result list crossed it).
- **Layers on one level stack by map order.** Spotlight and its dim scrim
  mapped on the same event; Spotlight consistently mapped first, so the scrim
  covered it on every fresh open (panel luminance 37.4 vs 48.8). Different
  levels make it timing-independent: Spotlight is on Overlay, the scrim on Top.
- **`ii` wipes Brolli's settings.** Both shells shared
  `~/.config/illogical-impulse/config.json`, and each rewrites it with only the
  keys its own schema knows. Brolli now uses `~/.config/brolli-glass/`.
- **Debounce vs throttle.** `Timer.restart()` on every change sends nothing
  until changes stop — Spotlight's glass stayed collapsed through its whole
  expand animation. `start()` only when idle.
- **Ghost rects** from a killed shell drew the material twice in one spot, the
  second pass capturing the first. Fixed by session ownership.
- **Plugin version-hash guard mismatches spuriously**: `__hyprland_api_get_hash()`
  appends dependency versions, `getHyprlandVersion().hash` is the bare commit.
- **`hyprctl keyword` doesn't work on a Lua-configured Hyprland** — use
  `hyprctl eval`. **`SHyprCtlCommand.exact` must be `false`** for a command
  that takes arguments.
- **`pkill -f <pattern>` from a shell matches its own command line** and kills
  the shell running it. Match `/proc/<pid>/cmdline` exactly instead.
- **The shell copy must run as `Brolli-Glass`**, not a new config name:
  `keybinds.lua` probes `qs -c $qsConfig ipc call TEST_ALIVE` and falls back to
  fuzzel when it fails, which steals focus from Spotlight.

## Files

- `src/glass4.cpp` — the plugin
- `src/port_shader.py` — Qt `.frag` → GLES translator
- `src/generated/` — its output, loaded at runtime
- `src/glass3.cpp`, `src/glass5.cpp` — early spikes (fixed rectangle; draw-over
  diagnostic), kept for history
- `nested.lua` — minimal stock-Hyprland config for nested testing
