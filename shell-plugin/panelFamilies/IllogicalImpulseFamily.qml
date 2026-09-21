import QtQuick
import Quickshell

import qs.modules.common
import qs.modules.common.widgets.glass
import qs.modules.ii.background
import qs.modules.ii.bar
import qs.modules.ii.cheatsheet
import qs.modules.ii.desktopIcons
import qs.modules.ii.desktopWidgets
import qs.modules.ii.dock
import qs.modules.ii.focusTimer
import qs.modules.ii.glassTest
import qs.modules.ii.hotCorners
import qs.modules.ii.lock
import qs.modules.ii.macDock
import qs.modules.ii.mediaControls
import qs.modules.ii.menubar
import qs.modules.ii.notificationPopup
import qs.modules.ii.onScreenDisplay
import qs.modules.ii.onScreenKeyboard
import qs.modules.ii.overview
import qs.modules.ii.polkit
import qs.modules.ii.regionSelector
import qs.modules.ii.screenCorners
import qs.modules.ii.screenTranslator
import qs.modules.ii.sessionScreen
import qs.modules.ii.sidebarLeft
import qs.modules.ii.sidebarRight
import qs.modules.ii.overlay
import qs.modules.ii.verticalBar
import qs.modules.ii.wallpaperSelector

Scope {
    // PLUGIN-TEST SHELL COPY: Quickshell creates singletons lazily, on first
    // reference. Nothing else touches GlassUniformBridge, so without this it
    // would never be instantiated and the Hyprland plugin would never receive
    // the material's uniform values.
    readonly property var glassUniformBridge: GlassUniformBridge

    // Brolli-Glass: full-width Bar disabled in favor of the macOS-style
    // Menubar. The Island/notch feature (IslandLeft/Right/Notch) has been
    // removed entirely — Menubar reserves its own top-strip space now.
    // PanelLoader { extraCondition: !Config.options.bar.vertical; component: Bar {} }
    PanelLoader { component: Menubar {} }
    PanelLoader { component: Background {} }
    PanelLoader { component: Cheatsheet {} }
    PanelLoader { extraCondition: Config.options.background.widgets.todo.enable; component: DesktopWidgets {} }
    PanelLoader { component: DesktopIcons {} }
    PanelLoader { extraCondition: Config.options.dock.enable && !Config.options.dock.macStyleDock; component: Dock {} }
    PanelLoader { extraCondition: Config.options.dock.enable && Config.options.dock.macStyleDock; component: MacDock {} }
    PanelLoader { component: FocusOverlay {} }
    // Throwaway liquid-glass test rig — toggle: qs -c Brolli-Glass ipc call glassTest toggle
    // PLUGIN-TEST SHELL COPY: GlassTest was the original liquid-glass test
    // rig — its own inline ScreencopyView plus the full shader chain. All of
    // the old glass is removed in this copy, so it is unregistered here
    // rather than left to spin up a capture nothing consumes.
    // PanelLoader { component: GlassTest {} }
    PanelLoader { component: HotCorners {} }
    PanelLoader { component: Lock {} }
    PanelLoader { component: MediaControls {} }
    PanelLoader { component: NotificationPopup {} }
    // PanelLoader { component: OnScreenDisplay {} }
    PanelLoader { component: OnScreenKeyboard {} }
    PanelLoader { component: Overlay {} }
    PanelLoader { component: Overview {} }
    PanelLoader { component: Polkit {} }
    PanelLoader { component: RegionSelector {} }
    PanelLoader { component: ScreenCorners {} }
    PanelLoader { component: ScreenTranslator {} }
    PanelLoader { component: SessionScreen {} }
    PanelLoader { component: SidebarLeft {} }
    PanelLoader { component: SidebarRight {} }
    PanelLoader { extraCondition: Config.options.bar.vertical; component: VerticalBar {} }
    PanelLoader { component: WallpaperSelector {} }
}
