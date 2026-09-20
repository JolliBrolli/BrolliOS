pragma ComponentBehavior: Bound

import qs.modules.common
import QtQuick

/**
 * PLUGIN-TEST SHELL COPY — the old glass has been removed entirely.
 *
 * The real component (see ../../../../../quickshell/modules/common/widgets/
 * glass/LiquidGlassBackground.qml) captured the screen per-monitor, cropped
 * it, ran a separable blur and a 607-line refraction shader, and carried a
 * whole adaptive-rate system (settle timers, idle pulse, drag detection,
 * static-wallpaper fallback, lock/unlock recovery) to keep that affordable.
 * ALL of that is gone here — no ScreencopyView, no ShaderEffect, no
 * ShaderEffectSource, no timers, no wallpaper reconstruction.
 *
 * What's left is a translucent silhouette. That is deliberate and load-
 * bearing: the Hyprland glass plugin uses this surface's own ALPHA as the
 * shape to render its material into (the same arrangement bea4dev's
 * LiquidIslandQS uses with ShojiWM — the client draws the silhouette, the
 * compositor draws the glass). Fully transparent would leave the plugin
 * with no shape to find, so the fill has to stay above the plugin's own
 * alpha threshold.
 *
 * Every property the real component exposed is kept, inert, so consumers
 * (MacDock, DesktopWidget) bind against it unchanged.
 */
Item {
    id: root

    required property var screen

    // --- kept for API compatibility, all no-ops now ---
    property bool staticWallpaper: false
    property bool useOwnCapture: false
    property bool unlockRecoveryEnabled: false
    property bool extraCaptureActive: false
    property real yOffset: 0
    property real cornerRadiusOverride: Config.options.appearance.liquidGlass.maxCornerRadius

    // Consumers read these (MacDock, DesktopWidget). Nothing is captured any
    // more, so there is no backdrop texture to hand out and nothing is ever
    // "live" — AdaptiveGlassText already treats a null texture as "not
    // wired" and falls back to plain themed text.
    readonly property var currentBackdropTexture: null
    readonly property bool liveCaptureActive: false
    readonly property bool glassReady: true

    // The silhouette the compositor plugin masks to.
    Rectangle {
        anchors.fill: parent
        radius: Math.min(Math.min(root.width, root.height) / 2, Math.max(root.cornerRadiusOverride, 1))
        color: Qt.rgba(1, 1, 1, 0.14)
    }
}
