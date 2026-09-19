pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland

/**
 * Reusable liquid-glass material — the same capture/refract/blur pipeline
 * already used by Spotlight, the dock and GlassTest, factored out so a new
 * surface is a drop-in `anchors.fill: parent` instead of ~80 lines of
 * hand-copied capture/shader wiring per file.
 *
 * Usage: place as the FIRST child of the item that should look like glass,
 * with `anchors.fill: parent` and `screen:` set to that item's ShellScreen.
 * The shader draws the ENTIRE visible shape itself (superellipse SDF, AA
 * edge) — remove any existing background Rectangle/border on the caller,
 * the same way Spotlight/the dock don't have one either.
 *
 * Requires the item this fills to live inside a PanelWindow that spans the
 * TRUE full monitor (anchored top/bottom/left/right, real global (0,0),
 * same convention as Background.qml/GlassTest.qml) — position is computed
 * by walking the parent chain, which only lines up with the live capture's
 * own coordinate space under that convention.
 *
 * Needs `no_self_capture` layer-rule coverage for the layer this ends up
 * inside (see ~/.config/hypr/custom/rules.lua) or it will self-reflect.
 *
 * The actual full-screen capture is SHARED across every instance of this
 * component via GlassCaptureService (one wlr-screencopy capture per
 * monitor, not one per glass surface) — see that file for why. This
 * component registers/unregisters itself as a consumer while visible; the
 * shared capture only stays live while at least one consumer needs it.
 */
Item {
    id: root

    // CLAUDE/local: crash investigation, 2026-09-17. Every debug log in
    // this file is tagged with screenName alone, which is IDENTICAL across
    // every consumer on the same monitor (dock, bar, every desktop widget,
    // Spotlight) — with 3+ separate desktop widget instances all sharing
    // one screen, their log lines are indistinguishable from each other or
    // from the dock's. This tag disambiguates which physical component
    // instance produced a given line, purely for this investigation.
    readonly property string instanceTag: Qt.md5("" + Date.now() + Math.random()).slice(0, 6)

    required property var screen
    // Refract the STATIC WALLPAPER FILE instead of a live screen capture —
    // for a surface that only ever sits behind other content (desktop
    // widgets, on WlrLayer.Bottom: anything actually in front of one would
    // occlude it in the real compositor output anyway, so a live capture
    // there was paying full self-capture-pipeline cost to show something
    // that's provably always just the wallpaper). No ScreencopyView, no
    // GlassCaptureService registration, no no_self_capture layer rule
    // needed at all in this mode — genuinely free of the live pipeline,
    // not just cheaper.
    // Can be a plain bool OR a reactive binding — unlike every other
    // consumer of this component (which sets this once and never touches
    // it again), the dock drives it live off whether a floating window is
    // currently near it. onStaticWallpaperChanged below exists specifically
    // for that case.
    property bool staticWallpaper: false

    // CLAUDE/local: crash investigation, 2026-09-17 — resolved. Desktop
    // widgets segfaulted (nested QSGRhiLayer::grab() reentrancy) 100% of
    // the time on the very first live activation. Root-caused via window-
    // identity logging: GlassCaptureService's shared capture item gets
    // attached to whichever PanelWindow's scenegraph first renders it —
    // the dock, its only real consumer since that service was built, so
    // the shared item lives in the DOCK's window. A desktop widget is a
    // genuinely separate PanelWindow (its own QQuickWindow) trying to grab
    // that same item — Qt Quick's ShaderEffectSource/layer machinery isn't
    // safe across two different top-level windows' render contexts, which
    // is what actually crashed, not anything about drag timing, geometry,
    // consumer counts, or the source-identity swap pattern (all tried and
    // ruled out first). Confirmed directly: logged window addresses
    // differed between the shared item (dock's window) and the widget
    // (its own window) at the exact moment of the crash.
    //
    // Set true for a consumer whose live capture must NOT go through the
    // shared cross-window service — gives it its own independent
    // ScreencopyView/ShaderEffectSource pair instead (see ownCapView/
    // ownCapReg below), scoped to its own window, at the cost of losing
    // the sharing optimization while live. Only desktop widgets need this
    // today (MacDock.qml and everything else share one window with
    // GlassCaptureService's actual owner, the dock, and are unaffected).
    property bool useOwnCapture: false

    // Extra Y correction for a caller whose own window ISN'T anchored to
    // the true full monitor (top+bottom+left+right) — e.g. the dock, which
    // only anchors bottom+left+right so wlr-layer-shell's exclusiveZone
    // keeps working (see MacDock.qml's own windowScreenYOffset). Leave at
    // 0 for a caller that already spans the full monitor.
    property real yOffset: 0

    // Corner radius cap, independent of this item's own w/h — leave at the
    // default (effectively uncapped/"fully round on the short axis") unless
    // this surface specifically needs a small fixed radius regardless of
    // how tall it gets (see Spotlight's own spotlightMaxCornerRadius for
    // why that one needed its own override).
    property real cornerRadiusOverride: Config.options.appearance.liquidGlass.maxCornerRadius

    readonly property real glassRadius: Math.min(root.width, root.height) / 2
    readonly property real glassPad: Math.max(Config.options.appearance.liquidGlass.pad, glassRadius * 0.6)

    // Walk the parent chain to this window's own root — every read here is
    // a plain QML property read (x/y/parent), so it's genuinely reactive,
    // and a top-level Item has no QML parent so the loop naturally stops at
    // this window's own local origin, matching ScreencopyView's own
    // per-output capture space. (mapToItem(null, ...) looks equivalent but
    // its internal position reads do not reliably re-trigger this binding
    // when an ancestor moves — a known QML limitation.)
    function computeWindowLocalPos(item) {
        let x = 0, y = 0, cur = item;
        while (cur) {
            x += cur.x;
            y += cur.y;
            cur = cur.parent;
        }
        return Qt.point(x, y);
    }
    readonly property point glassPos: {
        const p = computeWindowLocalPos(root);
        return Qt.point(p.x, p.y + root.yOffset);
    }
    // Kept from the crash investigation above (glassPos churn turned out
    // NOT to be the cause — see useOwnCapture's comment for the real one —
    // but per standing instruction, debug logs stay in once added.
    onGlassPosChanged: console.log("[lgbdbg]", root.screenName, root.instanceTag, "glassPos ->", root.glassPos.x, root.glassPos.y, "showLive:", root.showLive, "liveCapSettling:", root.liveCapSettling, "@", Date.now())
    readonly property real glassTexW: root.width + glassPad * 2
    readonly property real glassTexH: root.height + glassPad * 2

    readonly property string screenName: root.screen ? root.screen.name : ""

    // Registers/unregisters this instance as a consumer of the shared
    // per-monitor capture (see GlassCaptureService) purely by visibility —
    // onXChanged does not fire for the initial value during construction,
    // so onCompleted/onDestruction cover the start/end of life and
    // onVisibleChanged covers everything in between, with no double-count.
    Component.onCompleted: {
        // CLAUDE/local: crash investigation, 2026-09-17 (round 3). Baseline
        // window identity at creation time, to compare against the
        // showLive-time reading — see onShowLiveChanged's own comment.
        console.log("[lgbdbg]", root.screenName, root.instanceTag, "onCompleted, window:", root.Window.window, "@", Date.now());
        console.log("[lgbdbg]", root.screenName, root.instanceTag, "INITIAL wallpaperImgW/H ->", root.wallpaperImgW, root.wallpaperImgH, "coverScale:", root.wallpaperCoverScale, "scaledW/H:", root.wallpaperScaledW, root.wallpaperScaledH, "glassTexW/H:", root.glassTexW, root.glassTexH, "glassPos:", root.glassPos.x, root.glassPos.y, "staticWallpaper:", root.staticWallpaper, "@", Date.now());
        if (!root.staticWallpaper && root.visible) {
            // useOwnCapture consumers never touch the shared service at
            // all — ownCapView's own live binding is fully self-contained
            // (see useOwnCapture's comment above liveCapReg).
            if (!root.useOwnCapture)
                GlassCaptureService.registerConsumer(root.screenName, root.instanceTag);
            // Mirrors the Component.onDestruction fix (2026-09-16) — a
            // freshly (re)created instance that's already live on its very
            // first binding evaluation (e.g. the dock's layer reopening
            // after a screen unlock while a window is still overlapping
            // it) never gets an onStaticWallpaperChanged signal to react
            // to (no signal fires for an initial value), so it needs the
            // same explicit catch-up registerConsumer above already gets.
            root.requestCaptureActive(root.liveCaptureActive);
        }
        wallpaperSizeProc.running = true;
    }
    Component.onDestruction: {
        // Real bug (2026-09-16): this only ever called unregisterConsumer,
        // never setActive(false) — unregisterConsumer just tracks whether a
        // consumer EXISTS (existence), but the shared capture's actual
        // live/idle state is separately driven by activeScreens (see
        // GlassCaptureService.setActive). If this instance is destroyed
        // while it happened to be active (e.g. Hyprland closing/reopening
        // this layer entirely across a screen lock/unlock, not just a
        // visibility toggle this component's own bindings ever see), the
        // shared capture's "active" flag for this screen was never
        // cleared — it stayed live forever, orphaned, tied to nothing,
        // and a freshly (re)created instance registering on top of that
        // already-leaked live state is a real candidate for exactly the
        // "same item on different windows" crash class hit repeatedly this
        // session. Whatever the reason this instance is going away, make
        // sure the shared capture is told to stop wanting fresh frames for
        // it — same as the visible:false branch below.
        if (!root.staticWallpaper && root.visible && !root.useOwnCapture) {
            GlassCaptureService.unregisterConsumer(root.screenName, root.instanceTag);
            GlassCaptureService.setActive(root.screenName, false, root.instanceTag);
        }
    }
    onVisibleChanged: {
        if (root.visible)
            root.recoverVisibility();
        if (root.staticWallpaper || root.useOwnCapture)
            return;
        if (root.visible) {
            GlassCaptureService.registerConsumer(root.screenName, root.instanceTag);
        } else {
            GlassCaptureService.unregisterConsumer(root.screenName, root.instanceTag);
            GlassCaptureService.setActive(root.screenName, false, root.instanceTag);
        }
    }
    // Real bug (2026-09-16): confirmed via logging that a screen lock/
    // unlock does NOT destroy/recreate this component at all — Hyprland
    // force-unmaps every layer-shell surface in the shell during lock
    // (not just glass ones — screenCorners, menubar, background, this
    // component's every instance, all of it) and remaps them all on
    // unlock, and root.visible above reflects that. Confirmed via logging:
    // all 4 LiquidGlassBackground instances (the dock + every desktop
    // widget) got visible:false then visible:true within ~1ms of each
    // other across one real lock/unlock cycle — a real, sudden "several
    // different windows all need to redo real GPU work at the same
    // instant" collision, the exact shape already documented elsewhere in
    // this file as dangerous (see the comment above everSettled). Since
    // this is driven by the compositor unmapping/remapping surfaces
    // directly — not something any layer_rule or QML-side flag controls —
    // working around the collision instead of avoiding the trigger:
    // stagger each instance's own wallpaper-settle re-trigger with a small
    // per-instance random jitter, so four windows recovering from the same
    // compositor event don't all redo their own image-decode/shader-render
    // work in the exact same tick.
    readonly property real recoveryJitterMs: Math.random() * 400
    Timer {
        id: visibilityRecoveryTimer
        interval: root.recoveryJitterMs
        onTriggered: {
            console.log("[timerdbg]", root.screenName, "visibilityRecoveryTimer fired @", Date.now());
            root.wallpaperSettling = true;
            wallpaperSettleTimer.restart();
        }
    }
    function recoverVisibility() {
        visibilityRecoveryTimer.restart();
    }
    // staticWallpaper flipping at runtime (the dock does this — see its own
    // useLiveCapture) needs the SAME register/unregister treatment as
    // visibility does above; every other consumer sets this once at
    // creation and never touches it again, so this never used to matter.
    //
    // Also drives liveCapSettling below: switching to live capture doesn't
    // mean liveCapReg already HAS a rendered frame — its own `live` flag
    // only just turned true this same instant, and it needs at least one
    // real frame render of the (already-live) shared capture through its
    // own crop/hblur chain before its texture is actually valid. Switching
    // glassShaderEffect.source to it immediately showed a blank/black frame
    // for that gap. Same grace-period shape as wallpaperSettling: hold the
    // still-valid static content on screen for a short window after
    // flipping to live, then cut over once the live chain has had time to
    // render. Going the other way (live -> static) needs no such delay —
    // wallpaperReg/staticCapReg never stopped being ready.
    onStaticWallpaperChanged: {
        console.log("[lgbdbg]", root.screenName, root.instanceTag, "staticWallpaper ->", root.staticWallpaper, "visible:", root.visible, "@", Date.now());
        if (!root.visible)
            return;
        if (root.staticWallpaper) {
            if (!root.useOwnCapture) {
                GlassCaptureService.unregisterConsumer(root.screenName, root.instanceTag);
                GlassCaptureService.setActive(root.screenName, false, root.instanceTag);
            }
            root.liveCapSettling = false;
        } else {
            if (!root.useOwnCapture)
                GlassCaptureService.registerConsumer(root.screenName, root.instanceTag);
            root.liveCapSettling = true;
            liveCapSettleTimer.restart();
            // Also (re)start the adaptive live-rate settle window — just
            // switched to live, so start at full rate rather than
            // whatever it happened to be left at.
            root.captureSettling = true;
            captureSettleTimer.restart();
            root.requestCaptureActive(root.liveCaptureActive);
        }
    }
    // See onStaticWallpaperChanged above for why this exists.
    property bool liveCapSettling: false
    Timer {
        id: liveCapSettleTimer
        // See unlockRecovering below for why this needs to be longer right
        // after a screen unlock.
        interval: root.unlockRecovering ? 3000 : 120
        onTriggered: {
            console.log("[timerdbg]", root.screenName, "liveCapSettleTimer fired @", Date.now());
            root.liveCapSettling = false;
        }
    }
    // What's actually shown right now — staticWallpaper flips instantly to
    // static, but only flips to live once the settle window above clears.
    readonly property bool showLive: !root.staticWallpaper && !root.liveCapSettling

    // ---- Adaptive ("VRR-style") live rate — added 2026-09-16 ----
    // Ports the SAME mechanism already proven on Spotlight (SearchWidget.qml)
    // to the dock's own live-capture path: while `!staticWallpaper`, this
    // used to be a flat, unthrottled "live whenever showing live" boolean
    // (a measured constant ~30% GPU whenever a floating window was
    // nearby, regardless of whether it was actually moving) — the exact
    // same shape Spotlight had before this session's work. Reuses the
    // SAME global motion signals already proven working there, rather
    // than inventing a second detection mechanism:
    //   - settling: full rate for a short grace period after switching to
    //     live, or after any real Hyprland event (window moved/resized/
    //     opened/closed nearby) — see onRawEvent below.
    //   - idlePulse: a low fixed-rate pulse (~1Hz) once settled, so a
    //     slow ambient change still eventually shows through.
    //   - captureDragActive: GlobalStates.mouseDragActive (real button
    //     hold) || trackpadGestureActive (3-finger gesture move) ||
    //     (superDown && pointerMoving) (tap-then-drag — the actual normal
    //     way this user drags windows, confirmed this session; a real
    //     button/tap event alone misses the continuation of the drag).
    property bool captureSettling: true
    Timer {
        id: captureSettleTimer
        // See unlockRecovering below for why this needs to be longer right
        // after a screen unlock.
        interval: root.unlockRecovering ? 3000 : 500
        onTriggered: {
            console.log("[timerdbg]", root.screenName, "captureSettleTimer fired @", Date.now());
            root.captureSettling = false;
        }
    }
    property bool captureIdlePulse: false
    Timer {
        id: captureIdlePulseTimer
        interval: 1000
        running: root.showLive && !root.captureSettling
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            console.log("[timerdbg]", root.screenName, "captureIdlePulseTimer fired @", Date.now());
            root.captureIdlePulse = true;
            captureIdlePulseResetTimer.restart();
        }
    }
    Timer {
        id: captureIdlePulseResetTimer
        interval: 60
        onTriggered: {
            console.log("[timerdbg]", root.screenName, "captureIdlePulseResetTimer fired @", Date.now());
            root.captureIdlePulse = false;
        }
    }
    readonly property bool captureDragActive: GlobalStates.mouseDragActive || GlobalStates.trackpadGestureActive || (GlobalStates.superDown && GlobalStates.pointerMoving)
    // CLAUDE/local, 2026-09-17: none of GlobalStates' three motion signals
    // above can ever see a desktop widget dragging ITSELF — mouseDragActive/
    // trackpadGestureActive are driven by external scripts watching real
    // Hyprland-level window drags (a widget moving is a plain QML Item
    // position change inside one PanelWindow, not a compositor-level window
    // move, so nothing external ever fires for it), and pointerMoving alone
    // isn't used without superDown also held. Result: dragging a widget
    // without holding Super fell through to the ~1x/sec, ~60ms-wide
    // idlePulse the whole time instead of getting continuous "settling"-
    // rate refreshes — reported as the backdrop updating at an "arythmic,
    // almost random" cadence while actively dragging. This is a generic
    // escape hatch a consumer can drive directly with its OWN interaction
    // state instead of only Hyprland-visible motion signals (see
    // DesktopWidget.qml's own use of it).
    property bool extraCaptureActive: false
    onExtraCaptureActiveChanged: {
        console.log("[lgbdbg]", root.screenName, root.instanceTag, "extraCaptureActive ->", root.extraCaptureActive, "@", Date.now());
        root.reArmCaptureSettle();
    }
    // Drives liveCapReg/liveHBlurReg below — ANDed with showLive there, so
    // this only ever matters once already in live mode; staticWallpaper
    // mode is completely untouched by any of this.
    readonly property bool liveCaptureActive: root.captureSettling || root.captureIdlePulse || root.captureDragActive || root.extraCaptureActive
    // Drives the SHARED capture's own fresh-frame pulsing (GlassCaptureService's
    // activeScreens, set 2026-09-16) — mirrors SearchWidget.qml's
    // onCaptureLiveChanged: SpotlightCaptureService.setActive(...) exactly.
    // Without this, GlassCaptureService.isLive() (now activeScreens-based,
    // not consumerCounts-based) never goes true and the shared capture
    // never actually renders a frame.
    //
    // requestCaptureActive (2026-09-16), not a direct GlassCaptureService
    // .setActive call: extending the settle timers below (unlockRecovering)
    // only delays when THIS component starts trusting/displaying the
    // capture — it does nothing to delay the underlying cap.live flip
    // itself, which is what actually asks Hyprland/Quickshell to establish
    // a fresh wlr-screencopy session. The crash this session hit happens on
    // exactly that first post-unlock activation, so the activation itself
    // (not just the display of its result) needs to be delayed while
    // recovering — centralized here so every call site (this handler,
    // onStaticWallpaperChanged, Component.onCompleted) gets it for free
    // instead of each needing its own copy of the same check.
    function requestCaptureActive(active) {
        // useOwnCapture consumers never touch the shared service — their
        // own ownCapView.live binding is fully self-contained and reactive
        // already, no imperative activation call needed at all.
        if (root.useOwnCapture)
            return;
        if (root.unlockRecovering && active) {
            liveActivationDelayTimer.pendingActive = active;
            liveActivationDelayTimer.restart();
        } else {
            liveActivationDelayTimer.stop();
            GlassCaptureService.setActive(root.screenName, active, root.instanceTag);
        }
    }
    Timer {
        id: liveActivationDelayTimer
        interval: 800
        property bool pendingActive: false
        onTriggered: {
            console.log("[timerdbg]", root.screenName, root.instanceTag, "liveActivationDelayTimer fired, activating:", pendingActive, "@", Date.now());
            GlassCaptureService.setActive(root.screenName, pendingActive, root.instanceTag);
        }
    }
    onLiveCaptureActiveChanged: {
        console.log("[lgbdbg]", root.screenName, "liveCaptureActive ->", root.liveCaptureActive, "@", Date.now());
        root.requestCaptureActive(root.staticWallpaper ? false : root.liveCaptureActive);
    }
    Connections {
        target: GlobalStates
        function onMouseDragActiveChanged() { console.log("[lgbdbg]", root.screenName, "GlobalStates.mouseDragActive ->", GlobalStates.mouseDragActive, "@", Date.now()); root.reArmCaptureSettle(); }
        function onTrackpadGestureActiveChanged() { console.log("[lgbdbg]", root.screenName, "GlobalStates.trackpadGestureActive ->", GlobalStates.trackpadGestureActive, "@", Date.now()); root.reArmCaptureSettle(); }
        function onPointerMovingChanged() { console.log("[lgbdbg]", root.screenName, "GlobalStates.pointerMoving ->", GlobalStates.pointerMoving, "@", Date.now()); root.reArmCaptureSettle(); }
        function onSuperDownChanged() { console.log("[lgbdbg]", root.screenName, "GlobalStates.superDown ->", GlobalStates.superDown, "@", Date.now()); root.reArmCaptureSettle(); }
    }
    function reArmCaptureSettle() {
        if (!root.showLive)
            return;
        if (!root.captureDragActive) {
            // A drag-ish signal just ended — settle briefly for one clean
            // final frame instead of an abrupt cut to the idle pulse.
            root.captureSettling = true;
            captureSettleTimer.restart();
        }
    }
    // Any real Hyprland event while live — a window moving/resizing/
    // opening/closing nearby. Same exclusion list SearchWidget.qml uses
    // (screencastv2 excluded alongside screencast — a real bug found this
    // session: missing it let our OWN capture's start/stop notifications
    // re-arm themselves in a self-feeding loop).
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (!root.showLive)
                return;
            if (["openlayer", "closelayer", "screencast", "screencastv2"].includes(event.name))
                return;
            console.log("[lgbdbg]", root.screenName, "Hyprland event while live:", event.name, "@", Date.now());
            root.captureSettling = true;
            captureSettleTimer.restart();
        }
    }

    // Static-wallpaper source: a monitor-sized reconstruction of the
    // wallpaper FILE (not a capture of anything on screen), geometrically
    // matched to how the REAL wallpaper renderer (modules/ii/background/
    // Background.qml) actually places it — plain `Image.PreserveAspectCrop`
    // here was NOT the same thing: Background.qml computes an exact cover
    // scale from the image's true pixel dimensions (via `magick identify`,
    // same as here) and then applies an extra `parallax.workspaceZoom`
    // zoom on top (1.01 by default) — PreserveAspectCrop's own built-in
    // scale-to-cover has no idea about that extra zoom. At the same fixed
    // screen coordinates (the dock's own position, near the bottom edge),
    // sampling a slightly-less-zoomed reconstruction vs. the real,
    // slightly-more-zoomed rendered wallpaper picks a genuinely different
    // source pixel — a small, constant, one-directional offset. This was
    // the real cause of a visible vertical "shift" when the dock switched
    // between static and live capture of the exact same plain wallpaper.
    // Replicating Background.qml's own cover+zoom+center math (with
    // parallax itself ignored — this only needs to match the wallpaper's
    // RESTING position, and workspace/sidebar parallax are both off by
    // default; revisit if parallax is ever enabled) makes this pixel-
    // accurate instead of approximate.
    Process {
        id: wallpaperSizeProc
        property string path: Config.options.background.wallpaperPath
        command: ["magick", "identify", "-format", "%w %h", path]
        stdout: StdioCollector {
            id: wallpaperSizeCollector
            onStreamFinished: {
                const parts = wallpaperSizeCollector.text.trim().split(" ").map(Number);
                if (parts.length === 2 && parts[0] > 0 && parts[1] > 0) {
                    root.wallpaperImgW = parts[0];
                    root.wallpaperImgH = parts[1];
                }
            }
        }
    }
    // Reasonable defaults (assume the file already covers the screen 1:1)
    // until the real dimensions above arrive — mirrors Background.qml's
    // own initial values, avoiding a zero-size/NaN image in the meantime.
    property real wallpaperImgW: root.screen ? root.screen.width : 1920
    property real wallpaperImgH: root.screen ? root.screen.height : 1080
    onScreenChanged: wallpaperSizeProc.running = true
    onWallpaperImgWChanged: console.log("[lgbdbg]", root.screenName, root.instanceTag, "wallpaperImgW/H ->", root.wallpaperImgW, root.wallpaperImgH, "coverScale:", root.wallpaperCoverScale, "scaledW/H:", root.wallpaperScaledW, root.wallpaperScaledH, "screenW/H:", root.wallpaperScreenW, root.wallpaperScreenH, "@", Date.now())
    onWallpaperImgHChanged: console.log("[lgbdbg]", root.screenName, root.instanceTag, "wallpaperImgW/H ->", root.wallpaperImgW, root.wallpaperImgH, "coverScale:", root.wallpaperCoverScale, "scaledW/H:", root.wallpaperScaledW, root.wallpaperScaledH, "screenW/H:", root.wallpaperScreenW, root.wallpaperScreenH, "@", Date.now())

    readonly property real wallpaperScreenW: root.screen ? root.screen.width : 1920
    readonly property real wallpaperScreenH: root.screen ? root.screen.height : 1080
    // Same formula as Background.qml's minSuitableScale * parallaxRation —
    // "cover" scale (fills both dimensions, may overshoot one) plus the
    // same extra zoom factor.
    readonly property real wallpaperCoverScale: Math.max(
        root.wallpaperScreenW / root.wallpaperImgW,
        root.wallpaperScreenH / root.wallpaperImgH
    ) * Config.options.background.parallax.workspaceZoom
    readonly property real wallpaperScaledW: root.wallpaperImgW * root.wallpaperCoverScale
    readonly property real wallpaperScaledH: root.wallpaperImgH * root.wallpaperCoverScale

    // Frame sized exactly to the monitor — real screen (0,0) lands at this
    // item's own (0,0), matching the crop math below, same requirement the
    // old direct Image had.
    Item {
        id: wallpaperFrame
        visible: false
        width: root.wallpaperScreenW
        height: root.wallpaperScreenH

        Image {
            id: wallpaperImg
            source: Config.options.background.wallpaperPath
            asynchronous: true
            cache: true
            fillMode: Image.Stretch // size below is already the exact, correctly-scaled target — no extra fit/crop needed
            // Decode directly at final display size instead of native
            // resolution — same effective sharpness as the real renderer,
            // without decoding (and holding in VRAM) more than that.
            sourceSize.width: Math.round(root.wallpaperScaledW)
            sourceSize.height: Math.round(root.wallpaperScaledH)
            width: root.wallpaperScaledW
            height: root.wallpaperScaledH
            // Centered — parallax.enableWorkspace/enableSidebar are both
            // off by default, which is what makes Background.qml's own
            // fraction math collapse to a plain center (see comment above).
            x: (root.wallpaperScreenW - root.wallpaperScaledW) / 2
            y: (root.wallpaperScreenH - root.wallpaperScaledH) / 2
        }
        Timer {
            id: settledCheckTimer
            interval: 3000
            running: true
            onTriggered: console.log("[lgbdbg]", root.screenName, root.instanceTag, "SETTLED CHECK (3s later) wallpaperImg actual w/h:", wallpaperImg.width, wallpaperImg.height,
                                      "status:", wallpaperImg.status, "root.wallpaperImgW/H:", root.wallpaperImgW, root.wallpaperImgH, "root.wallpaperCoverScale:",
                                      root.wallpaperCoverScale, "root.wallpaperScaledW/H:", root.wallpaperScaledW, root.wallpaperScaledH, "@", Date.now())
        }
    }
    // Grace period after the image decode reports Ready, rather than
    // freezing the capture chain the INSTANT status flips. Two real
    // problems with keying live purely off status===Ready directly:
    // (1) property-binding evaluation and the scene graph's actual
    // rendered pixel content aren't perfectly synchronized frame-to-frame
    // through a chain of ShaderEffectSources — the capture that fires the
    // same frame status flips can still be a half-settled/transitional
    // frame, not the final decoded image (reported as "catches some frame
    // but the wrong one"). (2) changing wallpaperImg.source to a DIFFERENT
    // file (the user picking a new wallpaper) doesn't reliably re-arm a
    // pure status check either. Staying live for a fixed window after ANY
    // relevant change — a Ready transition OR the source path itself
    // changing — gives the whole chain several real frames to converge on
    // the correct, final content before freezing, and explicitly re-arms
    // on a wallpaper swap instead of depending on status timing alone.
    property bool wallpaperSettling: true
    // Real reported bug (2026-09-14): on a genuinely fresh boot (not just a
    // quickshell restart), the dock's static texture sometimes comes back
    // solid black/stale, fixed only by manually restarting quickshell — a
    // full restart works because by then the GPU driver/shader pipeline is
    // already warmed up from the previous run. Likely cause: cold-boot
    // GPU/shader-compile warmup taking longer than the 500ms grace window
    // below, so the capture chain freezes on a still-transitional frame
    // before it's actually converged. Fixed with a LONGER window only for
    // the very first settle (this component's own Component.onCompleted,
    // below) — later re-settles (wallpaper swapped, geometry changed) keep
    // the short 500ms, since the GPU is already warm by then. Deliberately
    // NOT tied to any broadcast/multi-window signal (e.g. screen lock) —
    // that approach was tried and reverted after a real crash; this is
    // purely local per-instance startup timing, same shape as every other
    // trigger already proven safe here.
    //
    // The real screen-lock/unlock re-arm (2026-09-16) below follows the
    // same "no broadcast" rule differently: it's OPT-IN per instance
    // (unlockRecoveryEnabled, default false/no-op) rather than a shared
    // Connections block every LiquidGlassBackground instance would react to
    // identically — only MacDock.qml turns it on, so desktop widgets never
    // go through this at all, and only ONE window's worth of GPU work
    // happens on unlock, not every glass consumer's at once.
    property bool everSettled: false
    Timer {
        id: wallpaperSettleTimer
        interval: (!root.everSettled || root.unlockRecovering) ? 3000 : 500
        onTriggered: {
            console.log("[timerdbg]", root.screenName, "wallpaperSettleTimer fired @", Date.now());
            root.wallpaperSettling = false;
            root.everSettled = true;
        }
    }
    // Opt-in screen-lock/unlock recovery — see the comment above
    // everSettled for why this is scoped per-instance instead of a shared
    // signal every consumer reacts to. Real reported bug: the dock's
    // texture (static wallpaper reconstruction, or the live capture if it
    // happened to already be live) came back solid black after a
    // suspend/resume cycle (lock screen, close the lid, reopen it) —
    // same root cause as the cold-boot bug above (GPU/shader pipeline
    // resources invalidated by the underlying suspend, converging on a
    // still-transitional frame before the normal short settle window
    // elapses), just triggered by unlock instead of startup. Reuses the
    // exact same "longer grace window, once" shape already proven safe for
    // that case, applied to all three settle timers (wallpaper, live-cap,
    // adaptive-rate) for a single bounded window after unlock, rather than
    // trying to guess which one specifically needs it.
    // STICKY, not time-based (2026-09-16 redesign) — the first attempt
    // deployed a fixed 3-second timer, which is the wrong shape: real
    // testing showed the actual crash isn't near unlock itself (unlocking
    // alone, or even opening Spotlight right after, was fine) — it's
    // specifically the dock's FIRST static-\>live transition after a lock
    // cycle, whenever that actually happens, which could easily be well
    // outside any fixed window (the user unlocked, tested Spotlight, THEN
    // moved a window near the dock — by then a 3s timer would already have
    // expired, silently disarming the very protection meant to cover this
    // exact case). Likely cause: the underlying wlr-screencopy session for
    // the shared capture (GlassCaptureService) needs to be considered
    // "possibly disrupted" by the session-lock protocol (which exists
    // specifically to restrict screen capture while locked) until the
    // dock's live capture is actually exercised for real again — not just
    // "for a few seconds after unlock". So this now stays armed
    // indefinitely from unlock until showLive genuinely goes true once,
    // however long that takes, then clears itself.
    property bool unlockRecoveryEnabled: false
    property bool unlockRecovering: false
    Connections {
        target: GlobalStates
        enabled: root.unlockRecoveryEnabled
        function onScreenLockedChanged() {
            console.log("[lgbdbg]", root.screenName, "(dock) GlobalStates.screenLocked ->", GlobalStates.screenLocked, "@", Date.now());
            if (GlobalStates.screenLocked)
                return;
            root.unlockRecovering = true;
            root.wallpaperSettling = true;
            wallpaperSettleTimer.restart();
        }
    }
    onShowLiveChanged: {
        // CLAUDE/local: crash investigation, 2026-09-17 (round 3). Every
        // other hypothesis (geometry churn, multi-consumer race, zero
        // size, source-identity swap on the downstream ShaderEffect) has
        // been ruled out or fixed without effect — still crashes 100% of
        // the time right after this line, same stack trace every time.
        // New theory: GlassCaptureService is a Quickshell `Singleton`
        // (see its own file) — a bare, WINDOW-LESS root object. Its
        // per-screen ShaderEffectSource (liveCapReg's sourceItem) is
        // created once up front, with no PanelWindow of its own, and only
        // gets attached to a real QQuickWindow's scenegraph the first
        // time something actually grabs it. The dock has been that first
        // grabber, constantly, since launch — every desktop widget is a
        // COMPLETELY SEPARATE PanelWindow (its own QQuickWindow) trying to
        // grab that SAME shared item for the first time. Logging window
        // identity (default toString includes a memory address) to see if
        // the widget's window really differs from whichever window last
        // grabbed the shared source — this print itself doesn't touch
        // GlassCaptureService's internals, purely observational.
        console.log("[lgbdbg]", root.screenName, root.instanceTag, "showLive ->", root.showLive,
            "window:", root.Window.window, "@", Date.now());
        if (root.showLive)
            root.unlockRecovering = false;
    }
    Connections {
        target: wallpaperImg
        function onStatusChanged() {
            if (wallpaperImg.status === Image.Ready) {
                root.wallpaperSettling = true;
                wallpaperSettleTimer.restart();
            }
        }
        function onSourceChanged() {
            root.wallpaperSettling = true;
            wallpaperSettleTimer.restart();
            // Wallpaper file swapped — re-query its real dimensions too,
            // since wallpaperCoverScale is only valid for the PREVIOUS
            // file's pixel size otherwise.
            wallpaperSizeProc.running = true;
        }
    }
    // Also re-arm when the real geometry (from magick identify) arrives or
    // changes — wallpaperScaledW/H flipping moves/resizes wallpaperImg
    // inside wallpaperFrame, same kind of transitional-frame risk as the
    // status/source changes above.
    onWallpaperScaledWChanged: { root.wallpaperSettling = true; wallpaperSettleTimer.restart(); }
    onWallpaperScaledHChanged: { root.wallpaperSettling = true; wallpaperSettleTimer.restart(); }
    // Also re-arm on screen unlock — a real, reported bug: after a
    // suspend/resume cycle (lock screen, close the lid, reopen it), the
    // static wallpaper texture came back solid black instead of the
    // wallpaper, needing an unrelated live-capture trigger (e.g. moving a
    // window near the dock) to "accidentally" fix it. This is a frozen
    // (live:false) GPU texture, deliberately not re-rendered per-frame for
    // the GPU savings — a real suspend cycle can invalidate cached GPU
    // resources entirely, and nothing else would ever tell a frozen node
    // to re-render after that. Screen unlock is the best available signal
    // for "the display/GPU just came back" (hypridle locks before/during
    // suspend on this system, so unlock correlates with resume) without
    // needing a dedicated system suspend/resume hook.
    // A re-arm on screen unlock (to fix a real reported bug: the frozen
    // static wallpaper texture coming back black after a suspend/resume
    // cycle) was tried and REVERTED 2026-09-14 alongside the mouseDragActive
    // change above, after a real crash on the user's live session. This
    // component is shared across MULTIPLE separate top-level windows (the
    // dock, desktop widgets) — even without a literally shared texture,
    // broadcasting the SAME re-arm signal to all of them at once means
    // several different windows' render threads all start heavy GPU work
    // (image decode, ShaderEffectSource re-render) simultaneously, which
    // is the same general "everyone goes live at once across different
    // windows" shape that already crashed this shell once before this
    // session (see the git history around GlassCaptureService). Not
    // confirmed as the actual cause of this particular crash (the crash
    // stack trace pointed more directly at the mouseDragActive IPC path),
    // but reverted out of caution rather than leave two suspects live on
    // a real desktop. The wake-from-sleep black-dock bug is still real and
    // unfixed — revisit scoped to a single consumer/window at a time.
    readonly property bool wallpaperLive: wallpaperImg.status !== Image.Ready || root.wallpaperSettling

    ShaderEffectSource {
        id: wallpaperReg
        sourceItem: wallpaperFrame
        live: root.wallpaperLive
        hideSource: true
        recursive: false
        visible: false
        width: root.screen ? root.screen.width : 1920
        height: root.screen ? root.screen.height : 1080
    }

    // Downsample-before-blur, matching Apple's own documented Liquid Glass
    // technique: capture small, blur cheap, upscale on display — rather
    // than capturing/blurring at full native resolution the whole way
    // through. Only the crop + blur STORAGE size shrinks here; every
    // shader UNIFORM (texSize, radiusPx, panelSize, pad, etc. — see
    // glassShaderEffect below) stays bound to the real/logical glassTexW/
    // glassTexH throughout, unchanged. This works because GLSL texture
    // sampling is UV-based (0-1, resolution-independent by definition) —
    // toTex()/sampleBlurred() in the main shader convert a real-pixel
    // offset into a UV fraction using the LOGICAL size, then sample
    // whatever texture is bound at that UV coordinate; the GPU's own
    // bilinear filtering handles the rest regardless of how many texels
    // that texture actually has stored. Shrinking storage only reduces
    // the actual pixel-shader work for the crop + both blur passes (the
    // most expensive remaining stages) — it does not require touching a
    // single uniform value or the shader source itself.
    readonly property int glassCaptureDownsample: 2
    readonly property real glassCropW: Math.max(1, Math.round(root.glassTexW / root.glassCaptureDownsample))
    readonly property real glassCropH: Math.max(1, Math.round(root.glassTexH / root.glassCaptureDownsample))

    // Two FULLY SEPARATE crop stages, each with a FIXED (never-switching)
    // sourceItem, rather than one stage whose sourceItem swaps between the
    // two at runtime. That swap is what actually broke this: a
    // ShaderEffectSource with live:false doesn't reliably perform a fresh
    // capture just because its sourceItem changed — it can keep showing
    // whatever it last had (observed as the dock freezing on old live
    // content after switching back to static). Only the plain ShaderEffect
    // at the very end (glassShaderEffect, a normal reactive Item, not a
    // capture-semantics node) is safe to switch dynamically — see its
    // source/sourceHBlur below. Every consumer that never changes
    // staticWallpaper after creation (every one except the dock) never
    // exercised this switch at all, which is why it went unnoticed until
    // something actually toggled it live.
    ShaderEffectSource {
        id: staticCapReg
        sourceItem: wallpaperReg
        // Same grace-period condition as wallpaperReg — chained one level
        // down, so this can't freeze on a stale/transitional capture
        // either.
        live: root.wallpaperLive
        hideSource: true
        recursive: false
        visible: false
        width: root.glassCropW
        height: root.glassCropH
        sourceRect: Qt.rect(root.glassPos.x - root.glassPad, root.glassPos.y - root.glassPad, root.glassTexW, root.glassTexH)
        wrapMode: ShaderEffectSource.ClampToEdge
    }
    // CLAUDE/local: crash investigation fix, 2026-09-17. Own independent
    // live capture, used instead of GlassCaptureService's shared
    // cross-window item when root.useOwnCapture is true — see that
    // property's own comment for the root cause this works around.
    // Mirrors GlassCaptureService's own capView exactly (same
    // ScreencopyView setup, same full-screen size — liveCapReg below still
    // does the actual cropping via sourceRect), just scoped to THIS
    // consumer's own window instead of shared across every window. Gated
    // identically to liveCapReg's own live below, so an idle/static
    // consumer (the common case — most desktop widgets sit still) pays
    // nothing extra for this; only active while genuinely live.
    ScreencopyView {
        id: ownCapView
        captureSource: root.screen
        visible: false
        live: root.useOwnCapture && root.visible && !root.staticWallpaper && root.liveCaptureActive
        paintCursor: false
        width: root.screen ? root.screen.width : 1920
        height: root.screen ? root.screen.height : 1080
    }
    ShaderEffectSource {
        id: liveCapReg
        // Constant per-instance (useOwnCapture never changes after
        // creation for any given consumer), so this isn't the kind of
        // runtime sourceItem identity swap that's unsafe elsewhere in this
        // file — it only ever evaluates to one branch for the whole
        // lifetime of a given instance.
        sourceItem: root.useOwnCapture ? ownCapView : GlassCaptureService.sourceFor(root.screenName)
        live: root.visible && !root.staticWallpaper && root.liveCaptureActive
        hideSource: true
        recursive: false
        visible: false
        width: root.glassCropW
        height: root.glassCropH
        sourceRect: Qt.rect(root.glassPos.x - root.glassPad, root.glassPos.y - root.glassPad, root.glassTexW, root.glassTexH)
        wrapMode: ShaderEffectSource.ClampToEdge
    }

    // Separable blur, horizontal half (see liquidglasshblur.frag) — pre-
    // blurs the crop once so the main shader's own vertical pass only
    // needs a 1D loop, instead of a full 9x9 (81-tap) 2D loop. Two separate
    // fixed chains again, same reasoning as the crop stages above. Same
    // downsampled storage size as the crop above — texSize/radiusPx below
    // deliberately stay at the LOGICAL (full) size, not glassCropW/H; see
    // the big comment above glassCaptureDownsample for why that's correct.
    ShaderEffect {
        id: staticHBlurEffect
        visible: false
        width: root.glassCropW
        height: root.glassCropH
        property var source: staticCapReg
        property vector2d texSize: Qt.vector2d(root.glassTexW, root.glassTexH)
        property real radiusPx: Math.max(Config.options.appearance.liquidGlass.blurPx, Config.options.appearance.liquidGlass.frostBlur)
        fragmentShader: Qt.resolvedUrl("liquidglasshblur.frag.qsb")
    }
    ShaderEffectSource {
        id: staticHBlurReg
        sourceItem: staticHBlurEffect
        live: root.wallpaperLive
        hideSource: true
        recursive: false
        visible: false
        width: root.glassCropW
        height: root.glassCropH
        wrapMode: ShaderEffectSource.ClampToEdge
    }
    ShaderEffect {
        id: liveHBlurEffect
        visible: false
        width: root.glassCropW
        height: root.glassCropH
        property var source: liveCapReg
        property vector2d texSize: Qt.vector2d(root.glassTexW, root.glassTexH)
        property real radiusPx: Math.max(Config.options.appearance.liquidGlass.blurPx, Config.options.appearance.liquidGlass.frostBlur)
        fragmentShader: Qt.resolvedUrl("liquidglasshblur.frag.qsb")
    }
    ShaderEffectSource {
        id: liveHBlurReg
        sourceItem: liveHBlurEffect
        live: root.visible && !root.staticWallpaper && root.liveCaptureActive
        hideSource: true
        recursive: false
        visible: false
        width: root.glassCropW
        height: root.glassCropH
        wrapMode: ShaderEffectSource.ClampToEdge
    }

    // Ready as soon as the wallpaper decode finishes (static mode, or still
    // settling into live — see showLive above) or the live capture (shared
    // per-monitor via GlassCaptureService, or this instance's own — see
    // useOwnCapture) has a real frame — keyed off showLive rather than
    // staticWallpaper directly so this matches what's actually selected
    // below, not what's merely been requested.
    readonly property bool glassReady: root.showLive
        ? (root.useOwnCapture ? ownCapView.hasContent : GlassCaptureService.hasContentFor(root.screenName))
        : wallpaperImg.status === Image.Ready
    onGlassReadyChanged: console.log("[lgbdbg]", root.screenName, root.instanceTag, "glassReady ->", root.glassReady, "showLive:", root.showLive, "@", Date.now())

    // For AdaptiveGlassText/AdaptiveGlassSymbol consumers (see that file) —
    // "whatever texture is currently actually backing the glass", so a
    // caller doesn't need to know about this component's own static/live
    // duality. Mirrors glassShaderEffect's own source selection exactly.
    readonly property var currentBackdropTexture: root.showLive ? liveHBlurReg : staticHBlurReg

    // CLAUDE/local: crash investigation, 2026-09-17. Desktop widgets
    // segfaulted (nested QSGRhiLayer::grab() reentrancy, native, deep
    // inside libQt6Quick.so) 100% reliably at the exact moment showLive
    // flipped true — confirmed via extensive logging to NOT be about drag
    // geometry churn (crash happens on the click alone, before any
    // movement), NOT a multi-consumer race (consumer count logged as
    // exactly 1 at the crash moment), and NOT a zero-size edge case
    // (logged width/height were legitimate, e.g. 482x813).
    //
    // What's left: this used to be ONE ShaderEffect whose `source`/
    // `sourceHBlur` properties swapped IDENTITY at runtime between the
    // static and live chains (`root.showLive ? liveCapReg : staticCapReg`),
    // on the stated assumption that this was safe because a plain
    // ShaderEffect (unlike a ShaderEffectSource) has no "one-time capture"
    // semantics to break. But this file's OWN history already found and
    // fixed the identical bug class ONE level up: staticCapReg/liveCapReg
    // above are two fully separate, NEVER-swapping ShaderEffectSources
    // specifically because "a ShaderEffectSource with live:false doesn't
    // reliably perform a fresh capture just because its sourceItem
    // changed" (see that comment). The dock exercises this exact
    // static<->live swap constantly without ever crashing — but it's been
    // doing so since launch, at a small, simple, unchanging geometry;
    // every desktop widget hits it for the very first time, at a
    // different size, and reliably crashes. That "safe to switch
    // dynamically" assumption on the downstream ShaderEffect is what's
    // actually failing.
    //
    // Fixed the same way as the level above: two fully separate,
    // non-swapping ShaderEffect instances (all shader uniforms duplicated
    // verbatim between them — QML has no clean way to share a property set
    // across two ShaderEffect instances without a separate base component
    // file, and this mirrors the crop/hblur duplication already
    // established in this same file), switched between via `visible`
    // instead of a source-identity swap.
    ShaderEffect {
        id: staticGlassShaderEffect
        anchors.fill: parent
        visible: root.glassReady && !root.showLive
        blending: true

        readonly property color tintColor: Appearance.m3colors.darkmode ? Config.options.appearance.liquidGlass.tint : "#FFFFFF"
        readonly property color baseColor: Appearance.colors.colLayer0
        readonly property color textThemeColor: Appearance.colors.colOnLayer0

        property var source: staticCapReg
        property var sourceHBlur: staticHBlurReg
        property vector2d panelSize: Qt.vector2d(root.width, root.height)
        property vector2d texSize: Qt.vector2d(root.glassTexW, root.glassTexH)
        property real pad: root.glassPad
        property real power: Config.options.appearance.liquidGlass.power
        property real maxCornerRadius: root.cornerRadiusOverride
        property real fPower: Config.options.appearance.liquidGlass.fPower
        property real fa: Config.options.appearance.liquidGlass.fa
        property real fb: Config.options.appearance.liquidGlass.fb
        property real fc: Config.options.appearance.liquidGlass.fc
        property real fd: Config.options.appearance.liquidGlass.fd
        property real rimGap: Config.options.appearance.liquidGlass.rimGap
        property real refractStrength: Config.options.appearance.liquidGlass.refractStrength
        property real rimHighlightStrength: Config.options.appearance.liquidGlass.rimHighlightStrength
        property real rimHighlightWidth: Config.options.appearance.liquidGlass.rimHighlightWidth
        property real rimDiagonalReach: Config.options.appearance.liquidGlass.rimDiagonalReach
        property real chromaticAberration: Config.options.appearance.liquidGlass.chromaticAberration
        property real blurPx: Config.options.appearance.liquidGlass.blurPx
        property real frostBlur: Config.options.appearance.liquidGlass.frostBlur
        property vector4d base: Qt.vector4d(baseColor.r, baseColor.g, baseColor.b, 1)
        property vector4d textColor: Qt.vector4d(textThemeColor.r, textThemeColor.g, textThemeColor.b, 1)
        readonly property real lightModeFloorBoost: 1.4
        property real baseOpacity: Config.options.appearance.liquidGlass.baseOpacity * (Appearance.m3colors.darkmode ? 1.0 : lightModeFloorBoost)
        property real minFloor: Config.options.appearance.liquidGlass.minFloor * (Appearance.m3colors.darkmode ? 1.0 : lightModeFloorBoost)
        property real busynessStrength: Config.options.appearance.liquidGlass.busynessStrength
        property vector4d tint: Qt.vector4d(tintColor.r, tintColor.g, tintColor.b, Config.options.appearance.liquidGlass.tintStrength)
        property real frostSaturation: Config.options.appearance.liquidGlass.frostSaturation
        property real frostDarken: Config.options.appearance.liquidGlass.frostDarken

        fragmentShader: Qt.resolvedUrl("liquidglasstest.frag.qsb")
    }
    ShaderEffect {
        id: liveGlassShaderEffect
        anchors.fill: parent
        visible: root.glassReady && root.showLive
        blending: true

        readonly property color tintColor: Appearance.m3colors.darkmode ? Config.options.appearance.liquidGlass.tint : "#FFFFFF"
        readonly property color baseColor: Appearance.colors.colLayer0
        readonly property color textThemeColor: Appearance.colors.colOnLayer0

        property var source: liveCapReg
        property var sourceHBlur: liveHBlurReg
        property vector2d panelSize: Qt.vector2d(root.width, root.height)
        property vector2d texSize: Qt.vector2d(root.glassTexW, root.glassTexH)
        property real pad: root.glassPad
        property real power: Config.options.appearance.liquidGlass.power
        property real maxCornerRadius: root.cornerRadiusOverride
        property real fPower: Config.options.appearance.liquidGlass.fPower
        property real fa: Config.options.appearance.liquidGlass.fa
        property real fb: Config.options.appearance.liquidGlass.fb
        property real fc: Config.options.appearance.liquidGlass.fc
        property real fd: Config.options.appearance.liquidGlass.fd
        property real rimGap: Config.options.appearance.liquidGlass.rimGap
        property real refractStrength: Config.options.appearance.liquidGlass.refractStrength
        property real rimHighlightStrength: Config.options.appearance.liquidGlass.rimHighlightStrength
        property real rimHighlightWidth: Config.options.appearance.liquidGlass.rimHighlightWidth
        property real rimDiagonalReach: Config.options.appearance.liquidGlass.rimDiagonalReach
        property real chromaticAberration: Config.options.appearance.liquidGlass.chromaticAberration
        property real blurPx: Config.options.appearance.liquidGlass.blurPx
        property real frostBlur: Config.options.appearance.liquidGlass.frostBlur
        property vector4d base: Qt.vector4d(baseColor.r, baseColor.g, baseColor.b, 1)
        property vector4d textColor: Qt.vector4d(textThemeColor.r, textThemeColor.g, textThemeColor.b, 1)
        readonly property real lightModeFloorBoost: 1.4
        property real baseOpacity: Config.options.appearance.liquidGlass.baseOpacity * (Appearance.m3colors.darkmode ? 1.0 : lightModeFloorBoost)
        property real minFloor: Config.options.appearance.liquidGlass.minFloor * (Appearance.m3colors.darkmode ? 1.0 : lightModeFloorBoost)
        property real busynessStrength: Config.options.appearance.liquidGlass.busynessStrength
        property vector4d tint: Qt.vector4d(tintColor.r, tintColor.g, tintColor.b, Config.options.appearance.liquidGlass.tintStrength)
        property real frostSaturation: Config.options.appearance.liquidGlass.frostSaturation
        property real frostDarken: Config.options.appearance.liquidGlass.frostDarken

        fragmentShader: Qt.resolvedUrl("liquidglasstest.frag.qsb")
    }
}
