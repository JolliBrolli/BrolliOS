import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import Qt.labs.synchronizer
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

Scope {
    id: overviewScope
    property bool dontAutoCancelSearch: false

    // PLUGIN-TEST SHELL COPY: the dim scrim used to be a Rectangle filling the
    // main overview panel, which is why that panel had to span the whole
    // monitor. That forced the compositor glass plugin to treat a full-screen
    // box as Spotlight's shape: its blur region became the entire display
    // (~5.2M px) to serve a panel of a few hundred thousand, and the panel's
    // silhouette could only be told apart from the scrim by colour.
    //
    // Splitting the scrim into its own layer lets the panel shrink to its
    // content. Declared first so it stacks below the panel; masked to an
    // empty region so it takes no input, exactly like the Rectangle did.
    PanelWindow {
        id: dimWindow
        visible: GlobalStates.overviewOpen || dimScrim.opacity > 0
        WlrLayershell.namespace: "quickshell:overviewDim"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        mask: Region {}
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        Rectangle {
            id: dimScrim
            anchors.fill: parent
            color: "black"
            opacity: GlobalStates.overviewOpen ? 0.35 : 0.0
            visible: opacity > 0
            Behavior on opacity {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }
        }
    }

    PanelWindow {
        id: panelWindow
        property string searchingText: ""
        readonly property HyprlandMonitor monitor: Hyprland.monitorFor(panelWindow.screen)
        property bool monitorIsFocused: (Hyprland.focusedMonitor?.id == monitor?.id)
        visible: GlobalStates.overviewOpen

        WlrLayershell.namespace: "quickshell:overview"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: GlobalStates.overviewOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        color: "transparent"
        // This used to span the TRUE full monitor because SearchWidget's own
        // liquid-glass background captured the whole screen and cropped by
        // this window's coordinates. That capture no longer exists — the
        // compositor plugin supplies the backdrop — so the window can size to
        // its content, which is what makes the plugin's blur region small.
        exclusionMode: ExclusionMode.Ignore

        mask: Region {
            item: GlobalStates.overviewOpen ? columnLayout : null
        }

        // Top-anchored only: layer-shell centres an unanchored axis, so this
        // sits top-centre at implicitWidth/implicitHeight (columnLayout's own
        // size, set below) instead of covering the display.
        //
        // The vertical placement has to come from the SCREEN, not from this
        // window. columnLayout used to position itself with
        // `topMargin: (parent.height - collapsedHeight) / 2`, which read the
        // window's height — fine while the window WAS the screen. Once the
        // window sizes to its content that became circular (window height <-
        // content height <- top margin <- window height), and the panel
        // started near the top and crept downward as results grew. Same
        // intent, expressed against a fixed reference.
        anchors {
            top: true
        }
        margins.top: Math.max(0, ((panelWindow.screen?.height ?? 0) - searchWidget.collapsedHeight) / 2)

        Connections {
            target: GlobalStates
            function onOverviewOpenChanged() {
                if (!GlobalStates.overviewOpen) {
                    // Release the grown size once the panel is closed, so the
                    // next open starts from the collapsed bar again instead of
                    // inheriting however far this session expanded.
                    panelWindow.grownWidth = 0;
                    panelWindow.grownHeight = 0;
                    searchWidget.disableExpandAnimation();
                    overviewScope.dontAutoCancelSearch = false;
                    GlobalFocusGrab.dismiss();
                } else {
                    if (!overviewScope.dontAutoCancelSearch) {
                        searchWidget.cancelSearch();
                    }
                    GlobalFocusGrab.addDismissable(panelWindow);
                }
            }
        }

        Connections {
            target: GlobalFocusGrab
            function onDismissed() {
                GlobalStates.overviewOpen = false;
            }
        }
        // Padded by elevationMargin on each side so SearchWidget's drop shadow
        // (StyledRectangularShadow, which draws outside its target's bounds)
        // still has room. The old full-screen window gave it that for free.
        //
        // QUANTISED, and that matters. searchWidgetContent animates its own
        // implicitHeight (Behavior on implicitHeight, elementMove) as results
        // populate. While this window spanned the monitor that animation was
        // purely internal — the surface never changed size. Sizing the window
        // to its content turned every frame of that animation into a real
        // layer-surface resize, configure and buffer commit included, and the
        // result never settled: measured heights bounced 283 -> 280 -> 283 ->
        // 278 -> 280 and were still oscillating 270 <-> 271 long after the
        // animation should have finished. That oscillation is what read as
        // flicker.
        //
        // Rounding up to a step means a few pixels of movement keep landing
        // in the same bucket, so the surface simply does not resize: the
        // animation goes back to being internal, while the box stays far
        // smaller than the display (which is what the plugin's blur region
        // cares about). The step is deliberately coarse relative to the
        // animation's per-frame delta.
        // ...and MONOTONIC while open, which quantising alone did not give.
        // elementMove's easing overshoots its target by a pixel or two, and
        // near a bucket boundary that overshoot promotes itself into a full
        // step: measured 384 -> 320 -> 448 -> 384 -> 448 -> 512 -> 576 -> 448,
        // two steps forward and one back, so the coarser step made each
        // visible jump bigger rather than removing it.
        //
        // Growing only (until the panel closes and this resets) means an
        // overshoot cannot move the surface at all. The panel still shrinks
        // back visually — that is the content animating inside a window that
        // simply stays as large as it has needed to be this session.
        readonly property int sizeStep: 64
        property int grownWidth: 0
        property int grownHeight: 0

        readonly property int wantedWidth: Math.ceil((columnLayout.implicitWidth + Appearance.sizes.elevationMargin * 2) / sizeStep) * sizeStep
        readonly property int wantedHeight: Math.ceil((columnLayout.implicitHeight + Appearance.sizes.elevationMargin * 2) / sizeStep) * sizeStep

        onWantedWidthChanged: if (wantedWidth > grownWidth) grownWidth = wantedWidth
        onWantedHeightChanged: if (wantedHeight > grownHeight) grownHeight = wantedHeight

        // FLOOR the size at the search panel's own maximum, so typing never
        // resizes the surface at all.
        //
        // Neither quantising nor monotonic requests fixed the flicker, and the
        // frame-tagged compositor log shows why: every size "drop" landed
        // EXACTLY on the committed texture's size. That is the layer-shell
        // configure/commit handshake, not an oscillation — Hyprland advances
        // the geometry to the size just requested, then falls back to the size
        // of the buffer the client actually has, until the client catches up.
        // Measured over one expand:
        //     box=512 tex=448 -> box=448 tex=448 -> box=512 tex=512
        //     box=640 tex=512 -> box=512 tex=512 -> box=576 tex=576
        // The client's own requests were strictly monotonic throughout
        // (256, 320, 384, ... 768), so no amount of well-behaved sizing on the
        // QML side avoids this. ANY resize produces it.
        //
        // The original never flickered because it spanned the monitor and
        // never resized. This keeps that property — a surface that does not
        // change size — while staying small enough that the plugin's blur
        // region is still a fraction of the display. The results list caps
        // itself at 600px (SearchWidget.qml), so the search panel's maximum is
        // knowable up front rather than discovered by resizing into it.
        //
        // grown*/wanted* remain as the fallback for anything TALLER than this
        // floor (the workspace overview), where a resize is a discrete user
        // action rather than a per-keystroke animation.
        // One step of headroom on top of the computed maximum, because the
        // computation lands exactly ON a step boundary and the real content is
        // a hair over it. Measured: collapsedHeight 84 + list cap 600 +
        // margins 20 = 704, quantising to 704 — while a full result list
        // actually reports colImplicit 685.45, i.e. 705.45 with margins, which
        // rounds up to 768. So a *completely* filled list crossed the floor by
        // a single step and paid for a real resize (and its flash), while a
        // short list stayed under it and was clean. The gap is the column's
        // own spacing, which this formula has no view of.
        //
        // Rather than chase the exact figure, take the next step up: the cost
        // is a marginally larger blur box, and the benefit is that no search
        // result count can resize the surface.
        readonly property int searchFloorWidth: Math.ceil((640 + Appearance.sizes.elevationMargin * 2) / sizeStep) * sizeStep + sizeStep
        readonly property int searchFloorHeight: Math.ceil((searchWidget.collapsedHeight + 600 + Appearance.sizes.elevationMargin * 2) / sizeStep) * sizeStep + sizeStep

        implicitWidth: Math.max(grownWidth, wantedWidth, searchFloorWidth)
        implicitHeight: Math.max(grownHeight, wantedHeight, searchFloorHeight)


        function setSearchingText(text) {
            searchWidget.setSearchingText(text);
            searchWidget.focusFirstItem();
        }

        // (dim scrim now lives in dimWindow above — see the comment there)

        Column {
            id: columnLayout
            visible: GlobalStates.overviewOpen
            anchors {
                horizontalCenter: parent.horizontalCenter
                top: parent.top
                // Vertical placement moved up to the window's own margins.top,
                // computed from the SCREEN height — see the comment there for
                // why reading parent.height here is now circular. The intent
                // is unchanged: the collapsed bar sits where a true vertical
                // centre would put it, and results drop down below it rather
                // than re-centring the whole panel.
                topMargin: 0
            }
            spacing: -8

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    GlobalStates.overviewOpen = false;
                }
            }

            SearchWidget {
                id: searchWidget
                screen: panelWindow.screen
                anchors.horizontalCenter: parent.horizontalCenter
                Synchronizer on searchingText {
                    property alias source: panelWindow.searchingText
                }
            }

            Loader {
                id: overviewLoader
                anchors.horizontalCenter: parent.horizontalCenter
                active: GlobalStates.overviewOpen && (Config?.options.overview.enable ?? true)
                sourceComponent: OverviewWidget {
                    screen: panelWindow.screen
                    visible: (panelWindow.searchingText == "")
                }
            }
        }
    }

    function toggleClipboard() {
        if (GlobalStates.overviewOpen && overviewScope.dontAutoCancelSearch) {
            GlobalStates.overviewOpen = false;
            return;
        }
        overviewScope.dontAutoCancelSearch = true;
        panelWindow.setSearchingText(Config.options.search.prefix.clipboard);
        GlobalStates.overviewOpen = true;
    }

    function toggleEmojis() {
        if (GlobalStates.overviewOpen && overviewScope.dontAutoCancelSearch) {
            GlobalStates.overviewOpen = false;
            return;
        }
        overviewScope.dontAutoCancelSearch = true;
        panelWindow.setSearchingText(Config.options.search.prefix.emojis);
        GlobalStates.overviewOpen = true;
    }

    IpcHandler {
        target: "search"

        function toggle() {
            GlobalStates.overviewOpen = !GlobalStates.overviewOpen;
        }
        function workspacesToggle() {
            GlobalStates.overviewOpen = !GlobalStates.overviewOpen;
        }
        function close() {
            GlobalStates.overviewOpen = false;
        }
        function open() {
            GlobalStates.overviewOpen = true;
        }
        function toggleReleaseInterrupt() {
            GlobalStates.superReleaseMightTrigger = false;
        }
        function clipboardToggle() {
            overviewScope.toggleClipboard();
        }
    }

    GlobalShortcut {
        name: "searchToggle"
        description: "Toggles search on press"

        onPressed: {
            GlobalStates.overviewOpen = !GlobalStates.overviewOpen;
        }
    }
    GlobalShortcut {
        name: "overviewWorkspacesClose"
        description: "Closes overview on press"

        onPressed: {
            GlobalStates.overviewOpen = false;
        }
    }
    GlobalShortcut {
        name: "overviewWorkspacesToggle"
        description: "Toggles overview on press"

        onPressed: {
            GlobalStates.overviewOpen = !GlobalStates.overviewOpen;
        }
    }
    GlobalShortcut {
        name: "searchToggleRelease"
        description: "Toggles search on release"

        onPressed: {
            GlobalStates.superReleaseMightTrigger = true;
        }

        onReleased: {
            if (!GlobalStates.superReleaseMightTrigger) {
                GlobalStates.superReleaseMightTrigger = true;
                return;
            }
            GlobalStates.overviewOpen = !GlobalStates.overviewOpen;
        }
    }
    GlobalShortcut {
        name: "searchToggleReleaseInterrupt"
        description: "Interrupts possibility of search being toggled on release. " + "This is necessary because GlobalShortcut.onReleased in quickshell triggers whether or not you press something else while holding the key. " + "To make sure this works consistently, use binditn = MODKEYS, catchall in an automatically triggered submap that includes everything."

        onPressed: {
            GlobalStates.superReleaseMightTrigger = false;
        }
    }
    GlobalShortcut {
        name: "overviewClipboardToggle"
        description: "Toggle clipboard query on overview widget"

        onPressed: {
            overviewScope.toggleClipboard();
        }
    }

    GlobalShortcut {
        name: "overviewEmojiToggle"
        description: "Toggle emoji query on overview widget"

        onPressed: {
            overviewScope.toggleEmojis();
        }
    }
}
