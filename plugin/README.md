# Brolli-Glass Hyprland plugin — compositor-side liquid glass

A Hyprland **plugin** that renders the liquid-glass material inside the
compositor, sampling the live frame directly instead of capturing the screen
and feeding it back into Quickshell.

**It modifies zero lines of Hyprland source.** It builds against the stock
distro headers, loads into the stock `/usr/bin/Hyprland` with
`hyprctl plugin load`, and unloads again in about two seconds with no restart.
That is the whole point: it is additive and removable, which is what
`Liquid_Glass_Hyprland_Performance_Handoff.md`'s safety rules (1, 2, 15) ask
for, achieved more completely than that document expected.

---

## Why this exists

The capture-based implementation (still intact in `quickshell/`, and the
reference for what the material should look like) had to solve an awkward
problem: Quickshell needed a picture of what was behind itself. That needed
`no_self_capture` — a patched Hyprland that renders an extra, whole-scene
copy per flagged layer, splices it into screencopy, ships it to Quickshell,
which re-uploads, crops, blurs and refracts it. Measured cost: **~16 W**, with
the raw capture alone accounting for roughly 40 of the ~45-49 percentage
points of GPU load while Spotlight was open.

A compositor already has the picture. Mid-frame, after windows are drawn and
before top-layer surfaces are, the framebuffer *is* "what is behind the dock".
Nothing needs capturing at all.

First measurement of this approach: **~7 W peak**, with no optimisation of any
kind applied yet (see "Known costs" below — the current code is close to the
most expensive version possible). Target is 1-2 W.

## How it works

```
RENDER_POST_WINDOWS            (windows drawn, top/overlay layers not yet)
   -> for each targeted layer surface
        -> queue a custom IPassElement (ePassElementType EK_CUSTOM)
   -> at draw():
        blurMainFramebuffer()  the live mid-frame composite
        + layer's own texture  as the silhouette
        -> our GLSL            rounded shape, circular-lens refraction, rim
```

Every piece of that is an interface upstream Hyprland already provides:

| Need | Upstream API |
|---|---|
| A hook at the right point in the frame | `Event::bus()->m_events.render.stage`, `RENDER_POST_WINDOWS` (`SharedDefs.hpp`) |
| Somewhere to put custom drawing | `IPassElement` + `EK_CUSTOM` (`render/pass/PassElement.hpp`) |
| The live backdrop | `IHyprRenderer::blurMainFramebuffer()` (public) |
| The layer list, geometry, namespace | `Desktop::layerState()->layers()`, `CLayerSurface` |
| The layer's own pixels | `LS->wlSurface()->resource()->m_current.texture` |

## Files

- `src/glass3.cpp` — first working version. Fixed centred rectangle, proves a
  plugin can run its own shader on the live backdrop.
- `src/glass4.cpp` — current. Targets real layer surfaces by namespace, masks
  to their actual visible shape.
- `src/glass5.cpp` — `glass4` drawn at `RENDER_LAST_MOMENT` (over the layer
  instead of under it). Kept as a diagnostic: it makes the material visible
  even when the layer above is opaque.

Build:

```bash
cd plugin/src
g++ -shared -fPIC --no-gnu-unique -std=c++26 -O2 -DWLR_USE_UNSTABLE \
    $(pkg-config --cflags hyprland pixman-1 libdrm) glass4.cpp -o glass4.so
hyprctl plugin load "$PWD/glass4.so"
```

The plugin is pinned to the exact Hyprland build (`__hyprland_api_get_hash()`),
so it must be rebuilt after any Hyprland update. It will refuse to load
otherwise, which is the correct behaviour.

**Do not load a plugin built against stock headers into the patched
`Hyprland-brolli` binary.** That patch adds data members to `LayerSurface.hpp`
and changes `Renderer.hpp`; the struct layouts the plugin was compiled against
no longer match, and the failure mode is memory corruption, not a clean error.

## The shell side

This only works if the shell **stops drawing its own glass**. A layer that
paints opaque pixels over its whole shape hides anything the compositor draws
beneath it — confirmed directly: with the unmodified dock, the material was
rendering correctly and was completely invisible.

`shell-plugin/` is a copy of `quickshell/` with all of the old glass removed:
`LiquidGlassBackground.qml` reduced from 990 lines to 55, both capture
services gutted to no-ops, Spotlight's 114-line shader chain deleted,
`GlassTest` unregistered. No `ScreencopyView`, no `ShaderEffect`, no settle
timers, no idle pulse, no static-wallpaper fallback anywhere in the glass path.

What remains is a **translucent white silhouette at alpha 0.14**. That is
load-bearing, not decoration: it is the shape the plugin masks its material
to. This mirrors bea4dev's `LiquidIslandQS`, which deliberately implements no
refraction client-side and lets ShojiWM's compositor draw the material behind
its silhouette.

## Known problems

### The silhouette convention is a hack

The mask test is not "is this pixel opaque". Spotlight's layer is **full
screen** and carries a black dim scrim at opacity 0.35 over the entire
display — *more* opaque than the 0.14 silhouette. No alpha threshold can
separate them, so the plugin matches on unpremultiplied **brightness**
instead: the shell paints silhouettes white and scrims black.

The three cases, as composited:

| | premultiplied rgb | alpha | unpremultiplied brightness |
|---|---|---|---|
| Scrim alone | 0.0 | 0.35 | **0.0** |
| Spotlight panel (white 0.14 over the scrim) | 0.14 | 0.441 | **0.317** |
| Dock (white 0.14, nothing behind) | 0.14 | 0.14 | **1.0** |

Threshold sits at 0.2. Note the panel is *not* 1.0 — compositing over the
scrim keeps its rgb but inherits the scrim's alpha, which drags the ratio
down. An earlier 0.5 threshold passed the dock and rejected Spotlight for
exactly this reason.

This works, and it is still a convention rather than an interface. It breaks
for anything dark that wants glass, or anything bright that does not.

**The structural fix** is for a glass surface to be its own layer, sized to
the panel, instead of a full-screen layer carrying both the panel and a
screen-wide scrim — then the layer's own alpha simply *is* the shape, with
nothing to disambiguate.

**Done for Spotlight.** Its dim scrim now lives in its own full-screen layer
(`quickshell:overviewDim`), letting the overview panel shrink to its content.
The panel only spanned the monitor because the old capture cropped by this
window's coordinates, a reason that died with the capture. Its blur region
went from the whole display (~5.2M px) to the panel (~500k px), and the
brightness test is no longer load-bearing there. The mask still uses
brightness, since the dock's silhouette benefits from it and it costs nothing.

`desktopWidgets` is still full-screen anchored and will hit the same wall.

### Any layer-shell resize produces a visibly wrong frame

This one cost several wrong attempts, so it is worth stating precisely.

When a glass layer resizes, Hyprland advances the layer's geometry to the size
it has just requested, then falls back to the size of the buffer the client
has actually committed, until the client catches up. Frame-tagged measurement
across one Spotlight expand:

```
frame=1413  box=512  tex=448     geometry ahead of the committed buffer
frame=1414  box=448  tex=448     geometry drops to EXACTLY the texture size
frame=1416  box=512  tex=512     client catches up

frame=1419  box=640  tex=512
frame=1420  box=512  tex=512     again, exactly the texture size
frame=1421  box=576  tex=576
```

Every drop lands exactly on the committed texture's size. `snap=0` throughout
and frame numbers strictly increase, so this is neither snapshot rendering nor
the layer being visited twice in a frame.

Crucially, the CLIENT's own requests were strictly monotonic over the same
period (256, 320, 384, 448, 512, 576, 640, 704, 768 — measured on the QML
side, never decreasing). **No client-side sizing discipline avoids this.**
Three attempts tried and failed:

1. Quantising the window size to a 64px step — `elementMove`'s easing
   overshoots by a pixel or two, and near a bucket boundary that overshoot
   promotes itself into a full 64px resize. Fewer, bigger jumps.
2. Making the requested size monotonic (grow only, reset on close) — the
   client stopped asking for smaller sizes; the compositor still reported
   them, because the fallback is to the committed buffer, not to the request.
3. Reading `position/size(GEOMETRIC_CURRENT)` instead of `m_geometry` to match
   `renderLayer` exactly — measurement showed the two are identical on every
   frame here, so this changed nothing. (It is still the correct source to
   read, and is kept: it matters for a layer that genuinely animates.)

**What actually works is not resizing.** Spotlight's window now has a floor at
the search panel's maximum size, so no number of results resizes the surface;
the content animates inside a fixed box, exactly as it did when the window
spanned the monitor — just a small box now. The original never flickered for
precisely this reason, which was the clue.

Note the floor must include headroom. Computed exactly, it landed ON a step
boundary (collapsedHeight 84 + list cap 600 + margins 20 = 704) while a
completely full result list needs 705.45 — so the single case of a fully
populated list still crossed by one step and still flashed, while shorter
lists were clean. The floor now takes the next step up.

Anything else that resizes will meet this: the dock (icon magnification), the
desktop widgets, and a morphing island most of all.

### Known costs (none of these are optimised yet)

1. **The blur is full-screen, every frame.** `blurMainFramebuffer` is handed
   the whole monitor as its damage region to serve a dock pill of roughly
   1100x120. Hyprland's blur already honours a damage region and expands it by
   the blur's own reach, so this should be the largest and cheapest win.
2. **No skip when nothing changed behind the glass.** A fully idle desktop is
   already free — Hyprland renders no frame, so the hook never fires. But any
   frame rendered for an unrelated reason (clock tick, cursor) drags a full
   screen blur with it.
3. **One backdrop per element, not per monitor.** Dock plus Spotlight open is
   two full-screen blurs per frame of the same content. `GlassCaptureService`
   learned this exact lesson on the QML side, where per-surface captures took
   idle GPU from ~32% to ~75-79%.
4. **The distance march is per-pixel.** Up to 24 mask taps plus 4 gradient
   taps per glass pixel, as a stand-in for the reference's jump-flood distance
   field. For known rounded rectangles an analytic SDF is nearly free — but
   the plugin does not know the pill's rect, only the layer's much larger box,
   so that needs a geometry channel from the shell (a plugin-registered
   `hyprctl` command would do it).
5. **Full-resolution backdrop**, for something only ever shown blurred and
   refracted.

On (1) and (5), note carefully: this is **not** the resolution downscale that
failed four times in `hyprland-patch/README.md`, and not the tile-based damage
gating that measured zero win there. Both of those concerned a **full scene
re-render**, where scissoring clips writes without reducing traversal or
shading. Here the cost is a blur over an existing texture, where shrinking the
region or the resolution removes real work. Different mechanism, different
outcome.

### The material is a stand-in

`glass4.cpp`'s shader is about 60 lines: rounded-rect SDF, Aghajari circular
lens refraction, specular rim. `quickshell/modules/common/widgets/glass/
liquidglasstest.frag` is 607 lines and does chromatic aberration, the frost
desaturate/darken recipe, the adaptive legibility floor, the superellipse
squircle, tint and a diagonal light model.

The 7 W figure therefore understates the final cost — porting the real
material will add work (chromatic aberration alone is two more 9-tap blurred
samples at the rim). Optimise first, then spend the headroom.

Also worth knowing: the refraction currently uses the **circular lens**
profile from the ShojiWM reference, which is not what the real shader does
(a tuned exponential falloff via `fa`/`fb`/`fc`/`fd`). Porting the real
material restores the existing look; which profile reads better then becomes
an A/B that can actually be judged side by side.

## Gotchas already paid for

- **Unload crashed the compositor.** Queued pass elements have vtable pointers
  into the `.so`; `dlclose()` unmaps it and the next frame calls through a
  dangling vtable. `PLUGIN_EXIT` must drop them first — upstream provides
  `CRenderPass::removeAllOfType()` for exactly this. Crash was on *unload*,
  not load.
- **Hyprland's render target is top-down.** `gl_FragCoord.y == 0` is the top
  of the screen. An initial version flipped the box and drew the dock's shape
  at the top of the display. A vertically centred test rectangle hides this
  perfectly, because it flips onto itself.
- **`decoration:blur:enabled` was `false`** in the live config. Asking for a
  blurred backdrop Hyprland never prepares returns an empty buffer — the
  material rendered as a flat grey card. With `size 10, passes 3` it then
  averaged the backdrop to mush. The plugin inheriting the user's blur config
  is itself a design flaw; owning the backdrop copy fixes it.
- **The version-hash guard fires spuriously.** `__hyprland_api_get_hash()`
  returns the commit *with dependency versions appended*; `getHyprlandVersion()
  .hash` returns the bare commit. Comparing them directly always mismatches.
- **`hyprctl keyword` does not work on a Lua-configured Hyprland** — use
  `hyprctl eval 'hl.config({...})'`.
- **Running the shell copy under a different config name breaks keybinds.**
  `keybinds.lua` probes liveness with `qs -c $qsConfig ipc call TEST_ALIVE`
  and falls back to fuzzel when it fails, which steals focus from a Spotlight
  that opened correctly. Point `~/.config/quickshell/Brolli-Glass` at the copy
  instead of inventing a new config name.
