# NOTES.md — architecture

How Brolli-Glass is put together and why. The running log is `PROGRESS.md`; the
plugin has its own `plugin/README.md`.

---

## 1. The two halves

**BrolliOS** (`quickshell/`) is the shell: menubar, dock, desktop widgets,
Spotlight, sidebars, lock. It is a fork of end-4 / illogical-impulse, so most
modules are theirs; this project's work is the macOS-shaped surfaces and the
glass.

**Brolli-Glass** (`plugin/`) is a Hyprland plugin that draws the shell's liquid
glass compositor-side, on stock Hyprland.

The split exists for one reason: **the shell cannot see what is behind itself
cheaply**. The old design captured the screen with screencopy, cropped, blurred
and refracted it in QML, and needed a patched Hyprland (`no_self_capture`) to
stop each panel capturing its own last frame. It cost about 16 W. The plugin
already has the composited frame in hand, so it does the same work for ~0.1 W
idle and ~1 W while dragging a window across the widgets.

---

## 2. The contract between them

The shell owns *what* and *where*; the plugin owns *how it is drawn*.

| direction | channel | carries |
|---|---|---|
| shell → plugin | `hyprctl glassrect <id> <ns> x y w h radius darkText` | where each panel is, in its layer's own coordinates |
| shell → plugin | `hyprctl glassuniform <name>[@<ns>] v...` | every look value, one `--batch` per change |
| shell → plugin | `hyprctl glasssample <id> <ns> x y w h` | regions whose backdrop colour to measure |
| plugin → shell | `glasssample>><id>,r,g,b` | that colour (adaptive text) |
| plugin → shell | `glassstats>><id>,busy` | how busy a panel's backdrop is (chip boost) |
| plugin → shell | `glassplugin>>loaded` | re-send everything |

Shell side: `GlassRegion` (rect), `GlassSample` (colour), `GlassUniformBridge`
(values), `LiquidGlassBackground` (marks a panel and exposes its text colour),
`AdaptiveGlassText`/`AdaptiveGlassSymbol` (use it).

Why the shell sends rects at all: the compositor only sees a layer's box, and
that is not the glass. The dock's layer is the full-width strip while its glass
is a centred pill.

---

## 3. How a frame is drawn

1. **`RENDER_PRE`** — snapshot each monitor's *new* damage, before Hyprland
   rotates its damage ring. Colour samples trigger on this, never on the full
   frame damage, which also replays the previous frames' damage for this
   swapchain buffer.
2. **`RENDER_BEGIN`** — decide, for the whole monitor at once, which panels draw
   this frame and which regions get measured. Per-panel decisions at queue time
   left cut-outs: Hyprland grows the damage around live-blur elements *after*
   everything is queued, repainting the wallpaper over a skipped neighbour.
   Panels hidden completely behind an opaque window are dropped here too.
3. **`renderLayer` hook** — for each layer, queue that layer's glass (and its
   colour samples) immediately before the layer's own surface, so the glass sits
   under the panel it belongs to. The popups pass does the same for the
   menubar's dropdowns, which are xdg-popups rather than layer surfaces.
4. **Draw** — blit the backdrop out of the frame being composited, run the panel
   statistics pass, then the material.

---

## 4. The material (`plugin/src/brolliglass.frag`)

Based on Aghajari's Liquid Glass recreation: a circular lens profile over a rim
band, a radial offset, a small Gaussian softening, a chromatic split and a tint.
What this project added:

- **Centre line, not centre point** (`aghStretch`) — the original bends every
  pixel away from one centre, which smears sideways along a long panel like the
  dock. Above 0 the centre becomes a line along the long axis.
- **Readability** — per panel, never per pixel: the backdrop's mean and spread
  come from a small averaging pass (`panelStats`), and the whole panel gets one
  contrast squash, one brightness push (only when the backdrop nears the text's
  own brightness) and one body lift. A per-pixel floor was tried first and
  striped busy backdrops.
- **Rim outline** — the shell's original white rim, verbatim.
- **No blur on blur** — a panel drawn over glass already drawn this frame drops
  its own softening (Apple: avoid the material on both layers).
- **9-tap blur** — the 5×5 Gaussian taken in 9 samples using the GPU's blending
  between pixels: 75 backdrop reads per pixel down to 27.

Adaptive text is one colour per panel, decided from the plugin's measurement of
the finished glass. The old shader did it per element, which needed a backdrop
texture the shell no longer has.

---

## 5. Rules learned the hard way

- **Never overwrite a loaded `.so`.** Hyprland has it mapped; the next unload
  crashes the session. Unload, copy to a temp name, `mv`, load.
- **Never add to the damage ring from the render path.** It schedules another
  frame, which runs the same code: a permanent 120 fps loop.
- **A rim deeper than the corner radius must fold or round the corners off.**
  Apple and ShojiWM both keep the lensing rim thin.
- **Restart the shell by exact cmdline**, never `pkill -f qs`.
- **Measure in pairs**, same action with and without, because hand-driven runs
  vary by ~0.4 W.

---

## 6. Removed

A Dynamic Island notch (with a Claude Code agent monitor) and the screencopy
glass pipeline both lived here. Both are gone; git history has them. Nothing in
the project needs a patched Hyprland any more.
