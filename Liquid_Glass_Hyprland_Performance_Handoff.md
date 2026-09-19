# Liquid Glass on Hyprland — Architecture & Performance Handoff

## Purpose

This document captures the current state of a custom Liquid Glass implementation on Arch Linux + Hyprland + Quickshell, the performance problem discovered during development, and the architectural direction worth investigating next.

The goal is **not** to throw away the existing implementation. The current `.frag`-based effect is already visually successful. The purpose of this document is to give a future coding/reasoning session (including Claude, which already has the project's full implementation context) a clear model of what has been learned and what should be investigated.

---

# 1. Current environment

- Linux
- Arch Linux
- Hyprland
- Quickshell
- end-4 dotfiles
- A fork/customization derived from `openagentisland`, primarily retaining its macOS-like visual styling.
- The agent functionality from that fork was removed.
- Hyprland itself has been forked and modified.

The visual target is Apple's **Liquid Glass** aesthetic.

The implementation is deliberately pushing Hyprland + Quickshell beyond what they were originally designed to do.

---

# 2. What already works

The hard visual problem has essentially been solved.

The current Liquid Glass effect is implemented primarily as a **GLSL `.frag` shader**.

It successfully produces the desired Liquid Glass appearance, including the important visual relationship with the content behind the glass.

This is important:

> The project is no longer primarily a visual-design problem. It is now a rendering architecture and power-efficiency problem.

The existing visual implementation should therefore be treated as a valuable reference implementation rather than something to casually discard.

---

# 3. Why Hyprland had to be modified

Quickshell and Hyprland do not inherently share the same compositor-level understanding that Apple's UI stack can have.

The Liquid Glass effect needs information about the content behind the glass.

A major problem appeared when Quickshell attempted to obtain/process a representation of the screen containing itself.

This created a recursive/self-reflecting problem:

    Hyprland scene
        ↓
    capture/screenshot
        ↓
    Quickshell
        ↓
    Liquid Glass
        ↓
    Quickshell appears in the captured content
        ↓
    capture again
        ↓
    recursion / self-reflection

To work around this, Hyprland's existing privacy/screenshot-related machinery was modified.

The privacy mechanism was effectively repurposed to make a custom form of background capture possible while excluding the relevant Quickshell content.

This was a major breakthrough because it made the visual effect possible at all.

---

# 4. The current performance problem

The current implementation can consume approximately:

**~16 W of additional system power while actively calculating/updating the effect.**

This is severe enough to substantially damage laptop battery life.

When the effect is frozen when no calculation/update is required, power consumption can effectively fall to approximately:

**~0 W additional.**

That observation is extremely important.

It strongly suggests that the existence of the shader itself is not necessarily the dominant problem.

The expensive part may be the **continuous update/capture/render pipeline**.

In other words:

    "Liquid Glass costs 16 W"

may actually be closer to:

    "Continuously obtaining and processing live compositor content for Liquid Glass costs 16 W."

That distinction should guide optimization.

---

# 5. The 480p experiment

The background portion of Liquid Glass was reduced to roughly 480p in an attempt to reduce the amount of information being processed.

The reasoning was:

- The background is heavily blurred/transformed.
- Fine detail in the source image may not be perceptually important.
- Therefore a lower-resolution representation might provide essentially the same visual result for less GPU work.

This is a legitimate optimization direction.

However, resolution is only one variable.

A lower-resolution texture can still be expensive if it is:

- captured continuously,
- copied continuously,
- uploaded continuously,
- processed every frame,
- or causing QML/compositor invalidation every frame.

Therefore the key performance variables should be separated:

1. capture frequency
2. capture resolution
3. pixels captured
4. texture upload frequency
5. shader execution frequency
6. shader pixel count
7. number of blur/sampling passes
8. QML redraw frequency
9. compositor damage/invalidation frequency
10. GPU/CPU synchronization or readback

---

# 6. The important architectural realization

The current implementation is effectively asking a userspace UI layer to obtain a representation of the compositor scene behind itself.

Conceptually:

    Hyprland
       ↓
    screen/background capture
       ↓
    Quickshell
       ↓
    GLSL Liquid Glass shader
       ↓
    final UI

This is fundamentally different from a compositor-integrated material.

A more native architecture would conceptually look like:

    Hyprland compositor
          │
          ├── normal surfaces
          │
          └── glass surface
                  │
                  ↓
          sample underlying scene
                  │
                  ↓
          Liquid Glass material
                  │
                  ↓
             final output

The second architecture potentially avoids treating the compositor's already-existing scene as an external screenshot that must be captured and fed back into another rendering layer.

---

# 7. Why this could be much more efficient

The compositor already knows:

- what surfaces exist,
- their positions,
- which surfaces are underneath another surface,
- which regions have changed,
- the output resolution,
- the current frame,
- the rendering pipeline,
- and the geometry of the glass UI.

A compositor-level implementation could therefore potentially avoid unnecessary work.

Instead of:

    capture entire display
    ↓
    transfer/process image
    ↓
    run shader
    ↓
    display

it could potentially do something closer to:

    identify glass region
    ↓
    use the existing compositor scene
    ↓
    sample only what the glass requires
    ↓
    apply material
    ↓
    composite

This is the major architectural idea to investigate.

---

# 8. The most important optimization target: invalidation

The current frozen behavior provides a particularly useful clue.

If the desktop underneath the glass does not change, the glass generally does not need a new background calculation.

The desired behavior conceptually is:

    static desktop
        ↓
    no relevant damage
        ↓
    no glass recalculation

Whereas:

    window moves behind glass
        ↓
    affected region becomes dirty
        ↓
    update glass only where necessary

This suggests investigating Hyprland's existing damage/dirty-region mechanisms.

The important question is not simply:

> "How can the shader be made cheaper?"

It is:

> **"What causes the glass to update, and can updates be limited to the parts of the scene that actually changed?"**

---

# 9. Resolution vs update rate

These should not be conflated.

Example:

    480p × 144 updates/second

can still be substantially more expensive than:

    1080p × occasional updates

depending on the pipeline.

The first diagnostic task should therefore establish:

- how often the background is captured,
- how often the shader executes,
- how often QML redraws,
- and how much of the screen is processed.

---

# 10. A useful diagnostic matrix

Before rebuilding anything, measure the following separately.

### Test A — Current full implementation

Measure:

- total system power
- GPU utilization
- GPU memory activity if available
- CPU utilization
- capture/update rate

### Test B — Freeze the captured background but continue rendering the shader

Purpose:

Determine whether the shader itself is expensive.

### Test C — Disable the shader but keep background capture active

Purpose:

Determine whether capture/texture transfer is expensive.

### Test D — Keep the shader but reduce source resolution

Try approximately:

- 480p
- 720p
- 1080p

Purpose:

Determine how strongly cost scales with source resolution.

### Test E — Keep resolution fixed but reduce update frequency

Purpose:

Determine whether continuous invalidation is the primary problem.

### Test F — Static desktop vs moving window

Compare:

    static scene
    moving window
    scrolling content
    animations

Purpose:

Determine whether compositor damage could be used to drive updates.

---

# 11. Do not prematurely throw away the current shader

The current `.frag` implementation represents roughly 30–50 hours of work.

It has already solved the difficult visual-design problem.

The next architecture should therefore be treated as a **new rendering backend for the same visual effect**, not necessarily a replacement for the visual work.

The existing shader can potentially remain useful as:

- the visual reference,
- the material logic,
- a source for equations,
- a baseline for comparing new implementations,
- or potentially the actual shader used by a compositor-side implementation.

The goal is to change **where and when the input data is obtained**, not necessarily reinvent the appearance.

---

# 12. A potentially useful decomposition of the material

Liquid Glass should not necessarily be treated as one monolithic expensive operation.

Conceptually it can be decomposed into:

### A. Underlying-content sampling

This is the genuinely scene-dependent component.

### B. Blur / low-frequency background

Potentially cheaper than processing a full-resolution image.

### C. Refraction / distortion

May not require full-resolution information everywhere.

### D. Tint

Can be procedural.

### E. Specular highlights

Can be procedural.

### F. Edge lighting

Can be procedural.

### G. Noise / grain

Can be procedural.

### H. Shadows / surrounding visual effects

Can potentially be generated separately.

This decomposition may allow the expensive scene-dependent data to be minimized while keeping the visually important characteristics of the material.

---

# 13. Apple comparison — important caveat

Apple is the reference visual target, but its exact internal Liquid Glass implementation should not be assumed from external descriptions.

Apple controls:

- the operating system,
- compositor/window-server architecture,
- rendering APIs,
- hardware,
- GPU drivers,
- display pipeline,
- and the UI framework.

Therefore an Apple device can exploit architectural optimizations that are difficult or impossible to reproduce exactly in a userspace Wayland client.

Apple publicly describes Liquid Glass as a system-level material that responds to surrounding content and has rendering/performance mechanisms, but the exact private implementation should not be reverse-engineered from marketing or documentation claims.

The useful takeaway is therefore not:

> "Apple definitely uses technique X."

It is:

> **Apple has system-level access to the scene, whereas this implementation currently has to bridge that gap between Hyprland and Quickshell.**

That is the architectural difference worth exploiting.

---

# 14. The likely long-term direction

A plausible future design would expose something conceptually similar to a native compositor material:

    GlassSurface
        geometry
        corner radius
        blur amount
        distortion
        tint
        opacity
        specular parameters

Quickshell would then describe:

> "There is a glass surface here."

Hyprland would handle:

- scene sampling,
- underlying surfaces,
- damage,
- compositing,
- and potentially the expensive parts of the material.

This would make Quickshell responsible primarily for UI structure rather than acting as an external compositor.

This is a **fundamental architectural change**, but it does not need to happen immediately.

---

# 15. Immediate strategic recommendation

Do not start by rebuilding.

First establish the cost breakdown of the existing implementation.

The decision tree should be:

    Is shader execution itself expensive?
             │
       ┌─────┴─────┐
      yes          no
       │            │
 optimize       Is capture expensive?
 shader              │
                ┌────┴────┐
               yes        no
                │          │
          optimize      investigate
          capture       invalidation/
                        texture transfer

If the dominant cost turns out to be continuous scene capture and invalidation, then the case for moving the glass closer to the compositor becomes much stronger.

---

# 16. The key conceptual shift

The project started as:

> "How do I recreate Apple's Liquid Glass appearance in Linux?"

That problem has effectively been solved.

The next problem is:

> **"How do I make the compositor understand that Liquid Glass is a material rather than a screenshot-based visual effect?"**

That is a different engineering problem.

It is also potentially the path to turning the current 16 W implementation into something practical for daily laptop use.

---

# 17. Handoff summary

Current state:

- Liquid Glass appearance: **working**
- Main visual implementation: **GLSL `.frag`**
- Platform: **Arch + Hyprland + Quickshell**
- Hyprland: **custom fork**
- Background capture: **customized using existing privacy/screenshot-related compositor machinery**
- Major issue: **~16 W while actively calculating/updating**
- Frozen state: **approximately 0 W additional**
- 480p background experiment: **performed**
- Development investment: **approximately 30–50 hours**
- Current priority: **power efficiency without unnecessarily discarding the existing visual implementation**

Core hypothesis:

> The dominant problem may not be the Liquid Glass shader itself. It may be the architecture required to continuously capture and feed compositor content into a separate Quickshell rendering layer.

Potential long-term direction:

> Move scene sampling/material composition closer to Hyprland while retaining the existing shader/material logic as much as possible.

Most important first investigation:

> **Measure exactly what is responsible for the 16 W before changing the architecture.**

---

## One-line handoff for a future coding session

**"The Liquid Glass shader already works; don't redesign the visual effect. The current problem is that Quickshell needs live compositor content to feed the shader, and active updates cost ~16 W. Investigate whether capture/texture transfer/invalidation—not the shader itself—is the dominant cost, then consider moving scene sampling toward Hyprland's compositor while preserving the existing material."**


# 18. HARD SAFETY CONSTRAINTS FOR ANY FUTURE HYPRLAND WORK

This project should be treated as **brain surgery on a running compositor**.

The objective is to experiment with compositor-assisted Liquid Glass **without modifying or destabilizing Hyprland's existing behavior**.

These are hard constraints, not preferences.

## Rule 1 — Never modify existing Hyprland behavior

Do not edit existing Hyprland implementation merely because an existing function/class/path appears convenient.

Do not rewrite, refactor, optimize, rename, or alter existing Hyprland core logic as part of the Liquid Glass work.

If existing code already performs something similar to what the glass subsystem needs, treat it as an **external dependency/interface**, not something to modify.

Prefer:

    new code → existing Hyprland interface/hook

over:

    existing Hyprland code → modified to accommodate new code

If an integration point absolutely requires a change, the change must be the smallest possible adapter/hook and must be justified explicitly before implementation.

## Rule 2 — All Liquid Glass code lives separately

Create a clearly isolated namespace/directory/module for the experimental subsystem.

Conceptually:

    src/
        existing Hyprland code/
        liquid-glass/
            GlassManager.*
            GlassSurface.*
            GlassProvider.*
            GlassRenderer.*
            ...

Names and exact locations should follow the project's conventions, but the architectural principle is strict:

> Liquid Glass code should be additive and independently identifiable.

The subsystem should have as few dependencies on Hyprland internals as reasonably possible.

## Rule 3 — Prefer read-only observation over mutation

When possible, Liquid Glass should **observe/request information from Hyprland**, rather than changing Hyprland state or rendering behavior.

Prefer:

    query existing state
    obtain existing scene information
    request a controlled resource
    render through an isolated path

Avoid:

    changing global renderer state
    changing frame scheduling
    changing damage semantics
    changing cursor behavior
    changing input behavior
    changing surface lifecycle rules
    changing compositor-wide rendering assumptions

## Rule 4 — No touching sensitive subsystems

Unless absolutely unavoidable, the experimental work must not modify:

- cursor rendering
- input/event handling
- frame scheduling
- damage tracking
- surface lifecycle/destruction
- buffer lifecycle
- renderer synchronization
- output management
- window management
- focus handling
- GPU synchronization primitives
- existing blur implementation
- existing screenshot/privacy implementation

If interaction with one of these is required, build a narrow adapter around the existing behavior rather than altering the behavior itself.

## Rule 5 — Baseline Hyprland is mandatory

Before any meaningful modification:

1. Build and run a known-good baseline.
2. Record the exact Hyprland commit/version.
3. Record build configuration/toolchain information.
4. Record GPU/driver information.
5. Record relevant runtime configuration.
6. Establish a baseline test suite.
7. Confirm the baseline passes before introducing Liquid Glass changes.

The baseline should remain available as a known-good comparison point.

Ideally maintain:

    baseline branch/tag
        ↓
    experimental branch
        ↓
    isolated Liquid Glass commits

Never let the only working copy become the experimental copy.

## Rule 6 — Git checkpoints must be extremely granular

Each logical change should be its own commit.

Avoid giant commits such as:

    "implement liquid glass"

Prefer a sequence such as:

    add GlassManager skeleton
    add isolated provider interface
    add test instrumentation
    add read-only compositor integration
    add resource acquisition
    add Quickshell bridge
    ...

This makes regressions bisectable and makes complete removal straightforward.

## Rule 7 — Every integration point needs a rollback path

For every point where the new subsystem touches Hyprland:

- identify the exact existing function/path,
- document what is being hooked,
- document what data crosses the boundary,
- document what state is modified, if any,
- provide a way to disable the integration,
- verify that disabling it restores baseline behavior.

A compile-time or runtime feature flag is strongly preferred.

Conceptually:

    LIQUID_GLASS_ENABLED=0

should leave the compositor behaving as close to baseline as possible.

The exact mechanism should follow Hyprland/project conventions.

## Rule 8 — Test BEFORE compilation where possible

Before compiling any change, perform static/diff-level checks intended to catch accidental modifications.

At minimum:

- inspect the complete git diff,
- verify only intended files changed,
- verify no existing Hyprland implementation was altered unintentionally,
- verify no unrelated formatting/refactoring occurred,
- verify no generated files or build artifacts entered the source diff,
- verify the dependency direction remains isolated.

The desired workflow is:

    edit
      ↓
    inspect diff
      ↓
    automated checks
      ↓
    build
      ↓
    baseline comparison
      ↓
    runtime tests

Not:

    edit
      ↓
    compile
      ↓
    discover what changed

## Rule 9 — Regression tests are mandatory

The compositor should be tested for unrelated behavior after every meaningful integration change.

At minimum, explicitly test:

### Rendering

- normal windows
- fullscreen windows
- multiple monitors
- monitor hotplugging
- resizing
- moving windows
- animations
- transparency
- existing blur
- screenshots/screen capture

### Cursor

- cursor visible
- cursor movement
- cursor changes
- cursor over different surfaces
- cursor at different refresh rates
- cursor while glass is active

The previous observed regression of cursor disappearance makes this particularly important.

### GPU/load

Measure:

- idle GPU usage
- GPU usage while moving the mouse
- GPU usage while moving windows
- GPU usage while glass is static
- GPU usage while glass updates
- power consumption in each state

The previous observed ~50% GPU usage during mouse movement is a known class of regression that must be guarded against.

### Input

- keyboard
- mouse
- touchpad
- focus changes
- pointer movement
- clicking through/around glass
- application interaction

### Frame timing

Check for:

- dropped frames
- stutter
- excessive frame scheduling
- unexpected redraws
- abnormal GPU wakeups
- increased idle power

## Rule 10 — Establish quantitative baselines

Do not rely exclusively on:

> "It feels fine."

Record measurements.

Useful baseline metrics include:

- idle power
- idle GPU utilization
- CPU utilization
- GPU memory usage
- frame rate
- frame time
- redraw/update frequency
- capture frequency
- texture dimensions
- texture upload frequency

The important comparison is:

    baseline Hyprland
          vs
    Hyprland + disabled Glass subsystem
          vs
    Hyprland + active Glass subsystem

If the disabled subsystem differs materially from baseline, stop and investigate before proceeding.

## Rule 11 — Use differential testing

The safest experiment is:

    BASELINE
       │
       ├── test A
       │
       └── experimental
              │
              ├── test A
              └── compare

Tests should be repeatable.

Where practical, automate them rather than relying on visual inspection.

## Rule 12 — Fail closed

If the Liquid Glass subsystem encounters:

- unavailable resources,
- unexpected surface state,
- invalid dimensions,
- GPU/resource errors,
- unsupported output conditions,
- synchronization problems,

the correct behavior should be:

> Disable/fallback the Glass subsystem.

It must **not** compromise the normal compositor.

The normal desktop should survive a Glass failure.

## Rule 13 — No global state unless unavoidable

Avoid introducing global mutable state into Hyprland.

Prefer:

    GlassManager instance
        ↓
    explicitly owned resources
        ↓
    explicitly scoped lifecycle

rather than:

    global GlassState
        ↓
    accessible everywhere

This reduces accidental coupling.

## Rule 14 — No opportunistic refactoring

Do not clean up nearby Hyprland code while implementing Liquid Glass.

No:

- unrelated renames
- formatting migrations
- architecture cleanups
- performance tweaks unrelated to Glass
- "while we're here" changes
- replacing existing abstractions because a new one looks nicer

A boring patch is a safe patch.

## Rule 15 — Keep the experimental subsystem removable

At any point it should be possible to remove the Liquid Glass subsystem by:

1. disabling the feature,
2. reverting the small integration commits,
3. deleting the isolated Glass files,
4. rebuilding,
5. returning to the baseline behavior.

The project should never reach a state where Glass logic is deeply woven throughout Hyprland.

The ideal result is:

    Hyprland
       │
       ├── existing code remains intact
       │
       └── tiny integration boundary
                 │
                 ↓
          Liquid Glass subsystem

## Rule 16 — Treat performance regressions as bugs

A visually successful implementation that causes:

- unexpected GPU usage,
- increased idle power,
- mouse-triggered GPU activity,
- frame pacing problems,
- unnecessary redraws,
- CPU wakeups,
- or battery drain

is not considered successful.

Performance regressions should be investigated before additional features are layered on top.

---

# 19. Recommended development protocol

The following process should be used for the entire experimental phase.

## Phase 0 — Freeze the working implementation

Do not change the existing working Liquid Glass implementation.

Create a tagged/checkpointed state representing the current known-good visual result.

This becomes the visual reference.

## Phase 1 — Capture the baseline

Create a reproducible baseline Hyprland build.

Record:

- commit
- compiler/toolchain
- GPU
- driver
- monitor configuration
- relevant Hyprland configuration
- power measurements
- GPU measurements
- frame behavior

## Phase 2 — Build an empty Glass subsystem

Create the new isolated files/classes with no meaningful compositor behavior.

Compile and run.

The system should behave identically to baseline.

If it doesn't, stop.

## Phase 3 — Add instrumentation

Before optimizing anything, add measurement/instrumentation capable of answering:

> What is causing the 16 W?

Do not guess.

## Phase 4 — Add the smallest possible integration boundary

Introduce only the minimum hook necessary to obtain information/resources from Hyprland.

Do not alter existing rendering logic.

Run the full regression suite.

Compare against baseline.

## Phase 5 — Obtain background information

Only after the integration boundary is proven safe should the subsystem begin obtaining compositor scene information.

Measure:

- source resolution
- capture frequency
- upload frequency
- update regions
- GPU cost

## Phase 6 — Connect the existing shader

Reuse the current `.frag` implementation wherever practical.

Do not redesign the visual effect during the architecture experiment.

The purpose of this phase is to change the **data path**, not the appearance.

## Phase 7 — Investigate incremental updates

If the architecture supports it, investigate:

- damage-aware updates
- region-based updates
- cached background textures
- update-on-change rather than update-every-frame
- lower-resolution background representations
- avoiding unnecessary texture uploads

Each optimization should be independently measurable.

## Phase 8 — Stress testing

Test pathological cases:

- rapidly moving windows
- scrolling
- video playback
- animations
- multiple glass surfaces
- multiple monitors
- monitor refresh-rate differences
- fullscreen applications
- rapid workspace changes
- opening/closing windows
- cursor movement
- screenshots

Watch for unrelated regressions.

## Phase 9 — Battery/power validation

Compare:

    baseline
    current implementation
    new implementation

under identical workloads.

The target is not merely:

> "lower than 16 W."

The target is:

> **minimum additional power while preserving the visual behavior.**

## Phase 10 — Only then consider deeper compositor integration

If the isolated architecture cannot achieve acceptable performance, document exactly why.

Only then should deeper Hyprland integration be considered.

Even at that point, the same constraints remain:

- smallest possible change
- isolated boundary
- baseline comparison
- rigorous regression testing
- easy rollback

---

# 20. Additional engineering rules

These are recommended additions to the core safety rules.

### A. One variable at a time

Do not simultaneously change:

- capture architecture,
- shader,
- resolution,
- update rate,
- and compositor integration.

Change one major variable, measure it, then proceed.

### B. Keep a performance notebook

For each experiment record:

    commit:
    change:
    GPU usage:
    power:
    frame time:
    update rate:
    visual result:
    regressions:

This prevents optimization from becoming guesswork.

### C. Keep visual and performance acceptance criteria separate

A change can be:

    visually better + slower
    visually identical + faster
    visually worse + faster
    visually better + faster

The project should explicitly record both dimensions.

### D. Never optimize based on one machine measurement

Power consumption is affected by:

- GPU
- driver
- display refresh rate
- compositor configuration
- background applications
- power state
- laptop firmware
- browser/video activity
- external monitors

Repeat measurements under controlled conditions.

### E. Preserve a known-good escape hatch

Always be able to boot/run the baseline configuration without the experimental subsystem.

Do not make the experimental branch the only path to a working desktop.

---

# 21. Core architectural principle

The guiding principle for the project should be:

> **Add capability; do not alter existing capability.**

Hyprland should remain Hyprland.

The Liquid Glass work should ideally be a small, isolated extension that uses carefully selected interfaces into the compositor.

The closer the implementation gets to:

    "Hyprland + an isolated Glass subsystem"

rather than:

    "Hyprland modified throughout to understand Glass"

the safer and more maintainable the project becomes.

---

# 22. What success looks like

Success is not simply reproducing the Apple visual effect.

The complete success criteria are:

1. Existing Liquid Glass appearance is preserved.
2. Active power consumption is dramatically reduced from the current ~16 W.
3. Static Glass remains effectively idle.
4. Normal Hyprland behavior is unchanged when Glass is disabled.
5. No cursor/input/frame/damage regressions are introduced.
6. The Glass subsystem can be disabled independently.
7. The Glass subsystem can be removed without a major Hyprland rewrite.
8. The implementation remains understandable and maintainable.
9. Performance is measured rather than assumed.

The ideal end state is a **small experimental extension around Hyprland**, not a permanently mutated Hyprland core.

---

# 23. Instructions to the coding/reasoning agent

When working on this project:

**Do not start coding immediately.**

First:

1. inspect the existing repository,
2. understand the current Liquid Glass implementation,
3. map the current data flow,
4. identify the exact source of the background texture,
5. identify update/invalidation behavior,
6. identify all existing Hyprland modifications,
7. establish the baseline,
8. propose the smallest safe integration boundary,
9. define tests and measurements,
10. only then implement.

The agent should explicitly state:

- what existing files it intends to modify,
- why each modification is necessary,
- what new files it intends to add,
- what existing Hyprland behavior could theoretically be affected,
- how that behavior will be tested,
- how the change will be reverted.

If an approach requires broad modifications to Hyprland core, stop and redesign the approach before implementation.

**No "while we're here" refactors. No broad renderer rewrites. No speculative optimization of unrelated code.**

The current Liquid Glass shader is valuable and should be preserved as the visual reference throughout the experiment.

---

# 24. Final mental model

This project should now be thought of as three layers:

    ┌───────────────────────────────────────┐
    │           Quickshell UI              │
    │                                       │
    │  layout / interaction / Glass object  │
    └───────────────────┬───────────────────┘
                        │
                        │ isolated interface
                        ↓
    ┌───────────────────────────────────────┐
    │       Liquid Glass subsystem          │
    │                                       │
    │  capture/provider/cache/instrumentation│
    │  existing .frag material              │
    └───────────────────┬───────────────────┘
                        │
                        │ narrow, carefully tested
                        ↓
    ┌───────────────────────────────────────┐
    │             Hyprland                  │
    │                                       │
    │       EXISTING CORE — PROTECTED       │
    │                                       │
    │  renderer / cursor / input / damage   │
    │  scheduling / surfaces / outputs      │
    └───────────────────────────────────────┘

The bottom layer should be considered **protected infrastructure**.

The middle layer is where experimentation belongs.

The top layer remains the UI/visual implementation.

The project is successful when the middle layer can obtain what it needs from the bottom layer through a narrow interface without forcing the bottom layer to change how it fundamentally works.

EXTREMELY USEFUL PROJECT THAT HAS NOT BEEN EXPLORED YET: ShojiWM. copy the repo and read the source code, its not exactly what we want but it could give us a very good idea on what to do inside of hyprland itself.

piece of advice ive learnt on shoji. capture padding must be atleast as large as the pixel your shader reaches for. blur and refraction both sample outside the visual box. if the padding is smaller than the reach, the edges clamp and you get a smeered shreaks that look like a driver bug but they are not.
