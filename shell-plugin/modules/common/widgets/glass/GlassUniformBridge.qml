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

    function push() {
        const c = Appearance.colors.colLayer0;
        const t = Appearance.colors.colOnLayer0;
        const tint = Appearance.m3colors.darkmode ? lg.tint : "#FFFFFF";
        const tintColor = Qt.color(tint);

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
            radiusPx: [Math.max(lg.blurPx, lg.frostBlur)]
        };

        let cmds = [];
        for (const name in values)
            cmds.push("hyprctl glassuniform " + name + " " + values[name].join(" "));
        pushProc.command = ["sh", "-c", cmds.join("; ")];
        pushProc.running = true;
    }

    Process {
        id: pushProc
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
        Quickshell.execDetached(["sh", "-c", "hyprctl glassrect reset " + root.sessionId + " >/dev/null"]);
        root.push();
    }

    // A freshly loaded plugin holds no uniforms and no rects: resend everything.
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name !== "glassplugin")
                return;
            Quickshell.execDetached(["sh", "-c", "hyprctl glassrect reset " + root.sessionId + " >/dev/null"]);
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
    }

    // Theme changes move base/textColor/tint without touching any setting.
    Connections {
        target: Appearance.m3colors
        function onDarkmodeChanged() { root.schedule(); }
    }
}
