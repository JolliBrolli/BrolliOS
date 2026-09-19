pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

/**
 * Spotlight's OWN dedicated full-screen live capture per monitor — same
 * structure as GlassCaptureService (see that file's own comment for why a
 * window-less Singleton/Instantiator-scoped ScreencopyView is cheap), but
 * deliberately a SEPARATE instance, not shared with the dock/widgets.
 *
 * Measured 2026-09-14: an equivalent ScreencopyView embedded directly
 * inside SearchWidget.qml (a child of Overview.qml's own real PanelWindow)
 * cost ~35-47% GPU while Spotlight sat open and idle, REGARDLESS of
 * whether its own `live` property was continuously true or pulsed on/off —
 * while GlassCaptureService's window-less pattern measured ~9% for the
 * exact same "open and idle" scenario. Being a child of an actively-
 * redrawing real window's own scene graph appears to carry a real,
 * unavoidable per-frame cost independent of the item's own live-ness;
 * living in a Singleton's own Instantiator tree (attached to no particular
 * window) does not.
 *
 * NOT the same instance as GlassCaptureService: that shared texture
 * crashed the shell ("Cannot make QOpenGLContext current in a different
 * thread") the moment two DIFFERENT top-level windows (the dock's and
 * Overview's) both had it live at once — a real, previously-hit failure
 * mode, not a hypothetical. Keeping Spotlight on its own separate instance
 * means it can never have more than one consumer TYPE (Overview's own
 * PanelWindow, one per monitor), so that specific crash class cannot
 * recur here even though the underlying pattern is otherwise identical.
 *
 * Isolated 2026-09-14 via a direct ablation test (registration forced off
 * entirely while "open"): the raw capture itself is ~40 of the ~45-49
 * percentage points measured while Spotlight sits open and idle — the
 * dominant cost by far, not the downstream crop/blur/shader stage.
 * consumerCounts (existence — is Spotlight around at all, for
 * hasContentFor to mean anything) is DELIBERATELY separate from
 * activeScreens (is a fresh frame wanted RIGHT NOW) — `live` below follows
 * the latter, letting the sole consumer (SearchWidget) drive an adaptive
 * duty-cycle instead of a flat "registered at all" boolean, without losing
 * the once-latched hasContentFor semantics existence-tracking provides.
 */
Singleton {
    id: root

    property var consumerCounts: ({}) // screen.name -> count (existence)
    property var activeScreens: ({})  // screen.name -> true while a fresh frame is actually wanted
    property var captures: ({})       // screen.name -> { reg: ShaderEffectSource, hasContent: bool }

    function registerConsumer(screenName) {
        if (!screenName)
            return;
        const counts = Object.assign({}, root.consumerCounts);
        counts[screenName] = (counts[screenName] ?? 0) + 1;
        root.consumerCounts = counts;
    }
    function unregisterConsumer(screenName) {
        if (!screenName || !(screenName in root.consumerCounts))
            return;
        const counts = Object.assign({}, root.consumerCounts);
        counts[screenName] = Math.max(0, (counts[screenName] ?? 0) - 1);
        root.consumerCounts = counts;
    }
    // Sole consumer drives this directly with its own adaptive rate
    // (captureLive in SearchWidget.qml) instead of a flat on/off.
    function setActive(screenName, active) {
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

            ScreencopyView {
                id: cap
                captureSource: perScreen.screen
                visible: false
                live: root.isLive(perScreen.screen.name)
                paintCursor: false
                width: perScreen.screen.width
                height: perScreen.screen.height
                onHasContentChanged: {
                    console.log("[scsdbg]", perScreen.screen.name, "cap.hasContent ->", hasContent, "@", Date.now());
                    perScreen.publish();
                }
                onLiveChanged: console.log("[scsdbg]", perScreen.screen.name, "cap.live ->", live, "@", Date.now())
                Component.onCompleted: console.log("[scsdbg]", perScreen.screen.name, "cap ScreencopyView CREATED @", Date.now())
            }
            ShaderEffectSource {
                id: reg
                sourceItem: cap
                live: root.isLive(perScreen.screen.name)
                hideSource: true
                recursive: false
                visible: false
                width: perScreen.screen.width
                height: perScreen.screen.height
                wrapMode: ShaderEffectSource.ClampToEdge
                onLiveChanged: console.log("[scsdbg]", perScreen.screen.name, "reg.live ->", live, "@", Date.now())
            }

            function publish() {
                const c = Object.assign({}, root.captures);
                c[perScreen.screen.name] = { reg: reg, hasContent: cap.hasContent };
                root.captures = c;
            }

            Component.onCompleted: perScreen.publish()
            Component.onDestruction: {
                const c = Object.assign({}, root.captures);
                delete c[perScreen.screen.name];
                root.captures = c;
            }
        }
    }
}
