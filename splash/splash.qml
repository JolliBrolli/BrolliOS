//
// BrolliOS splash-lock: the first thing on screen after autologin.
//
// It is deliberately NOT part of the shell. `qs -c BrolliOS` loads ~965 files
// and takes seconds; this is one file and draws in under 200ms, which is the
// whole point -- it covers the gap while the real shell starts behind it.
//
// It is a real locker, not an overlay: WlSessionLock speaks ext-session-lock-v1,
// so the compositor -- not this process -- owns whether the screen is covered.
// If this crashes, the protocol says the session STAYS locked rather than
// falling open.
//
//   qs -p ~/Projects/Brolli-Glass/splash/splash.qml
//   BROLLI_SPLASH_PREVIEW=1 qs -p ...   # a window instead of locking you out
//
// Nothing here imports from the shell. Battery and wifi come from sysfs and
// nmcli rather than the shell's services, which would drag in everything.
//
// Run splash/generate-wordmark.py first. It writes wordmark.json, which is
// glyph outlines from a proprietary font, so it is generated and never committed.
//
import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pam

ShellRoot {
    id: root

    // ── state ────────────────────────────────────────────────────────────
    property var wordmark: null
    property int glyphCount: wordmark ? wordmark.paths.length : 0
    property real drawProgress: 0

    property string wallpaper: ""
    property string stampSrc: ""

    readonly property string cachePath:
        (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache"))
        + "/brollios-splash/wallpaper.jpg"

    // Prefer the pre-scaled copy, but only when it was made from the wallpaper
    // actually in use -- change the wallpaper and the stamp stops matching, so
    // it falls back to the original until the cache catches up.
    readonly property string wallpaperSource:
        (stampSrc !== "" && stampSrc === wallpaper) ? cachePath : wallpaper
    property int batteryPercent: -1
    property bool batteryCharging: false
    property string wifiSsid: ""
    property int wifiSignal: 0

    property bool unlocking: false
    property bool failed: false
    property bool authOk: false
    property string password: ""
    property bool powerMenuOpen: false

    // Testing a locker by locking your own session is a bad way to find out
    // the password field does not take focus.
    readonly property bool preview: Quickshell.env("BROLLI_SPLASH_PREVIEW") === "1"

    // How far outside the panel the material samples. The plugin clamps its
    // own capture to 48px for the same reason.
    readonly property real glassPad: 24

    readonly property double startedAt: Date.now()

    // The field is not there until it has something to show. In preview it
    // stays up, because you cannot type into a preview to make it appear.
    readonly property bool fieldVisible: password.length > 0 || unlocking || failed || preview

    // Glyphs draw one after another, left to right, so it reads as writing
    // rather than everything appearing at once.
    function glyphProgress(i) {
        return Math.max(0, Math.min(1, root.drawProgress * root.glyphCount - i));
    }

    // ── the wallpaper the shell is actually using ────────────────────────
    // Same source the SDDM theme syncs from: the shell writes its current
    // wallpaper path here, so reading it needs no copy, no root, and no
    // systemd watcher -- and it is right even if the wallpaper changed a
    // second ago.
    FileView {
        id: wallpaperState
        path: Quickshell.env("HOME") + "/.local/state/quickshell/user/generated/wallpaper/path.txt"
        watchChanges: true
        onLoaded: root.wallpaper = wallpaperState.text().trim()
        onFileChanged: reload()
        onLoadFailed: console.warn("[splash] no wallpaper state file; falling back to flat colour")
    }

    FileView {
        id: stampFile
        path: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache"))
              + "/brollios-splash/stamp.json"
        watchChanges: true
        onLoaded: {
            try {
                root.stampSrc = JSON.parse(stampFile.text()).src || "";
            } catch (e) {
                root.stampSrc = "";
            }
        }
        onFileChanged: reload()
        onLoadFailed: root.stampSrc = ""      // no cache yet; use the original
    }

    // Refresh the cache for NEXT time, once the screen is already up. Never on
    // the critical path: this is the slow job the cache exists to avoid.
    Process { id: cacheProc }
    Timer {
        running: true
        interval: 2500
        onTriggered: cacheProc.exec({
            command: ["python3", Qt.resolvedUrl("cache-wallpaper.py").toString().replace("file://", "")]
        })
    }

    FileView {
        id: wordmarkFile
        path: Qt.resolvedUrl("wordmark.json").toString().replace("file://", "")
        onLoaded: {
            try {
                root.wordmark = JSON.parse(wordmarkFile.text());
                drawAnim.start();
            } catch (e) {
                console.warn("[splash] wordmark.json unreadable:", e);
            }
        }
        onLoadFailed: console.warn("[splash] no wordmark.json — run generate-wordmark.py")
    }

    NumberAnimation {
        id: drawAnim
        target: root
        property: "drawProgress"
        from: 0
        to: 1
        duration: 1500
        easing.type: Easing.InOutQuad
    }

    // ── battery and wifi, cheaply ────────────────────────────────────────
    Process {
        id: statusProc
        command: ["bash", "-c",
            "cap=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo -1); " +
            "st=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo Unknown); " +
            "wifi=$(nmcli -t -f ACTIVE,SSID,SIGNAL dev wifi 2>/dev/null | grep '^yes' | head -1); " +
            "echo \"$cap|$st|$wifi\""]
        stdout: StdioCollector {
            id: statusOut
            onStreamFinished: {
                const parts = statusOut.text.trim().split("|");
                root.batteryPercent = parseInt(parts[0]);
                root.batteryCharging = parts[1] === "Charging";
                // "yes:SSID:SIGNAL"
                if (parts.length > 2 && parts[2].length > 0) {
                    const w = parts[2].split(":");
                    root.wifiSsid = w[1] || "";
                    root.wifiSignal = parseInt(w[2]) || 0;
                } else {
                    root.wifiSsid = "";
                }
            }
        }
    }

    Timer {
        running: true
        triggeredOnStart: true
        interval: 30000
        repeat: true
        onTriggered: statusProc.running = true
    }

    // ── auth ─────────────────────────────────────────────────────────────
    // With autologin there is no password at login, so pam_gnome_keyring starts
    // the keyring daemon LOCKED. This is the first moment a password exists, so
    // it is the right place to hand one over.
    Process {
        id: keyringProc
        onExited: (code, status) => {
            if (code !== 0)
                console.warn("[splash] keyring stayed locked (exit " + code + ")");
        }
    }

    function unlockKeyring(pw) {
        keyringProc.exec({
            environment: ({ "UNLOCK_PASSWORD": pw }),
            command: ["bash", Qt.resolvedUrl("unlock-keyring.sh").toString().replace("file://", "")]
        });
    }

    PamContext {
        id: pam
        onPamMessage: if (this.responseRequired) this.respond(root.password)
        onCompleted: result => {
            if (result === PamResult.Success) {
                root.unlocking = false;
                root.authOk = true;
                root.unlockKeyring(root.password);   // before it is cleared
                if (root.preview) {
                    root.password = "";
                    return;
                }
                lock.locked = false;
                quitTimer.start();
            } else {
                root.password = "";
                root.unlocking = false;
                root.failed = true;
            }
        }
    }

    // Leave by unlocking, never by dying: the compositor keeps a session locked
    // when its lock client disappears, which would strand the desktop.
    Timer {
        id: quitTimer
        interval: 350
        onTriggered: Qt.exit(0)
    }

    // Never fire a real power action from a preview window.
    function session(cmd, label) {
        if (root.preview) {
            console.log("[splash] preview: would run " + label);
            root.powerMenuOpen = false;
            return;
        }
        Quickshell.execDetached(["bash", "-c", cmd]);
        root.powerMenuOpen = false;
    }

    // ── the face ─────────────────────────────────────────────────────────
    Component {
        id: face

        Item {
            id: screen

            Image {
                id: wallpaperImage
                anchors.fill: parent
                // Measured, not guessed: how long from process start to the
                // first frame that actually has a wallpaper in it.
                onStatusChanged: if (status === Image.Ready)
                    console.log("[splash] wallpaper ready after "
                                + (Date.now() - root.startedAt) + "ms: "
                                + width + "x" + height)
                source: root.wallpaperSource ? "file://" + root.wallpaperSource : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                // Decode scaled. This wallpaper is 6016x6016 -- 36 megapixels
                // for a 2880x1800 screen -- and decoding it whole is the
                // second the glass spends lensing a black rectangle.
                // Only width is set: Qt keeps the aspect, and a square source
                // cropped to cover needs the LONGER screen edge, not the
                // shorter, or it comes back too small and soft.
                sourceSize.width: Math.max(screen.width, screen.height)
                visible: status === Image.Ready
            }

            // Flat ground when the wallpaper is missing or still decoding, so
            // the lock is never transparent even for a frame.
            Rectangle {
                anchors.fill: parent
                color: "#08080b"
                z: -1
            }

            // Keeps the wordmark and the status row legible over any wallpaper.
            Rectangle {
                anchors.fill: parent
                color: "#000000"
                opacity: 0.32
            }

            // ── top right: wifi · battery · power ────────────────────────
            Row {
                id: statusRow
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: 22
                anchors.rightMargin: 26
                spacing: 18
                z: 10

                Row {
                    spacing: 6
                    visible: root.wifiSsid.length > 0
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        font.family: "Material Symbols Rounded"
                        font.pixelSize: 19
                        color: "#f2f2f4"
                        text: root.wifiSignal >= 75 ? "signal_wifi_4_bar"
                            : root.wifiSignal >= 50 ? "network_wifi_3_bar"
                            : root.wifiSignal >= 25 ? "network_wifi_2_bar"
                            : "network_wifi_1_bar"
                    }
                }

                Row {
                    spacing: 5
                    visible: root.batteryPercent >= 0
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        font.family: "Material Symbols Rounded"
                        font.pixelSize: 19
                        color: root.batteryPercent <= 15 && !root.batteryCharging ? "#e0536b" : "#f2f2f4"
                        text: root.batteryCharging ? "battery_charging_full"
                            : root.batteryPercent >= 90 ? "battery_full"
                            : root.batteryPercent >= 60 ? "battery_5_bar"
                            : root.batteryPercent >= 40 ? "battery_3_bar"
                            : root.batteryPercent >= 20 ? "battery_2_bar"
                            : "battery_alert"
                    }
                }

                // Icon only, no plate behind it.
                Item {
                    width: 30
                    height: 30
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        anchors.centerIn: parent
                        font.family: "Material Symbols Rounded"
                        font.pixelSize: 21
                        color: powerArea.containsMouse || root.powerMenuOpen ? "#ffffff" : "#d8d8de"
                        text: "power_settings_new"
                        Behavior on color { ColorAnimation { duration: 150 } }
                    }

                    MouseArea {
                        id: powerArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.powerMenuOpen = !root.powerMenuOpen
                    }
                }
            }

            // Power menu, hanging under the icon.
            Rectangle {
                anchors.top: statusRow.bottom
                anchors.right: statusRow.right
                anchors.topMargin: 10
                width: 168
                height: powerCol.implicitHeight + 12
                radius: 14
                color: "#1a1a20"
                border.width: 1
                border.color: "#2c2c36"
                opacity: root.powerMenuOpen ? 1 : 0
                visible: opacity > 0
                z: 11
                Behavior on opacity { NumberAnimation { duration: 160 } }

                Column {
                    id: powerCol
                    anchors.centerIn: parent
                    width: parent.width - 12

                    Repeater {
                        model: [
                            { icon: "power_settings_new", label: "Shut down", cmd: "systemctl poweroff" },
                            { icon: "restart_alt",        label: "Restart",   cmd: "systemctl reboot" },
                            { icon: "bedtime",            label: "Sleep",     cmd: "systemctl suspend" },
                            { icon: "logout",             label: "Log out",   cmd: "loginctl terminate-user \"$USER\"" }
                        ]

                        Rectangle {
                            required property var modelData
                            width: powerCol.width
                            height: 34
                            radius: 9
                            color: itemArea.containsMouse ? "#2a2a33" : "transparent"

                            Row {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 10
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    font.family: "Material Symbols Rounded"
                                    font.pixelSize: 17
                                    color: "#e6e6ec"
                                    text: modelData.icon
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.label
                                    color: "#e6e6ec"
                                    font.pixelSize: 13
                                    font.family: "Google Sans Flex"
                                }
                            }

                            MouseArea {
                                id: itemArea
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: root.session(modelData.cmd, modelData.label)
                            }
                        }
                    }
                }
            }

            // Clicking anywhere else closes the menu.
            MouseArea {
                anchors.fill: parent
                enabled: root.powerMenuOpen
                onClicked: root.powerMenuOpen = false
                z: 9
            }

            // ── centre: wordmark, then the field ─────────────────────────
            Item {
                anchors.centerIn: parent
                width: Math.max(markHolder.width, 300)
                height: markHolder.height + 120

                Item {
                    id: markHolder
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    width: root.wordmark ? root.wordmark.width : 1
                    height: root.wordmark ? root.wordmark.ascent + root.wordmark.descent : 1

                    // One Shape per glyph: Repeater delegates have to be Items,
                    // and ShapePath is not one. The path data is already in
                    // absolute coordinates, so every Shape fills the same box.
                    Repeater {
                        model: root.wordmark ? root.wordmark.paths : []

                        Shape {
                            id: glyph
                            required property var modelData
                            required property int index
                            anchors.fill: parent
                            asynchronous: false
                            preferredRendererType: Shape.CurveRenderer

                            readonly property real p: root.glyphProgress(index)
                            readonly property real dash: modelData.len / 1.6

                            ShapePath {
                                strokeColor: "#ffffff"
                                strokeWidth: 1.6
                                capStyle: ShapePath.RoundCap
                                joinStyle: ShapePath.RoundJoin
                                fillColor: Qt.rgba(1, 1, 1, Math.max(0, glyph.p - 0.7) / 0.3)
                                strokeStyle: ShapePath.DashLine
                                dashPattern: [glyph.dash, glyph.dash]
                                dashOffset: glyph.dash * (1 - glyph.p)
                                PathSvg { path: glyph.modelData.d }
                            }
                        }
                    }
                }

                // Centred under the wordmark, and only there when in use.
                Item {
                    id: fieldHolder
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: markHolder.bottom
                    anchors.topMargin: 46
                    width: 260
                    height: 44

                    opacity: root.fieldVisible ? 1 : 0
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 220 } }

                    // The plugin cannot draw this one: it hooks renderLayer,
                    // which never fires for a session-lock surface. It does not
                    // need to -- the backdrop here is the wallpaper this same
                    // process drew, so the material runs over a
                    // ShaderEffectSource of it and nothing is captured.
                    ShaderEffectSource {
                        id: fieldBackdrop
                        sourceItem: wallpaperImage
                        // The material samples a PADDED region: the lens reaches
                        // outside the panel at the edges, and sample() maps
                        // panel pixels into this texture as (pad + c) / texSize.
                        sourceRect: {
                            // Named so the binding re-evaluates when the layout
                            // moves; mapToItem alone is not a dependency.
                            const w = screen.width, h = screen.height;
                            const fy = fieldHolder.y, fw = fieldHolder.width, fh = fieldHolder.height;
                            const pt = fieldHolder.mapToItem(screen, 0, 0);
                            return Qt.rect(pt.x - glassPad, pt.y - glassPad,
                                           fw + glassPad * 2, fh + glassPad * 2);
                        }
                        width: fieldHolder.width + glassPad * 2
                        height: fieldHolder.height + glassPad * 2
                        hideSource: false
                        live: true
                        visible: false
                    }

                    ShaderEffect {
                        id: fieldBg
                        anchors.fill: parent          // exactly the panel
                        fragmentShader: Qt.resolvedUrl("glass.frag.qsb")
                        // Nothing to lens over until the wallpaper has decoded;
                        // glass over a black screen just looks broken.
                        visible: wallpaperImage.status === Image.Ready

                        property variant source: fieldBackdrop
                        property vector2d panelSize: Qt.vector2d(width, height)
                        property vector2d texSize: Qt.vector2d(fieldBackdrop.width, fieldBackdrop.height)
                        property real pad: glassPad
                        property real maxCornerRadius: height / 2

                        // Straight off the desktop's live settings, so the lock
                        // does not drift away from every other panel.
                        property real aghDepth: 0.302
                        property real aghStrength: 0.434
                        property real aghBlur: 1.484
                        property real aghChroma: 3.0
                        property real aghEdge: 0.02
                        property real aghTint: 0.994
                        property real aghStretch: 0.398

                        // What the plugin's mipmap-reduce pass would have
                        // measured: mean luma and mean luma squared. Neutral
                        // until the readability pass is ported too.
                        property vector2d panelStat: Qt.vector2d(0.5, 0.25)
                        property real glassDir: -1.0
                        property real aghSquash: 0.3
                        property real aghPush: 0.0
                        property real aghBody: 0.06
                        property real glassOverGlass: 0.0

                        property vector4d tint: Qt.vector4d(0, 0, 0, 0)
                        property real power: 2.78
                        property real rimHighlightStrength: 0.249
                        property real rimHighlightWidth: 1.497
                        property real rimDiagonalReach: 1.0
                    }

                    // The failure state still needs to read, so it rides on top
                    // of the glass rather than replacing it.
                    Rectangle {
                        anchors.fill: parent
                        radius: height / 2
                        color: "transparent"
                        border.width: 1
                        border.color: root.failed ? "#e0536b" : "transparent"
                        Behavior on border.color { ColorAnimation { duration: 200 } }
                    }

                    Text {
                        anchors.top: fieldBg.bottom
                        anchors.topMargin: 10
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.unlocking ? "Checking…"
                            : root.authOk ? (root.preview ? "PAM OK — password accepted" : "Welcome")
                            : root.failed ? "Try again" : ""
                        color: root.failed ? "#e0536b" : (root.authOk ? "#6fcf8b" : "#9a9aa8")
                        font.pixelSize: 12
                        font.family: "Google Sans Flex"
                    }
                }

                // Always focused and always present, even while the field is
                // invisible: typing is what makes the field appear, so it has
                // to be listening before there is anything to show.
                TextInput {
                    anchors.fill: fieldHolder
                    anchors.margins: 14
                    verticalAlignment: TextInput.AlignVCenter
                    horizontalAlignment: TextInput.AlignHCenter
                    echoMode: TextInput.Password
                    passwordCharacter: "•"
                    color: "#f2f2f4"
                    font.pixelSize: 15
                    font.family: "Google Sans Flex"
                    enabled: !root.unlocking
                    focus: true
                    text: root.password

                    // Present and focused even when invisible -- typing is what
                    // summons the field -- so the caret has to be silenced
                    // explicitly, or it blinks alone over the wallpaper.
                    opacity: root.fieldVisible ? 1 : 0
                    cursorVisible: root.fieldVisible && !root.unlocking

                    onTextChanged: {
                        root.password = text;
                        if (text.length > 0)
                            root.failed = false;
                    }
                    onAccepted: {
                        if (root.password.length === 0 || root.unlocking)
                            return;
                        root.unlocking = true;
                        pam.start();
                    }
                    Component.onCompleted: forceActiveFocus()
                }
            }
        }
    }

    // The real thing.
    WlSessionLock {
        id: lock
        locked: !root.preview
        surface: WlSessionLockSurface {
            color: "#08080b"
            Loader { anchors.fill: parent; sourceComponent: face }
        }
    }

    // The safe thing.
    LazyLoader {
        active: root.preview
        component: PanelWindow {
            anchors { top: true; left: true }
            implicitWidth: 960
            implicitHeight: 560
            color: "transparent"
            WlrLayershell.namespace: "brollios:splash-preview"
            Loader { anchors.fill: parent; sourceComponent: face }
        }
    }
}
