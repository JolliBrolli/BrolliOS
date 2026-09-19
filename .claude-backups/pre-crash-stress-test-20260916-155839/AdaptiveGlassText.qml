import qs.modules.common
import qs.modules.common.widgets
import QtQuick

/**
 * Drop-in replacement for StyledText for text that sits directly on top of a
 * liquid-glass surface (see LiquidGlassBackground.qml / SearchWidget.qml's
 * own hand-rolled equivalent). Instead of a fixed theme color, picks
 * black/white for the WHOLE element from the average local luminance of the
 * glass's own already-rendered backdrop behind this text — legible
 * regardless of what's behind this specific patch of glass, independent of
 * the system's dark/light mode. Deliberately whole-element, not per-pixel or
 * per-glyph — matches how Apple's own adaptive materials actually decide
 * (one appearance per element, not per letter); see glasstextcontrast.frag's
 * own comment for why per-glyph was tried and dropped.
 *
 * No GPU readback: uses Qt Quick's layer.enabled/layer.effect (this item's
 * own rendered glyphs become a texture for free) plus glasstextcontrast.frag,
 * which also samples the glass's already-computed blurred crop texture — a
 * texture that pipeline renders every frame anyway, not a new capture.
 *
 * Usage: set `glassRoot` to the LiquidGlassBackground instance (or
 * SearchWidget's own hand-rolled equivalent — anything exposing glassPos/
 * glassPad/glassTexW/glassTexH, same property names both already use) and
 * `backdropTexture` to that instance's own blurred crop
 * (liveHBlurReg/staticHBlurReg, or SearchWidget's glassHBlurReg). Leave
 * `contrastActive` bound to the same liveness signal gating the glass's own
 * live rendering (e.g. liveCaptureActive) — this adds a real render pass, so
 * it must go idle exactly when the glass itself does, not run unconditionally.
 *
 * `contrastActive` maps to `layer.live`, NOT `layer.enabled` — that
 * distinction matters: `layer.enabled: false` fully bypasses the layer and
 * falls back to this item's own plain `color`, which for adaptive text is
 * very possibly the WRONG color, so toggling it with the idle-pulse rhythm
 * produced a visible flicker between the right and wrong color every pulse.
 * `layer.live: false` instead just stops re-rendering the layer's texture
 * and keeps showing its last (correct) frame — exactly "hold the last
 * computed frame" from the plan.
 *
 * `layer.enabled` itself latches on once and never turns back off (see
 * `everReady` below) rather than tracking `contrastWired` directly — early
 * on, `glassRoot`/`backdropTexture` can already be non-null while the
 * backdrop texture itself has no real frame in it yet (the capture pipeline
 * hasn't rendered one), so the very first live sample reads empty/stale
 * data and renders the wrong color for a frame before flipping — a blink at
 * open. `glassRoot.glassReady` is the same sticky "has a real frame ever
 * landed" signal `LiquidGlassBackground`/`SearchWidget` already use to guard
 * their own main shader from this exact problem — reusing it here means the
 * layer doesn't turn on at all until there's real content to sample, so its
 * first-ever render is already correct.
 *
 * Hysteresis: a hard "luminance > 0.5" cut in a stateless shader flickers
 * whenever the average sits near that boundary (a busy backdrop, e.g. a
 * browser tab with lots of colors, keeps landing right around 0.5, so
 * ordinary frame-to-frame noise flips it back and forth). Blending the
 * color across the boundary avoids the flicker but was rejected — text must
 * stay strictly black or white, never gray. Real hysteresis needs memory of
 * the previous decision, which a stateless per-fragment shader doesn't have
 * — so `decisionEffect`/`decisionFeedback` below are a tiny separate 1x1
 * render pass with a `recursive: true` ShaderEffectSource feeding its own
 * previous output back into itself (Qt Quick's documented mechanism for
 * exactly this kind of feedback effect). See glasstextdecision.frag for the
 * actual hysteresis logic; glasstextcontrast.frag (this item's own
 * layer.effect) just reads that 1x1 decision and applies a hard color.
 */
StyledText {
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

    // The stateful hysteresis decision pass — a 1x1 texture holding 0.0
    // ("dark backdrop -> white text") or 1.0 ("light backdrop -> black
    // text"), fed back into itself each frame via `recursive: true` so it
    // has real memory instead of recomputing from scratch every frame.
    ShaderEffectSource {
        id: decisionFeedback
        sourceItem: decisionEffect
        live: root.everReady && root.contrastActive
        recursive: true
        hideSource: true
        visible: false
        width: 1
        height: 1
    }
    ShaderEffect {
        id: decisionEffect
        visible: false
        width: 1
        height: 1
        property var backdropSource: root.backdropTexture
        property vector4d backdropRect: root.backdropRect
        property var prevDecision: decisionFeedback
        fragmentShader: Qt.resolvedUrl("glasstextdecision.frag.qsb")
    }

    layer.enabled: root.everReady
    layer.live: root.contrastActive
    layer.effect: ShaderEffect {
        // Auto-bound by Qt to root's own layer texture (this text's rendered
        // glyphs) — same mechanism every OpacityMask/MultiEffect layer.effect
        // in this codebase relies on, just with a custom shader instead.
        property var source
        property var decisionSource: decisionFeedback
        fragmentShader: Qt.resolvedUrl("glasstextcontrast.frag.qsb")
    }
}
