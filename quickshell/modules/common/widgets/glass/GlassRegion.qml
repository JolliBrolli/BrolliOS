pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland

/**
 * Tells the Hyprland glass plugin where one glass panel is.
 *
 * The plugin can only see a layer surface's BOX, which is not the glass -- the
 * dock's layer is the full-width strip while its glass is a centred pill -- so
 * the rect comes from here, in coordinates relative to the layer surface.
 *
 * Sends `hyprctl glassrect <id> <ns> x y w h radius darkText`, and `remove`
 * when the target hides or this is destroyed. Throttled to ~16ms: the dock's
 * rect changes on every frame of icon magnification and each send is a
 * process spawn.
 */Item {
    id: root

    // The item whose bounds are the glass panel.
    property Item target: parent
    // The layer surface's namespace (WlrLayershell.namespace of the window).
    required property string layerNamespace
    // Per-panel corner cap; < 0 uses the material's global maxCornerRadius.
    property real radius: -1
    // True when this panel's text is dark (GlassSample.light). The material's
    // readability layer pushes the glass away from its text: lighter under
    // dark text, darker under light text.
    property bool darkText: false

    // How busy the backdrop under this panel is (0..1), as the plugin measures
    // it for the readability squash (glassstats>><id>,<busy>). Lets things
    // drawn on the glass -- Spotlight's chips -- strengthen with the squash.
    property real busyness: 0
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name !== "glassstats")
                return;
            const parts = event.data.split(",");
            if (parts.length === 2 && parts[0] === root.regionId)
                root.busyness = parseFloat(parts[1]);
        }
    }

    // "<session>:<n>" — see GlassUniformBridge.sessionId for why ownership matters.
    readonly property string regionId: GlassUniformBridge.sessionId + ":" + Qt.md5("" + Date.now() + Math.random()).slice(0, 10)

    // Walk to the window root with plain x/y reads so the binding re-evaluates
    // when any ancestor moves. mapToItem(null, ...) looks equivalent but does
    // not reliably re-trigger bindings on ancestor movement — the original
    // LiquidGlassBackground hit exactly this and used the same walk.
    function windowLocalPos(item) {
        let x = 0, y = 0, cur = item;
        while (cur) {
            x += cur.x;
            y += cur.y;
            cur = cur.parent;
        }
        return Qt.point(x, y);
    }

    readonly property point pos: root.target ? root.windowLocalPos(root.target) : Qt.point(0, 0)
    readonly property bool active: !!root.target && root.target.visible && root.target.width > 0 && root.target.height > 0 && root.layerNamespace !== ""

    readonly property string payload: root.active
        ? [root.regionId, root.layerNamespace, root.pos.x.toFixed(1), root.pos.y.toFixed(1),
           root.target.width.toFixed(1), root.target.height.toFixed(1), root.radius.toFixed(1),
           root.darkText ? "1" : "0"].join(" ")
        : ""

    // THROTTLE, not debounce. restart() on every change was a debounce: during
    // Spotlight's expand animation the rect changes every frame, so the timer
    // kept resetting and nothing was sent until the animation STOPPED. The
    // plugin went on drawing glass at the old collapsed size while the panel
    // grew past it — raw background showing through, then a snap to glass.
    // start() only when idle means one send per interval DURING the change,
    // and onTriggered always reads the latest payload.
    onPayloadChanged: if (!sendTimer.running) sendTimer.start()

    Timer {
        id: sendTimer
        interval: 16
        onTriggered: {
            if (root.payload !== "")
                Quickshell.execDetached(["sh", "-c", "hyprctl glassrect " + root.payload + " >/dev/null"]);
            else
                Quickshell.execDetached(["sh", "-c", "hyprctl glassrect " + root.regionId + " remove >/dev/null"]);
        }
    }

    Component.onCompleted: sendTimer.start()

    // The plugin just (re)loaded with an empty rect table: send ours again.
    Connections {
        target: GlassUniformBridge
        function onPluginLoaded() { sendTimer.start(); }
    }
    // execDetached, not a Process child: it has to outlive this object.
    Component.onDestruction: Quickshell.execDetached(["sh", "-c", "hyprctl glassrect " + root.regionId + " remove >/dev/null"])
}
