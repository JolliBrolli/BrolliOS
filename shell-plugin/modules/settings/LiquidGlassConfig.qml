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
            chipOpacity: lg.chipOpacity, chipOpacityHover: lg.chipOpacityHover
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
        target.chipOpacity = s.chipOpacity; target.chipOpacityHover = s.chipOpacityHover;
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
            text: Translation.tr("This is the dark-mode tint — light mode ignores it and always uses white instead, the same way this shell's own text colours already flip between light/dark automatically.")
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
    }
}
