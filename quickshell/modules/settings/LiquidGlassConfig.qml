import QtQuick
import QtQuick.Layouts
import qs.services
import qs.modules.common
import qs.modules.common.widgets

/**
 * Settings for the liquid glass the Hyprland plugin draws. Every value here is
 * pushed to it as a shader uniform (GlassUniformBridge); nothing is rendered
 * shell-side.
 *
 * Resets read liquidGlassDefaults, a persisted copy rather than literals, so
 * "Set as default" can move them without a code change.
 */
ContentPage {
    forceWidth: true

    readonly property var lg: Config.options.appearance.liquidGlass
    readonly property var lgDefaults: Config.options.appearance.liquidGlassDefaults

    readonly property var keys: [
        "maxCornerRadius", "spotlightMaxCornerRadius", "power",
        "aghDepth", "aghStrength", "aghStretch", "aghBlur", "aghChroma", "aghEdge", "aghTint",
        "aghSquash", "aghPush", "aghBody",
        "rimHighlightStrength", "rimHighlightWidth", "rimDiagonalReach",
        "tint", "tintStrength",
        "tintDock", "tintDockStrength", "tintWidgets", "tintWidgetsStrength",
        "tintSpotlight", "tintSpotlightStrength",
        "chipOpacity", "chipOpacityHover", "chipSquashBoost"
    ]

    component ResetButton: IconToolbarButton {
        id: resetBtn
        text: "restart_alt"
        Layout.alignment: Qt.AlignVCenter
        property var onReset: function () {}
        onClicked: resetBtn.onReset()
        StyledToolTip {
            text: Translation.tr("Reset to default")
        }
    }

    // One slider + its reset, bound to a key by name.
    component Setting: ColumnLayout {
        id: setting
        required property string key
        required property string label
        property string icon: "tune"
        property real from: 0
        property real to: 1
        property bool percent: false
        property string help: ""
        Layout.fillWidth: true
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 150
                text: setting.label
                value: lg[setting.key]
                usePercentTooltip: setting.percent
                buttonIcon: setting.icon
                from: setting.from
                to: setting.to
                stopIndicatorValues: [lgDefaults[setting.key]]
                onValueChanged: lg[setting.key] = value
            }
            ResetButton {
                onReset: function () { lg[setting.key] = lgDefaults[setting.key]; }
            }
        }
        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            visible: setting.help !== ""
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: setting.help
        }
    }

    // Hex colour field + strength slider, for one panel's tint.
    component TintSetting: ContentSubsection {
        id: tintSetting
        required property string colourKey
        required property string strengthKey
        Layout.fillWidth: true

        RowLayout {
            Layout.fillWidth: true
            MaterialTextArea {
                Layout.fillWidth: true
                placeholderText: Translation.tr("Tint colour (hex, dark mode only)")
                text: lg[tintSetting.colourKey]
                wrapMode: TextEdit.Wrap
                onTextChanged: lg[tintSetting.colourKey] = text
            }
            ResetButton {
                onReset: function () { lg[tintSetting.colourKey] = lgDefaults[tintSetting.colourKey]; }
            }
        }
        Setting {
            key: tintSetting.strengthKey
            label: Translation.tr("Tint strength")
            icon: "format_color_fill"
            percent: true
        }
    }

    // In-memory, one level, this window only.
    property var lastSnapshot: null
    function snapshotCurrent() {
        let s = {};
        for (const k of keys)
            s[k] = lg[k];
        return s;
    }
    function applyValues(target, s) {
        for (const k of keys)
            target[k] = s[k];
    }
    function resetAllToDefaults() {
        lastSnapshot = snapshotCurrent();
        applyValues(lg, lgDefaults);
    }
    function revertLastReset() {
        if (!lastSnapshot)
            return;
        applyValues(lg, lastSnapshot);
        lastSnapshot = null;
    }
    function setCurrentAsDefault() {
        applyValues(lgDefaults, snapshotCurrent());
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.bottomMargin: 8

        StyledText {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("\"Set as default\" saves your current values as what every reset below returns to. \"Reset all\" snapshots your current values first, so \"Revert\" can bring them straight back.")
        }
        IconAndTextToolbarButton {
            iconText: "bookmark_add"
            text: Translation.tr("Set as default")
            onClicked: setCurrentAsDefault()
        }
        IconAndTextToolbarButton {
            iconText: "restart_alt"
            text: Translation.tr("Reset all to defaults")
            onClicked: resetAllToDefaults()
        }
        IconAndTextToolbarButton {
            iconText: "undo"
            text: Translation.tr("Revert")
            enabled: lastSnapshot !== null
            onClicked: revertLastReset()
        }
    }

    ContentSection {
        icon: "water_drop"
        title: Translation.tr("Glass")

        Setting {
            key: "aghDepth"
            label: Translation.tr("Distortion depth")
            icon: "line_curve"
            from: 0.02
            to: 0.5
            help: Translation.tr("How far in from the edge the glass bends light, as a fraction of the panel's short side.")
        }
        Setting {
            key: "aghStrength"
            label: Translation.tr("Distortion strength")
            icon: "waves"
            from: 0
            to: 2
            help: Translation.tr("How hard it pulls what's behind it toward the middle. Past 1 the very edge reaches the centre, so big panels start showing content from their far side.")
        }
        Setting {
            key: "aghStretch"
            label: Translation.tr("Stretch along long side")
            icon: "width"
            percent: true
            help: Translation.tr("0 bends away from the panel's centre point, which suits round panels but smears sideways along long ones like the dock. 1 uses a centre line instead, so long edges bend straight across and the rounded ends keep the point behaviour.")
        }
        Setting {
            key: "aghBlur"
            label: Translation.tr("Softness (px)")
            icon: "blur_on"
            from: 0
            to: 4
            help: Translation.tr("A small blur under the glass, strongest in the middle. 0 = crisp, and cheapest: it is the most expensive part of the material.")
        }
        Setting {
            key: "aghChroma"
            label: Translation.tr("Chromatic shift (px)")
            icon: "gradient"
            from: 0
            to: 10
            help: Translation.tr("Red/blue fringing, like glass splitting light by wavelength.")
        }
        Setting {
            key: "aghEdge"
            label: Translation.tr("Chromatic fade-in")
            icon: "line_weight"
            from: 0.001
            to: 0.2
            help: Translation.tr("How far in from the edge that fringing takes to reach full strength.")
        }
        Setting {
            key: "aghTint"
            label: Translation.tr("Brightness")
            icon: "brightness_6"
            from: 0.5
            to: 1.2
            percent: true
            help: Translation.tr("Multiplies the glass colour. 1.0 = neutral.")
        }
    }

    ContentSection {
        icon: "visibility"
        title: Translation.tr("Readability")

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("Apple's approach: each panel measures what's behind it as a whole and adjusts itself as one, never pixel by pixel. All three at 0 = off.")
        }
        Setting {
            key: "aghSquash"
            label: Translation.tr("Contrast squash")
            icon: "contrast"
            percent: true
            help: Translation.tr("How much a busy backdrop's contrast is flattened behind the glass. Calm backdrops pass through untouched.")
        }
        Setting {
            key: "aghBody"
            label: Translation.tr("Glass body")
            icon: "light_mode"
            to: 0.4
            percent: true
            help: Translation.tr("A faint light of the glass's own. The lens only moves what's behind it around, so over a dark background it would otherwise be just as dark. This lifts the whole panel evenly.")
        }
        Setting {
            key: "aghPush"
            label: Translation.tr("Brightness push")
            icon: "brightness_medium"
            to: 0.4
            help: Translation.tr("Only when needed: once what's behind gets close to the text's own brightness, the glass shifts away from it. A backdrop that already contrasts is left alone.")
        }
    }

    ContentSection {
        icon: "line_weight"
        title: Translation.tr("Rim outline")

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("The white line at the edge: brightest along the top-left and bottom-right, fading out at the other two corners, and softer along straight runs than on curves.")
        }
        Setting {
            key: "rimHighlightStrength"
            label: Translation.tr("Rim highlight")
            icon: "line_weight"
            to: 0.5
            percent: true
        }
        Setting {
            key: "rimHighlightWidth"
            label: Translation.tr("Rim width (px)")
            icon: "line_weight"
            from: 0.2
            to: 6
        }
        Setting {
            key: "rimDiagonalReach"
            label: Translation.tr("Rim line length")
            icon: "line_weight"
            from: 0.2
            to: 3
            help: Translation.tr("How far the bright/dim diagonal lighting reaches along a flat edge before settling back. Lower stretches it further; higher keeps it at the corners.")
        }
        Setting {
            key: "power"
            label: Translation.tr("Corner shape")
            icon: "rounded_corner"
            from: 2
            to: 24
            help: Translation.tr("Shapes the corner curve the rim follows. 2 = a true circular arc; higher is progressively more squircle.")
        }
    }

    ContentSection {
        icon: "rounded_corner"
        title: Translation.tr("Corners")

        Setting {
            key: "maxCornerRadius"
            label: Translation.tr("Max radius: dock")
            icon: "rounded_corner"
            from: 10
            to: 300
            help: Translation.tr("Caps the corner radius independently of the panel's size. Large values keep the dock's fully round pill.")
        }
        Setting {
            key: "spotlightMaxCornerRadius"
            label: Translation.tr("Max radius: Spotlight")
            icon: "rounded_corner"
            from: 4
            to: 60
            help: Translation.tr("Spotlight's own cap: it is the one panel with enough text that an uncapped radius curves into it once the results list is tall. Defaults to 23px, matching the screen's own corner radius.")
        }
    }

    ContentSection {
        icon: "format_color_fill"
        title: Translation.tr("Panel tint")

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("A colour mixed over each panel's glass, set separately per panel. The colour applies in dark mode; light mode always uses white. Strength 0 = no tint.")
        }

        ContentSubsection {
            title: Translation.tr("Dock")
            Layout.fillWidth: true
            TintSetting {
                colourKey: "tintDock"
                strengthKey: "tintDockStrength"
            }
        }
        ContentSubsection {
            title: Translation.tr("Desktop widgets")
            Layout.fillWidth: true
            TintSetting {
                colourKey: "tintWidgets"
                strengthKey: "tintWidgetsStrength"
            }
        }
        ContentSubsection {
            title: Translation.tr("Spotlight")
            Layout.fillWidth: true
            ConfigSwitch {
                buttonIcon: "contrast"
                text: Translation.tr("Darken the screen behind Spotlight")
                checked: Config.options.overview.dimBackground
                onCheckedChanged: {
                    Config.options.overview.dimBackground = checked;
                }
            }
            TintSetting {
                colourKey: "tintSpotlight"
                strengthKey: "tintSpotlightStrength"
            }
        }
        ContentSubsection {
            title: Translation.tr("Menubar dropdowns")
            Layout.fillWidth: true
            TintSetting {
                colourKey: "tint"
                strengthKey: "tintStrength"
            }
        }
    }

    ContentSection {
        icon: "highlight"
        title: Translation.tr("Highlights")

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("Translucent chips behind individual controls on the glass: the search bar's icons, the search box, and the highlighted result row.")
        }
        Setting {
            key: "chipOpacity"
            label: Translation.tr("Chip opacity (resting)")
            icon: "check_box_outline_blank"
            to: 0.5
            percent: true
        }
        Setting {
            key: "chipOpacityHover"
            label: Translation.tr("Chip opacity (hovered)")
            icon: "check_box"
            to: 0.8
            percent: true
        }
        Setting {
            key: "chipSquashBoost"
            label: Translation.tr("Chip boost with squash")
            icon: "exposure_plus_1"
            to: 0.6
            percent: true
            help: Translation.tr("Chips get more opaque as the readability squash flattens a busy backdrop, so they stay visible exactly when the glass is working hardest.")
        }
    }
}
