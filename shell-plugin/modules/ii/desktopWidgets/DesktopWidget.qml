pragma ComponentBehavior: Bound

import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.widgets.glass
import QtQuick

/**
 * Shared chrome for anything that lives on the wallpaper.
 *
 * Every desktop widget is this container plus a content item. The container
 * owns the parts that are identical for all of them — frosted material, the
 * drag strip, resize grips, position and size persistence, snapping, and the
 * right-click menu's placement — so a new widget is a face and nothing else.
 *
 * Sizing is one-directional, and has to stay that way: the content declares its
 * own implicitHeight, the container takes that plus padding. Anchoring content
 * to the container's bottom edge puts height on both sides of one binding and
 * QML silently resolves it to zero, which renders the widget invisible with no
 * error to go on.
 */
Item {
    id: widget

    required property string widgetId
    required property var config
    // The board this belongs to. Supplies screen size, the sibling list used
    // for snapping, and the guide overlay.
    required property var board

    property real padding: 16
    property real cardRadius: 22
    property real dragHandleHeight: 56

    property bool resizableWidth: true
    property bool resizableVertical: true
    property real minWidth: 200
    property real maxWidth: 700
    property real minVertical: 40
    property real maxVertical: 900

    // Menu shown on right-click. Given `open` and `requestClose` by the container.
    property Component menuComponent: null

    // Content sets this true while a text field holds focus, so the board knows
    // to keep asking for keys.
    property bool inputActive: false
    // Content raises this when the user backs out of typing.
    signal dismissed()

    default property alias contentData: contentHolder.data
    // Full-bleed slot above the content and below the grips, for a face that
    // has to cover the whole card (the todo widget's duration picker). A padded
    // content slot would leave a frame of card showing around it.
    property alias overlayData: overlayHolder.data

    readonly property real screenWidth: widget.board?.screenWidth ?? 1920
    readonly property real screenHeight: widget.board?.screenHeight ?? 1080

    // ── Gesture state ─────────────────────────────────────────────
    property bool dragging: false
    property bool resizing: false
    readonly property bool interacting: widget.dragging || widget.resizing

    property bool menuOpen: false
    property point menuPos: Qt.point(0, 0)

    // Live gesture values. Config is written once, on release — writing it per
    // motion event pushes the whole options object through JsonAdapter
    // serialisation and restarts the debounced file write dozens of times a
    // second, which is what made resizing feel like it was fighting back.
    property real pendingWidth: -1
    property real pendingVertical: -1

    readonly property real verticalSize: widget.pendingVertical >= 0
        ? widget.pendingVertical
        : (widget.config.contentHeight ?? 0)

    implicitWidth: widget.pendingWidth >= 0 ? widget.pendingWidth : widget.config.width
    implicitHeight: contentHolder.implicitHeight + widget.padding * 2

    // ── Position ──────────────────────────────────────────────────
    // True once the surface and the widget both have real geometry. Until then
    // any clamp is meaningless: the layer surface starts at zero width, so
    // `screenWidth - width` is negative and every widget pins to the top-left
    // corner. That is exactly what happened when this logic moved out of the
    // host, which used to re-run it on every window resize.
    readonly property bool sized: widget.screenWidth > 0 && widget.screenHeight > 0
        && widget.width > 0 && widget.height > 0

    function clampX(v) {
        const max = widget.screenWidth - widget.width;
        if (!(max > 0)) return v;
        return Math.max(0, Math.min(v, max));
    }
    function clampY(v) {
        const max = widget.screenHeight - widget.height;
        if (!(max > 0)) return v;
        return Math.max(0, Math.min(v, max));
    }

    function restorePosition() {
        if (!widget.sized) return;
        widget.x = widget.clampX(widget.config.x);
        widget.y = widget.clampY(widget.config.y);
    }

    // Re-apply as soon as the geometry becomes real, and whenever it changes
    // afterwards — the screen can be resized and the card grows with its
    // content. Never mid-gesture, or it would fight the drag.
    onSizedChanged: widget.restorePosition()
    onWidthChanged: if (!widget.interacting) widget.restorePosition()
    onHeightChanged: if (!widget.interacting) widget.restorePosition()

    Connections {
        target: widget.board
        function onScreenWidthChanged() { widget.restorePosition(); }
        function onScreenHeightChanged() { widget.restorePosition(); }
    }

    // The single place a finished gesture becomes a stored position. Placement
    // mode is applied here and nowhere else, so free/snap/grid stay one concept
    // rather than three code paths.
    function commitPosition() {
        // Never persist a position derived from geometry we do not have yet.
        if (!widget.sized) return;
        const placed = widget.board.placeWidget(widget, widget.x, widget.y);
        widget.x = widget.clampX(placed.x);
        widget.y = widget.clampY(placed.y);
        widget.config.x = Math.round(widget.x);
        widget.config.y = Math.round(widget.y);
        widget.board.clearGuides();
    }

    Component.onCompleted: {
        widget.restorePosition();
        widget.board.register(widget);
    }
    Component.onDestruction: widget.board.unregister(widget)

    // Backing out of a field should return the keyboard to whatever app had it.
    onDismissed: widget.board.releaseFocus()

    Connections {
        target: widget.config
        // Nothing re-applied the stored position when the value changed, so
        // editing it (or "Reset position") moved the number and left the widget
        // where it was.
        function onXChanged() { if (!widget.dragging) widget.x = widget.clampX(widget.config.x); }
        function onYChanged() { if (!widget.dragging) widget.y = widget.clampY(widget.config.y); }
    }

    // ── Material ──────────────────────────────────────────────────
    // Was FrostedBackdrop (a static blurred copy of the wallpaper FILE, not
    // a live capture). Swapped for the same live liquid-glass material as
    // Spotlight/the dock, now backed by the SHARED per-monitor capture
    // (GlassCaptureService) rather than its own — the shader draws the
    // entire visible shape itself (SDF + AA edge), so cardBackground below
    // no longer needs its own border.
    // Exposed so subclasses (ClockCard/TodoCard/CalendarCard) can wire
    // AdaptiveGlassText for their own on-glass text — see LiquidGlassBackground
    // .qml's currentBackdropTexture and this pattern's other use in
    // MacDock.qml.
    property alias glassBackground: widgetGlass
    LiquidGlassBackground {
        id: widgetGlass
        anchors.fill: parent
        screen: widget.board?.screen ?? null
        cornerRadiusOverride: widget.cardRadius
        // Opts this card into the compositor glass plugin. The widgets layer is
        // WlrLayer.Bottom, which the plugin queues at RENDER_POST_WALLPAPER so
        // the glass sits under any window covering the card, not over it.
        glassNamespace: "quickshell:desktopWidgets"
        // Desktop widgets sit on WlrLayer.Bottom — anything actually in
        // front of one (a window) would occlude it entirely in the real
        // compositor output, so the only thing a widget can ever
        // legitimately show behind itself is the wallpaper — EXCEPT while
        // the widget itself is being dragged/resized, when it's sliding
        // over the wallpaper and other widgets live, same idea as the
        // dock/Spotlight going live for a window moving near them. Much
        // simpler here than the dock's own version of this: no need to
        // track other windows/monitor state at all, since a desktop widget
        // only ever needs to react to ITS OWN interaction state, not
        // anything happening elsewhere on screen.
        //
        // Refracting the static wallpaper file directly (no live capture)
        // the rest of the time is cheaper AND avoids a real bug: this
        // window is full-screen sized like Spotlight's own (needed for the
        // same position-math reasons), so if it's flagged no_self_capture
        // and live at the same time Spotlight opens, they're geometrically
        // ambiguous same-size layers to the "smaller wins" sort that
        // correctly handles the dock nesting inside Spotlight — showed up
        // as Spotlight's own dim overlay repeatedly bleeding into every
        // widget's glass when this was tried before. Dragging/resizing a
        // widget while Spotlight/the overview is also open isn't a
        // realistic combination, so this is an accepted, very unlikely
        // edge case rather than something actively guarded against here.
        //
        // CLAUDE/local (2026-09-17): this component going live here relies
        // on TWO fixes, both required:
        //
        // 1. quickshell:desktopWidgets needs the same no_self_capture
        //    layer rule as the dock/Spotlight (see
        //    ~/.config/hypr/custom/rules.lua) — without it, going live
        //    feeds this widget's own rendered glass back into its own
        //    capture with no circuit-breaker.
        //
        // 2. useOwnCapture: true below — the actual crash (100% reliable,
        //    on click alone, no drag needed) turned out to be unrelated to
        //    self-reflection: GlassCaptureService's shared capture item is
        //    a Quickshell Singleton with no window of its own, and gets
        //    attached to whichever PanelWindow's scenegraph first renders
        //    it — the dock's, its only real consumer historically. A
        //    desktop widget is a genuinely separate PanelWindow (its own
        //    QQuickWindow) trying to grab that SAME item, which crashed
        //    Qt's own layered rendering (nested QSGRhiLayer::grab()
        //    reentrancy) — confirmed directly via logged window addresses
        //    differing between the shared item and this widget's own
        //    window at the exact crash moment. useOwnCapture gives this
        //    component its own independent ScreencopyView instead of the
        //    cross-window shared one — see its own comment in
        //    LiquidGlassBackground.qml for the full writeup.
        staticWallpaper: !widget.interacting
        useOwnCapture: true
        // CLAUDE/local (2026-09-17): none of LiquidGlassBackground's own
        // motion signals (mouseDragActive/trackpadGestureActive/
        // superDown+pointerMoving) can ever see THIS widget dragging
        // itself — those are all driven by external scripts watching
        // real Hyprland-level window drags, and a widget moving is a
        // plain QML Item position change inside one PanelWindow, nothing
        // Hyprland itself ever sees. Without this, dragging fell through
        // to the ~1x/sec idle-pulse the whole time instead of refreshing
        // continuously, reported as the backdrop updating at an
        // "arythmic, almost random" cadence while actively dragging.
        extraCaptureActive: widget.interacting
    }

    Rectangle {
        id: cardBackground
        anchors.fill: parent
        radius: widget.cardRadius
        color: "transparent"

        // Right-click opens the menu. Declared first so it sits BEHIND the
        // dragger and accepts only the right button; left presses are not
        // accepted here and fall through to the dragger above, so neither area
        // has to know the other exists.
        MouseArea {
            anchors.fill: dragArea
            acceptedButtons: Qt.RightButton
            onPressed: mouse => {
                widget.menuPos = Qt.point(mouse.x, mouse.y);
                widget.menuOpen = true;
            }
        }

        MouseArea {
            id: dragArea
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: widget.dragHandleHeight
            acceptedButtons: Qt.LeftButton
            cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor

            // `drag.target` must be a plain reference, not a binding on
            // pressedButtons — that is only set at the END of press handling,
            // so the target was still null while the press was processed.
            drag.target: widget
            drag.axis: Drag.XAndYAxis

            // Qt defaults `smoothed` to true, which moves the target only once
            // the threshold is crossed and then keeps it offset by however far
            // the pointer travelled in that first motion event. A few pixels
            // when you move slowly; a wide gap when you flick. Track straight.
            drag.threshold: 0
            drag.smoothed: false

            drag.minimumX: 0
            drag.maximumX: Math.max(0, widget.screenWidth - widget.width)
            drag.minimumY: 0
            drag.maximumY: Math.max(0, widget.screenHeight - widget.height)

            onPressed: widget.dragging = true
            onPositionChanged: {
                if (widget.dragging) widget.board.previewGuides(widget, widget.x, widget.y);
            }
            onReleased: dragArea.finish()
            onCanceled: dragArea.finish()

            function finish() {
                if (!widget.dragging) return;
                widget.dragging = false;
                widget.commitPosition();
            }
        }

        Item {
            id: contentHolder
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: widget.padding
            // Height comes from the children, never from the parent. See the
            // note at the top of this file.
            implicitHeight: childrenRect.height
        }

        Item {
            id: overlayHolder
            anchors.fill: parent
            z: 20
        }

        // ── Resize grips ──────────────────────────────────────────
        // Declared after the content so they sit on top of it, and measured in
        // GLOBAL coordinates: a grip's local mouse position shifts as the
        // widget resizes underneath it, which feeds the resize back into its
        // own input.
        ResizeGrip { edge: "right"; visible: widget.resizableWidth }
        ResizeGrip { edge: "bottom"; visible: widget.resizableVertical }
        ResizeGrip { edge: "corner"; visible: widget.resizableWidth || widget.resizableVertical }
    }

    // ── Menu ──────────────────────────────────────────────────────
    // Catcher and menu are both reparented to the board, because z-order only
    // sorts among siblings: a child cannot rise above its parent's sibling, so
    // leaving the menu inside the widget put it under the catcher and none of
    // its rows ever fired.
    MouseArea {
        parent: widget.parent
        anchors.fill: parent
        visible: widget.menuOpen
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        z: 90
        onClicked: widget.menuOpen = false
    }

    Loader {
        id: menuLoader
        parent: widget.parent
        active: widget.menuComponent !== null
        sourceComponent: widget.menuComponent
        z: 100
        // Surface coordinates, so the widget's own position has to be added.
        // Flips to the other side of the cursor when it would run off an edge.
        x: Math.max(8, Math.min(widget.x + widget.menuPos.x,
                                widget.screenWidth - width - 8))
        y: (widget.y + widget.menuPos.y + height > widget.screenHeight)
            ? Math.max(8, widget.y + widget.menuPos.y - height)
            : widget.y + widget.menuPos.y

        onLoaded: {
            item.open = Qt.binding(() => widget.menuOpen);
            item.requestClose.connect(() => widget.menuOpen = false);
        }
    }

    component ResizeGrip: MouseArea {
        id: grip
        required property string edge
        readonly property int thickness: 10

        parent: cardBackground
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        z: 50

        anchors.right: grip.edge !== "bottom" ? parent.right : undefined
        anchors.left: grip.edge === "bottom" ? parent.left : undefined
        anchors.bottom: grip.edge !== "right" ? parent.bottom : undefined
        anchors.top: grip.edge === "right" ? parent.top : undefined
        anchors.bottomMargin: grip.edge === "right" ? grip.thickness : 0
        anchors.rightMargin: grip.edge === "bottom" ? grip.thickness : 0

        implicitWidth: grip.edge === "bottom" ? 0 : grip.thickness
        implicitHeight: grip.edge === "right" ? 0 : grip.thickness
        width: grip.edge === "bottom" ? parent.width - grip.thickness : grip.thickness
        height: grip.edge === "right" ? parent.height - grip.thickness : grip.thickness

        cursorShape: grip.edge === "right" ? Qt.SizeHorCursor
            : grip.edge === "bottom" ? Qt.SizeVerCursor
            : Qt.SizeFDiagCursor

        property real startWidth: 0
        property real startVertical: 0
        property point startGlobal: Qt.point(0, 0)

        onPressed: mouse => {
            grip.startWidth = widget.width;
            grip.startVertical = widget.verticalSize > 0
                ? widget.verticalSize
                : contentHolder.implicitHeight;
            grip.startGlobal = grip.mapToGlobal(mouse.x, mouse.y);
            widget.resizing = true;
        }

        onPositionChanged: mouse => {
            if (!grip.pressed) return;
            const now = grip.mapToGlobal(mouse.x, mouse.y);
            const dx = now.x - grip.startGlobal.x;
            const dy = now.y - grip.startGlobal.y;

            if (grip.edge !== "bottom" && widget.resizableWidth) {
                widget.pendingWidth = Math.max(widget.minWidth,
                    Math.min(widget.maxWidth, grip.startWidth + dx));
            }
            if (grip.edge !== "right" && widget.resizableVertical) {
                widget.pendingVertical = Math.max(widget.minVertical,
                    Math.min(widget.maxVertical, grip.startVertical + dy));
            }
        }

        onReleased: grip.finish()
        onCanceled: grip.finish()

        function finish() {
            if (!widget.resizing) return;
            widget.resizing = false;
            const sized = widget.board.sizeWidget(widget,
                widget.pendingWidth >= 0 ? widget.pendingWidth : widget.width,
                widget.pendingVertical);
            if (widget.pendingWidth >= 0) widget.config.width = Math.round(sized.width);
            if (widget.pendingVertical >= 0) widget.config.contentHeight = Math.round(sized.vertical);
            widget.pendingWidth = -1;
            widget.pendingVertical = -1;
        }

        // The corner gets a visible grip; the edges stay invisible so the
        // silhouette stays clean until you reach for them.
        MaterialSymbol {
            visible: grip.edge === "corner"
            anchors.centerIn: parent
            text: "drag_handle"
            rotation: -45
            iconSize: 12
            color: Appearance.colors.colSubtext
            opacity: grip.containsMouse || grip.pressed ? 0.9 : 0.28
            Behavior on opacity {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }
        }
    }
}
