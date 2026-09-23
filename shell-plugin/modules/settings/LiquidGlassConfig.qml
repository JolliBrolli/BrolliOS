import QtQuick
import QtQuick.Layouts
import qs.services
import qs.modules.common
import qs.modules.common.widgets

ContentPage {
    forceWidth: true

    // No reset-to-default control exists elsewhere in this codebase to
    // reuse (checked — the closest precedent is WidgetMenu.qml's "Reset
    // size/position" context-menu items, which hardcode the default
    // literal same as this does; there's no schema-default introspection
    // anywhere to avoid that duplication). One small icon button, reused
    // per-setting below rather than copy-pasted 13 times.
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

    // A collapsible group of sections -- one per material, so only the sliders
    // for the material being tuned are on screen. ContentSection itself has no
    // collapse; this wraps it rather than changing it for every settings page.
    component Tray: ColumnLayout {
        id: tray
        property string title
        property string icon: ""
        property bool expanded: false
        default property alias trayData: trayBody.data
        Layout.fillWidth: true
        spacing: 8

        RippleButton {
            Layout.fillWidth: true
            implicitHeight: 48
            buttonRadius: Appearance.rounding.normal
            colBackground: Appearance.colors.colLayer2
            colBackgroundHover: Appearance.colors.colLayer2Hover
            colRipple: Appearance.colors.colLayer2Active
            onClicked: tray.expanded = !tray.expanded
            contentItem: RowLayout {
                spacing: 8
                OptionalMaterialSymbol {
                    Layout.leftMargin: 12
                    icon: tray.icon
                    iconSize: Appearance.font.pixelSize.hugeass
                }
                StyledText {
                    Layout.fillWidth: true
                    text: tray.title
                    font.pixelSize: Appearance.font.pixelSize.larger
                    font.weight: Font.Medium
                    color: Appearance.colors.colOnSecondaryContainer
                }
                MaterialSymbol {
                    Layout.rightMargin: 12
                    text: "keyboard_arrow_down"
                    iconSize: Appearance.font.pixelSize.hugeass
                    color: Appearance.colors.colOnLayer2
                    rotation: tray.expanded ? 180 : 0
                    Behavior on rotation {
                        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                    }
                }
            }
        }

        ColumnLayout {
            id: trayBody
            Layout.fillWidth: true
            Layout.leftMargin: 8
            visible: tray.expanded
            spacing: 16
        }
    }

    readonly property var lg: Config.options.appearance.liquidGlass
    readonly property var lgDefaults: Config.options.appearance.liquidGlassDefaults

    // "Reset all" + "Revert" — a bulk counterpart to the per-setting
    // ResetButtons above. lastSnapshot is in-memory only (not persisted),
    // so it only survives within this Settings window session, and only
    // holds ONE level of undo — clicking "Reset all" twice in a row loses
    // the first snapshot.
    property var lastSnapshot: null

    function snapshotCurrent() {
        return {
            power: lg.power, maxCornerRadius: lg.maxCornerRadius, spotlightMaxCornerRadius: lg.spotlightMaxCornerRadius,
            fPower: lg.fPower, pad: lg.pad, blurPx: lg.blurPx, frostBlur: lg.frostBlur,
            frostSaturation: lg.frostSaturation, frostDarken: lg.frostDarken,
            fa: lg.fa, fb: lg.fb, fc: lg.fc, fd: lg.fd, rimGap: lg.rimGap, refractStrength: lg.refractStrength,
            rimHighlightStrength: lg.rimHighlightStrength, rimHighlightWidth: lg.rimHighlightWidth, rimDiagonalReach: lg.rimDiagonalReach, chromaticAberration: lg.chromaticAberration,
            baseOpacity: lg.baseOpacity, minFloor: lg.minFloor, busynessStrength: lg.busynessStrength,
            tint: lg.tint, tintStrength: lg.tintStrength,
            chipOpacity: lg.chipOpacity, chipOpacityHover: lg.chipOpacityHover, chipSquashBoost: lg.chipSquashBoost,
            lensRimPx: lg.lensRimPx, lensStrength: lg.lensStrength, lensBlur: lg.lensBlur, lensChroma: lg.lensChroma, lensTint: lg.lensTint,
            aghDepth: lg.aghDepth, aghStrength: lg.aghStrength, aghBlur: lg.aghBlur, aghChroma: lg.aghChroma, aghEdge: lg.aghEdge, aghTint: lg.aghTint, aghStretch: lg.aghStretch, aghSquash: lg.aghSquash, aghPush: lg.aghPush, aghBody: lg.aghBody,
            tintDock: lg.tintDock, tintWidgets: lg.tintWidgets, tintSpotlight: lg.tintSpotlight, tintDockStrength: lg.tintDockStrength, tintWidgetsStrength: lg.tintWidgetsStrength, tintSpotlightStrength: lg.tintSpotlightStrength
        };
    }

    function applyValues(target, s) {
        target.power = s.power; target.maxCornerRadius = s.maxCornerRadius; target.spotlightMaxCornerRadius = s.spotlightMaxCornerRadius;
        target.fPower = s.fPower; target.pad = s.pad; target.blurPx = s.blurPx; target.frostBlur = s.frostBlur;
        target.frostSaturation = s.frostSaturation; target.frostDarken = s.frostDarken;
        target.fa = s.fa; target.fb = s.fb; target.fc = s.fc; target.fd = s.fd; target.rimGap = s.rimGap; target.refractStrength = s.refractStrength;
        target.rimHighlightStrength = s.rimHighlightStrength; target.rimHighlightWidth = s.rimHighlightWidth; target.rimDiagonalReach = s.rimDiagonalReach; target.chromaticAberration = s.chromaticAberration;
        target.baseOpacity = s.baseOpacity; target.minFloor = s.minFloor; target.busynessStrength = s.busynessStrength;
        target.tint = s.tint; target.tintStrength = s.tintStrength;
        target.chipOpacity = s.chipOpacity; target.chipOpacityHover = s.chipOpacityHover; target.chipSquashBoost = s.chipSquashBoost;
        target.lensRimPx = s.lensRimPx; target.lensStrength = s.lensStrength; target.lensBlur = s.lensBlur; target.lensChroma = s.lensChroma; target.lensTint = s.lensTint;
        target.aghDepth = s.aghDepth; target.aghStrength = s.aghStrength; target.aghBlur = s.aghBlur; target.aghChroma = s.aghChroma; target.aghEdge = s.aghEdge; target.aghTint = s.aghTint; target.aghStretch = s.aghStretch; target.aghSquash = s.aghSquash; target.aghPush = s.aghPush; target.aghBody = s.aghBody;
        target.tintDock = s.tintDock; target.tintWidgets = s.tintWidgets; target.tintSpotlight = s.tintSpotlight; target.tintDockStrength = s.tintDockStrength; target.tintWidgetsStrength = s.tintWidgetsStrength; target.tintSpotlightStrength = s.tintSpotlightStrength;
    }

    // Resets every slider back to liquidGlassDefaults — NOT hardcoded
    // literals, so this always matches whatever "Set as default" last
    // saved rather than some fixed value baked into this file.
    function resetAllToDefaults() {
        lastSnapshot = snapshotCurrent();
        applyValues(lg, lgDefaults);
    }

    function revertLastReset() {
        if (!lastSnapshot) return;
        applyValues(lg, lastSnapshot);
        lastSnapshot = null;
    }

    // Persists the CURRENT live values as the new default — everything
    // above (every per-setting ResetButton, and "Reset all") reads from
    // liquidGlassDefaults rather than a literal, so this is the only place
    // "the default" actually changes. Saves needing a code edit + rebuild
    // every time tuning settles somewhere new.
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
        icon: "layers"
        title: Translation.tr("Material")

        ConfigSelectionArray {
            currentValue: lg.material
            onSelected: newValue => { lg.material = newValue; }
            options: [
                { displayName: Translation.tr("Original"), icon: "water_drop", value: "main" },
                { displayName: Translation.tr("Lens"), icon: "lens_blur", value: "lens" },
                { displayName: Translation.tr("Pasted lens"), icon: "science", value: "aghajari" }
            ]
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("Which glass the compositor draws. \"Lens\" is the Aghajari-style recreation adapted for panels of any size; \"Pasted lens\" is the recreation exactly as you pasted it, with its numbers on sliders (at their defaults it is unchanged). Each material has its own tray of sliders below.")
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
            text: Translation.tr("A colour mixed over each panel's glass, set separately per panel and applied with any material. As with the original tint: the colour here is used in dark mode; light mode always uses white. Strength 0 = no tint.")
        }

        ContentSubsection {
            title: Translation.tr("Dock")
            Layout.fillWidth: true

            RowLayout {
                Layout.fillWidth: true
                MaterialTextArea {
                    Layout.fillWidth: true
                    placeholderText: Translation.tr("Tint colour (hex, dark mode only)")
                    text: lg.tintDock
                    wrapMode: TextEdit.Wrap
                    onTextChanged: {
                        lg.tintDock = text;
                    }
                }
                ResetButton {
                    onReset: function() { lg.tintDock = lgDefaults.tintDock; }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                ConfigSlider {
                    Layout.fillWidth: true
                    text: Translation.tr("Tint strength")
                    value: lg.tintDockStrength
                    usePercentTooltip: true
                    buttonIcon: "format_color_fill"
                    from: 0
                    to: 1
                    stopIndicatorValues: [lgDefaults.tintDockStrength]
                    onValueChanged: {
                        lg.tintDockStrength = value;
                    }
                }
                ResetButton {
                    onReset: function() { lg.tintDockStrength = lgDefaults.tintDockStrength; }
                }
            }
        }

        ContentSubsection {
            title: Translation.tr("Desktop widgets")
            Layout.fillWidth: true

            RowLayout {
                Layout.fillWidth: true
                MaterialTextArea {
                    Layout.fillWidth: true
                    placeholderText: Translation.tr("Tint colour (hex, dark mode only)")
                    text: lg.tintWidgets
                    wrapMode: TextEdit.Wrap
                    onTextChanged: {
                        lg.tintWidgets = text;
                    }
                }
                ResetButton {
                    onReset: function() { lg.tintWidgets = lgDefaults.tintWidgets; }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                ConfigSlider {
                    Layout.fillWidth: true
                    text: Translation.tr("Tint strength")
                    value: lg.tintWidgetsStrength
                    usePercentTooltip: true
                    buttonIcon: "format_color_fill"
                    from: 0
                    to: 1
                    stopIndicatorValues: [lgDefaults.tintWidgetsStrength]
                    onValueChanged: {
                        lg.tintWidgetsStrength = value;
                    }
                }
                ResetButton {
                    onReset: function() { lg.tintWidgetsStrength = lgDefaults.tintWidgetsStrength; }
                }
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
            RowLayout {
                Layout.fillWidth: true
                MaterialTextArea {
                    Layout.fillWidth: true
                    placeholderText: Translation.tr("Tint colour (hex, dark mode only)")
                    text: lg.tintSpotlight
                    wrapMode: TextEdit.Wrap
                    onTextChanged: {
                        lg.tintSpotlight = text;
                    }
                }
                ResetButton {
                    onReset: function() { lg.tintSpotlight = lgDefaults.tintSpotlight; }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                ConfigSlider {
                    Layout.fillWidth: true
                    text: Translation.tr("Tint strength")
                    value: lg.tintSpotlightStrength
                    usePercentTooltip: true
                    buttonIcon: "format_color_fill"
                    from: 0
                    to: 1
                    stopIndicatorValues: [lgDefaults.tintSpotlightStrength]
                    onValueChanged: {
                        lg.tintSpotlightStrength = value;
                    }
                }
                ResetButton {
                    onReset: function() { lg.tintSpotlightStrength = lgDefaults.tintSpotlightStrength; }
                }
            }
        }
    }

    Tray {
        title: Translation.tr("Original material sliders")
        icon: "water_drop"
        expanded: lg.material === "main"

    ContentSection {
        icon: "water_drop"
        title: Translation.tr("Shape & refraction")

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Corner shape")
                value: lg.power
                usePercentTooltip: false
                buttonIcon: "rounded_corner"
                from: 2
                to: 24
                stopIndicatorValues: [lgDefaults.power]
                onValueChanged: {
                    lg.power = value;
                }
            }
            ResetButton {
                onReset: function() { lg.power = lgDefaults.power; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("2 = a true circular arc, matching ii's own screen-corner rounding. Higher values get progressively more \"squircle\" (macOS-app-icon-like).")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Max radius: dock")
                value: lg.maxCornerRadius
                usePercentTooltip: false
                buttonIcon: "rounded_corner"
                from: 10
                to: 300
                stopIndicatorValues: [Math.min(lgDefaults.maxCornerRadius, 300)]
                onValueChanged: {
                    lg.maxCornerRadius = value;
                }
            }
            ResetButton {
                onReset: function() { lg.maxCornerRadius = lgDefaults.maxCornerRadius; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("Caps how big the corner radius can get, independent of the panel's own size. Default (9999) is a no-op — the dock and other panels keep the old \"fully round on the short axis\" pill look. Only lower this if a panel besides Spotlight starts looking over-rounded.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Max radius: Spotlight")
                value: lg.spotlightMaxCornerRadius
                usePercentTooltip: false
                buttonIcon: "rounded_corner"
                from: 4
                to: 60
                stopIndicatorValues: [lgDefaults.spotlightMaxCornerRadius]
                onValueChanged: {
                    lg.spotlightMaxCornerRadius = value;
                }
            }
            ResetButton {
                onReset: function() { lg.spotlightMaxCornerRadius = lgDefaults.spotlightMaxCornerRadius; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("Spotlight's own radius cap, separate from the one above — it's the one surface with enough text that an uncapped radius visibly curves into it once the results list expands the box tall. Defaults to 23px, matching ii's own screen-corner radius (Settings > Quick bar & screen > Screen round corner) rather than an arbitrary number.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                text: Translation.tr("Refraction sharpness")
                value: lg.fPower
                usePercentTooltip: false
                buttonIcon: "vital_signs"
                from: 0.2
                to: 5
                stopIndicatorValues: [lgDefaults.fPower]
                onValueChanged: {
                    lg.fPower = value;
                }
            }
            ResetButton {
                onReset: function() { lg.fPower = lgDefaults.fPower; }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                text: Translation.tr("Capture padding (px)")
                value: lg.pad
                usePercentTooltip: false
                buttonIcon: "crop"
                from: 10
                to: 200
                stopIndicatorValues: [lgDefaults.pad]
                onValueChanged: {
                    lg.pad = value;
                }
            }
            ResetButton {
                onReset: function() { lg.pad = lgDefaults.pad; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("How far beyond the shape's own edge the refraction can reach and pull in nearby content. Too high and it starts dragging in whole neighbouring widgets instead of a thin rim bend.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                text: Translation.tr("Refraction sample blur (px)")
                value: lg.blurPx
                usePercentTooltip: false
                buttonIcon: "blur_on"
                from: 0
                to: 20
                stopIndicatorValues: [lgDefaults.blurPx]
                onValueChanged: {
                    lg.blurPx = value;
                }
            }
            ResetButton {
                onReset: function() { lg.blurPx = lgDefaults.blurPx; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("Softens what the refraction itself samples — subtle, and part of the light-bending math.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                text: Translation.tr("Frosting (top layer, px)")
                value: lg.frostBlur
                usePercentTooltip: false
                buttonIcon: "blur_on"
                from: 0
                to: 64
                stopIndicatorValues: [lgDefaults.frostBlur]
                onValueChanged: {
                    lg.frostBlur = value;
                }
            }
            ResetButton {
                onReset: function() { lg.frostBlur = lgDefaults.frostBlur; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("Same technique the desktop widgets' frosted cards use (FrostedBackdrop.qml): blur + desaturate + darken slightly. The two sliders below control that desaturate/darken pair — they only kick in once Frosting above is turned up (frostAmount scales with frostBlur), so they do nothing while Frosting is 0.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                text: Translation.tr("Frost saturation")
                value: lg.frostSaturation
                usePercentTooltip: true
                buttonIcon: "invert_colors"
                from: 0
                to: 1
                stopIndicatorValues: [lgDefaults.frostSaturation]
                onValueChanged: {
                    lg.frostSaturation = value;
                }
            }
            ResetButton {
                onReset: function() { lg.frostSaturation = lgDefaults.frostSaturation; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("1 = full colour, 0 = fully grey.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                text: Translation.tr("Frost darken")
                value: lg.frostDarken
                usePercentTooltip: true
                buttonIcon: "brightness_4"
                from: 0
                to: 0.3
                stopIndicatorValues: [lgDefaults.frostDarken]
                onValueChanged: {
                    lg.frostDarken = value;
                }
            }
            ResetButton {
                onReset: function() { lg.frostDarken = lgDefaults.frostDarken; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("How much to dim the frosted glass, matching FrostedBackdrop.qml's brightness: -0.05.")
        }
    }

    ContentSection {
        icon: "tune"
        title: Translation.tr("Falloff curve")

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("Advanced: shapes exactly how fast refraction ramps up from the centre (no bend) to the edge (full bend). Leave alone unless the edge transition itself looks wrong — e.g. a sharp/broken-looking band instead of a smooth curve.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                text: Translation.tr("Curve a")
                value: lg.fa
                usePercentTooltip: false
                buttonIcon: "exposure"
                from: 0
                to: 3
                stopIndicatorValues: [lgDefaults.fa]
                onValueChanged: {
                    lg.fa = value;
                }
            }
            ResetButton {
                onReset: function() { lg.fa = lgDefaults.fa; }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                text: Translation.tr("Curve b")
                value: lg.fb
                usePercentTooltip: false
                buttonIcon: "exposure"
                from: 0
                to: 3
                stopIndicatorValues: [lgDefaults.fb]
                onValueChanged: {
                    lg.fb = value;
                }
            }
            ResetButton {
                onReset: function() { lg.fb = lgDefaults.fb; }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                text: Translation.tr("Curve c")
                value: lg.fc
                usePercentTooltip: false
                buttonIcon: "exposure"
                from: 0.1
                to: 15
                stopIndicatorValues: [lgDefaults.fc]
                onValueChanged: {
                    lg.fc = value;
                }
            }
            ResetButton {
                onReset: function() { lg.fc = lgDefaults.fc; }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                text: Translation.tr("Curve d")
                value: lg.fd
                usePercentTooltip: false
                buttonIcon: "exposure"
                from: 0
                to: 15
                stopIndicatorValues: [lgDefaults.fd]
                onValueChanged: {
                    lg.fd = value;
                }
            }
            ResetButton {
                onReset: function() { lg.fd = lgDefaults.fd; }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Rim gap")
                value: lg.rimGap
                usePercentTooltip: false
                buttonIcon: "line_curve"
                from: 0
                to: 0.6
                stopIndicatorValues: [lgDefaults.rimGap]
                onValueChanged: {
                    lg.rimGap = value;
                }
            }
            ResetButton {
                onReset: function() { lg.rimGap = lgDefaults.rimGap; }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Refraction strength")
                value: lg.refractStrength
                usePercentTooltip: false
                buttonIcon: "waves"
                from: 0.2
                to: 4
                stopIndicatorValues: [lgDefaults.refractStrength]
                onValueChanged: {
                    lg.refractStrength = value;
                }
            }
            ResetButton {
                onReset: function() { lg.refractStrength = lgDefaults.refractStrength; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("How deep/apparent the bend itself looks — 1.0 is the \"natural\" depth; higher makes the glass-bending effect more visually obvious.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Rim highlight")
                value: lg.rimHighlightStrength
                usePercentTooltip: true
                buttonIcon: "line_weight"
                from: 0
                to: 0.5
                stopIndicatorValues: [lgDefaults.rimHighlightStrength]
                onValueChanged: {
                    lg.rimHighlightStrength = value;
                }
            }
            ResetButton {
                onReset: function() { lg.rimHighlightStrength = lgDefaults.rimHighlightStrength; }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Rim highlight width (px)")
                value: lg.rimHighlightWidth
                usePercentTooltip: false
                buttonIcon: "line_weight"
                from: 0.2
                to: 6
                stopIndicatorValues: [lgDefaults.rimHighlightWidth]
                onValueChanged: {
                    lg.rimHighlightWidth = value;
                }
            }
            ResetButton {
                onReset: function() { lg.rimHighlightWidth = lgDefaults.rimHighlightWidth; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("The thin, distinct outline real Liquid Glass has right at its edge — a plain brightness lift toward white in a narrow band right at the boundary, applied after everything else so it's consistently visible regardless of what's behind. Width is a FIXED pixel value, not relative to the panel's own size — a size-relative width looked like a soft halo on Spotlight but a harder, more defined ring on the much bigger dock; a fixed px width reads the same on both. Strength 0 = no rim.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Rim highlight line length")
                value: lg.rimDiagonalReach
                usePercentTooltip: false
                buttonIcon: "line_weight"
                from: 0.2
                to: 3
                stopIndicatorValues: [lgDefaults.rimDiagonalReach]
                onValueChanged: {
                    lg.rimDiagonalReach = value;
                }
            }
            ResetButton {
                onReset: function() { lg.rimDiagonalReach = lgDefaults.rimDiagonalReach; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("How far the bright/dim diagonal lighting effect (the top-left/bottom-right corner pop, top-right/bottom-left fade) reaches along a FLAT edge before settling back to baseline. Lower = the bright lines stretch further along the border; higher = they stay tight right at the corners. 1.0 is the original, linear falloff.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Chromatic aberration (px)")
                value: lg.chromaticAberration
                usePercentTooltip: false
                buttonIcon: "gradient"
                from: 0
                to: 10
                stopIndicatorValues: [lgDefaults.chromaticAberration]
                onValueChanged: {
                    lg.chromaticAberration = value;
                }
            }
            ResetButton {
                onReset: function() { lg.chromaticAberration = lgDefaults.chromaticAberration; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("Subtle rainbow fringing at the rim, like real glass splitting light by wavelength — offsets red/blue oppositely right at the same rim band as above, green stays true. 0 = off.")
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("How far in from the very edge the bend ramps up from ~0 before the curve above takes over — without this, the bend is already at its strongest exactly at the boundary. 0 = old behaviour (no gap, content touches the edge immediately). Higher pushes the visible bend further from the edge.")
        }
    }

    ContentSection {
        icon: "palette"
        title: Translation.tr("Tint")

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("Legibility is handled automatically (the floor strengthens over bright content, relaxes over dark content — same approach Apple's own Liquid Glass uses). Tint here is purely a cosmetic accent, kept subtle on purpose.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                text: Translation.tr("Base (luminance floor) opacity")
                value: lg.baseOpacity
                usePercentTooltip: true
                buttonIcon: "opacity"
                from: 0
                to: 1
                stopIndicatorValues: [lgDefaults.baseOpacity]
                onValueChanged: {
                    lg.baseOpacity = value;
                }
            }
            ResetButton {
                onReset: function() { lg.baseOpacity = lgDefaults.baseOpacity; }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Floor minimum")
                value: lg.minFloor
                usePercentTooltip: true
                buttonIcon: "opacity"
                from: 0
                to: 0.8
                stopIndicatorValues: [lgDefaults.minFloor]
                onValueChanged: {
                    lg.minFloor = value;
                }
            }
            ResetButton {
                onReset: function() { lg.minFloor = lgDefaults.minFloor; }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Busy content floor")
                value: lg.busynessStrength
                usePercentTooltip: false
                buttonIcon: "blur_on"
                from: 0
                to: 2
                stopIndicatorValues: [lgDefaults.busynessStrength]
                onValueChanged: {
                    lg.busynessStrength = value;
                }
            }
            ResetButton {
                onReset: function() { lg.busynessStrength = lgDefaults.busynessStrength; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("Reimplemented — a work in progress. Pushes the floor up over LOCALLY high-contrast backdrops (e.g. half-dark half-bright photos) that the average-brightness floor above can miss. This is a continuous contribution, not a threshold — an earlier threshold-based version of this caused a 'duplicate text' artifact, which is why this exists as a separate, simpler control rather than folded into the floor above. 0 = off.")
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("The hard floor the legibility mechanism above can never blend below, regardless of the Base opacity slider — this was hardcoded before and unreachable from any setting. Higher keeps a guaranteed presence over any background (never fully invisible) but reads softer/hazier — \"jello\" rather than a defined glass pane. Lower for a crisper, more refraction-dominant look; content behind can look a bit washed out over very bright backgrounds if pushed too low.")
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("This is the dark-mode tint — light mode ignores it and always uses white instead, the same way this shell's own text colours already flip between light/dark automatically. Note: the dock, desktop widgets and Spotlight each have their own tint under \"Panel tint\" at the top, which takes over from this one on those panels.")
        }

        RowLayout {
            Layout.fillWidth: true
            MaterialTextArea {
                Layout.fillWidth: true
                placeholderText: Translation.tr("Tint colour (hex, dark mode only)")
                text: lg.tint
                wrapMode: TextEdit.Wrap
                onTextChanged: {
                    lg.tint = text;
                }
            }
            ResetButton {
                onReset: function() { lg.tint = lgDefaults.tint; }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                text: Translation.tr("Tint strength")
                value: lg.tintStrength
                usePercentTooltip: true
                buttonIcon: "format_color_fill"
                from: 0
                to: 1
                stopIndicatorValues: [lgDefaults.tintStrength]
                onValueChanged: {
                    lg.tintStrength = value;
                }
            }
            ResetButton {
                onReset: function() { lg.tintStrength = lgDefaults.tintStrength; }
            }
        }
    }

    }

    Tray {
        title: Translation.tr("Lens material sliders")
        icon: "lens_blur"
        expanded: lg.material === "lens"

    ContentSection {
        icon: "lens_blur"
        title: Translation.tr("Lens")

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Rim width (px)")
                value: lg.lensRimPx
                usePercentTooltip: false
                buttonIcon: "line_curve"
                from: 4
                to: 80
                stopIndicatorValues: [lgDefaults.lensRimPx]
                onValueChanged: {
                    lg.lensRimPx = value;
                }
            }
            ResetButton {
                onReset: function() { lg.lensRimPx = lgDefaults.lensRimPx; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("How far in from the edge the glass bends, in pixels (ShojiWM's default, 30). Keep it near the panels' corner radius: much deeper than the corners (widgets have 22px corners) and the bend has to fold along the corner diagonals — the \"split into four\" look. Measured seam-free up to about 30px.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Bend strength")
                value: lg.lensStrength
                usePercentTooltip: false
                buttonIcon: "waves"
                from: 0
                to: 1
                stopIndicatorValues: [lgDefaults.lensStrength]
                onValueChanged: {
                    lg.lensStrength = value;
                }
            }
            ResetButton {
                onReset: function() { lg.lensStrength = lgDefaults.lensStrength; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("How far the rim pulls in what's behind it, as a fraction of the rim width. 1 = the very edge shows what sits at the rim's inner edge (ShojiWM caps it there too), so nothing is ever pulled in from across the panel.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Sample softness (px)")
                value: lg.lensBlur
                usePercentTooltip: false
                buttonIcon: "blur_on"
                from: 0
                to: 4
                stopIndicatorValues: [lgDefaults.lensBlur]
                onValueChanged: {
                    lg.lensBlur = value;
                }
            }
            ResetButton {
                onReset: function() { lg.lensBlur = lgDefaults.lensBlur; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("Spacing of the recreation's small 5x5 softening under the lens, strongest in the middle. 0 = crisp, and cheapest.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Chromatic split (px)")
                value: lg.lensChroma
                usePercentTooltip: false
                buttonIcon: "gradient"
                from: 0
                to: 10
                stopIndicatorValues: [lgDefaults.lensChroma]
                onValueChanged: {
                    lg.lensChroma = value;
                }
            }
            ResetButton {
                onReset: function() { lg.lensChroma = lgDefaults.lensChroma; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("Red/blue fringing right at the edge, pushed along the edge's own direction. 0 = off.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Brightness")
                value: lg.lensTint
                usePercentTooltip: true
                buttonIcon: "brightness_6"
                from: 0.5
                to: 1.2
                stopIndicatorValues: [lgDefaults.lensTint]
                onValueChanged: {
                    lg.lensTint = value;
                }
            }
            ResetButton {
                onReset: function() { lg.lensTint = lgDefaults.lensTint; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("Multiplies the glass's colour. The recreation darkens slightly (0.90); 1.0 = neutral.")
        }
    }
    }

    Tray {
        title: Translation.tr("Pasted lens sliders")
        icon: "science"
        expanded: lg.material === "aghajari"

    ContentSection {
        icon: "science"
        title: Translation.tr("Pasted lens")

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Stretch along long side")
                value: lg.aghStretch
                usePercentTooltip: true
                buttonIcon: "width"
                from: 0
                to: 1
                stopIndicatorValues: [lgDefaults.aghStretch]
                onValueChanged: {
                    lg.aghStretch = value;
                }
            }
            ResetButton {
                onReset: function() { lg.aghStretch = lgDefaults.aghStretch; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("0 = exactly the pasted shader: everything bends away from the panel's centre point, which suits round panels but smears sideways along long ones like the dock. 1 = the centre becomes a line along the long side, so long edges bend straight across while the rounded ends behave like the paste. Round and square panels look the same either way.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Distortion depth")
                value: lg.aghDepth
                usePercentTooltip: false
                buttonIcon: "line_curve"
                from: 0.02
                to: 0.5
                stopIndicatorValues: [lgDefaults.aghDepth]
                onValueChanged: {
                    lg.aghDepth = value;
                }
            }
            ResetButton {
                onReset: function() { lg.aghDepth = lgDefaults.aghDepth; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("How far in from the edge the distortion reaches, as a fraction of the panel's short side. Original: 0.3.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Distortion strength")
                value: lg.aghStrength
                usePercentTooltip: false
                buttonIcon: "waves"
                from: 0
                to: 2
                stopIndicatorValues: [lgDefaults.aghStrength]
                onValueChanged: {
                    lg.aghStrength = value;
                }
            }
            ResetButton {
                onReset: function() { lg.aghStrength = lgDefaults.aghStrength; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("How hard the glass pulls what's behind it toward the middle. 1 = original, which pulls the very edge all the way to the centre — on big panels that is what brings content in from the far side. Lower it to keep the pull local.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Softness (px)")
                value: lg.aghBlur
                usePercentTooltip: false
                buttonIcon: "blur_on"
                from: 0
                to: 4
                stopIndicatorValues: [lgDefaults.aghBlur]
                onValueChanged: {
                    lg.aghBlur = value;
                }
            }
            ResetButton {
                onReset: function() { lg.aghBlur = lgDefaults.aghBlur; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("Spacing of the small 5x5 softening, strongest in the middle. Original: 1.2. 0 = crisp.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Chromatic shift (px)")
                value: lg.aghChroma
                usePercentTooltip: false
                buttonIcon: "gradient"
                from: 0
                to: 10
                stopIndicatorValues: [lgDefaults.aghChroma]
                onValueChanged: {
                    lg.aghChroma = value;
                }
            }
            ResetButton {
                onReset: function() { lg.aghChroma = lgDefaults.aghChroma; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("Red/blue split, pointing away from the centre. Original: 3.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Chromatic fade-in")
                value: lg.aghEdge
                usePercentTooltip: false
                buttonIcon: "line_weight"
                from: 0.001
                to: 0.2
                stopIndicatorValues: [lgDefaults.aghEdge]
                onValueChanged: {
                    lg.aghEdge = value;
                }
            }
            ResetButton {
                onReset: function() { lg.aghEdge = lgDefaults.aghEdge; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("How far in from the edge the colour split takes to reach full strength, as a fraction of the short side. Original: 0.02 (almost immediately).")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Brightness")
                value: lg.aghTint
                usePercentTooltip: true
                buttonIcon: "brightness_6"
                from: 0.5
                to: 1.2
                stopIndicatorValues: [lgDefaults.aghTint]
                onValueChanged: {
                    lg.aghTint = value;
                }
            }
            ResetButton {
                onReset: function() { lg.aghTint = lgDefaults.aghTint; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("Multiplies the glass colour. Original: 0.90; 1.0 = neutral.")
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
            text: Translation.tr("Apple's approach: each panel measures what's behind it as a whole and adjusts itself as one — never pixel by pixel, which is what made the old floor stripe. Both at 0 = off.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Contrast squash")
                value: lg.aghSquash
                usePercentTooltip: true
                buttonIcon: "contrast"
                from: 0
                to: 1
                stopIndicatorValues: [lgDefaults.aghSquash]
                onValueChanged: {
                    lg.aghSquash = value;
                }
            }
            ResetButton {
                onReset: function() { lg.aghSquash = lgDefaults.aghSquash; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("How much a busy backdrop's contrast is flattened behind the glass. Calm backdrops pass through untouched; busier ones get squashed more, up to this amount.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Glass body")
                value: lg.aghBody
                usePercentTooltip: true
                buttonIcon: "light_mode"
                from: 0
                to: 0.4
                stopIndicatorValues: [lgDefaults.aghBody]
                onValueChanged: {
                    lg.aghBody = value;
                }
            }
            ResetButton {
                onReset: function() { lg.aghBody = lgDefaults.aghBody; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("A faint light of the glass's own. The lens only moves what's behind it around, so over a dark background it was just as dark — a black shape with a rim. This lifts the whole panel evenly, so it reads as a sheet of glass. 0 = off.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Brightness push")
                value: lg.aghPush
                usePercentTooltip: false
                buttonIcon: "brightness_medium"
                from: 0
                to: 0.4
                stopIndicatorValues: [lgDefaults.aghPush]
                onValueChanged: {
                    lg.aghPush = value;
                }
            }
            ResetButton {
                onReset: function() { lg.aghPush = lgDefaults.aghPush; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("Only when needed: once what's behind gets close to the text's own brightness, the glass shifts away from it (darker under white text, lighter under dark text). A backdrop that already contrasts with the text is left alone.")
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
            text: Translation.tr("The white outline from the original material — brightest along the top-left and bottom-right, fading out at the other two corners. Same settings as the rim highlight in the original tray; moving one moves both.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Rim highlight")
                value: lg.rimHighlightStrength
                usePercentTooltip: true
                buttonIcon: "line_weight"
                from: 0
                to: 0.5
                stopIndicatorValues: [lgDefaults.rimHighlightStrength]
                onValueChanged: {
                    lg.rimHighlightStrength = value;
                }
            }
            ResetButton {
                onReset: function() { lg.rimHighlightStrength = lgDefaults.rimHighlightStrength; }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Rim highlight width (px)")
                value: lg.rimHighlightWidth
                usePercentTooltip: false
                buttonIcon: "line_weight"
                from: 0.2
                to: 6
                stopIndicatorValues: [lgDefaults.rimHighlightWidth]
                onValueChanged: {
                    lg.rimHighlightWidth = value;
                }
            }
            ResetButton {
                onReset: function() { lg.rimHighlightWidth = lgDefaults.rimHighlightWidth; }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                textWidth: 140
                text: Translation.tr("Rim highlight line length")
                value: lg.rimDiagonalReach
                usePercentTooltip: false
                buttonIcon: "line_weight"
                from: 0.2
                to: 3
                stopIndicatorValues: [lgDefaults.rimDiagonalReach]
                onValueChanged: {
                    lg.rimDiagonalReach = value;
                }
            }
            ResetButton {
                onReset: function() { lg.rimDiagonalReach = lgDefaults.rimDiagonalReach; }
            }
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
            text: Translation.tr("Translucent-white \"chip\" overlays behind individual controls on the glass — the search bar's icons, the search box itself, and the highlighted search result row (keyboard or mouse) all share these two values, so they brighten together.")
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                text: Translation.tr("Chip opacity (resting)")
                value: lg.chipOpacity
                usePercentTooltip: true
                buttonIcon: "check_box_outline_blank"
                from: 0
                to: 0.5
                stopIndicatorValues: [lgDefaults.chipOpacity]
                onValueChanged: {
                    lg.chipOpacity = value;
                }
            }
            ResetButton {
                onReset: function() { lg.chipOpacity = lgDefaults.chipOpacity; }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                text: Translation.tr("Chip opacity (hovered/selected)")
                value: lg.chipOpacityHover
                usePercentTooltip: true
                buttonIcon: "check_box"
                from: 0
                to: 0.8
                stopIndicatorValues: [lgDefaults.chipOpacityHover]
                onValueChanged: {
                    lg.chipOpacityHover = value;
                }
            }
            ResetButton {
                onReset: function() { lg.chipOpacityHover = lgDefaults.chipOpacityHover; }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            ConfigSlider {
                Layout.fillWidth: true
                text: Translation.tr("Chip boost with squash")
                value: lg.chipSquashBoost
                usePercentTooltip: true
                buttonIcon: "exposure_plus_1"
                from: 0
                to: 0.6
                stopIndicatorValues: [lgDefaults.chipSquashBoost]
                onValueChanged: {
                    lg.chipSquashBoost = value;
                }
            }
            ResetButton {
                onReset: function() { lg.chipSquashBoost = lgDefaults.chipSquashBoost; }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: 4
            Layout.bottomMargin: 4
            wrapMode: Text.Wrap
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colSubtext
            text: Translation.tr("With the Pasted lens: chips get more opaque as the Readability squash flattens a busy backdrop — added opacity = this × squash × how busy the backdrop is. So they stay visible exactly when the glass is working hardest. 0 = off.")
        }
    }
}
