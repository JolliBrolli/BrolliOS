pragma Singleton
import QtQuick
import Quickshell
import qs.modules.common

// Shared design tokens for IslandPopup (the menubar's dropdown popup style).
// Moved here from the now-deleted Island/notch feature — this is its only
// remaining consumer.
Singleton {
    id: root

    // Geometry
    readonly property int margin: 4            // gap from the screen edge (top/left/right)
    readonly property int pillHeight: 32       // island height
    readonly property int hPadding: 10         // inner horizontal padding
    readonly property real radius: Appearance.rounding.full

    // Surface — pure pitch black (reference pills/notch are opaque true black,
    // not the translucent themed bar look).
    readonly property color pillColor: "#000000"
    readonly property color pillBorder: Appearance.colors.colLayer0Border
    readonly property int borderWidth: 1

    // Content colors
    readonly property color textColor: "#FFFFFF"        // primary text / used indicators
    readonly property color subtextColor: "#9AA0AA"     // secondary text
    readonly property color accent: "#8AB4F8"           // blue tint (current workspace, highlights)
    readonly property real inactiveOpacity: 0.45        // unused / dim elements
}
