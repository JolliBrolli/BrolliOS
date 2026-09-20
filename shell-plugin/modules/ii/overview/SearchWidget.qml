pragma ComponentBehavior: Bound

import Qt.labs.synchronizer
import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.widgets.glass
import qs.modules.common.functions

Item { // Wrapper
    id: root

    required property var screen
    readonly property string xdgConfigHome: Directories.config
    readonly property int typingDebounceInterval: 200
    readonly property int typingResultLimit: 15 // Should be enough to cover the whole view

    property string searchingText: LauncherSearch.query
    property bool showResults: searchingText != ""
    implicitWidth: searchWidgetContent.implicitWidth + Appearance.sizes.elevationMargin * 2
    implicitHeight: searchWidgetContent.implicitHeight + searchBar.verticalPadding * 2 + Appearance.sizes.elevationMargin * 2
    // Height with just the input row — the separator + results ListView
    // excluded on purpose, so this stays constant while typing. Lets a
    // caller anchor the widget by this instead of the (growing) real
    // height, so the search box itself doesn't move as results populate.
    readonly property real collapsedHeight: searchBar.height + searchBar.verticalPadding * 2 + Appearance.sizes.elevationMargin * 2

    function focusFirstItem() {
        appResults.currentIndex = 0;
    }

    function focusSearchInput() {
        searchBar.forceFocus();
    }

    function disableExpandAnimation() {
        searchBar.animateWidth = false;
    }

    function cancelSearch() {
        searchBar.searchInput.selectAll();
        LauncherSearch.query = "";
        searchBar.animateWidth = true;
    }

    function setSearchingText(text) {
        searchBar.searchInput.text = text;
        LauncherSearch.query = text;
    }

    Keys.onPressed: event => {
        // Prevent Esc and Backspace from registering
        if (event.key === Qt.Key_Escape)
            return;

        // Handle Backspace: focus and delete character if not focused
        if (event.key === Qt.Key_Backspace) {
            if (!searchBar.searchInput.activeFocus) {
                root.focusSearchInput();
                if (event.modifiers & Qt.ControlModifier) {
                    // Delete word before cursor
                    let text = searchBar.searchInput.text;
                    let pos = searchBar.searchInput.cursorPosition;
                    if (pos > 0) {
                        // Find the start of the previous word
                        let left = text.slice(0, pos);
                        let match = left.match(/(\s*\S+)\s*$/);
                        let deleteLen = match ? match[0].length : 1;
                        searchBar.searchInput.text = text.slice(0, pos - deleteLen) + text.slice(pos);
                        searchBar.searchInput.cursorPosition = pos - deleteLen;
                    }
                } else {
                    // Delete character before cursor if any
                    if (searchBar.searchInput.cursorPosition > 0) {
                        searchBar.searchInput.text = searchBar.searchInput.text.slice(0, searchBar.searchInput.cursorPosition - 1) + searchBar.searchInput.text.slice(searchBar.searchInput.cursorPosition);
                        searchBar.searchInput.cursorPosition -= 1;
                    }
                }
                // Always move cursor to end after programmatic edit
                searchBar.searchInput.cursorPosition = searchBar.searchInput.text.length;
                event.accepted = true;
            }
            // If already focused, let TextField handle it
            return;
        }

        // Only handle visible printable characters (ignore control chars, arrows, etc.)
        if (event.text && event.text.length === 1 && event.key !== Qt.Key_Enter && event.key !== Qt.Key_Return && event.key !== Qt.Key_Delete && event.text.charCodeAt(0) >= 0x20) // ignore control chars like Backspace, Tab, etc.
        {
            if (!searchBar.searchInput.activeFocus) {
                root.focusSearchInput();
                // Insert the character at the cursor position
                searchBar.searchInput.text = searchBar.searchInput.text.slice(0, searchBar.searchInput.cursorPosition) + event.text + searchBar.searchInput.text.slice(searchBar.searchInput.cursorPosition);
                searchBar.searchInput.cursorPosition += 1;
                event.accepted = true;
                root.focusFirstItem();
            }
        }
    }

    StyledRectangularShadow {
        target: searchWidgetContent
    }
    Rectangle { // Background
        id: searchWidgetContent
        anchors {
            top: parent.top
            horizontalCenter: parent.horizontalCenter
            topMargin: Appearance.sizes.elevationMargin
        }
        // NOT clip:true — that's a native, fixed, always-CIRCULAR corner
        // (Qt's Rectangle.radius can't draw a superellipse), independent of
        // the shader's own `power`-driven shape. With the ShaderEffect as a
        // child of this Rectangle, that clip was cropping the shader's
        // actual (sharper, more rectangular at higher power) corner back
        // down to its own rounder one — a visible crease where the two
        // disagree, worse the more `power` diverges from a plain circle.
        // The ColumnLayout's own content below has its own correct
        // OpacityMask already; the shader does its own correct SDF cutoff;
        // neither needs this Rectangle's clip at all.
        implicitWidth: columnLayout.implicitWidth
        implicitHeight: columnLayout.implicitHeight
        radius: searchBar.height / 2 + searchBar.verticalPadding
        // Was "transparent" — the shader provided the fill. That shader is
        // gone in this copy, so this rectangle IS the silhouette the
        // compositor plugin masks its glass to.
        color: Qt.rgba(1, 1, 1, 0.14)

        Behavior on implicitHeight {
            id: searchHeightBehavior
            enabled: GlobalStates.overviewOpen && root.showResults
            animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
        }

        // ---- Liquid glass background ----
        // Same capture-and-refract technique as GlassTest.qml, adapted for a
        // widget that moves/resizes within a layout instead of a fixed
        // screen-center square: boxX/boxY track this Rectangle's own
        // position via mapToItem(null, ...) (reactive — QML tracks the x/y
        // reads that happen inside it through the parent chain), so the crop
        // stays correct as results expand the box downward. All shape/
        // refraction tuning comes from Config.options.appearance.liquidGlass
        // (see modules/settings/LiquidGlassConfig.qml) — shared with every
        // other panel using this shader, not a local copy.
        //
        // Capture pipeline rebuilt 2026-09-14 to fix a real, measured GPU
        // cost, in three attempts:
        //
        // 1. Started as its own ScreencopyView, hardcoded live:true with no
        //    idle-skip at all, and NOT behind a Loader — existed and ran
        //    for the whole session's uptime, not just while Overview was
        //    open. Measured at 50-60% GPU while just sitting open, idle.
        // 2. Tried the shared per-monitor GlassCaptureService (what the
        //    dock/widgets use) — reverted same day, it crashed the shell
        //    ("Cannot make QOpenGLContext current in a different thread")
        //    the moment the dock's window AND this Overview window both
        //    had that shared texture live at once (routinely — Spotlight
        //    opened while the dock is mid-drag-live). That shared texture
        //    is NOT safe across simultaneously-live different top-level
        //    windows.
        // 3. Tried keeping its own ScreencopyView but gating `live` on an
        //    adaptive "VRR-style" rate (settling/idlePulse below) instead
        //    of hardcoded true — measured NO improvement at all (~35-47%
        //    either pulsed or left continuously live). The real cost
        //    turned out to be structural, not about live-ness frequency:
        //    a ScreencopyView living as a child of an actively-redrawing
        //    REAL PanelWindow's own scene graph (Overview.qml's) carries a
        //    real per-frame cost independent of its own `live` value.
        //    Confirmed by isolating GlassCaptureService's own pattern (a
        //    window-less Singleton/Instantiator tree, attached to no
        //    particular window) at ~9% for the identical scenario.
        //
        // Landed on SpotlightCaptureService — the SAME window-less
        // Singleton/Instantiator structure as GlassCaptureService (see its
        // own file), but a SEPARATE, dedicated instance never touched by
        // the dock, so attempt 2's cross-window crash class can't recur
        // (Spotlight is its only possible consumer). registerConsumer/
        // unregisterConsumer below keeps it simply on/off (open or
        // pre-warming — NOT pulsed, matching what actually worked); the
        // crop/blur stage on top still gets the adaptive settling/idlePulse
        // rate, which IS cheap to toggle (plain shader re-rendering, not a
        // capture session) and gives a bit more savings on top for free.
        // Cold-start (a dormant capture needs a moment to establish before
        // it has real content) is covered by pre-warming off
        // GlobalStates.superDown rather than overviewOpen itself — the real
        // keybind is SUPER+Tab, so Super always goes down before Tab,
        // giving genuine lead time on every real invocation instead of
        // registering at the exact instant the UI is asked to show.
        // Sticky latch (first successful capture ever), NOT a live binding
        // to hasContentFor — the underlying capture now genuinely pulses
        // (setActive follows captureLive below), and hasContentFor can
        // drop back false while it's momentarily off. A plain reactive
        // binding here would flicker the whole panel visible/invisible in
        // sync with that pulse; latching it once true avoids that.
        property bool glassReady: false
        onScreenNameChanged: glassReadyWatcher.check()
        Connections {
            id: glassReadyWatcher
            target: SpotlightCaptureService
            function check() {
                if (SpotlightCaptureService.hasContentFor(searchWidgetContent.screenName) && !searchWidgetContent.glassReady)
                    searchWidgetContent.glassReady = true;
            }
            function onCapturesChanged() { check() }
        }
        // The corner radius is min(width,height)/2 (see the shader's own
        // `radius` — must match, it's the same shape), and the refraction
        // pull's reach scales with that radius, not with a fixed pixel
        // count. A tall results list has a much bigger radius than a small
        // collapsed pill; a flat configured pad that's only enough for the
        // small case runs the pull past the edge of what was actually
        // captured at high `power`/larger sizes, hitting ClampToEdge's
        // fallback — visible as a chunk of wrong/stale content "bleeding
        // in" from the clamped edge. Scale the actual capture margin with
        // the radius so there's always enough real content to pull from.
        readonly property real glassRadius: Math.min(searchWidgetContent.width, searchWidgetContent.height) / 2
        readonly property real glassPad: Math.max(Config.options.appearance.liquidGlass.pad, glassRadius * 0.6)
        // mapToItem(null, ...)'s result isn't reliably re-evaluated by QML's
        // binding system when ancestors move (a known limitation — its
        // internal position reads don't hook into property dependency
        // tracking the way plain QML property reads do). Walking the parent
        // chain by hand instead: every read here is a plain QML property
        // read (x/y/parent), so it's genuinely reactive, and the loop
        // naturally stops at this window's own root (a top-level Item has no
        // QML parent), giving monitor-local coordinates matching
        // ScreencopyView's own per-output capture space.
        function computeWindowLocalPos(item) {
            let x = 0, y = 0, cur = item;
            while (cur) {
                x += cur.x;
                y += cur.y;
                cur = cur.parent;
            }
            return Qt.point(x, y);
        }
        readonly property point glassPos: computeWindowLocalPos(searchWidgetContent)
        readonly property real glassTexW: searchWidgetContent.width + glassPad * 2
        readonly property real glassTexH: searchWidgetContent.height + glassPad * 2
        readonly property string screenName: root.screen ? root.screen.name : ""

        // Downsample-before-blur (same technique, same reasoning, as
        // LiquidGlassBackground.qml's own glassCaptureDownsample — see its
        // comment there for the full UV-math explanation of why only the
        // crop/blur STORAGE size shrinks here while every shader uniform
        // stays bound to the full/logical glassTexW/glassTexH).
        readonly property int glassCaptureDownsample: 2
        readonly property real glassCropW: Math.max(1, Math.round(searchWidgetContent.glassTexW / searchWidgetContent.glassCaptureDownsample))
        readonly property real glassCropH: Math.max(1, Math.round(searchWidgetContent.glassTexH / searchWidgetContent.glassCaptureDownsample))

        // Was glassHBlurReg, the blurred crop AdaptiveGlassText sampled for
        // per-region text contrast. That chain is gone in this copy, so
        // there is no backdrop texture to expose — AdaptiveGlassText treats
        // null as "not wired" and falls back to plain themed text.
        readonly property var glassBackdropTexture: null

        // Tried mirroring MacDock.qml's own anyWindowOverlappingDock (any
        // window's static geometry overlapping the box, no floating
        // requirement — catches a tiled window mid-drag) — REVERTED same
        // day: it works for the dock only because the dock has an
        // EXCLUSIVE ZONE, so a genuinely SETTLED tiled window can never
        // actually overlap its box (Hyprland keeps tiled windows out of
        // that reserved strip) — this check is only ever true there during
        // an active drag passing through. Spotlight's search box has no
        // exclusive zone at all, so an ordinary settled tiled window
        // (confirmed via `hyprctl clients`: a half-screen terminal sitting
        // right where the search box renders) overlaps it CONSTANTLY,
        // making this true almost the entire time Spotlight is open —
        // forcing captureLive on permanently and silently undoing the
        // whole throttling mechanism (measured: GPU cost back to
        // pre-optimization levels). The dock's own comment about this
        // check explicitly assumes the exclusive-zone guarantee; copying
        // the check without that guarantee was the actual bug, not the
        // technique itself.

        // ---- SpotlightCaptureService registration ----
        // Two SEPARATE signals to the service, deliberately not conflated:
        // shouldRegister (existence — is Spotlight around at all, for
        // consumerCounts/bookkeeping) vs captureLive (is a fresh frame
        // actually wanted RIGHT NOW, below) — the actual fix for the
        // ~40-point raw-capture cost: isolated via a direct ablation test
        // (forcing registration off entirely while "open" measured ~6.8%
        // vs ~45-49% normally) that the service's own capture, not the
        // crop/blur/shader stage on top of it, was the dominant cost, and
        // that every earlier attempt this session only ever throttled the
        // crop/blur while leaving the raw capture flatly on-while-open.
        // setActive (driven by captureLive, further below) now genuinely
        // pulses the service's own capture at the same adaptive duty cycle
        // that was already proven to work cleanly for the crop/blur stage.
        property bool keepWarm: false
        readonly property bool shouldRegister: GlobalStates.overviewOpen || keepWarm
        onShouldRegisterChanged: {
            if (!searchWidgetContent.screenName)
                return;
            if (shouldRegister)
                SpotlightCaptureService.registerConsumer(searchWidgetContent.screenName);
            else
                SpotlightCaptureService.unregisterConsumer(searchWidgetContent.screenName);
        }
        onCaptureLiveChanged: SpotlightCaptureService.setActive(searchWidgetContent.screenName, searchWidgetContent.captureLive)
        Component.onCompleted: {
            if (searchWidgetContent.shouldRegister)
                SpotlightCaptureService.registerConsumer(searchWidgetContent.screenName);
            SpotlightCaptureService.setActive(searchWidgetContent.screenName, searchWidgetContent.captureLive);
        }
        Component.onDestruction: {
            if (searchWidgetContent.shouldRegister)
                SpotlightCaptureService.unregisterConsumer(searchWidgetContent.screenName);
            SpotlightCaptureService.setActive(searchWidgetContent.screenName, false);
        }
        Timer {
            id: prewarmReleaseTimer
            interval: 1500 // Super pressed but overview never opened (some other Super shortcut)
            onTriggered: searchWidgetContent.keepWarm = false
        }
        Timer {
            id: keepWarmReleaseTimer
            interval: 4000 // keep-alive after close, so a quick reopen doesn't cold-start
            onTriggered: searchWidgetContent.keepWarm = false
        }
        Connections {
            target: GlobalStates
            function onSuperDownChanged() {
                if (GlobalStates.superDown) {
                    prewarmReleaseTimer.stop();
                    searchWidgetContent.keepWarm = true;
                } else if (!GlobalStates.overviewOpen) {
                    prewarmReleaseTimer.restart();
                }
                // Releasing Super can end a superDown+pointerMoving drag
                // too — same settle re-arm as the other drag-end cases.
                if (!searchWidgetContent.anyDragActive && GlobalStates.overviewOpen) {
                    searchWidgetContent.settling = true;
                    settleTimer.restart();
                }
            }
            function onOverviewOpenChanged() {
                if (GlobalStates.overviewOpen) {
                    keepWarmReleaseTimer.stop();
                    searchWidgetContent.settling = true;
                    settleTimer.restart();
                } else {
                    keepWarmReleaseTimer.restart();
                }
            }
            // A drag ending drops straight from continuous-live back to
            // the idle-pulse cadence — settling briefly first guarantees
            // one clean, immediate frame at the drag's actual final
            // resting position instead of waiting for the next pulse tick.
            // Covers both a real mouse-button drag AND the 3-finger
            // trackpad gesture move (see anyDragActive below — window
            // moves on this system are done via the trackpad gesture at
            // least as often as the mouse, confirmed by direct libinput
            // capture: GESTURE_SWIPE_BEGIN with 3 fingers, not
            // POINTER_BUTTON, was what actually showed up during testing).
            function onMouseDragActiveChanged() {
                if (!searchWidgetContent.anyDragActive && GlobalStates.overviewOpen) {
                    searchWidgetContent.settling = true;
                    settleTimer.restart();
                }
            }
            function onTrackpadGestureActiveChanged() {
                if (!searchWidgetContent.anyDragActive && GlobalStates.overviewOpen) {
                    searchWidgetContent.settling = true;
                    settleTimer.restart();
                }
            }
            // Super held + pointer actively moving — a real, gap-free
            // "is a drag happening" signal that doesn't depend on
            // button/tap timing at all (unlike mouseDragActive, which
            // only reflects the tap's own brief press window, missing the
            // continued drag entirely for a tap-then-move interaction —
            // the actual normal way this user drags windows).
            function onPointerMovingChanged() {
                if (!searchWidgetContent.anyDragActive && GlobalStates.overviewOpen) {
                    searchWidgetContent.settling = true;
                    settleTimer.restart();
                }
            }
        }

        // ---- Adaptive ("VRR-style") live rate for the crop/blur stage ----
        property bool settling: true
        Timer {
            id: settleTimer
            // History: 400ms, then 800ms, then 3000ms — the widening was
            // specifically to bridge changefloatingmode's own unreliable
            // 1.3-2.3s gaps during a drag, since THAT was the only signal
            // available at the time. Now that GlobalStates.pointerMoving +
            // superDown (see anyDragActive) tracks drags directly and
            // continuously — no gaps to bridge at all — this timer is back
            // to its original, smaller job: a brief grace period after a
            // one-time event (open, resize, drag just ended) for a few
            // real frames to converge before dropping to idle.
            //
            // CLAUDE/local, 2026-09-18: lowered 500 -> 250. The results
            // list's own implicitHeight animates over a full 500ms
            // (Appearance.animation.elementMove), and onHeightChanged
            // below restarts THIS timer on every single frame of that
            // animation — so the real "full live-rate" burst on every
            // open was never just 500ms, it was animation-duration +
            // this interval (~1000ms), since the timer can't count down
            // while still being reset every frame. This is the original
            // "~50%->30% open burst" cost item from way earlier in this
            // whole effort, only now actually root-caused. Shrinking just
            // this trailing grace window (not the animation itself, which
            // stays the same visible 500ms) cuts real time off the burst
            // with zero change to how the open animation looks — still
            // "comfortable" for a few real frames to converge per the
            // reasoning above, just tighter.
            interval: 250
            onTriggered: {
                console.log("[timerdbg] SearchWidget settleTimer fired @", Date.now());
                searchWidgetContent.settling = false;
            }
        }
        // Typing expands/collapses the results list, which resizes AND
        // repositions this box (glassTexW/H, glassPos) — a real visual
        // change to the crop itself, not just "content behind it changed".
        // Missing this meant the crop could sit frozen at a stale size/
        // position (caught by the user as "typed, glass didn't update")
        // until the idle pulse's next tick, up to ~1s later.
        onWidthChanged: { settling = true; settleTimer.restart(); }
        onHeightChanged: { settling = true; settleTimer.restart(); }
        property bool idlePulse: false
        Timer {
            id: idlePulseTimer
            // A first attempt at GlobalStates.mouseDragActive caused a real
            // segfault on the live session (QQuickItem::update()/
            // addToDirtyList(), stack trace originating from the IPC call
            // handler) — reverted, then re-applied here for careful testing
            // in the NESTED instance first this time, not the real session
            // directly. While dragging, captureLive is forced true by
            // mouseDragActive directly (see above), so this pulse doesn't
            // need to run at all during that window.
            interval: 1000
            running: GlobalStates.overviewOpen && !searchWidgetContent.settling && !searchWidgetContent.anyDragActive
            repeat: true
            // Without this, a Timer waits a full interval before its FIRST
            // tick — meaning right as settling ends there was a real gap of
            // up to 1000ms with NEITHER settling NOR idlePulse active
            // (captureLive false the whole time), before the first catch-up
            // frame even happened. That's the exact "freezes, catches up,
            // freezes again" pattern reported — not just a slow steady-
            // state rate, an actual dead gap on every settle->idle
            // transition.
            triggeredOnStart: true
            onTriggered: {
                console.log("[timerdbg] SearchWidget idlePulseTimer fired @", Date.now());
                searchWidgetContent.idlePulse = true;
                idlePulseResetTimer.restart();
            }
        }
        Timer {
            id: idlePulseResetTimer
            interval: 60 // long enough for one real re-render before freezing again — ~40% duty cycle at the 150ms pulse interval above
            onTriggered: {
                console.log("[timerdbg] SearchWidget idlePulseResetTimer fired @", Date.now());
                searchWidgetContent.idlePulse = false;
            }
        }
        // Adaptive rate for the crop/blur stage ONLY — SpotlightCaptureService's
        // own underlying capture is governed by simple consumer-count
        // registration above (NOT this), since pulsing THAT on/off measured
        // as pointless (see the big comment up top). This just controls how
        // often the cheap crop+blur re-renders while open.
        // keepWarm's contribution is scoped to !overviewOpen deliberately —
        // a real, LOGGED bug (2026-09-14): the actual SUPER+SUPER_L release
        // keybind fires GlobalStates.overviewOpen=true a few ms BEFORE
        // GlobalStates.superDown=false (same physical release event, just
        // that ordering) — onSuperDownChanged's own reset-scheduling only
        // runs inside `if (!GlobalStates.overviewOpen)`, so by the time
        // superDown actually goes false, that branch never fires and
        // keepWarm never gets released. Confirmed via real event-timestamp
        // logging: keepWarm/captureLive stayed stuck true for the ENTIRE
        // ~28s a real open was held, only dropping ~1.5s after closing —
        // 100% duty cycle the whole time, completely bypassing
        // settling/idlePulse. A synthetic `hl.dispatch(hl.dsp.global(...))`
        // test never exercises superDown at all, which is why it measured
        // the intended low rate while every real keypress didn't — this
        // wasn't a measurement error, it was a real bug invisible to any
        // test that doesn't go through the actual keybind. Scoping it here
        // sidesteps the ordering race entirely: once genuinely open,
        // keepWarm's value stops mattering at all.
        //
        // GlobalStates.mouseDragActive: real left-button-down state via an
        // independent libinput watcher (see mouse-drag-watch.sh), so this
        // stays FULLY continuously live during a drag instead of polling —
        // a first attempt at this crashed the live session (see
        // idlePulseTimer's own comment above); re-applied here after being
        // tested in the nested instance first this time.
        //
        // GlobalStates.trackpadGestureActive: the OTHER real way windows
        // get moved on this system — a direct libinput capture during
        // testing showed GESTURE_SWIPE_BEGIN (3 fingers), not
        // POINTER_BUTTON, was what actually fired. Already a proven,
        // working signal (trackpad-gesture-watch.sh, built earlier for the
        // dock's own gesture-drag detection) — reused here rather than
        // building a second mechanism for the same underlying need.
        // GlobalStates.superDown && GlobalStates.pointerMoving: the real
        // fix for tap-then-drag (this user's normal workflow, confirmed —
        // never a genuine physical button hold). mouseDragActive alone
        // only reflects the tap's own ~100ms press window; motion itself
        // has none of the gaps that plagued every event-based heuristic
        // tried before this (Hyprland's own IPC events, changefloatingmode
        // timing) — it fires continuously and reliably for the entire
        // real duration of any drag, tap-initiated or not. superDown
        // scopes it to "only while the SUPER+drag modifier is actually
        // held," so ordinary mouse movement with Super not held never
        // triggers this.
        readonly property bool anyDragActive: GlobalStates.mouseDragActive || GlobalStates.trackpadGestureActive || (GlobalStates.superDown && GlobalStates.pointerMoving)
        readonly property bool captureLive: (!GlobalStates.overviewOpen && searchWidgetContent.keepWarm) || (GlobalStates.overviewOpen && (searchWidgetContent.settling || searchWidgetContent.idlePulse || searchWidgetContent.anyDragActive))

        // Wakes back up to full rate on any real Hyprland event while
        // open — a window moving/resizing/opening/closing behind
        // Spotlight. Same exclusion list HyprlandData.qml itself uses.
        Connections {
            target: Hyprland
            function onRawEvent(event) {
                if (!GlobalStates.overviewOpen)
                    return;
                // "screencast"/"screencastv2" fire in pairs — the "v2"
                // one was missing here, a real bug: Hyprland emits these
                // whenever a screencopy client's capture state changes,
                // and SpotlightCaptureService IS a screencopy client
                // whose capture toggles on/off as part of the normal
                // adaptive pulse — meaning our OWN capture activity was
                // generating screencastv2 events that slipped through
                // this filter and re-armed settling, keeping captureLive
                // artificially high most of the time (measured: ~50% GPU
                // sustained, dropping only briefly). A self-feeding loop:
                // our own pulse kept re-triggering itself via this gap.
                if (["openlayer", "closelayer", "screencast", "screencastv2"].includes(event.name))
                    return;
                searchWidgetContent.settling = true;
                settleTimer.restart();
            }
        }

        // PLUGIN-TEST SHELL COPY — the whole glass chain that lived here
        // (glassCapReg crop -> glassHBlurEffect/glassHBlurReg separable blur
        // -> glassShaderEffect running liquidglasstest.frag) has been
        // removed. The compositor plugin draws Spotlight's material now,
        // masked to this surface's own alpha; see the Background rectangle's
        // translucent fill above, which is what gives the plugin its shape.

        ColumnLayout {
            id: columnLayout
            anchors {
                top: parent.top
                horizontalCenter: parent.horizontalCenter
            }
            spacing: 0

            // clip: true
            layer.enabled: true
            layer.effect: OpacityMask {
                maskSource: Rectangle {
                    width: searchWidgetContent.width
                    height: searchWidgetContent.width
                    radius: searchWidgetContent.radius
                }
            }

            SearchBar {
                id: searchBar
                property real verticalPadding: 4
                Layout.fillWidth: true
                Layout.leftMargin: 10
                Layout.rightMargin: 4
                Layout.topMargin: verticalPadding
                Layout.bottomMargin: verticalPadding
                Synchronizer on searchingText {
                    property alias source: root.searchingText
                }
            }

            Rectangle {
                // Separator
                visible: root.showResults
                Layout.fillWidth: true
                height: 1
                color: Appearance.colors.colOutlineVariant
            }

            ListView { // App results
                id: appResults
                visible: root.showResults
                Layout.fillWidth: true
                implicitHeight: Math.min(600, appResults.contentHeight + topMargin + bottomMargin)
                clip: true
                topMargin: 10
                bottomMargin: 10
                spacing: 2
                KeyNavigation.up: searchBar
                highlightMoveDuration: 100

                onFocusChanged: {
                    if (focus)
                        appResults.currentIndex = 1;
                }

                Connections {
                    target: root
                    function onSearchingTextChanged() {
                        if (appResults.count > 0)
                            appResults.currentIndex = 0;
                    }
                }

                Timer {
                    id: debounceTimer
                    interval: root.typingDebounceInterval
                    onTriggered: {
                        resultModel.values = LauncherSearch.results ?? [];
                    }
                }

                Connections {
                    target: LauncherSearch
                    function onResultsChanged() {
                        resultModel.values = LauncherSearch.results.slice(0, root.typingResultLimit);
                        root.focusFirstItem();
                        debounceTimer.restart();
                    }
                }

                model: ScriptModel {
                    id: resultModel
                    objectProp: "key"
                }

                delegate: SearchItem {
                    id: searchItem
                    // The selectable item for each search result
                    required property var modelData
                    anchors.left: parent?.left
                    anchors.right: parent?.right
                    entry: modelData
                    query: StringUtils.cleanOnePrefix(root.searchingText, [Config.options.search.prefix.action, Config.options.search.prefix.app, Config.options.search.prefix.clipboard, Config.options.search.prefix.emojis, Config.options.search.prefix.math, Config.options.search.prefix.shellCommand, Config.options.search.prefix.webSearch])
                    glassRoot: searchWidgetContent
                    glassBackdropTexture: searchWidgetContent.glassBackdropTexture
                    glassContrastActive: searchWidgetContent.captureLive

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Tab) {
                            if (LauncherSearch.results.length === 0)
                                return;
                            const tabbedText = searchItem.modelData.name;
                            LauncherSearch.query = tabbedText;
                            searchBar.searchInput.text = tabbedText;
                            event.accepted = true;
                            root.focusSearchInput();
                        }
                    }
                }
            }
        }
    }

}
