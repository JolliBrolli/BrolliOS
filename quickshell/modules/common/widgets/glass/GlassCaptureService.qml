pragma Singleton
pragma ComponentBehavior: Bound

import qs
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Wayland

/**
 * One shared full-screen live capture per monitor, reused by every
 * LiquidGlassBackground instance instead of each spinning up its own.
 *
 * Measured cause for building this: adding the bar + 2 desktop widgets to
 * the liquid-glass material (on top of the dock + Spotlight, each already
 * with their own independent ScreencopyView) took idle GPU load from ~32%
 * to ~75-79% — each glass surface was paying for a completely separate
 * full-screen wlr-screencopy capture, even though they're all capturing
 * the SAME screen content. That capture (the actual compositor round-trip
 * + full-res texture) is the expensive, genuinely shareable part; each
 * consumer's own crop region, blur pass and shader stay per-instance here
 * since those are cheap and need different regions/sizes anyway.
 *
 * live per-screen only while at least one registered consumer is actually
 * visible (see registerConsumer/unregisterConsumer) — matches the same
 * "don't pay for it when nothing's using it" pattern already used for
 * GlassTest/the dock, just centralized instead of per-file now.
 *
 * Adaptive pulsing added 2026-09-16, mirroring SpotlightCaptureService's
 * own (proven, measured) design exactly: consumerCounts tracks EXISTENCE
 * (is some consumer around at all, for hasContentFor to mean anything);
 * activeScreens tracks whether a FRESH FRAME is actually wanted right now
 * — the dock's own live-capture used to be a flat "live whenever a
 * floating window is nearby" boolean with zero throttling (same shape
 * Spotlight had before this), a measured constant ~30% GPU. The
 * consuming component (LiquidGlassBackground.qml) now drives setActive
 * with the same settle/idle-pulse/real-motion-signal system already
 * proven there, instead of leaving this capture flatly on.
 */
Singleton {
    id: root

    property var consumerCounts: ({}) // screen.name -> count (existence)
    property var activeScreens: ({})  // screen.name -> true while a fresh frame is actually wanted
    property var captures: ({})       // screen.name -> { reg: ShaderEffectSource, hasContent: bool }

    // CLAUDE/local: crash investigation, 2026-09-17. debugTag (optional,
    // default "") identifies the CALLING instance — every consumer on one
    // monitor logs under the same screenName otherwise, so with 3+ desktop
    // widgets plus the dock all sharing "eDP-1", their calls were
    // indistinguishable. Purely for this investigation; not used for any
    // actual logic.
    function registerConsumer(screenName, debugTag) {
        if (!screenName) {
            console.log("[gcsdbg] registerConsumer", screenName, debugTag ?? "", "@", Date.now());
            return;
        }
        const counts = Object.assign({}, root.consumerCounts);
        counts[screenName] = (counts[screenName] ?? 0) + 1;
        // Logging the count AFTER incrementing — if this is > 1 right when
        // a desktop widget's own registerConsumer fires, that means
        // another consumer (another widget, the dock, etc.) was ALREADY a
        // registered consumer at the same moment, which would point at a
        // multi-consumer race on the shared capture rather than something
        // specific to a single consumer going live in isolation.
        console.log("[gcsdbg] registerConsumer", screenName, debugTag ?? "", "count now:", counts[screenName], "@", Date.now());
        root.consumerCounts = counts;
    }
    function unregisterConsumer(screenName, debugTag) {
        console.log("[gcsdbg] unregisterConsumer", screenName, debugTag ?? "", "@", Date.now());
        if (!screenName || !(screenName in root.consumerCounts))
            return;
        const counts = Object.assign({}, root.consumerCounts);
        counts[screenName] = Math.max(0, (counts[screenName] ?? 0) - 1);
        root.consumerCounts = counts;
    }
    // Consumer drives this directly with its own adaptive rate instead of
    // a flat on/off — see LiquidGlassBackground.qml's own captureLive.
    function setActive(screenName, active, debugTag) {
        console.log("[gcsdbg] setActive", screenName, active, debugTag ?? "", "@", Date.now());
        if (!screenName)
            return;
        const m = Object.assign({}, root.activeScreens);
        if (active)
            m[screenName] = true;
        else
            delete m[screenName];
        root.activeScreens = m;
    }
    function isLive(screenName) {
        return !!root.activeScreens[screenName];
    }
    // The shared full-screen capture texture for this screen — consumers
    // crop THIS with their own sourceRect instead of capturing their own
    // copy of the whole screen. Null until that screen's capture exists
    // (immediate in practice — one per Quickshell.screens entry, created
    // up front, not lazily).
    function sourceFor(screenName) {
        return root.captures[screenName]?.reg ?? null;
    }
    function hasContentFor(screenName) {
        return root.captures[screenName]?.hasContent ?? false;
    }

    Instantiator {
        model: Quickshell.screens

        delegate: Item {
            id: perScreen
            required property var modelData
            readonly property var screen: modelData

            // Real bug (2026-09-16): this screen's ScreencopyView/
            // ShaderEffectSource pair crashed reliably — twice,
            // independently confirmed, 100% reproducible — the first time
            // `live` was set back to true after a real screen lock/unlock
            // cycle. Root cause (best understanding): the real Wayland
            // session-lock protocol restricts screencopy while locked, for
            // genuine security reasons — that's not something our own
            // `live` property controls, Hyprland enforces it regardless,
            // and very likely invalidates the underlying capture session
            // out from under us while locked. Quickshell's own C++ handling
            // of resuming a session that was invalidated externally appears
            // to crash rather than recover — that's below anything a QML
            // property, timer, or delay can reach (confirmed: ordinary
            // live:false->true toggling, which this same adaptive system
            // does constantly during normal idle-pulse operation, is
            // completely safe — it's specifically resuming after this
            // external invalidation that isn't).
            //
            // What DOES work: rebuilding these objects from scratch gets
            // genuinely fresh internal state — the same thing that's
            // already proven safe at real app launch, every time, with no
            // exceptions. So instead of trying to resume the possibly-
            // invalidated session, destroy it and build a new one the
            // instant the lock ends, via a Loader toggle — while nothing is
            // actually live yet (screenLocked forces every consumer's own
            // useLiveCapture false, so this is a genuinely quiet moment,
            // nobody is mid-render against the object being replaced).
            Loader {
                id: captureLoader
                active: true
                onActiveChanged: console.log("[gcsdbg]", perScreen.screen.name, "captureLoader.active ->", active, "@", Date.now())
                onStatusChanged: console.log("[gcsdbg]", perScreen.screen.name, "captureLoader.status ->", status, "@", Date.now())
                sourceComponent: Component {
                    Item {
                        property alias cap: capView
                        property alias reg: regSource

                        ScreencopyView {
                            id: capView
                            captureSource: perScreen.screen
                            visible: false
                            live: root.isLive(perScreen.screen.name)
                            paintCursor: false
                            width: perScreen.screen.width
                            height: perScreen.screen.height
                            onLiveChanged: console.log("[gcsdbg]", perScreen.screen.name, "cap.live ->", live, "window:", capView.Window.window, "@", Date.now())
                            onHasContentChanged: {
                                console.log("[gcsdbg]", perScreen.screen.name, "cap.hasContent ->", hasContent, "@", Date.now());
                                perScreen.publish();
                            }
                            Component.onCompleted: console.log("[gcsdbg]", perScreen.screen.name, "NEW cap ScreencopyView CREATED @", Date.now())
                            Component.onDestruction: console.log("[gcsdbg]", perScreen.screen.name, "OLD cap ScreencopyView DESTROYED @", Date.now())
                        }
                        ShaderEffectSource {
                            id: regSource
                            sourceItem: capView
                            live: root.isLive(perScreen.screen.name)
                            hideSource: true
                            recursive: false
                            visible: false
                            width: perScreen.screen.width
                            height: perScreen.screen.height
                            wrapMode: ShaderEffectSource.ClampToEdge
                            // CLAUDE/local: crash investigation, 2026-09-17
                            // (round 3). This Singleton has no PanelWindow
                            // of its own — regSource only gets a real
                            // QQuickWindow the moment some consumer's OWN
                            // ShaderEffectSource (liveCapReg, in
                            // LiquidGlassBackground.qml, a different file
                            // entirely, possibly in a completely different
                            // PanelWindow) actually grabs it as a
                            // sourceItem. Logging its window identity
                            // (default toString includes a memory address)
                            // on every live change — if this value changes
                            // depending on which consumer (dock vs a
                            // desktop widget, each their own separate
                            // PanelWindow/QQuickWindow) last triggered a
                            // grab, that's the cross-window sharing theory
                            // confirmed.
                            onLiveChanged: console.log("[gcsdbg]", perScreen.screen.name, "reg.live ->", live, "window:", regSource.Window.window, "@", Date.now())
                            Component.onCompleted: console.log("[gcsdbg]", perScreen.screen.name, "NEW reg ShaderEffectSource CREATED, window:", regSource.Window.window, "@", Date.now())
                            Component.onDestruction: console.log("[gcsdbg]", perScreen.screen.name, "OLD reg ShaderEffectSource DESTROYED @", Date.now())
                        }
                    }
                }
                onLoaded: {
                    console.log("[gcsdbg]", perScreen.screen.name, "captureLoader onLoaded @", Date.now());
                    perScreen.publish();
                }
            }
            Connections {
                target: GlobalStates
                function onScreenLockedChanged() {
                    console.log("[gcsdbg]", perScreen.screen.name, "GlobalStates.screenLocked ->", GlobalStates.screenLocked, "@", Date.now());
                    if (GlobalStates.screenLocked)
                        return;
                    console.log("[gcsdbg]", perScreen.screen.name, "REBUILDING capture on unlock @", Date.now());
                    // Clear the shared reference FIRST, before tearing the
                    // old objects down — makes sourceFor()/hasContentFor()
                    // defensively report "not ready" for the brief gap
                    // instead of ever handing out a reference to an object
                    // that's about to be destroyed.
                    const c = Object.assign({}, root.captures);
                    delete c[perScreen.screen.name];
                    root.captures = c;
                    captureLoader.active = false;
                    captureLoader.active = true;
                }
            }

            function publish() {
                console.log("[gcsdbg]", perScreen.screen.name, "publish() called, item exists:", !!captureLoader.item, "@", Date.now());
                if (!captureLoader.item)
                    return;
                const c = Object.assign({}, root.captures);
                c[perScreen.screen.name] = { reg: captureLoader.item.reg, hasContent: captureLoader.item.cap.hasContent };
                root.captures = c;
            }

            Component.onDestruction: {
                console.log("[gcsdbg]", perScreen.screen.name, "perScreen ITEM DESTROYED @", Date.now());
                const c = Object.assign({}, root.captures);
                delete c[perScreen.screen.name];
                root.captures = c;
            }
        }
    }
}
