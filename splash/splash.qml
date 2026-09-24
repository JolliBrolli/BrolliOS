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

    property var wordmark: null
    property int glyphCount: wordmark ? wordmark.paths.length : 0
    property real drawProgress: 0

    property bool unlocking: false
    property bool failed: false
    property bool authOk: false
    property string password: ""

    // Testing a locker by locking your own session is a bad way to find out
    // the password field does not take focus.
    readonly property bool preview: Quickshell.env("BROLLI_SPLASH_PREVIEW") === "1"

    // Glyphs draw one after another, left to right, so it reads as writing
    // rather than everything appearing at once.
    function glyphProgress(i) {
        return Math.max(0, Math.min(1, root.drawProgress * root.glyphCount - i));
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

    PamContext {
        id: pam
        onPamMessage: if (this.responseRequired) this.respond(root.password)
        onCompleted: result => {
            if (result === PamResult.Success) {
                root.unlocking = false;
                root.authOk = true;
                // In preview, prove the password works WITHOUT unlocking
                // anything -- the whole point is to find out before trusting
                // this with a real session.
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

    Component {
        id: face

        Rectangle {
            color: "#08080b"

            Column {
                anchors.centerIn: parent
                spacing: 54

                // ── the wordmark, drawn on ────────────────────────────────
                Item {
                    id: mark
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
                                strokeColor: "#f2f2f4"
                                strokeWidth: 1.6
                                capStyle: ShapePath.RoundCap
                                joinStyle: ShapePath.RoundJoin
                                // Fill arrives behind the stroke, once that
                                // glyph has finished being drawn.
                                fillColor: Qt.rgba(0.95, 0.95, 0.96,
                                                   Math.max(0, glyph.p - 0.7) / 0.3)
                                strokeStyle: ShapePath.DashLine
                                dashPattern: [glyph.dash, glyph.dash]
                                dashOffset: glyph.dash * (1 - glyph.p)
                                PathSvg { path: glyph.modelData.d }
                            }
                        }
                    }
                }

                // ── password ──────────────────────────────────────────────
                Item {
                    width: 260
                    height: 70
                    opacity: root.drawProgress > 0.6 ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 450 } }

                    Rectangle {
                        id: fieldBg
                        width: parent.width
                        height: 44
                        radius: height / 2
                        color: "#16161c"
                        border.width: 1
                        border.color: root.failed ? "#e0536b" : "#2a2a33"
                        Behavior on border.color { ColorAnimation { duration: 200 } }

                        TextInput {
                            id: field
                            anchors.fill: parent
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

                    Text {
                        anchors.top: fieldBg.bottom
                        anchors.topMargin: 9
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.unlocking ? "Checking…"
                            : root.authOk ? (root.preview ? "PAM OK — password accepted" : "Welcome")
                            : root.failed ? "Try again" : ""
                        color: root.failed ? "#e0536b" : (root.authOk ? "#6fcf8b" : "#7a7a88")
                        font.pixelSize: 12
                        font.family: "Google Sans Flex"
                    }
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
            implicitWidth: 900
            implicitHeight: 520
            color: "transparent"
            WlrLayershell.namespace: "brollios:splash-preview"
            Loader { anchors.fill: parent; sourceComponent: face }
        }
    }
}
