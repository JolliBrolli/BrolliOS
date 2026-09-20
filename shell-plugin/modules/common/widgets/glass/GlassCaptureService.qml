pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell

/**
 * PLUGIN-TEST SHELL COPY — gutted.
 *
 * The real GlassCaptureService ran one wlr-screencopy capture per
 * monitor (ScreencopyView + ShaderEffectSource), with consumer refcounting
 * and an adaptive duty cycle, because that capture was measured as the
 * dominant GPU cost of the old glass. In this copy the compositor plugin
 * supplies the backdrop instead, so there is nothing to capture: no
 * ScreencopyView is ever created.
 *
 * The API is kept so existing call sites are harmless no-ops.
 */
Singleton {
    function registerConsumer(screenName, debugTag) {}
    function unregisterConsumer(screenName, debugTag) {}
    function setActive(screenName, active, debugTag) {}
    function isLive(screenName) { return false; }
    function sourceFor(screenName) { return null; }
    function hasContentFor(screenName) { return false; }
}
