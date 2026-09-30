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
// Run splash/import-lineart.py on the umbrella drawing first. It writes
// wordmark.json and the textures beside it -- a signed distance field, a tube
// field, a drawing order and the drawn lines. They are build products of
// someone's artwork, so they are generated and never committed.
//
import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pam
import Qt5Compat.GraphicalEffects

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

    // Glass letters, or solid ones. The material's character is at its EDGES,
    // so cut to letter shapes it is mostly interior and can read flat -- worth
    // being able to flip back and compare.
    readonly property bool glassWordmark: Quickshell.env("BROLLI_SPLASH_FLATMARK") !== "1"

    // A pen stroke, not letterforms. Thick enough to be a body the glass can
    // refract through -- a hairline has no inside.
    readonly property bool isScript: wordmark && wordmark.style === "script"
    readonly property bool isImage: wordmark && wordmark.style === "image"
    readonly property real penWidth: 13

    // How far each letter's glass panel extends past its ink.
    readonly property real letterInset: 13

    readonly property double startedAt: Date.now()

    // The field is not there until it has something to show. In preview it
    // stays up, because you cannot type into a preview to make it appear.
    readonly property bool fieldVisible: password.length > 0 || unlocking || failed || preview

    // Glyphs draw one after another, left to right, so it reads as writing
    // rather than everything appearing at once.
    function glyphProgress(i) {
        if (root.isScript) return root.drawProgress;
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

    // The same settings the plugin and the Settings sliders use, so the lock
    // screen cannot drift away from every other panel.
    property var glass: ({})
    FileView {
        id: glassConfig
        path: Quickshell.env("HOME") + "/.config/brollios/config.json"
        watchChanges: true
        onLoaded: {
            try {
                root.glass = JSON.parse(glassConfig.text()).appearance.liquidGlass || ({});
            } catch (e) {
                console.warn("[splash] could not read liquidGlass settings:", e);
            }
        }
        onFileChanged: reload()
    }
    function g(key, fallback) {
        const v = root.glass[key];
        return (v === undefined || v === null) ? fallback : v;
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
        duration: 2900
        // A roller coaster: eases up, runs quick through the middle, then a
        // long slow finish. Asymmetric on purpose -- the tail is much longer
        // than the launch, so "OS" is laboured over while "Brolli" flows.
        easing.type: Easing.Bezier
        easing.bezierCurve: [0.42, 0.015, 0.25, 1.0, 1.0, 1.0]
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
            // Fills the screen rather than hugging its contents, so the
            // wordmark and the field can be placed apart from each other
            // instead of the field trailing the wordmark by a fixed margin.
            Item {
                anchors.fill: parent

                Item {
                    id: markHolder
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.topMargin: parent.height * 0.26
                    width: !root.wordmark ? 1
                        : root.isImage ? root.wordmark.width
                        : root.wordmark.width + root.penWidth
                    height: !root.wordmark ? 1
                        : root.isImage ? root.wordmark.height
                        : root.wordmark.ascent + root.wordmark.descent + root.penWidth




                    // ── an imported wordmark image ─────────────────────
                    // The image IS the mask. Tracing it would turn the brush
                    // stroke into its own outline, which is the wrong shape;
                    // used directly, every bit of weight and taper survives.
                    // ── handwriting: ONE continuous pen stroke ──────────
                    // Apple's "hello" is a single path, trimmed on, stroked
                    // with a round cap -- not letter outlines. A normal font
                    // cannot give that: it stores outlines, and the centreline
                    // of a glyph is not in the file. The Hershey script hand
                    // does store centrelines, so the wordmark is one path with
                    // pen-lifts in it, and the dash walks the whole word in
                    // writing order.
                    Shape {
                        id: penStroke
                        anchors.fill: parent
                        visible: root.isScript
                        asynchronous: false
                        preferredRendererType: Shape.CurveRenderer
                        transform: Translate { y: root.wordmark ? -root.wordmark.top : 0 }

                        readonly property real len: root.wordmark && root.isScript
                            ? root.wordmark.paths[0].len : 1
                        readonly property real w: root.penWidth

                        ShapePath {
                            strokeColor: "#ffffff"
                            fillColor: "transparent"
                            strokeWidth: penStroke.w
                            capStyle: ShapePath.RoundCap
                            joinStyle: ShapePath.RoundJoin
                            // dashPattern is in units of strokeWidth, not px.
                            strokeStyle: ShapePath.DashLine
                            dashPattern: [penStroke.len / penStroke.w,
                                          penStroke.len / penStroke.w]
                            dashOffset: penStroke.len / penStroke.w * (1 - root.drawProgress)
                            PathSvg { path: root.wordmark && root.isScript
                                ? root.wordmark.paths[0].d : "" }
                        }
                    }

                }

                // The letters, rendered to a texture and taken off screen.
                // hideSource is what stops you seeing the word itself: the
                // glass is the only thing drawn.
                ShaderEffectSource {
                    id: markMask
                    visible: false
                    sourceItem: markHolder
                    hideSource: root.glassWordmark
                    live: true
                    width: markHolder.width
                    height: markHolder.height
                }

                // The reveal-order texture.
                //
                // Handing a ShaderEffect a url and expecting a texture does
                // not work here -- the sampler stays unbound and reads
                // (0,0,0,1), so every pixel claims order 0 and the whole word
                // arrives at once. Which is exactly what "it just fades in"
                // was. An Image through a ShaderEffectSource does bind, and
                // premultiplication cannot hurt this one because it is fully
                // opaque.
                //
                // No smoothing anywhere: the order is a 16-bit value split
                // across R and G, and interpolating those two channels
                // independently invents values that are nonsense between
                // pixels.
                // The shape, as its own texture. It must NOT be a child of
                // anything on screen: an invisible child of a rendered item is
                // simply not drawn, so it would be missing from the mask -- but
                // an invisible item used directly as a sourceItem still renders
                // into its texture. That difference is why the letters were
                // showing through before they were written.
                Image {
                    id: markImage
                    visible: false
                    source: (root.isImage && root.wordmark.mask)
                        ? Qt.resolvedUrl(root.wordmark.mask) : ""
                    smooth: true
                    mipmap: false
                    cache: true
                }

                ShaderEffectSource {
                    id: maskSource
                    visible: false
                    sourceItem: markImage
                    hideSource: false
                    live: true
                    width: markImage.implicitWidth || 1
                    height: markImage.implicitHeight || 1
                }

                Image {
                    id: orderImage
                    visible: false
                    source: (root.isImage && root.wordmark.order)
                        ? Qt.resolvedUrl(root.wordmark.order) : ""
                    smooth: false
                    mipmap: false
                    cache: true
                }

                ShaderEffectSource {
                    id: orderSource
                    visible: false
                    sourceItem: orderImage
                    hideSource: false
                    live: true
                    smooth: false
                    width: orderImage.implicitWidth || 1
                    height: orderImage.implicitHeight || 1
                }

                // Backdrop for the wordmark glass, padded so the lens can
                // reach outside the letters.
                ShaderEffectSource {
                    id: markBackdrop
                    visible: false
                    sourceItem: wallpaperImage
                    sourceRect: {
                        const w = screen.width, h = screen.height;
                        const my = markHolder.y, mw = markHolder.width, mh = markHolder.height;
                        const pt = markHolder.mapToItem(screen, 0, 0);
                        return Qt.rect(pt.x - glassPad, pt.y - glassPad,
                                       mw + glassPad * 2, mh + glassPad * 2);
                    }
                    width: markHolder.width + glassPad * 2
                    height: markHolder.height + glassPad * 2
                    live: true
                }

                // The shape field: signed distance in R,G and local
                // half-thickness in B. No smoothing -- these are numbers, and
                // interpolating a 16-bit value split across two channels
                // invents values between pixels.
                Image {
                    id: shapeImage
                    visible: false
                    source: (root.isImage && root.wordmark.shape)
                        ? Qt.resolvedUrl(root.wordmark.shape) : ""
                    // Linear filtering, deliberately. A distance field is a
                    // smooth function and interpolates exactly; sampling it
                    // nearest-neighbour makes it a staircase, and fwidth() of
                    // a staircase is jagged antialiasing. This is also what
                    // lets the letters stay clean when the item is larger than
                    // the texture -- the whole reason SDF text rendering works.
                    smooth: true
                    mipmap: false
                    cache: true
                }

                ShaderEffectSource {
                    id: shapeSource
                    visible: false
                    sourceItem: shapeImage
                    live: true
                    smooth: true
                    width: shapeImage.implicitWidth || 1
                    height: shapeImage.implicitHeight || 1
                }

                // The noodle's own shape field: distance to the drawn line,
                // minus its radius. Linear filtering, same as the silhouette.
                Image {
                    id: tubeImage
                    visible: false
                    source: (root.isImage && root.wordmark.tube)
                        ? Qt.resolvedUrl(root.wordmark.tube) : ""
                    smooth: true
                    mipmap: false
                    cache: true
                }

                ShaderEffectSource {
                    id: tubeSource
                    visible: false
                    sourceItem: tubeImage
                    live: true
                    smooth: true
                    width: tubeImage.implicitWidth || 1
                    height: tubeImage.implicitHeight || 1
                }

                // THE material -- generated from plugin/src/brolliglass.frag by
                // port-letters.py, with only the three lines that assume a
                // rounded rectangle replaced. Same constants, same curves, same
                // everything the desktop panels are drawn with.
                ShaderEffect {
                    anchors.fill: markHolder
                    visible: root.glassWordmark && wallpaperImage.status === Image.Ready
                    fragmentShader: Qt.resolvedUrl("glassletters.frag.qsb")

                    property variant source: markBackdrop
                    property variant shapeTex: shapeSource
                    property variant orderTex: orderSource
                    property variant tubeTex: tubeSource
                    // 0 keeps the drawing invisible inside the glass, 1 makes
                    // the strokes black. Enough to read as line work.
                    // Much lower now the lines are a raised tube rather than
                    // a flat mark: the shape does the work, and heavy
                    // darkening on top just makes them look drawn on again.

                    property vector2d panelSize: Qt.vector2d(width, height)
                    property vector2d texSize: Qt.vector2d(markBackdrop.width, markBackdrop.height)
                    property real pad: glassPad
                    property real maxCornerRadius: root.g("maxCornerRadius", 29)

                    property real sdRange: root.wordmark && root.wordmark.sdRange
                        ? root.wordmark.sdRange : 64
                    property vector2d shapeTexel: Qt.vector2d(
                        1.0 / Math.max(1, shapeSource.width),
                        1.0 / Math.max(1, shapeSource.height))

                    // Straight from the same config the plugin reads, so the
                    // lock screen tracks the Settings sliders.
                    property real aghDepth: root.g("aghDepth", 0.30)
                    property real aghStrength: root.g("aghStrength", 0.43)
                    property real aghBlur: root.g("aghBlur", 1.48)
                    property real aghChroma: root.g("aghChroma", 3.0)
                    property real aghEdge: root.g("aghEdge", 0.02)
                    property real aghTint: root.g("aghTint", 0.99)
                    property real aghStretch: root.g("aghStretch", 0.40)

                    property vector2d panelStat: Qt.vector2d(0.5, 0.25)
                    property real glassDir: -1.0
                    property real aghSquash: root.g("aghSquash", 0.3)
                    property real aghPush: root.g("aghPush", 0.0)
                    property real aghBody: root.g("aghBody", 0.06)
                    property real glassOverGlass: 0.0

                    property vector4d tint: Qt.vector4d(0, 0, 0, 0)
                    property real power: root.g("power", 2.78)
                    property real rimHighlightStrength: root.g("rimHighlightStrength", 0.25)
                    property real rimHighlightWidth: root.g("rimHighlightWidth", 1.5)
                    property real rimDiagonalReach: root.g("rimDiagonalReach", 1.0)

                    // Cylinder lighting on the noodle, and the glow around it.
                    property real tubeLight: 0.85   // how lit the tube is
                    property real tubeSpec: 0.30    // the highlight along its top
                    property real tubeShine: 24.0   // how tight that highlight is
                    property real bloom: 0.34       // the halo's strength
                    property real bloomWidth: 13.0  // how far it reaches, px

                    property real revealEdge: root.drawProgress * 1.12 - 0.06
                    // A longer leading edge: a nib laying down a line, rather
                    // than a hard boundary sweeping over one.
                    property real revealSoft: 0.06
                }

                // Centred under the wordmark, and only there when in use.
                Item {
                    id: fieldHolder
                    anchors.horizontalCenter: parent.horizontalCenter
                    // Anchored to the bottom, so it sits where it should on
                    // any screen height rather than drifting with a percentage.
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Math.max(90, parent.height * 0.12)
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
            // Without this a layer-shell window never receives keys, so the
            // preview could be looked at but not typed into -- which made it
            // useless for testing the one thing that needs a password.
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
            Loader { anchors.fill: parent; sourceComponent: face }
        }
    }
}
