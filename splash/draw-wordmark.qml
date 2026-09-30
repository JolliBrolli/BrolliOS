//
// Draw the wordmark yourself, with the stylus.
//
//   qs -p ~/Projects/Brolli-Glass/splash/draw-wordmark.qml
//
// Why this rather than a drawing app: it records the PEN PATH -- the actual
// points your stylus travelled -- which is the centreline the splash needs. A
// drawing app would give a picture, and getting a centreline back out of a
// picture means tracing, which returns outlines, not the stroke you drew.
//
// Draw in one or more strokes, then press s. It writes drawing.json next to
// this file; import-drawing.py turns that into the wordmark.
//
// Keys:  s save   c clear   u undo last stroke   [ ] sheet opacity   Esc quit
//
// It is a normal window at 30% opacity, so it can be moved over a reference
// and traced.
//
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    // Each stroke is a flat [x0,y0,x1,y1,...]; a new stroke starts on pen down.
    property var strokes: []
    property var current: []
    property int strokeCount: 0
    property string status: "trace the wordmark in writing order — s save · c clear · u undo · [ ] opacity · Esc quit"
    property real sheetOpacity: 0.30

    // Trace over the imported wordmark if there is one.
    readonly property string traceSource:
        Qt.resolvedUrl("wordmark-mask.png").toString()

    readonly property string outPath:
        Qt.resolvedUrl("drawing.json").toString().replace("file://", "")

    Process { id: saveProc }

    function save() {
        if (root.strokes.length === 0) {
            root.status = "nothing drawn yet";
            return;
        }
        const payload = JSON.stringify({
            canvas: { width: canvas.width, height: canvas.height },
            // Where the wordmark sits inside the canvas, so the trace can be
            // mapped back onto the image it was drawn over.
            trace: { x: trace.x - canvas.x, y: trace.y - canvas.y,
                     width: trace.paintedWidth, height: trace.paintedHeight,
                     ox: (trace.width - trace.paintedWidth) / 2,
                     oy: (trace.height - trace.paintedHeight) / 2 },
            strokes: root.strokes
        });
        // Passed as an argument rather than stdin: Quickshell's Process has no
        // stdin writer, and this is drawing data, not a secret.
        saveProc.exec({
            command: ["bash", "-c", 'printf "%s" "$1" > "$2"', "_", payload, root.outPath]
        });
        root.status = "saved " + root.strokes.length + " stroke(s) → drawing.json";
    }

    // A real window, not a layer surface: it can be moved, resized and put
    // over whatever you are tracing. The canvas is translucent so you can see
    // through it while you sketch.
    FloatingWindow {
        id: win
        implicitWidth: 1100
        implicitHeight: 420
        title: "BrolliOS wordmark — draw it"
        color: "transparent"

        Rectangle {
            id: sheet
            anchors.fill: parent
            color: "#0d0d11"
            opacity: root.sheetOpacity
        }

        // The wordmark to trace over. You are not redrawing it -- the shape
        // still comes from the image. You are showing it the ORDER a human
        // writes it in, which is the one thing no amount of analysing the
        // picture can work out.
        Image {
            id: trace
            anchors.fill: parent
            anchors.margins: 16
            source: root.traceSource
            fillMode: Image.PreserveAspectFit
            opacity: 0.45
            smooth: true
            visible: status === Image.Ready
        }

        // Guides and ink sit ON TOP of the translucent sheet at full strength,
        // or they would fade out with it and be impossible to see.
        Item {
            anchors.fill: parent

            Rectangle {
                x: 40; width: parent.width - 80
                y: parent.height * 0.70; height: 1
                color: "#ffffff"; opacity: 0.22
            }
            Rectangle {
                x: 40; width: parent.width - 80
                y: parent.height * 0.34; height: 1
                color: "#ffffff"; opacity: 0.12
            }

            Canvas {
                id: canvas
                anchors.fill: parent
                anchors.margins: 16
                renderStrategy: Canvas.Immediate

                onPaint: {
                    const ctx = getContext("2d");
                    ctx.reset();
                    ctx.strokeStyle = "#ffffff";
                    ctx.lineWidth = 13;
                    ctx.lineCap = "round";
                    ctx.lineJoin = "round";
                    const all = root.strokes.concat(
                        root.current.length ? [root.current] : []);
                    for (const s of all) {
                        if (s.length < 4) continue;
                        ctx.beginPath();
                        ctx.moveTo(s[0], s[1]);
                        for (let i = 2; i < s.length; i += 2)
                            ctx.lineTo(s[i], s[i + 1]);
                        ctx.stroke();
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton

                    onPressed: mouse => {
                        root.current = [mouse.x, mouse.y];
                        canvas.requestPaint();
                    }
                    onPositionChanged: mouse => {
                        if (!pressed) return;
                        const c = root.current;
                        const n = c.length;
                        if (n >= 2) {
                            const dx = mouse.x - c[n - 2], dy = mouse.y - c[n - 1];
                            if (dx * dx + dy * dy < 4) return;
                        }
                        c.push(mouse.x, mouse.y);
                        root.current = c;
                        canvas.requestPaint();
                    }
                    onReleased: {
                        if (root.current.length >= 4) {
                            const s = root.strokes;
                            s.push(root.current);
                            root.strokes = s;
                            root.strokeCount = s.length;
                            root.status = root.strokeCount + " stroke(s) — s to save";
                        }
                        root.current = [];
                        canvas.requestPaint();
                    }
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 10
                text: root.status
                color: "#c8c8d4"
                font.pixelSize: 12
                font.family: "Google Sans Flex"
            }

            focus: true
            Keys.onPressed: event => {
                if (event.key === Qt.Key_S) root.save();
                else if (event.key === Qt.Key_C) {
                    root.strokes = []; root.current = []; root.strokeCount = 0;
                    root.status = "cleared";
                    canvas.requestPaint();
                } else if (event.key === Qt.Key_U) {
                    const s = root.strokes; s.pop(); root.strokes = s;
                    root.strokeCount = s.length;
                    root.status = "undo — " + s.length + " stroke(s)";
                    canvas.requestPaint();
                } else if (event.key === Qt.Key_BracketLeft) {
                    root.sheetOpacity = Math.max(0.05, root.sheetOpacity - 0.1);
                    root.status = "sheet " + Math.round(root.sheetOpacity * 100) + "%";
                } else if (event.key === Qt.Key_BracketRight) {
                    root.sheetOpacity = Math.min(1.0, root.sheetOpacity + 0.1);
                    root.status = "sheet " + Math.round(root.sheetOpacity * 100) + "%";
                } else if (event.key === Qt.Key_Escape) {
                    Qt.exit(0);
                }
            }
            Component.onCompleted: forceActiveFocus()
        }
    }

}
