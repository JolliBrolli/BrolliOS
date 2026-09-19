import qs.modules.common
import qs.modules.common.widgets
import QtQuick

/**
 * AdaptiveGlassText's own logic, applied to MaterialSymbol instead of
 * StyledText — the two are sibling types (both extend StyledText directly;
 * MaterialSymbol just layers its own icon-font properties on top), so this
 * duplicates AdaptiveGlassText's wiring rather than inheriting from it. See
 * that file for the full rationale (whole-element sampling, layer.live vs
 * layer.enabled, why this isn't stateful/hysteresis-corrected). Used for a
 * single icon glyph sitting directly on glass (e.g. MacDock.qml's non-app
 * entries) rather than a run of text.
 */
MaterialSymbol {
    id: root

    property var glassRoot: null
    property var backdropTexture: null
    property bool contrastActive: true

    readonly property bool contrastWired: !!root.glassRoot && !!root.backdropTexture
    readonly property bool contrastContentReady: root.contrastWired && !!root.glassRoot.glassReady
    property bool everReady: false
    onContrastContentReadyChanged: {
        if (root.contrastContentReady)
            root.everReady = true;
    }
    Component.onCompleted: {
        if (root.contrastContentReady)
            root.everReady = true;
    }

    function computeWindowLocalPos(item) {
        let x = 0, y = 0, cur = item;
        while (cur) {
            x += cur.x;
            y += cur.y;
            cur = cur.parent;
        }
        return Qt.point(x, y);
    }

    readonly property point selfPos: root.contrastWired ? root.computeWindowLocalPos(root) : Qt.point(0, 0)
    readonly property vector4d backdropRect: {
        if (!root.contrastWired)
            return Qt.vector4d(0, 0, 1, 1);
        const gp = root.glassRoot.glassPos;
        const pad = root.glassRoot.glassPad;
        const tw = root.glassRoot.glassTexW;
        const th = root.glassRoot.glassTexH;
        const u0 = (root.selfPos.x - (gp.x - pad)) / tw;
        const v0 = (root.selfPos.y - (gp.y - pad)) / th;
        const u1 = u0 + root.width / tw;
        const v1 = v0 + root.height / th;
        return Qt.vector4d(u0, v0, u1, v1);
    }

    layer.enabled: root.everReady
    layer.live: root.contrastActive
    layer.effect: ShaderEffect {
        property var source
        property var backdropSource: root.backdropTexture
        property vector4d backdropRect: root.backdropRect
        fragmentShader: Qt.resolvedUrl("glasstextcontrast.frag.qsb")
    }
}
