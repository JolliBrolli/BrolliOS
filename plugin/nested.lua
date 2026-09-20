-- Step-1 spike: STOCK Hyprland, nested. No Brolli patch, no layer rules,
-- no BROLLI_HYPR_PATCHED. Deliberately minimal.
hl.monitor({ output = "", mode = "1600x900", position = "auto", scale = 1 })

hl.config({
    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        force_default_wallpaper = 0,
    },
    decoration = { rounding = 10 },
    input = { kb_layout = "us", follow_mouse = 1 },
    debug = { disable_logs = false },
})

hl.on("hyprland.start", function()
    hl.exec_cmd("foot")
end)

hl.bind("SUPER + SHIFT + Q", hl.dsp.exit(), { description = "quit" })
