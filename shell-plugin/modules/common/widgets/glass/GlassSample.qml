pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland

/**
 * Asks the Hyprland glass plugin for the average colour behind an item, and
 * turns it into a black-or-white text colour -- adaptive text, now that the
 * shell no longer captures the screen itself (the old AdaptiveGlassText read
 * a backdrop texture this shell no longer has).
 *
 * Sends `hyprctl glasssample <id> <namespace> x y w h`; the plugin measures
 * that region just before its layer draws (for a glass panel: the finished
 * glass the text sits on) and posts `glasssample>><id>,r,g,b` whenever it
 * changes. Measured at most ~10x a second, and only when something behind it
 * changed.
 *
 * `layerNamespace` is the layer surface's namespace, or "popup:" + it for an
 * item inside that layer's PopupWindow (the menubar dropdowns).
 *
 * `overlayColor`/`overlayOpacity`: a translucent fill the item itself draws
 * over the backdrop (the menubar's own 55% strip). The text sits on the mix,
 * so that is what the contrast is judged against.
 *
 * Contrast rule and colours are the old glasstextcontrast.frag's exactly:
 * Rec.601 luma > 0.5 -> 0.05 grey, else 0.97. One addition: a small
 * hysteresis band, safe here because this is one held value per region (the
 * old shader had no memory between frames, which is why it was reverted
 * there), so a drag hovering at 0.5 does not flicker the text.
 */
Item {
    id: root

    property Item target: parent
    required property string layerNamespace
    property color overlayColor: "transparent"
    property real overlayOpacity: 0

    readonly property string sampleId: GlassUniformBridge.sessionId + ":s" + Qt.md5("" + Date.now() + Math.random()).slice(0, 10)

    // Result
    property bool ready: false
    property color backdrop: "black"
    readonly property color effective: Qt.rgba(
        root.backdrop.r * (1 - root.overlayOpacity) + root.overlayColor.r * root.overlayOpacity,
        root.backdrop.g * (1 - root.overlayOpacity) + root.overlayColor.g * root.overlayOpacity,
        root.backdrop.b * (1 - root.overlayOpacity) + root.overlayColor.b * root.overlayOpacity, 1)
    readonly property real luma: 0.299 * root.effective.r + 0.587 * root.effective.g + 0.114 * root.effective.b
    property bool light: false
    onLumaChanged: root.updateLight()
    function updateLight() {
        if (root.light && root.luma < 0.47)
            root.light = false;
        else if (!root.light && root.luma > 0.53)
            root.light = true;
    }
    readonly property color textColor: root.light ? Qt.rgba(0.05, 0.05, 0.05, 1) : Qt.rgba(0.97, 0.97, 0.97, 1)

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
        ? [root.sampleId, root.layerNamespace, root.pos.x.toFixed(1), root.pos.y.toFixed(1),
           root.target.width.toFixed(1), root.target.height.toFixed(1)].join(" ")
        : ""

    onPayloadChanged: if (!sendTimer.running) sendTimer.start()
    Timer {
        id: sendTimer
        interval: 50
        onTriggered: {
            if (root.payload !== "")
                Quickshell.execDetached(["sh", "-c", "hyprctl glasssample " + root.payload + " >/dev/null"]);
            else
                Quickshell.execDetached(["sh", "-c", "hyprctl glasssample " + root.sampleId + " remove >/dev/null"]);
        }
    }
    Component.onCompleted: sendTimer.start()
    Component.onDestruction: Quickshell.execDetached(["sh", "-c", "hyprctl glasssample " + root.sampleId + " remove >/dev/null"])

    Connections {
        target: GlassUniformBridge
        function onPluginLoaded() { sendTimer.start(); }
    }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name !== "glasssample")
                return;
            const parts = event.data.split(",");
            if (parts.length !== 4 || parts[0] !== root.sampleId)
                return;
            root.backdrop = Qt.rgba(parseInt(parts[1]) / 255, parseInt(parts[2]) / 255, parseInt(parts[3]) / 255, 1);
            root.ready = true;
            root.updateLight();
        }
    }
}
