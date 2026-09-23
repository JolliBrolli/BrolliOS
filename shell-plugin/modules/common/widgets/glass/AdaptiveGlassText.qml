import qs.modules.common
import qs.modules.common.widgets
import QtQuick

/**
 * StyledText for text sitting directly on liquid glass: black or white by
 * the glass behind it.
 *
 * Originally this rendered its glyphs to a layer and ran glasstextcontrast.frag
 * against the glass's own backdrop texture, per element. That texture came
 * from the shell's own screen capture, which is gone -- the Hyprland plugin
 * draws the glass now, and it is the only thing that sees the backdrop. So
 * the plugin measures each panel's average colour and the panel exposes the
 * resulting text colour (GlassSample; same luma rule and colours as the old
 * shader). One colour per PANEL now, not per element.
 */
StyledText {
    id: root

    // Kept so every existing usage binds unchanged; unused since the plugin
    // took over (there is no backdrop texture in the shell any more).
    property var glassRoot: null
    property var backdropTexture: null
    property bool contrastActive: true

    // The panel's measured text colour (LiquidGlassBackground / SearchWidget /
    // anything exposing adaptiveReady + adaptiveColor). Until the first
    // measurement lands -- or with no glassRoot, e.g. text on an opaque pill --
    // this keeps the plain `color` it was given.
    readonly property bool adaptiveWired: !!root.glassRoot && root.glassRoot.adaptiveReady !== undefined
    Binding {
        target: root
        property: "color"
        value: root.glassRoot ? root.glassRoot.adaptiveColor : "transparent"
        when: root.adaptiveWired && !!root.glassRoot.adaptiveReady
        restoreMode: Binding.RestoreBindingOrValue
    }
}
