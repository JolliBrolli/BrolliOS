import qs.modules.common
import qs.services
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
pragma Singleton
pragma ComponentBehavior: Bound

Singleton {
    id: root
    property bool barOpen: true
    property bool crosshairOpen: false
    property bool sidebarLeftOpen: false
    property bool sidebarRightOpen: false
    property bool mediaControlsOpen: false
    property bool osdBrightnessOpen: false
    property bool osdVolumeOpen: false
    property bool oskOpen: false
    property bool overlayOpen: false
    property bool overviewOpen: false
    property bool regionSelectorOpen: false
    // Bumped when the snip overlay is asked to accept its restored region. The key press
    // lands on whichever screen holds keyboard focus, which is not necessarily the screen
    // the region belongs to, so the request is broadcast to every overlay instance.
    property int regionAcceptRequest: 0
    property bool regionAcceptToEditor: false
    property bool searchOpen: false
    property bool screenLocked: false
    property bool screenLockContainsCharacters: false
    property bool screenUnlockFailed: false
    property bool screenTranslatorOpen: false
    property bool sessionOpen: false
    property bool superDown: false
    property bool superReleaseMightTrigger: true
    property bool wallpaperSelectorOpen: false
    property bool workspaceShowNumbers: false
    // Set by a small independent background script (see
    // ~/.local/bin/trackpad-gesture-watch.sh) watching raw libinput swipe
    // events directly — deliberately NOT via Hyprland's own gesture system,
    // since a 3-finger swipe drives Hyprland's native window-move gesture
    // (see hl.gesture in general.lua), which is a dedicated internal C++
    // implementation with its own state, not something a Lua hook could
    // safely piggyback on without risking replacing it entirely. This
    // exists specifically because that gesture-driven window move doesn't
    // fire the normal Hyprland window-position events the dock's own
    // floating-window detection relies on (see MacDock.qml's
    // anyWindowOverlappingDock) — reading the raw touchpad gesture stream
    // directly sidesteps that gap without touching the actual move gesture
    // at all.
    property bool trackpadGestureActive: false
    // Set by a small independent background script (see
    // ~/.local/bin/mouse-drag-watch.sh) watching raw libinput
    // POINTER_BUTTON events directly — deliberately independent of
    // Hyprland's own IPC event stream, which was confirmed (direct socket
    // monitoring, 6+ seconds of continuous dragging) to fire ZERO events
    // during an active window drag. Anything that needs to know "is a
    // drag likely happening right now" (Spotlight's live-capture rate,
    // see SearchWidget.qml) can't rely on Hyprland's own events for that,
    // the same gap trackpadGestureActive above exists to cover for
    // touchpad gesture-driven moves specifically — this covers regular
    // mouse-driven drags. Fires on any left-button-down, not just drags on
    // a specific window (a plain click is a harmless false positive).
    property bool mouseDragActive: false
    // Set by ~/.local/bin/pointer-motion-watch.sh — debounced "is the
    // pointer actively moving right now" (any device), independent of
    // button/tap state entirely. mouseDragActive alone misses a
    // tap-then-continue-moving drag (a real, measured gap: the button
    // only reports "pressed" for the tap's own ~100ms, not the drag that
    // follows it) — combined with superDown (below) at the point of use,
    // "Super held AND pointer moving" is a reliable drag proxy regardless
    // of whether the initiating input was a tap or a genuine hold.
    property bool pointerMoving: false

    onSidebarRightOpenChanged: {
        if (GlobalStates.sidebarRightOpen) {
            Notifications.timeoutAll();
            Notifications.markAllRead();
        }
    }

    GlobalShortcut {
        name: "workspaceNumber"
        description: "Hold to show workspace numbers, release to show icons"

        onPressed: {
            root.superDown = true
        }
        onReleased: {
            root.superDown = false
        }
    }

    IpcHandler {
        target: "trackpadGesture"
        function begin() {
            root.trackpadGestureActive = true;
        }
        function end() {
            root.trackpadGestureActive = false;
        }
    }

    IpcHandler {
        target: "mouseDrag"
        function begin() {
            root.mouseDragActive = true;
        }
        function end() {
            root.mouseDragActive = false;
        }
    }

    IpcHandler {
        target: "pointerMotion"
        function begin() {
            root.pointerMoving = true;
        }
        function end() {
            root.pointerMoving = false;
        }
    }
}