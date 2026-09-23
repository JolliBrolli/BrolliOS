pragma ComponentBehavior: Bound

import qs.modules.common
import QtQuick

/**
 * Marks where a panel's glass goes. Draws nothing itself: the Hyprland plugin
 * renders the material under this surface (GlassRegion sends it the rect), and
 * any fill here would sit on top of it.
 *
 * Also carries the panel's adaptive text colour, measured by the plugin, for
 * AdaptiveGlassText/Symbol to read through their glassRoot.
 */Item {
    id: root

    required property var screen

    property real cornerRadiusOverride: Config.options.appearance.liquidGlass.maxCornerRadius

    // Namespace of the layer surface this sits in. Empty = no glass sent,
    // which is the case for any consumer that has not opted in yet.
    property string glassNamespace: ""

    // Nothing is drawn here any more. The compositor plugin renders the whole
    // material — shape, refraction, rim, floor — behind this surface, so any
    // fill would sit ON TOP of the glass. (An earlier version drew a white
    // silhouette at alpha 0.14 for the plugin to mask against; the plugin now
    // receives the rect directly, so the silhouette is gone.)
    GlassRegion {
        target: root
        layerNamespace: root.glassNamespace
        radius: root.cornerRadiusOverride
        darkText: glassSample.light
    }

    // Adaptive text: black or white by the average colour of this panel's
    // finished glass, measured by the plugin (see GlassSample). Read by
    // AdaptiveGlassText / AdaptiveGlassSymbol through their glassRoot.
    readonly property bool adaptiveReady: glassSample.ready
    readonly property color adaptiveColor: glassSample.textColor
    GlassSample {
        id: glassSample
        target: root
        layerNamespace: root.glassNamespace
    }
}
