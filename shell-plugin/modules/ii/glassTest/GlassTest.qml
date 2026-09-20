pragma ComponentBehavior: Bound

import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

/**
 * Throwaway test rig for the "true continuous" liquid-glass refraction (see
 * liquidglasstest.frag) — a plain toggleable square, live Wayland capture,
 * real refraction of whatever's actually behind it (including its own
 * rendered pixels — self-reflection is accepted here on purpose; this only
 * exists to validate the shape/refraction math in real time before
 * tackling self-reflection separately). Not styled like the search bar.
 *
 * Toggle: `qs -c Brolli-Glass ipc call glassTest toggle`
 * (also: `open` / `close` — NOT `show`/`hide`, see note below)
 */
Scope {
    id: scope
    property bool testVisible: false

    IpcHandler {
        target: "glassTest"
        function toggle() {
            scope.testVisible = !scope.testVisible;
        }
        // Named open/close, not show/hide — a function literally named
        // "show" on this IpcHandler silently misbehaves in `qs ipc call`
        // (dumps the target's interface instead of invoking it; toggle/close
        // both invoke cleanly). Matches this codebase's existing convention
        // (session/mediaControls/sidebarRight etc. all use open/toggle/close).
        function open() {
            scope.testVisible = true;
        }
        function close() {
            scope.testVisible = false;
        }
    }

    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: root
            required property var modelData
            screen: modelData
            visible: scope.testVisible

            WlrLayershell.namespace: "quickshell:glassTest"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            color: "transparent"
            // Must span the TRUE full monitor (real global (0,0), matching
            // `cap` below, which captures the whole output) — without this,
            // other exclusive-zone panels (e.g. the bar) push this surface's
            // own local (0,0) down/over from the monitor's real origin, and
            // boxX/boxY (computed from this window's own width/height) end up
            // offset from cap's coordinate space, sampling the wrong region
            // entirely. Same fix as Background.qml.
            exclusionMode: ExclusionMode.Ignore
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }
            // Purely a passive visual test — fully click/scroll/type-through,
            // even though the surface itself covers the whole screen.
            mask: Region {}

            property real boxW: 420
            property real boxH: 420
            property real boxX: 100
            property real boxY: 100
            // Scale with the shape's own corner radius (min(w,h)/2), same
            // reasoning as SearchWidget.qml — the refraction pull's reach
            // scales with radius, not a fixed pixel count, so a fixed pad
            // that's fine for a small box runs the pull past the edge of
            // what was captured at high `power`/larger sizes.
            readonly property real boxRadius: Math.min(boxW, boxH) / 2
            property real pad: Math.max(Config.options.appearance.liquidGlass.pad, boxRadius * 0.6)

            readonly property real texW: boxW + pad * 2
            readonly property real texH: boxH + pad * 2

            property bool ready: false
            // Was manually stepped (one new frame every few seconds) to keep
            // the pre-no_self_capture recursive self-reflection feedback loop
            // from exploding into a grey blob within a frame. no_self_capture
            // (Hyprland layer rule, see nested-test.lua) now removes this
            // layer's own content from what it captures at the compositor
            // level, so that feedback loop can't happen anymore — continuous
            // `live: true` is safe and is what makes this an actually-live
            // effect instead of a frame frozen for seconds at a time.

            ScreencopyView {
                id: cap
                captureSource: root.screen
                visible: false
                // Was unconditionally true — a full-screen live capture
                // running forever regardless of whether this throwaway
                // test rig was ever actually toggled on. Measured as a
                // real, continuous GPU cost even with GlassTest untouched
                // for an entire session; gating it on testVisible is free
                // (this is a dev tool, not something that needs to be
                // instant-on).
                live: scope.testVisible
                paintCursor: false
                width: root.screen.width
                height: root.screen.height
                onHasContentChanged: {
                    console.log("[glassTest] cap.hasContent =", hasContent, "live =", live);
                    if (hasContent && !root.ready)
                        root.ready = true;
                }
                Component.onCompleted: console.log("[glassTest] cap created, live =", live)
            }

            Component.onCompleted: console.log("[glassTest] root created, boxX =", boxX, "boxY =", boxY, "width =", width, "height =", height)

            ShaderEffectSource {
                id: capReg
                sourceItem: cap
                live: scope.testVisible
                hideSource: true
                recursive: false
                visible: false
                width: root.texW
                height: root.texH
                sourceRect: Qt.rect(root.boxX - root.pad, root.boxY - root.pad, root.texW, root.texH)
                wrapMode: ShaderEffectSource.ClampToEdge
            }

            // Separable blur, horizontal half (see liquidglasshblur.frag) —
            // pre-blurs capReg once so the main shader's own vertical pass
            // only needs a 1D loop, instead of a full 9x9 (81-tap) 2D loop.
            ShaderEffect {
                id: hBlurEffect
                visible: false
                width: root.texW
                height: root.texH
                property var source: capReg
                property vector2d texSize: Qt.vector2d(root.texW, root.texH)
                property real radiusPx: Math.max(Config.options.appearance.liquidGlass.blurPx, Config.options.appearance.liquidGlass.frostBlur)
                fragmentShader: Qt.resolvedUrl("../../common/widgets/glass/liquidglasshblur.frag.qsb")
            }
            ShaderEffectSource {
                id: hBlurReg
                sourceItem: hBlurEffect
                live: scope.testVisible
                hideSource: true
                recursive: false
                visible: false
                width: root.texW
                height: root.texH
                wrapMode: ShaderEffectSource.ClampToEdge
            }

            // DIAGNOSTIC ONLY: static wallpaper crop, same padded-region
            // convention as capReg, so it's a drop-in swap for `source`
            // below with no shader changes — isolates whether the
            // refraction math itself still works, independent of the live
            // capture/self-reflection behavior.
            Image {
                id: wallpaperImg
                source: Config.options.background.wallpaperPath
                sourceSize.width: 1280
                fillMode: Image.PreserveAspectCrop
                width: root.screen.width
                height: root.screen.height
                visible: false
                asynchronous: true
                cache: true
            }
            ShaderEffectSource {
                id: wallReg
                sourceItem: wallpaperImg
                live: false
                hideSource: true
                recursive: false
                visible: false
                width: root.texW
                height: root.texH
                sourceRect: Qt.rect(root.boxX - root.pad, root.boxY - root.pad, root.texW, root.texH)
                wrapMode: ShaderEffectSource.ClampToEdge
            }

            ShaderEffect {
                x: root.boxX
                y: root.boxY
                width: root.boxW
                height: root.boxH
                visible: root.ready && scope.testVisible
                onVisibleChanged: console.log("[glassTest] shader visible =", visible, "ready =", root.ready, "testVisible =", scope.testVisible)
                blending: true

                // Frosting is combined INSIDE the shader now (blurPx and
                // frostBlur both feed sampleBlurred — see the .frag file) —
                // a QML-level MultiEffect layer wrapping this whole shader's
                // output also blurred away the nanotexture grain below,
                // since it ran after the shader and grain has to be the
                // true last step to survive at all.

                // All tunable params come from Config.options.appearance.liquidGlass
                // (see modules/settings/LiquidGlassConfig.qml) rather than being
                // hardcoded here, so every panel using this shader shares one set
                // of values and changes together.
                // Dark mode uses the configurable tint; light mode always
                // uses white instead, matching how this shell's own text
                // colours already flip automatically with Appearance's
                // dark/light state (see DarkModeToggle.qml).
                readonly property color tintColor: Appearance.m3colors.darkmode ? Config.options.appearance.liquidGlass.tint : "#FFFFFF"
                // Theme's own dark surface color, matching FrostedBackdrop.qml's
                // legibility floor (base: Appearance.colors.colLayer0) — not
                // plain white, which does nothing for text contrast.
                readonly property color baseColor: Appearance.colors.colLayer0
                // The real theme colour QML text elements draw with on
                // this material — colOnLayer0 pairs with colLayer0/base
                // above by theme design, so it's the right stand-in for
                // "our actual text colour" the floor should guarantee
                // contrast against.
                readonly property color textThemeColor: Appearance.colors.colOnLayer0

                property var source: capReg
                property var sourceHBlur: hBlurReg
                property vector2d panelSize: Qt.vector2d(root.boxW, root.boxH)
                property vector2d texSize: Qt.vector2d(root.texW, root.texH)
                property real pad: root.pad
                property real power: Config.options.appearance.liquidGlass.power
                property real maxCornerRadius: Config.options.appearance.liquidGlass.maxCornerRadius
                property real fPower: Config.options.appearance.liquidGlass.fPower
                property real fa: Config.options.appearance.liquidGlass.fa
                property real fb: Config.options.appearance.liquidGlass.fb
                property real fc: Config.options.appearance.liquidGlass.fc
                property real fd: Config.options.appearance.liquidGlass.fd
                property real rimGap: Config.options.appearance.liquidGlass.rimGap
                property real refractStrength: Config.options.appearance.liquidGlass.refractStrength
                property real rimHighlightStrength: Config.options.appearance.liquidGlass.rimHighlightStrength
                property real rimHighlightWidth: Config.options.appearance.liquidGlass.rimHighlightWidth
                property real rimDiagonalReach: Config.options.appearance.liquidGlass.rimDiagonalReach
                property real chromaticAberration: Config.options.appearance.liquidGlass.chromaticAberration
                property real blurPx: Config.options.appearance.liquidGlass.blurPx
                property real frostBlur: Config.options.appearance.liquidGlass.frostBlur
                property vector4d base: Qt.vector4d(baseColor.r, baseColor.g, baseColor.b, 1)
                property vector4d textColor: Qt.vector4d(textThemeColor.r, textThemeColor.g, textThemeColor.b, 1)
                // Light mode needs a stronger floor pull than dark mode to
                // read as equally legible at the SAME configured number —
                // see SearchWidget.qml's own comment on this for the full
                // reasoning.
                readonly property real lightModeFloorBoost: 1.4
                property real baseOpacity: Config.options.appearance.liquidGlass.baseOpacity * (Appearance.m3colors.darkmode ? 1.0 : lightModeFloorBoost)
                property real minFloor: Config.options.appearance.liquidGlass.minFloor * (Appearance.m3colors.darkmode ? 1.0 : lightModeFloorBoost)
                property real busynessStrength: Config.options.appearance.liquidGlass.busynessStrength
                property vector4d tint: Qt.vector4d(tintColor.r, tintColor.g, tintColor.b, Config.options.appearance.liquidGlass.tintStrength)
                property real frostSaturation: Config.options.appearance.liquidGlass.frostSaturation
                property real frostDarken: Config.options.appearance.liquidGlass.frostDarken

                fragmentShader: Qt.resolvedUrl("../../common/widgets/glass/liquidglasstest.frag.qsb")
            }
        }
    }
}
