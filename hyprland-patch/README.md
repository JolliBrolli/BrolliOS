# no_self_capture Hyprland patch

Adds a custom `no_self_capture` layer rule effect to Hyprland (based on
v0.56.2, commit `efb50993780079460b0cbed1363e2166a2de1d9f`) that eliminates
self-reflection in the liquid-glass shader by substituting a live
"what's behind me" snapshot into any screencopy-based capture of the tagged
layer, instead of leaving that layer's own rendered content in place.

The self-capture snapshot is throttled to the monitor's own real refresh
rate (`pMonitor->m_refreshRate`), not a hardcoded assumption — it's a full
extra render of the scene, so recomputing it faster than the display can
show is wasted GPU work, but capping it below the real rate is a visible lag.
This is additionally hard-capped at 60Hz even on higher-refresh monitors —
see "Perf fix 2026-09-13" below.

## Bug fixed 2026-09-13: multiple simultaneous no_self_capture layers

Originally only ever exercised one flagged layer at a time (glassTest, then
overview). Once the dock (`quickshell:macDock`, always mapped, unlike the
toggle-only overview) also got flagged, opening Spotlight made the dock's
glass collapse to solid black.

Root cause, in `ScreenshareFrame.cpp`'s consumption loop: it blits EVERY
flagged layer's own "what's behind me" snapshot into the SAME output
capture, one `glBlitFramebuffer` per layer, each covering that layer's own
full geometry, in `Desktop::layerState()->layers()`'s own (unspecified)
order. Overview's own snapshot only hides overview — the dock renders
completely normally inside it. So when overview's full-screen blit landed
AFTER the dock's own (correctly dock-excluded) blit, it overwrote the
dock's region with the dock's own current frame again — reintroducing
exactly the self-capture feedback loop this whole mechanism exists to
prevent, compounding every frame into a black collapse.

Fixed by sorting the flagged layers largest-area-first before blitting, so
a smaller/nested layer (the dock, inside overview's full-screen bounds)
always blits last and wins within its own footprint, regardless of
`layers()`'s own ordering. Outside that overlap the larger layer is
unaffected. This is a heuristic (nesting-by-area), not a real "who is this
capture actually for" answer — Hyprland has no way to attribute a given
screencopy session to a specific QML layer, since every ScreencopyView in
this shell shares one wl_client — but it's correct for every layer
geometry this shell actually produces (dock always sits inside overview's
full-screen bounds when both are open, never the reverse or a partial
overlap).

## Perf fix 2026-09-13: cap self-capture regeneration at 60Hz (superseded)

**Superseded same day** by the resolution-downscale fix below, which let the
60Hz cap be reverted back to native refresh rate — kept here for history.

This system's monitor runs 120Hz, so the self-capture snapshot (a full extra
render of the entire scene per flagged layer, per `renderMonitor()` frame —
see above) was regenerating up to 120 times/sec for as long as any glass
panel (Spotlight, the dock) stayed open, even while fully static. User
reported coil whine while Spotlight sat open with nothing moving; confirmed
via `/sys/class/drm/card1/device/gpu_busy_percent` that this was a real,
sustained GPU load increase, not a transient.

A QML-side fix (gating `ScreencopyView`/`ShaderEffectSource` `live:` on
actual panel visibility instead of leaving them unconditionally `live: true`
forever) already cut the *idle* baseline by ~20% (41%→33-34%), but the
*while-open* cost was still dominated by this C++ throttle running at the
monitor's full 120Hz.

Fixed in `src/render/Renderer.cpp`'s `renderMonitor()` by clamping the
computed `hz` to 60 regardless of the monitor's real refresh rate:

```cpp
const auto hz = std::min(pMonitor->m_refreshRate > 1.f ? pMonitor->m_refreshRate : 60.f, 60.f);
```

60Hz was chosen over a more aggressive 30Hz (offered, not taken) as the more
conservative option — this snapshot only feeds a static backdrop texture for
glass panels that also blur/refract it further, so redraw frequency past
60Hz isn't visually distinguishable there, while halving the worst-case
regeneration rate on a 120Hz display.

User reported the 60Hz cap was "really noticeable" (visibly choppier behind
fast-moving content), which motivated the deeper fix below instead of just
living with the cap.

## Perf fix 2026-09-13 (later same day): downscale the self-capture render itself — REVERTED, see below

**Reverted the same day**, after item 2 below broke the hardware cursor's
rendered size system-wide (it appeared as a single pixel) on every panel,
not just glass ones — `src/render/OpenGL.cpp`'s `beginSimple` is a
general-purpose rendering entry point used well beyond this patch's own
scope, and changing its viewport logic had a blast radius far past what
this patch owns. The plan is to eventually upstream just the
`no_self_capture` mechanism itself as a real Hyprland PR, which is
specifically why a general-purpose renderer function is the wrong place
for this patch to be making changes at all, correctness risk aside. Left
this section in place for the historical record of what was tried and
why it didn't ship, but the code is back to the simple 60Hz-cap-only
version (confirmed by rebuilding and diffing to a byte-identical binary
against the pre-downscale build).

The 60Hz cap above treated *frequency* as the only lever, but the actual
per-call cost — a full extra render of the entire scene at full monitor
resolution, every regeneration — was untouched. Since this snapshot only
ever feeds a shader that blurs/refracts it further (never shown 1:1), full
resolution there was pure waste.

Three coordinated changes, all needed together:

1. **`src/render/Renderer.cpp`, `makeSelfCaptureBackgroundFB`**: allocate
   and render the snapshot at half linear resolution (`SELF_CAPTURE_RENDER_SCALE
   = 0.5f`, i.e. 1/4 the pixels) instead of the monitor's full pixel size.
   `renderWorkspace`'s own aspect-ratio guard falls back to an *unscaled*
   1:1 render if the geometry box's aspect doesn't match the monitor's
   within 1%, so both axes must be scaled by the exact same factor.

2. **`src/render/OpenGL.cpp`, `beginSimple`**: this was the blocker for
   simply shrinking the framebuffer — the GL viewport was unconditionally
   set to the *monitor's* pixel size regardless of the actual target
   framebuffer's size. A viewport larger than the framebuffer it's drawing
   into doesn't scale content down, it just clips to the framebuffer's
   top-left corner. Fixed by sizing the viewport from the actual bound
   FBO's own `m_size` (falling back to the monitor's size when there's no
   FBO, preserving every other existing caller's behavior unchanged, since
   they all already allocate at full monitor size). `setProjectionType`
   (in `beginRender`) already did this correctly — only the viewport call
   hadn't caught up.

3. **`src/managers/screenshare/ScreenshareFrame.cpp`**: the blit that
   substitutes this snapshot back into a screencopy consumer computed its
   source rectangle in full monitor pixel coordinates, assuming the
   snapshot FB was always monitor-sized. Now scales that rectangle by
   `snapshotBackgroundFB.m_size / monitor.m_pixelSize` (derived from the
   actual allocated size, not a second hardcoded constant), so it stays
   correct regardless of whatever scale `makeSelfCaptureBackgroundFB`
   picks. `glBlitFramebuffer` already scales src→dest with `GL_LINEAR`, so
   the smaller source blits back up to full size for free.

With the per-call cost now roughly a quarter, the 60Hz cap was reverted back
to native refresh rate (`hz = pMonitor->m_refreshRate`) — paying the real
rate should now cost less than the old capped-but-full-resolution version
did, without the choppiness complaint. **This part was also reverted** along
with the viewport change it depended on — see above. The 60Hz cap is back.

Any future resolution-downscale attempt needs a way to shrink the render
target that doesn't touch a general-purpose renderer entry point shared
with unrelated features (the cursor, in this case) — e.g. a dedicated
render path scoped to just this patch's own snapshot, not a shared
`beginSimple`/viewport function. Not attempted yet.

## Perf fix 2026-09-14: skip regeneration when nothing changed behind the panel

The 60Hz cap still regenerated the self-capture snapshot on a fixed timer
regardless of whether anything behind the panel had actually changed. For a
panel that's toggled open/closed (Spotlight) that's bounded by how long it
stays open, but the dock is *permanently mapped* — its self-capture
background was doing a full extra scene render up to 60 times a second,
forever, even with a completely idle, unchanging desktop.

Two changes:

1. **`src/output/DamageRing.hpp`**: added a small read-only getter,
   `current()`, returning the damage accumulated since the last `rotate()`
   (i.e. since the last real frame render). Purely additive — every
   existing caller and behavior is unchanged; this just exposes what was
   already a private member as a const reference.

2. **`src/render/Renderer.cpp`**, the self-capture loop: after the existing
   60Hz throttle check, take a *copy* of `pMonitor->m_damage.current()` and
   intersect it with just that specific layer's own bounding box (not the
   whole monitor's damage) — if the intersection is empty, skip the
   regeneration entirely. Checking against the layer's own box specifically
   (rather than "did anything change anywhere") means a change happening in
   a completely unrelated part of the screen correctly doesn't trigger a
   regeneration either. Only applies once a first capture already exists,
   so opening a panel is never delayed by this — same "always captures
   immediately the first time" behavior as the existing throttle.

Never consumes or clears the damage region it reads — `rotate()` (called
elsewhere, once per real frame) is still the only thing that clears
`m_current`, so this doesn't interfere with the real frame's own damage
tracking at all.

Requires a full Hyprland session restart (logout/login) to take effect —
`no_self_capture`'s render-loop code runs inside the compositor binary
itself, so a `qs` shell restart alone does nothing here.

## Perf fix 2026-09-14: grouped/shared rendering across non-overlapping layers

Adding the bar and desktop widgets to the liquid-glass material (on top of
the dock + Spotlight) measured idle GPU load jumping from ~32% to ~75-79% —
each flagged layer was paying for a completely independent full-scene
self-capture render, even though the dock, bar, and desktop widgets
normally occupy entirely disjoint screen regions and could safely share
one.

(Desktop widgets were separately moved OFF this mechanism entirely — see
`DesktopWidget.qml`'s `staticWallpaper: true` — since they only ever sit
behind other content and refracting the static wallpaper file sidesteps
both the cost and a real bug: their window is full-screen sized like
Spotlight's own, which broke the "smaller wins" sort below when both were
flagged. This fix is about the layers that DO still need it — the dock and
the bar.)

Three changes:

1. **`src/render/Renderer.hpp`/`.cpp`**: new `makeSharedSelfCaptureBackgroundFB(PHLMONITOR, const std::vector<PHLLS>&)`,
   structurally identical to the existing `makeSelfCaptureBackgroundFB` but
   hiding every layer in the group simultaneously and returning ONE
   framebuffer for the caller to assign to all of them.

2. **`src/render/Renderer.cpp`**, the self-capture loop: now partitions
   currently-flagged, mapped layers into two groups every frame —
   "isolated" (no bounding-box overlap with any OTHER flagged layer) and
   "overlapping" (at least one overlap, e.g. the dock nested inside
   Spotlight when both are open). Overlapping layers keep the EXACT
   existing one-render-per-layer path, unchanged — sharing there would
   incorrectly hide a layer that's genuinely supposed to stay visible in
   another's snapshot (see the "multiple simultaneous no_self_capture
   layers" fix above for why that distinction matters). Isolated layers
   share one combined render instead: correct because hiding layer A in
   that shared render also hides layer B, which is exactly what B's own
   snapshot should show anyway if B never occludes A.

3. Same file: the isolated group's throttle/damage-gating is checked
   against the GROUP's combined bounding region (union of every member's
   box) rather than per-layer — any member not yet allocated forces an
   immediate shared render (matching the existing "always captures
   immediately the first time" behavior); otherwise a regen only happens
   once at least one member is throttle-due AND real damage overlaps the
   combined region.

Group membership is recomputed every frame (cheap — a handful of AABB
overlap tests, not a rescan of the scene), so a layer moving from isolated
to overlapping (or back) — e.g. Spotlight opening near the dock — is picked
up immediately, falling back to the safe per-layer path exactly when
needed.

Requires a full Hyprland session restart (logout/login) to take effect —
same reason as above.

## Perf fix 2026-09-14 (later same day): render-resolution downscale — tried again, reverted again

User measured the dock's live-capture GPU cost directly via `/proc/<pid>/fdinfo`'s
`drm-engine-gfx` counter (idle ~2%, live ~34% of `Hyprland-brolli`'s own GPU
time — a real, sustained jump, not noise) and asked for it to come down. This
is the SAME per-call-cost problem the "downscale the self-capture render
itself" section above already identified and reverted after it broke the
hardware cursor.

Found what actually broke the cursor last time on this retry:
`CHyprOpenGLImpl::setViewport` (`src/render/OpenGL.cpp`) caches the last
values it set (`m_lastViewport`) and skips the actual `glViewport` call when
asked to set the same values again. The original attempt shrank the viewport
(via `beginSimple`'s own logic, changed to use the bound FBO's size) for this
snapshot's smaller framebuffer, but never explicitly restored it afterward —
leaving both the real GL viewport AND that cache pointing at the small size
for whatever rendered next, which happened to be the cursor.

Retried with `beginSimple`/`OpenGL.cpp` left completely untouched this time —
both self-capture functions instead shrank their FB, passed a matching
scaled geometry `CBox` to `renderWorkspace`, and called
`Render::GL::g_pHyprOpenGL->setViewport(...)` directly (shrink after
`beginFullFakeRender`, restore after `endRender()`, both through
`setViewport()` itself so its cache stays in sync) — fully scoped to their
own function bodies, no shared code touched. `ScreenshareFrame.cpp`'s blit
`srcBox` was scaled to match via the FB's actual allocated size at runtime.

This built clean and genuinely didn't break the cursor this time (confirmed:
mouse rendered fine, GPU dropped from ~34% to ~28%) — but the dock's glass
came back solid black, no refraction at all, while live. Something else in
`renderWorkspace`/the render-pass pipeline (`RMOD_TYPE_SCALE`'s own render
hint, possibly interacting with the manually-set viewport in a way not fully
traced) doesn't behave as assumed when the target isn't monitor-sized —
not root-caused before reverting, rather than keep guessing changes against
the user's actual live desktop compositor one full rebuild+logout/login cycle
at a time. Reverted `makeSelfCaptureBackgroundFB`, `makeSharedSelfCaptureBackgroundFB`,
and the `ScreenshareFrame.cpp` blit scaling all the way back to full
monitor-resolution rendering (the same code these three functions had before
this section) — the "grouped rendering" and "skip regeneration when nothing
changed" fixes above are UNAFFECTED and still active.

**If attempted again**: iterate against a disposable/nested compositor
instance, not the user's real logged-in session — each failed guess here
cost a full rebuild + logout/login round-trip against their actual desktop.

Requires a full Hyprland session restart (logout/login) to take effect —
same reason as above.

## Perf fix 2026-09-17: gate self-capture generation on real demand

The generation side (`makeSelfCaptureBackgroundFB`/
`makeSharedSelfCaptureBackgroundFB`, both loops in `renderMonitor()`) ran on
every real frame for any flagged, mapped layer — throttled to 60Hz and
damage-gated (see the two fixes above), but with **no check at all for
whether anything is actually about to consume the result**. The consumption
side (`ScreenshareFrame.cpp`'s blit, inside `CScreenshareFrame::renderMonitor()`)
already only runs when a real client has an in-flight screencopy frame
request (`share()` was called, `m_shared == true`, not yet `done()`) — so
Hyprland was eagerly maintaining a fresh "what's behind the dock" snapshot
continuously whenever anything nearby changed, regardless of whether
Quickshell's own adaptive live-rate throttling (`GlassCaptureService`'s
settle/idle-pulse/drag system) currently wanted a live capture at all. This
was invisible to, and untouched by, all of that QML-side throttling work.

Fixed by gating the whole generation block (both the per-layer and the
shared-group loops, plus the `selfCaptureFlaggedLayers` scan itself) behind:

```cpp
const bool selfCaptureDemanded = Screenshare::mgr() && pMonitor->needsACopyFB();
```

`CMonitor::needsACopyFB()` → `Screenshare::mgr()->outputNeedsCopyFB(monitor)`
→ `pendingFrames > 0` is the exact same per-frame "is a real screencopy frame
actually pending right now" check `renderMonitor()` already uses elsewhere in
this same function (its own real-frame copy-FB gate) — found by reading
`ScreenshareManager.cpp`/`.hpp` and comparing the two other existing call
sites: `MonitorResources.cpp`'s `shouldKeepMirrorFB()` uses the coarser
`isOutputBeingSSd()` (does an active session exist at all — appropriate for
resource *retention*, not correct here), while `Monitor.cpp`'s own
`needsACopyFB()` uses the precise pending-frame check for a per-frame render
decision — the correct one to mirror for gating a per-frame render.

Requires `#include "../managers/screenshare/ScreenshareManager.hpp"` in
`Renderer.cpp` (no circular-include issue — `Renderer.hpp` only
forward-declares `Screenshare::CScreenshareFrame`).

Built clean in a disposable scratchpad clone, tested in the nested-compositor
harness below (`screencast`/`screencastv2` events fired as expected, no
crash, settled to idle cleanly) — but **not** visually confirmed against a
real "something moves behind the dock" interaction before being swapped into
`~/.local/bin/Hyprland-brolli`, since the user had no way to interact with the
nested window this session and asked to swap directly and check on the real
desktop instead. Takes effect on next logout/login. If the dock's glass goes
black/stale or crashes after that, **this is the gate to suspect first** —
check whether `pendingFrames` is going high enough/often enough for
Quickshell's specific capture pattern.

## Perf fix 2026-09-17 (later same day): demand-resume damage-check bypass

The demand gate above only reflects the CURRENT frame's demand — but the
damage-overlap check (Perf fix 2026-09-14, "skip regeneration when nothing
changed") only ever looks at damage since the LAST REAL FRAME. Combined,
these two silently interacted the first time this build actually ran on the
user's real desktop: after unlocking, if nothing else on screen changed
(no window moved, nothing clicked), the dock's self-capture snapshot stayed
exactly as stale as it was going into the lock — Quickshell's demand
resumed correctly, but there was no damage anywhere near the dock's own box
to satisfy the regeneration gate, so it just kept serving the old snapshot.
Reported symptom: "it only resets after a lock when my mouse cursor goes
above the dock" — hovering triggers the dock's own icon-magnification
animation, which repaints pixels *inside* the dock's bounding box, which
coincidentally satisfies the damage check even though the magnification has
nothing to do with what's actually behind the dock.

Fixed with a new per-layer timestamp, `m_lastSelfCaptureVisitTime`
(`LayerSurface.hpp`), stamped every real frame a layer is actually
considered by either self-capture loop in `renderMonitor()` (i.e. every
frame `selfCaptureDemanded` was true for its monitor) — independent of the
60Hz throttle inside each loop, so it tracks genuine demand-gap length, not
throttle cadence. When the gap since the last stamp exceeds 3x the
monitor's real frame interval, that means demand was absent for at least a
frame — nobody was watching what changed behind the layer — so the very
next visit bypasses the damage-overlap check once, exactly like a
never-yet-allocated snapshot already does. Applied to both the
per-layer (overlapping) and shared-group (isolated) paths.

Built and swapped into `~/.local/bin/Hyprland-brolli` same day as the
demand-gating fix above; not yet confirmed on the user's desktop (needs
another logout/login, then unlock with nothing else on screen changing, to
verify the dock's glass now updates immediately instead of needing a hover).

## Perf fix 2026-09-17 (evening): self-capture resolution downscale — attempt 3, and tile-based partial-region regeneration

Two changes bundled into one build (both touch `makeSelfCaptureBackgroundFB`/
`makeSharedSelfCaptureBackgroundFB`, so doing them separately would mean two
build+logout/login cycles instead of one) — heavily tagged with distinct
debug log prefixes (`[selfCapScale]`, `[tileDamage]`) specifically so that if
either one regresses, the tag alone identifies which is at fault without
needing to bisect.

### Resolution downscale (attempt 3)

Two previous attempts at this (see the two sections above) were both
reverted — one broke the hardware cursor (root-caused: a `setViewport`
caching bug), one produced solid black glass (never root-caused). This
attempt is based on actually reading this Hyprland version's own
`beginRender`/`renderWorkspace`, rather than guessing:

- `renderWorkspace(pMonitor, workspace, now, geometry)` computes
  `scale = geometry.width / pMonitor->m_pixelSize.x` and renders the entire
  monitor's scene through that uniform scale+translate — but if `geometry`'s
  aspect ratio doesn't match the monitor's own within 1%, it silently forces
  `scale=1, translate=0` (logs `Log::ERR`). So the render target has to stay
  the same aspect ratio as the monitor — a uniform downscale of the whole
  snapshot, not a crop to one layer's box.
- `beginRender(..., simple=true)` (which `beginFullFakeRender` always uses)
  calls `setProjectionType(fb->m_size)` — the projection is already derived
  from the framebuffer's own actual size, automatically. No manual
  projection-type handling needed, unlike the reverted attempts.
- The GL **viewport**, however, is NOT set anywhere in
  `beginRenderInternal`/`beginFullFakeRenderInternal` (confirmed by reading
  both) — this Hyprland codebase already has a working, in-tree precedent
  for exactly this situation: the "BGTex scale" code (`Renderer.cpp`, wallpaper
  downscaling), which manually calls `setViewport()` before its own
  render-into-smaller-target detour and restores it after. This patch does
  the same: `setViewport()` to the shrunk size right after
  `beginFullFakeRender`, restored to the monitor's own full size right
  before returning — never touching `OpenGL.cpp`'s shared `beginSimple`,
  which is what broke the cursor in attempt 1.
- `SELF_CAPTURE_RENDER_SCALE = 0.5f` — half linear resolution (1/4 the
  pixels) for both `makeSelfCaptureBackgroundFB` and
  `makeSharedSelfCaptureBackgroundFB`.
- `ScreenshareFrame.cpp`'s blit `srcBox` is scaled by the snapshot FB's own
  actual allocated size relative to `pMonitor->m_pixelSize` (read at blit
  time, not a second hardcoded constant), so it stays correct regardless of
  whatever scale `Renderer.cpp` picks.

**Still not proven** — built clean, sanity-checked in the nested-compositor
harness (no crash, no QML errors, idle for several seconds), but not
visually confirmed against a real "something moves behind the dock/Spotlight"
interaction before being swapped into `~/.local/bin/Hyprland-brolli` (same
reasons as the C++ work earlier this session: no way to interact with the
nested window this session). **If this reproduces the black-glass regression
again**, check the `[selfCapScale]` log lines first — they log the FB size
requested/actual and the viewport values at every step, which the two prior
attempts never had.

### Tile-based partial-region regeneration

The pre-existing damage-gating (see "Perf fix 2026-09-14" above) only
decides a binary "regenerate the whole snapshot or skip entirely" — for a
near-fullscreen layer (Spotlight), its bounding box covers almost the whole
monitor, so virtually *any* damage anywhere intersects it and forces a full
snapshot re-render on nearly every real frame the panel is open, regardless
of whether the content actually behind it changed. Measured earlier this
session (see memory `liquid_glass_tile_based_damage_gating`): disabling
`no_self_capture` entirely for Spotlight dropped its GPU cost ~10 percentage
points, because the "protection" was buying almost nothing while still
costing a full render every time.

Fix: `makeSelfCaptureBackgroundFB`/`makeSharedSelfCaptureBackgroundFB` now
take a `dirtyRegionMonitorSpace` parameter (a `CRegion`, monitor pixel
space, default empty). Empty means "full regen" (used for a brand-new
allocation or a demand-resume gap — unchanged from before). Non-empty means
only that region's own bounding box (via `CRegion::getExtents()`, scaled
into the downscaled FB's own coordinate space) gets cleared and redrawn, via
a GL scissor rect (`Render::GL::g_pHyprOpenGL->scissor(box, false)`) scoped
to it — `renderWorkspace` still issues draw calls for the whole scene as
always, but the scissor test discards anything outside the dirty rect,
leaving the framebuffer's existing content there completely untouched.
`renderMonitor()`'s own existing damage-intersection computation
(`pMonitor->m_damage.current().copy().intersect(...)`) is now passed straight
through as this dirty region, instead of being reduced to a boolean.

Only the region's single bounding rect is scissored, not each individual
sub-rect within a scattered damage region — simpler, and still a real win
for the common "one contiguous area changed" case; a damage region spread
across many disjoint areas gets a bounding rect bigger than the true dirty
set, which is a correctness-safe (never under-renders) conservative
approximation, not a bug.

**Also not proven live** — same caveats as the resolution downscale above.
If a partial update looks wrong (stale/torn content in part of a snapshot,
or a persistently-incorrect region that a full regen elsewhere would have
fixed), check the `[tileDamage]` log lines — they log the exact scissor
rect chosen every time, in both monitor and FB space.

Requires a full Hyprland session restart (logout/login) to take effect —
same reason as every other change in this file.

### Crash found and fixed the same evening: scissor(nullptr) after endRender()

The first build of the tile-based damage-gating above **crashed the user's
real, live Hyprland session** (not just Quickshell) — `SIGABRT`, kicking
them back to the login screen, with Hyprland's own crash-recovery
mechanism relaunching in `--safe-mode` automatically. Confirmed via
`~/.cache/hyprland/hyprlandCrashReport*.txt` and
`journalctl -b | grep -i hyprland`, stack trace:

```
handleUnrecoverableSignal
  <- CHyprOpenGLImpl::scissor(const pixman_box32*, bool).cold
  <- IHyprRenderer::makeSelfCaptureBackgroundFB(PHLLS, CRegion)
  <- IHyprRenderer::renderMonitor(PHLMONITOR, bool)
  <- CMonitorFrameScheduler::onFrame()
```

Root cause: both `makeSelfCaptureBackgroundFB` and
`makeSharedSelfCaptureBackgroundFB` called
`Render::GL::g_pHyprOpenGL->scissor(nullptr)` (to disable the scissor rect
again once the partial-region render finished) **after** `endRender()` —
but `scissor()` internally asserts `RASSERT(m_renderData.pMonitor, "Tried
to scissor without begin()!")`, and `endRender()` tears down that render
context first. `setViewport()`, called in the same spot, has no such
assertion and was already safe there (matches the "BGTex scale" precedent,
which also restores its viewport after its own detour) — only `scissor()`
needed to move.

Fixed by moving both `scissor(nullptr)` calls to run **before**
`endRender()`, right after the `m_hiddenForSelfCapture = false` lines,
while the render context set up by `beginFullFakeRender` is still valid.
`setViewport()`'s own restore call is unchanged, still after `endRender()`.

Rebuilt (single-file incremental rebuild, `Renderer.cpp` only, since only
this file changed), swapped into `~/.local/bin/Hyprland-brolli` again —
confirmed via `/proc/<pid>/exe` the session that was already running in
`--safe-mode` post-crash still points at its own old deleted inode,
unaffected.

### Resolution downscale REVERTED 2026-09-18 — third failure, root cause finally found

The crash fix above did stop the abort, but real-world testing (no crash
this time) surfaced the actual visual bug the two ORIGINAL reverted
attempts also hit: **dock and Spotlight glass came back solid black**, and
a dragged desktop widget showed a "zoomed out," wrong-region backdrop (the
dock, screen edges, visible while dragged near the top of the screen). GPU
cost still tracked correctly with the glass effect going live — the render
work was genuinely happening, just landing in the wrong place.

**Root cause, finally identified**: `CHyprOpenGLImpl::scissor()`'s default
overload (`transform=true`, used throughout the NORMAL window/surface
rendering path inside `renderWorkspace`'s own call chain — not anything
this patch calls directly) computes its transform from
`m_renderData.pMonitor->m_transformedSize` **unconditionally** — the real,
full monitor size, with zero awareness that the currently-bound render
target might be smaller. Any window whose own scissor rect, computed in
monitor-pixel-space, falls outside the ACTUAL (smaller, downscaled)
framebuffer's bounds — e.g. anything in roughly the bottom half of the
screen, once downscaled to half size — never gets drawn there at all. Not
corrupted: genuinely never painted, left exactly as the initial
transparent clear left it. Reading from that untouched region later (the
dock sits low on screen) shows solid black; reading from a region that
partially overlapped valid content (a widget near the top) shows something,
just at the wrong place/scale.

This finally explains attempt 2's own unresolved note from the very first
"Perf fix 2026-09-13 (later same day)" section above ("something in
renderWorkspace... doesn't behave as assumed when the target isn't
monitor-sized") — it's specifically `scissor()`'s own transform math, deep
inside the normal render path this patch doesn't control per-call, not
anything fixable from `makeSelfCaptureBackgroundFB`/
`makeSharedSelfCaptureBackgroundFB` themselves.

**Reverted**: `SELF_CAPTURE_RENDER_SCALE` set back to `1.0f` (a no-op —
full monitor size again, matching the behavior every non-downscaled
version of this patch has always had). This is the **third** attempt at
shrinking this render target's resolution, and the third revert — not
worth trying a fourth time without a much deeper change to how `scissor()`
itself computes its transform, which is well outside this patch's own
scope.

**Tile-based damage-gating is unaffected and stays active** — it scissors
(via `Render::GL::g_pHyprOpenGL->scissor(box, false)`, the `transform=false`
overload this patch uses directly, not the problematic default) within a
render target that's genuinely monitor-sized once this constant is back to
1.0, which is exactly the case `scissor()`'s own (unrelated, pre-existing)
transform math already assumes elsewhere — it never hits this problem at
all. This is the part that actually matters for Spotlight's cost, and is
now isolated from the failed downscale idea for an honest test on its own.

Rebuilt clean, swapped into `~/.local/bin/Hyprland-brolli`. **Not yet
confirmed** — needs another logout/login. This time only the tile-based
damage-gating is active; no resolution downscale of any kind. (Tile-based
damage-gating was later found to give no measurable GPU improvement, since
scissoring the output doesn't reduce the actual render work — see the
next section, which removes it in favor of a real resolution downscale.)

## Perf fix 2026-09-18 (later same night): resolution downscale — attempt 4, scoped narrower

Two findings prompted this. First: real-world testing of the tile-based
damage-gating above showed literally zero GPU change from an interaction
expected to exercise it. Root cause: `Render::GL::g_pHyprOpenGL->scissor()`
only limits which pixels get *written* — `renderWorkspace` still traverses
and shades the entire scene regardless of how small the scissor rect is.
The real cost of a self-capture regen is the scene render itself, not the
output area, so a scissored partial redraw saves bandwidth but not the
actual expensive part. Tile-based damage-gating was removed as a result —
not because it was buggy, but because it wasn't earning its keep.

Second: re-examining attempt 3's "scissor() hardcodes monitor size" theory
(the stated reason attempt 3 was reverted) by actually pulling hyprutils'
real source (`git clone --branch v0.14.2 hyprwm/hyprutils`) and reading
`CBox::transform()` directly: for `HYPRUTILS_TRANSFORM_NORMAL` (a normal,
non-rotated monitor — the common case, including the user's own machine),
the function is a complete no-op regardless of the `w`/`h` parameters
passed in. **That theory was wrong.** It was presented confidently without
verifying against real source, which shouldn't have happened — the actual
cause of attempt 3's solid-black-glass bug was never confirmed, and this
section doesn't claim to have found it either.

Given the real cause is still unknown, this attempt is deliberately scoped
to not depend on ever finding it: instead of changing
`m_selfCaptureBackground`'s (the consumer-facing object's) own size — which
is what required `ScreenshareFrame.cpp`'s blit to compensate in every prior
attempt, and is plausibly where whatever broke attempt 3 actually lived —
`m_selfCaptureBackground` now **always stays at full monitor resolution**.
Nothing downstream changes at all; `ScreenshareFrame.cpp`'s blit math is
back to the original, unscaled, pre-any-of-this-work form.

The actual smaller render happens into a new, separate framebuffer,
`m_selfCaptureScratch` (`LayerSurface.hpp`), confined entirely to
`makeSelfCaptureBackgroundFB`/`makeSharedSelfCaptureBackgroundFB`'s own
function bodies:
1. Allocate `m_selfCaptureScratch` at `SELF_CAPTURE_RENDER_SCALE` (0.5) of
   monitor size — same aspect-preserving downscale as before, required for
   `renderWorkspace`'s own aspect-ratio guard.
2. `beginFullFakeRender`/`renderWorkspace`/`endRender` target the scratch
   FB, viewport set/restored exactly as in attempt 3 (that part was never
   the problem, and is unaffected by the wrong-theory correction above).
3. After `endRender()`, a plain `glBlitFramebuffer(..., GL_LINEAR)` stretches
   the scratch FB up into the full-size `m_selfCaptureBackground` — raw GL,
   no `RASSERT`-guarded Hyprland call involved (unlike `scissor()`, which is
   why that one specifically had to run *before* `endRender()` in the crash
   fix earlier), so it's safe to run after the render context is torn down.

If this still produces wrong content, the blast radius is fully contained
to these two functions and the new scratch member — nothing else in the
codebase changed, so there's nowhere else to look.

Built clean, sanity-checked in the nested-compositor harness (no crash, no
errors), swapped into `~/.local/bin/Hyprland-brolli`. **Not yet confirmed**
— needs a fresh logout/login. User has explicitly accepted the risk of a
crash this time in exchange for real forward progress on GPU savings, on
the condition that it stays revertible — reverting means setting
`SELF_CAPTURE_RENDER_SCALE` back to `1.0f` (a one-line change, same as the
attempt-3 revert).

## Perf fix 2026-09-18 (same night, continued): attempt 4 still broken — the REAL root cause, confirmed from source

User confirmed via the nested-compositor test window (which they can
actually observe on their own screen, dragging a desktop widget) that
attempt 4 hits the **exact same bug** as attempt 3 — no crash this time,
but still "black at the bottom of the screen that doesn't exist." Since
attempt 4's whole design point was making `m_selfCaptureBackground` (the
consumer-facing object) always monitor-sized so there'd be nowhere else to
look, the bug had to be coming from something that runs **while rendering
into the smaller scratch FB itself** — a much narrower search space than
before, per the user's own framing.

Explicit instruction for this round: **don't revert, don't guess — find
the actual cause first.** Traced every `setViewport()` call site in the
renderer, then followed `preBlurQueued(pMonitor)` (in
`renderAllClientsForWorkspace`) into `CPreBlurElement`'s dispatch
(`ElementRenderer.cpp`'s `drawPreBlur`) into `preBlurForCurrentMonitor`
(`Renderer.cpp`). Found it:

```cpp
// ElementRenderer.cpp, drawPreBlur:
const auto SAVEDRENDERMODIF = m_renderData.renderModif;
m_renderData.renderModif    = {}; // fix shit
CRegion fakeDamage{0, 0, m_renderData.pMonitor->m_transformedSize.x, m_renderData.pMonitor->m_transformedSize.y};
draw(element, fakeDamage);
...

// Renderer.cpp, preBlurForCurrentMonitor:
const auto blurredTex = blurMainFramebuffer(1, fakeDamage);   // correctly blurs the CURRENT (scratch-sized) FB
auto guard = bindTempFB(m_renderData.pMonitor->resources()->m_blurFB); // persistent, MONITOR-sized, no viewport change
draw(CClearPassElement::SClearData{{0, 0, 0, 0}});             // clears the WHOLE monitor-sized blurFB
draw(CTexPassElement::SRenderData{
    .tex = blurredTex,
    .box = CBox{0, 0, m_renderData.pMonitor->m_transformedSize.x, m_renderData.pMonitor->m_transformedSize.y}, // full monitor box
    .damage = *fakeDamage,
}, *fakeDamage);
```

`drawPreBlur` deliberately zeroes out `renderModif` ("fix shit" — stock
Hyprland's own comment) so the blur precompute is never affected by an
active scale/translate render modifier — because upstream never expected
this to run against anything but a real, full-size monitor render.
`preBlurForCurrentMonitor` then: (1) blurs `m_renderData.currentFB`
correctly — that part respects whatever's actually bound, our scratch FB
included, and was never the problem; (2) `bindTempFB`s over to the
**persistent, monitor-native `m_blurFB`** — confirmed by reading
`bindTempFB`'s real implementation, this is a pure FBO bind/restore, it
never touches the GL viewport; (3) clears that whole monitor-sized buffer
to transparent black; (4) draws the blurred texture into it using a
`{0,0,transformedSize}` box — monitor-scale coordinates.

But the **viewport and projection matrix are still the ones we explicitly
set for the scratch render** (`makeSelfCaptureBackgroundFB`'s own
`setViewport(0,0,SCRATCH_SIZE)`, and `beginFullFakeRender`'s
`setProjectionType(scratchFB->m_size)`, both still active — nothing
restores them until after `endRender()`, well after this runs). So a box
described in full monitor units gets projected through a projection/
viewport calibrated for a canvas half that size: the draw lands
wrong-scaled and clipped into a small corner of `m_blurFB`, leaving the
rest of that monitor-sized, persistent buffer as the transparent black the
clear left it. Any window rendered afterward that live-samples `m_blurFB`
for its own blur-behind-window effect reads mostly stale black, plus a
wrongly-scaled fragment of real content in one corner — exactly the "solid
black" and "zoomed out, wrong region" symptoms reported across every
attempt (1 through 4), because **this mechanism was never touched by any
of the FB-resizing changes those attempts made** — it's triggered by
`preBlurQueued()`, completely independent of which framebuffer the actual
scene render targets.

**Fix**: don't queue `CPreBlurElement` at all when the current render
target isn't monitor-sized — `renderAllClientsForWorkspace`:

```cpp
const bool renderTargetIsMonitorSized = m_renderData.currentFB && m_renderData.currentFB->m_size == pMonitor->m_pixelSize;
if (preBlurQueued(pMonitor) && renderTargetIsMonitorSized)
    m_renderPass.add(makeUnique<CPreBlurElement>());
```

Deliberately scoped to the actual render target's size, not a flag tied to
self-capture specifically — so `makeSnapshotFB`'s existing close-animation
snapshots (which share this same code path but always render at full
monitor size) are completely unaffected; they still get their normal
blur-behind precompute. Skipping it only for a genuinely downscaled render
means anything that would have used `m_blurFB` there falls back to
whatever it already had — visually fine here, since our own QML liquid-
glass shader re-blurs its captured background anyway.

Built clean (`NINJA_EXIT:0`), sanity-checked in the nested-compositor
harness with the widget-drag repro live in it — no crashes, log clean.
Swapped into `~/.local/bin/Hyprland-brolli` (live session's old, deleted
inode confirmed unaffected via `/proc/<pid>/exe`). **Not yet confirmed** —
needs the user to reproduce the widget-drag test again post-swap (nested
window, fast loop) and, separately, a real logout/login to check dock/
Spotlight glass.

If this is *still* wrong after confirming this fix actually took effect:
the next most likely culprit by the same shape of bug is `getBackground()`
(`Renderer.cpp` ~line 1322), which also does a manual viewport
set-then-unconditionally-restore-to-monitor-size around its own temp-FB
detour — but that path is cached (`renderBackground()` only calls it once
per monitor via `if (!pMonitor->m_background)`), so it's a much weaker
candidate for a bug that reproduces on every drag, not just once.

## Perf fix 2026-09-18 (following morning): the demand-gate itself was the real bug, all along

After the blur-precompute fix above still didn't resolve the black/wrong-
region glass, direct correlated logging on BOTH sides of the pipeline
proved the actual root cause — one that predates and is independent of
every resolution-downscale attempt in this file.

**The evidence.** QML's own `SpotlightCaptureService.qml` was given a
`[scsdbg]`-tagged debug log (`cap.hasContent`/`cap.live`/`reg.live`
transitions). Hyprland's own demand-gate (`renderAllClientsForWorkspace`)
was given an unconditional, throttled-to-1/sec `[selfCapDBG]` log of
`Screenshare::mgr()`, `pMonitor->needsACopyFB()`, and the resulting
`selfCaptureDemanded`. With both logs running simultaneously and real
Quickshell instance timestamps to correlate against: QML's own log showed
`cap.live`/`reg.live` toggling `true` repeatedly over a full, continuous
6-second window while Spotlight was open and in active use. During that
*exact* window, confirmed by wall-clock timestamps on both sides, the
Hyprland-side gate **never once observed `needsACopyFB()` return true** —
not once, in dozens of separate test attempts across several logout/login
cycles, several different rebuilds, and even a from-scratch reproduction
after the whole investigation environment had to be rebuilt from zero.

**What this means.** `pMonitor->needsACopyFB()` reflects
`Screenshare::mgr()`'s tracked screencopy *sessions* — built for
`SHARE_MONITOR`/`SHARE_REGION` (screen recorders, video-call sharing,
`xdg-desktop-portal`'s ScreenCast). Quickshell's own `ScreencopyView` (used
internally by `GlassCaptureService.qml`/`SpotlightCaptureService.qml` to
grab "what's behind this layer" for the glass shader) apparently never
registers as one of those tracked sessions — quite possibly because it
uses a different underlying Wayland protocol implementation
(`ext-image-copy-capture-v1`, which exists as a genuinely separate
protocol handler from the older `wlr-screencopy-v1` `CScreenshareManager`
was built around — both protocol files are compiled into this same
Hyprland build, confirming they're separate implementations). Whatever the
precise mechanism, the practical effect since the demand-gate was added
(2026-09-17, see the "Perf fix 2026-09-17" section above) has been: **the
entire self-capture regeneration loop silently stopped running** for every
`no_self_capture`-flagged layer (dock, Spotlight, desktop widgets)
whenever nothing else (an actual external screen share) was also active —
which, for this user, is effectively always.

**Why this explains the actual symptom.** Quickshell's capture services
grab the *whole screen* (`captureSource: perScreen.screen`), including
whatever's on top at the flagged layer's own location — `no_self_capture`
exists specifically to substitute "what's behind this layer" for that
region so the capture isn't self-referential. With regeneration silently
dead, that substitution never refreshes, so the capture of Spotlight's own
on-screen area was self-referential/stale — which reads exactly like
"seeing coordinates that don't exist" or content from the wrong part of
the screen, the symptom reported from the very first report of this bug,
well before any resolution-downscale work started. Every attempt 1
through 4 in this file was debugging correctly-identified-as-broken
resolution-scaling code that, it turns out, was sitting downstream of a
gate that had already made the whole mechanism a no-op.

**The fix** (`renderAllClientsForWorkspace`): reverted the demand-gate
entirely rather than trying to find the "correct" signal for "does
Quickshell's own capture want a frame" —

```cpp
// was: const bool selfCaptureDemanded = Screenshare::mgr() && pMonitor->needsACopyFB();
const bool selfCaptureDemanded = true;
```

Back to the pre-2026-09-17 behavior: regeneration runs for every flagged,
mapped layer, gated only by the 60Hz throttle and the damage-overlap check
(both still fully in place, still doing real work — this reverts only the
demand pre-check, not the other confirmed-working optimizations). The
diagnostic log that proved this bug is left in place permanently
(throttled, cheap) so a future regression here is immediately visible
instead of requiring another multi-hour rediscovery.

Built clean from a fresh clone (the prior scratchpad checkout was lost
mid-session — re-cloned Hyprland at the same commit, `git apply`'d this
same patch file cleanly, confirming the patch itself is portable/
reproducible). Tested with `SELF_CAPTURE_RENDER_SCALE` deliberately held
at `1.0f` (fully inert scratch-FB machinery) to isolate the demand-gate
fix from the resolution-downscale question. Swapped into
`~/.local/bin/Hyprland-brolli`, live session's old inode confirmed
unaffected.

**CONFIRMED FIXED by the user** after a fresh logout/login — Spotlight's
glass no longer shows wrong-region/self-referential content. This closes
out the entire black-glass saga documented across this file: it was never
about resolution scaling at all, just this one dead gate sitting upstream
of everything else that got built and debugged on top of it.

The resolution downscale (`SELF_CAPTURE_RENDER_SCALE`) was re-enabled at
`0.5f` immediately after this confirmation, as its own separate, isolated
step on top of the now-confirmed-working capture pipeline. **The user
confirmed the wrong-region bug came straight back at scale 0.5** — a
clean natural experiment, since it had just been proven fixed at scale
1.0 moments earlier.

**Second blur bug, found immediately after** (`ElementRenderer.cpp`'s
`drawTex`): the demand-gate fix made this path reachable for the first
time all session, surfacing a second, independent bug in the same family
as the `drawPreBlur` one fixed earlier. When a blur-enabled surface isn't
using `blockBlurOptimization`, its "new optimizations" branch samples
`m_renderData.pMonitor->resources()->m_blurFB->getTexture()` directly — a
persistent, monitor-native-sized resource, with zero awareness of what
size the active render target actually is. At scale 1.0 this is harmless
(sizes match by construction, which is exactly why it went undetected
during the isolated test). At any other scratch scale, it's the same
class of bug as `drawPreBlur`, just on the READ side instead of the WRITE
side — that earlier fix only stopped `m_blurFB` from being corrupted
*during* a scratch render, it never stopped *other* surfaces from
sampling it directly during that same render.

**Fix**: force the scale-correct `blockBlurOptimization` path (which
calls `blurMainFramebuffer`, operating on whatever's actually bound right
now) whenever the active render target isn't monitor-sized — mirroring
`drawPreBlur`'s own gating condition exactly:

```cpp
const bool forceScaleCorrectBlur = g_pHyprRenderer->m_bRenderingSnapshot &&
    (!m_renderData.currentFB || m_renderData.currentFB->m_size != m_renderData.pMonitor->m_pixelSize);
if (element->m_data.blockBlurOptimization.value_or(false) || forceScaleCorrectBlur) { ... }
```

Built, swapped, live session's old inode confirmed unaffected. **Not yet
confirmed** — needs a fresh logout/login, then check the glass content is
correct with the downscale active AND that GPU usage actually drops.

## Debug session 2026-09-18 (overnight): screenshot/glass cutoff bug — GPU-side rendering confirmed correct, root cause still open

After the demand-gate and blur fixes above, the user kept seeing a cutoff
bug on both plain screenshots and glass surfaces: content gets progressively
more cut off toward the bottom-right of the screen, worse in `overview`/
Spotlight and plain screenshots than the dock. Both symptoms share a cause:
`quickshell:desktopWidgets` and `quickshell:overview` are BOTH full-screen
anchored layer-shell surfaces (confirmed via `hyprctl layers`:
`xywh: 1920 -360 2880 1800`, the whole monitor) even though their visible
content is only a small fraction of that box — since the `no_self_capture`
splice substitutes a layer's ENTIRE logical box, virtually the whole screen
gets replaced by self-capture-derived content on every screenshot, which
also explains the quality loss (that substituted region is generated via
the 0.5x-downscale-then-GL_LINEAR-upscale pipeline).

**Extensive one-night diagnostic instrumentation** was added to root-cause
this, all in the scratchpad clone (never touched the user's actual desktop
code beyond swapping the built binary):

- Fixed `debug:disable_logs` (defaults `true` in stock Hyprland) via
  `hl.config({ debug = { disable_logs = false } })` in
  `~/.config/hypr/hyprland/general.lua` — without this, none of the
  session's logging was ever reaching disk.
- A dedicated unbuffered log sink in `src/debug/log/Logger.cpp`'s
  `CLogger::log()`: any line containing `[selfCap` is also written straight
  to `/tmp/selfcap_debug.log`, bypassing Hyprland's own buffered file
  logging (which doesn't flush until the buffer fills).
- Frame-correlated logging: a per-call counter (`thisFrame`) in
  `CScreenshareFrame::renderMonitor()` (`ScreenshareFrame.cpp`) tags every
  log/dump from one call so they can be compared within the SAME frame —
  an earlier round of "the splice must be broken" conclusions was
  invalidated by comparing dumps from unrelated, non-contemporaneous calls.
- `glReadPixels`-based PPM dumps at three points: the scratch FB right after
  `endRender()` (moved there after realizing `renderWorkspace()` only
  queues draw calls — the real GL drawing happens inside `endRender()`'s
  own `m_renderPass.render()`), the post-blit consumer-facing buffer, and
  the full capture destination after the entire splice loop finishes for
  one frame.
- `RESULT_COPIED` markers at both `dmabuf`/`shm` copy-success sites,
  confirming `CScreenshareFrame::renderMonitor()` runs continuously at high
  frequency (797 calls measured in one short test) for BOTH plain
  screenshots and Quickshell's own glass captures (same `SHARE_MONITOR`
  session type) — not a single-shot-per-screenshot mechanism as first
  assumed.

**Finding:** a frame-correlated full-frame dump (frame #1176, matched
against its own `FRAME#1176 BLIT ...` log lines) showed COMPLETE, correct
content — the whole desktop, widgets, and background, no cutoff anywhere —
proving the actual GPU-side rendering and splice mechanism are correct at
that point in the pipeline. The remaining bug, if still present, is
downstream of this point (the copy-to-client step) or was an artifact of
comparing mismatched frames earlier in the investigation — not yet
conclusively separated at the point this instrumentation was removed.

**All diagnostic `glReadPixels`/dump code was removed** the same night
(kept only the cheap text `Log::logger` lines, which have no GPU-readback
cost) once the frame-correlated capture confirmed the rendering path
itself: three `glReadPixels`+PPM-write blocks in `Renderer.cpp`, one in
`ScreenshareFrame.cpp`, and a capped-but-still-active per-draw-call
viewport sample in `OpenGL.cpp`'s `renderTextureInternal` — all deleted.
Rationale: a synchronous `glReadPixels` on a full monitor-sized buffer is a
real GPU stall, and doing it repeatedly (even throttled to 2s) was suspect
as either contributing to reported stutter or interacting badly with
whatever runs immediately after in the real capture pipeline; removing it
rules that out before pursuing any further theory downstream.

**Stutter fix, same night**: the pre-existing `[selfCapScale]` log lines
inside `makeSelfCaptureBackgroundFB`/`makeSharedSelfCaptureBackgroundFB`
were UNTHROTTLED — they fire once per self-capture regeneration, which for
a near-fullscreen layer can be up to 60Hz. Confirmed via
`grep -c "\[selfCapScale\]" /tmp/selfcap_debug.log` → 14,136 occurrences in
one test, each an unbuffered/flushed disk write through the dedicated debug
sink above — the likely cause of "stuttery as fuck" reported live. Fixed by
adding a 2-second time-based throttle (same pattern as
`ScreenshareFrame.cpp`'s existing `selfCapLogDetailNow`), gating every
`[selfCapScale]` DEBUG log in both functions plus the one remaining
unthrottled call site in `ScreenshareFrame.cpp`'s blit loop. The two `ERR`-
level lines (dynamic_cast failure — a real bug indicator, not routine
per-frame chatter) are left unthrottled since they should never fire in
practice.

Built clean, swapped into `~/.local/bin/Hyprland-brolli` (live session's old,
deleted inode confirmed unaffected via `/proc/<pid>/exe`). **Not yet
confirmed** — needs a fresh logout/login, then a real screenshot test with
none of the removed diagnostic overhead active, to determine whether the
cutoff bug is still present now that GPU-side rendering is proven correct
and the stutter-causing logging is gone.

## Resolution downscale ABANDONED 2026-09-18 (same night, final) — root cause never found, reverted to inert

The screenshot test above still showed a real artifact — but it turned out
to be a completely different SHAPE of bug than everything chased earlier
this session, once actually looked at closely in the real screenshot file
(not a dump): not a clipped/missing region at all, but a **staircase of
2-3 distinct rectangular steps**, each with its own genuinely-rendered
rounded corner, with text re-wrapped at a different column width in each
step. First guess was a terminal caught mid-resize (a known, compositor-
agnostic artifact when a screenshot lands during an active resize
animation) — user confirmed this was wrong: reproduced on a browser window
too, and nothing was being resized when the screenshot was taken.

**Full verification pass, all before giving up** (every one of these was
checked against either real upstream source or real log/screenshot data
from an actual reproduction, not assumption):

- **Viewport**: a live diagnostic (since removed) logged the actual GL
  viewport at the real draw call, every single self-capture render, for an
  entire test session — 18,266 samples, zero mismatches from the expected
  scratch size.
- **Scissor**: all three `CHyprOpenGLImpl::scissor()` overloads (`CBox&`,
  `pixman_box32*`, `int×4`) confirmed to delegate to the one with the
  `m_bRenderingSnapshot` early-return; traced the actual `glClearBufferfv`
  clear call site (`GLElementRenderer.cpp`) and confirmed it goes through
  the same disable. No raw `glEnable`/`glDisable(GL_SCISSOR_TEST)` call
  anywhere bypasses the shared cache in `setCapStatus`.
- **Projection matrix**: cloned real hyprutils v0.14.2 source
  (`Mat3x3::outputProjection`/`projectBox`) and confirmed the projection is
  always built from the monitor's real, full pixel size (`CMonitor::
  getScaleMatrix()` → `m_projOutputMatrix`, computed once in `updateMatrix()`
  from `m_pixelSize`) — never from whichever framebuffer happens to be
  bound. `getFBProjection` (the one function that DOES take an `fbSize` arg)
  is a no-op for a non-rotated monitor regardless of that arg's value —
  confirmed this monitor is `transform=0` via `hyprctl monitors`.
- **Blit math**: real `BLIT` log lines from an actual reproduction showed
  exact, correct `srcBox`/`destBox` values for both `desktopWidgets`
  (0,0 2880×1800) and `macDock` (0,1622 2880×178).
- **Layer grouping**: added a dedicated log
  (`[selfCapGroup]`) confirming `desktopWidgets` and `macDock` are
  consistently classified as overlapping (correctly forced onto the
  same per-layer render path each one on its own, never incorrectly
  merged into the shared/isolated path) across dozens of samples.
- **Stencil**: found the scratch/background framebuffers have no stencil
  attachment (`createFB()` doesn't add one, unlike `CMonitorResources`'s
  persistent buffers), which could matter for Hyprland's blur-discard path
  (`renderTextureWithBlurInternal`'s `NEEDS_STENCIL` branch) — but this is
  identical at scale 1.0 and 0.5, so it can't be the differentiator for a
  bug that only appears at 0.5. Worth fixing on its own merits some other
  time, not chased further here.
- **The screenshot mechanism itself**: confirmed the user's actual
  screenshot keybind (`Print` → `grim -o <output>`) wraps a
  `CScreencopyFrame` (`Screencopy.cpp`), which itself owns a
  `Screenshare::CScreenshareFrame` — i.e. `grim`'s wlr-screencopy-v1
  captures go through the exact same `renderMonitor()`/splice code as
  Quickshell's own `ext-image-copy-capture-v1`-based glass captures. Not a
  second, unpatched code path — ruled out as an explanation for why the
  artifact shows up in both.

None of this explains the staircase artifact. Every individual mechanism
checks out correct both on paper and against live evidence, yet the bug is
real, reproducible, and scale-dependent (confirmed absent at 1.0, present
at 0.5, via a clean user-run bisection). This is the fourth distinct
downscale attempt to fail in this file, each for what turned out to be
different specific reasons — this one's specific reason was never found.

**Reverted**: `SELF_CAPTURE_RENDER_SCALE` back to `1.0f` — the scratch FB
becomes monitor-sized, so the downscale/upscale blit machinery still runs
every frame but is a geometric no-op (proven clean by the user's own
bisection test earlier the same night). Not removing the machinery itself
(scratch FB, viewport shrink/restore, upscale blit) since it's fully inert
at this constant and ripping it out would just make a future re-attempt
start from zero instead of from this file's own history.

**If picked up again**: don't re-run the same checks above — they're done
and they came back clean. The productive next steps are things that were
explicitly deferred rather than fully explored: reproducing in the nested
dev compositor (`dev/nested-perf-test.sh`) rather than the live session, so
heavier instrumentation (a live `glGetError()` check on the blit, an FBO
completeness check on the scratch FB, or a proper non-lossy pixel dump that
doesn't run on the render thread) can be added without any live-system
stutter risk — the exact thing that made tonight's `glReadPixels`-based
diagnostics too risky to leave in.

## Reapplying after a reboot

`/tmp` doesn't survive a reboot, so if the scratchpad Hyprland checkout is
gone:

```bash
cd /tmp/.../scratchpad   # your session's scratchpad dir
git clone --depth 1 --branch v0.56.2 https://github.com/hyprwm/Hyprland.git
cd Hyprland
git submodule update --init --recursive
git apply /home/Joel/Projects/Brolli-Glass/hyprland-patch/no_self_capture.patch
cmake -DCMAKE_BUILD_TYPE=Release -S . -B build -G Ninja
ninja -C build -j$(nproc)
```

Then atomically swap the binary (never overwrite in place — a session may
be running it):

```bash
cp build/Hyprland ~/.local/bin/Hyprland-brolli.new
chmod +x ~/.local/bin/Hyprland-brolli.new
mv ~/.local/bin/Hyprland-brolli.new ~/.local/bin/Hyprland-brolli
```

The running session keeps using its old (now-deleted) inode until it's
restarted — this is always safe, never blocks on who's currently using it.

## If you change the patch

After editing the checkout, regenerate this file:

```bash
cd /tmp/.../scratchpad/Hyprland
git diff --no-color > /home/Joel/Projects/Brolli-Glass/hyprland-patch/no_self_capture.patch
```

## Consuming it (Hyprland config side)

Gated behind `BROLLI_HYPR_PATCHED=1` (set by the "Hyprland (Brolli custom
build)" login session only) in `~/.config/hypr/custom/rules.lua`, since stock
Hyprland doesn't know this field and errors on it:

```lua
if os.getenv("BROLLI_HYPR_PATCHED") == "1" then
  hl.layer_rule({ match = { namespace = "quickshell:glassTest" }, no_self_capture = true })
  hl.layer_rule({ match = { namespace = "quickshell:overview" }, no_self_capture = true })
end
```
