import qs.modules.common
import qs.modules.common.widgets
import QtQuick

/**
 * StyledText for text on liquid glass: takes the panel's measured text colour
 * (black or white, whichever contrasts) from its glassRoot, and keeps its own
 * `color` until the first measurement lands -- or for good, if glassRoot is
 * null, which is how text on an opaque pill opts out.
 *
 * The plugin measures the colour now (GlassSample); the shell cannot see the
 * backdrop any more, so this is one colour per panel, not per element.
 */StyledText {
    id: root

    // The panel this text sits on: LiquidGlassBackground, or anything else
    // exposing adaptiveReady + adaptiveColor (SearchWidget does).
    property var glassRoot: null

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
