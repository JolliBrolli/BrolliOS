pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

/**
 * Sends the liquid-glass material's uniform values to the Hyprland plugin.
 *
 * The plugin renders the material now, but it must not OWN the material's
 * values. Several of them are not settings at all — `base` and `textColor` are
 * Material You colours derived in Appearance.qml (colLayer0 is a mix of
 * m3background and m3primary, then transparentised), and reproducing that
 * derivation in C++ would be re-authoring the look a layer down. Everything
 * else already has a home in Config.options.appearance.liquidGlass and a UI in
 * LiquidGlassConfig.qml.
 *
 * So the shell stays the source of truth and pushes values across. Names match
 * the shader's own uniforms; the plugin applies whatever it receives by
 * introspecting its linked program, so adding a uniform to the .frag means
 * touching the shader and this file, and nothing else.
 *
 * Pushes are coalesced through a short timer: theme changes touch many values
 * at once, and each push is a process spawn.
 */
Singleton {
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
            // shape / refraction
            power: [lg.power],
            maxCornerRadius: [lg.maxCornerRadius],
            fPower: [lg.fPower],
            fa: [lg.fa], fb: [lg.fb], fc: [lg.fc], fd: [lg.fd],
            rimGap: [lg.rimGap],
            refractStrength: [lg.refractStrength],
            // rim / dispersion
            rimHighlightStrength: [lg.rimHighlightStrength],
            rimHighlightWidth: [lg.rimHighlightWidth],
            rimDiagonalReach: [lg.rimDiagonalReach],
            chromaticAberration: [lg.chromaticAberration],
            // sampling
            blurPx: [lg.blurPx],
            frostBlur: [lg.frostBlur],
            frostSaturation: [lg.frostSaturation],
            frostDarken: [lg.frostDarken],
            // legibility floor
            baseOpacity: [lg.baseOpacity],
            minFloor: [lg.minFloor],
            busynessStrength: [lg.busynessStrength],
            // theme-derived colours (NOT settings — see the comment above)
            base: [c.r, c.g, c.b, 1],
            textColor: [t.r, t.g, t.b, 1],
            tint: [tintColor.r, tintColor.g, tintColor.b, lg.tintStrength],
            // the separable blur's horizontal half reads this under its own name
            radiusPx: [Math.max(lg.blurPx, lg.frostBlur)],
            // "lens" material (experimental/lens.gles.frag). Harmless to the
            // others: the plugin only sets uniforms a program declares.
            lensRimPx: [lg.lensRimPx],
            lensStrength: [lg.lensStrength],
            lensBlur: [lg.lensBlur],
            lensChroma: [lg.lensChroma],
            lensTint: [lg.lensTint],
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
        let cmds = ["glassopt material " + (lg.material || "main")];
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
        function onFPowerChanged() { root.schedule(); }
        function onFaChanged() { root.schedule(); }
        function onFbChanged() { root.schedule(); }
        function onFcChanged() { root.schedule(); }
        function onFdChanged() { root.schedule(); }
        function onRimGapChanged() { root.schedule(); }
        function onRefractStrengthChanged() { root.schedule(); }
        function onRimHighlightStrengthChanged() { root.schedule(); }
        function onRimHighlightWidthChanged() { root.schedule(); }
        function onRimDiagonalReachChanged() { root.schedule(); }
        function onChromaticAberrationChanged() { root.schedule(); }
        function onBlurPxChanged() { root.schedule(); }
        function onFrostBlurChanged() { root.schedule(); }
        function onFrostSaturationChanged() { root.schedule(); }
        function onFrostDarkenChanged() { root.schedule(); }
        function onBaseOpacityChanged() { root.schedule(); }
        function onMinFloorChanged() { root.schedule(); }
        function onBusynessStrengthChanged() { root.schedule(); }
        function onTintChanged() { root.schedule(); }
        function onTintStrengthChanged() { root.schedule(); }
        function onMaterialChanged() { root.schedule(); }
        function onLensRimPxChanged() { root.schedule(); }
        function onLensStrengthChanged() { root.schedule(); }
        function onLensBlurChanged() { root.schedule(); }
        function onLensChromaChanged() { root.schedule(); }
        function onLensTintChanged() { root.schedule(); }
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
