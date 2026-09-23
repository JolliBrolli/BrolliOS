pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

/**
 * Pushes the material's uniform values to the Hyprland glass plugin.
 *
 * The plugin renders the material but does not own its values: they live in
 * Config.options.appearance.liquidGlass with a UI in LiquidGlassConfig.qml,
 * and some are derived Material You colours the shell alone can compute.
 * Names match the shader's uniforms, and the plugin applies whatever it
 * receives by introspecting its linked program, so adding a uniform means
 * touching the shader and this file and nothing else.
 *
 * Sent as one `hyprctl --batch` (~7ms), coalesced through a short timer since
 * a theme change touches many values at once.
 */Singleton {
    id: root

    readonly property var lg: Config.options.appearance.liquidGlass

    // Identifies THIS shell process to the plugin. Every GlassRegion prefixes its
    // rect id with it, and startup sends `glassrect reset <session>` so rects left
    // behind by a previous shell that was killed (and so never sent its
    // `remove`s) are dropped instead of drawing ghost glass.
    readonly property string sessionId: "s" + Qt.md5("" + Date.now() + Math.random()).slice(0, 8)

    // Fired when the plugin (re)loads; GlassRegions listen for it too.
    signal pluginLoaded()

    // Qt.color() THROWS on a partial hex string, and the tint fields hand over
    // partial strings ("#", "#0", ... "#00000") while they are being filled.
    // One of those used to abort the whole push -- the plugin then kept its
    // previous material and values (seen: stuck on "main" after a reload).
    // Anything that is not a complete colour falls back, for that tint only.
    function safeColor(str, fallback) {
        return /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(String(str)) ? Qt.color(str) : Qt.color(fallback);
    }

    function push() {
        const c = Appearance.colors.colLayer0;
        const t = Appearance.colors.colOnLayer0;
        const tint = Appearance.m3colors.darkmode ? lg.tint : "#FFFFFF";
        const tintColor = root.safeColor(tint, "#000000");

        const values = {
            power: [lg.power],
            maxCornerRadius: [lg.maxCornerRadius],
            fa: [lg.fa], fb: [lg.fb], fc: [lg.fc], fd: [lg.fd],
            rimHighlightStrength: [lg.rimHighlightStrength],
            rimHighlightWidth: [lg.rimHighlightWidth],
            rimDiagonalReach: [lg.rimDiagonalReach],
            tint: [tintColor.r, tintColor.g, tintColor.b, lg.tintStrength],
            // "aghajari" material (experimental/aghajari.gles.frag)
            aghDepth: [lg.aghDepth],
            aghStrength: [lg.aghStrength],
            aghBlur: [lg.aghBlur],
            aghChroma: [lg.aghChroma],
            aghEdge: [lg.aghEdge],
            aghTint: [lg.aghTint],
            aghStretch: [lg.aghStretch],
            aghSquash: [lg.aghSquash],
            aghPush: [lg.aghPush],
            aghBody: [lg.aghBody]
        };

        // Per-panel tint: `tint@<layer namespace>` overrides `tint` for that
        // panel only (plugin: g_nsUniformValues). Same dark/light rule as the
        // global tint above.
        const panelTints = {
            "quickshell:macDock": [lg.tintDock, lg.tintDockStrength],
            "quickshell:desktopWidgets": [lg.tintWidgets, lg.tintWidgetsStrength],
            "quickshell:overview": [lg.tintSpotlight, lg.tintSpotlightStrength]
        };
        for (const ns in panelTints) {
            const col = root.safeColor(Appearance.m3colors.darkmode ? panelTints[ns][0] : "#FFFFFF", "#000000");
            values["tint@" + ns] = [col.r, col.g, col.b, panelTints[ns][1]];
        }

        // One `hyprctl --batch`: one process, one socket round trip (~7ms).
        // It used to be ~52 separate hyprctl processes chained in a shell,
        // several seconds end to end -- and with the material switch LAST, a
        // freshly loaded plugin drew the wrong material for all that time.
        // Material first: validated plugin-side (an unknown name is refused
        // and the previous material stays).
        let cmds = [];
        for (const name in values)
            cmds.push("glassuniform " + name + " " + values[name].join(" "));
        // A push arriving while one is still running used to be DROPPED
        // (setting running = true on a running Process does nothing). Now it
        // runs again as soon as the current one exits.
        console.log("[glassbridge] push: running=" + pushProc.running + " cmds=" + cmds.length + " material=" + (lg.material || "main")); // DIAGNOSTIC
        if (pushProc.running) {
            root.pushAgain = true;
            return;
        }
        pushProc.command = ["hyprctl", "--batch", cmds.join(" ; ")];
        pushProc.running = true;
    }

    property bool pushAgain: false
    Process {
        id: pushProc
        stdout: StdioCollector {} // discard the replies
        onRunningChanged: {
            if (!running && root.pushAgain) {
                root.pushAgain = false;
                root.push();
            }
        }
    }

    Timer {
        id: coalesce
        interval: 80
        onTriggered: root.push()
    }
    function schedule() {
        coalesce.restart();
    }

    Component.onCompleted: {
        Quickshell.execDetached(["sh", "-c", "hyprctl glassrect reset " + root.sessionId + " >/dev/null; hyprctl glasssample reset " + root.sessionId + " >/dev/null"]);
        root.push();
    }

    // A freshly loaded plugin holds no uniforms and no rects: resend everything.
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name !== "glassplugin")
                return;
            Quickshell.execDetached(["sh", "-c", "hyprctl glassrect reset " + root.sessionId + " >/dev/null; hyprctl glasssample reset " + root.sessionId + " >/dev/null"]);
            root.push();
            root.pluginLoaded();
        }
    }

    Connections {
        target: Config.options.appearance.liquidGlass
        function onPowerChanged() { root.schedule(); }
        function onMaxCornerRadiusChanged() { root.schedule(); }
        function onRimHighlightStrengthChanged() { root.schedule(); }
        function onRimHighlightWidthChanged() { root.schedule(); }
        function onRimDiagonalReachChanged() { root.schedule(); }
        function onTintChanged() { root.schedule(); }
        function onTintStrengthChanged() { root.schedule(); }
        function onAghDepthChanged() { root.schedule(); }
        function onAghStrengthChanged() { root.schedule(); }
        function onAghBlurChanged() { root.schedule(); }
        function onAghChromaChanged() { root.schedule(); }
        function onAghEdgeChanged() { root.schedule(); }
        function onAghTintChanged() { root.schedule(); }
        function onAghStretchChanged() { root.schedule(); }
        function onAghSquashChanged() { root.schedule(); }
        function onAghPushChanged() { root.schedule(); }
        function onAghBodyChanged() { root.schedule(); }
        function onTintDockChanged() { root.schedule(); }
        function onTintDockStrengthChanged() { root.schedule(); }
        function onTintWidgetsChanged() { root.schedule(); }
        function onTintWidgetsStrengthChanged() { root.schedule(); }
        function onTintSpotlightChanged() { root.schedule(); }
        function onTintSpotlightStrengthChanged() { root.schedule(); }
    }

    // Theme changes move base/textColor/tint without touching any setting.
    Connections {
        target: Appearance.m3colors
        function onDarkmodeChanged() { root.schedule(); }
    }
}
