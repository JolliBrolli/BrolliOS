<h1 align="center">Brolli-Glass</h1>

<p align="center"><b>A macOS-style desktop for Hyprland, with liquid glass drawn by the compositor.</b></p>

<p align="center">
  <a href="#-the-glass">The glass</a> ·
  <a href="#install">Install</a> ·
  <a href="docs/README.md">Docs</a> ·
  <a href="#credits">Credits</a>
</p>

<p align="center"><img src="docs/screenshots/desktop.png" alt="The desktop — menubar, widgets and dock" width="900"></p>

Two halves that only make sense together:

- **BrolliOS** — a [Quickshell](https://quickshell.outfoxxed.me/)/QML shell (menubar, dock,
  desktop widgets, Spotlight) built on the [end-4 / illogical-impulse](https://github.com/end-4/dots-hyprland) framework.
- **Brolli-Glass** — a Hyprland **plugin** that draws the shell's glass *inside the
  compositor*, mid-frame, on stock Hyprland.

The second one is the point of the project. Panels here are not blurred
screenshots: the plugin already holds the frame being composited, so it refracts
the real thing under each surface for about **0.1 W idle and 1 W worst case**.
The shell used to do this with screencopy, in QML, on a patched Hyprland — that
cost ~16 W.

---

## 🍎 The desktop

<p align="center"><img src="docs/screenshots/menubar.png" alt="The menubar: app menus and the status cluster" width="900"></p>

**Menubar** — traffic lights and real app menus (Window · Go · Capture · Focus) on
the left, a system menu, and audio · bluetooth · network · Control Centre ·
battery · tray · clock on the right. Every dropdown is glass, and the whole bar's
text flips between light and dark **as one**, following whatever is behind it.

<p align="center"><img src="docs/screenshots/dock.png" alt="The dock, with magnification and running-app indicators" width="900"></p>

**Dock** — magnifies on hover, marks running apps, and its Trash reflects whether
the Trash actually has anything in it.

<p align="center"><img src="docs/screenshots/widgets.png" alt="Clock, calendar and to-do widgets on the wallpaper" width="640"></p>

**Widgets** — clock, calendar and to-do sit above the wallpaper and below every
window. Desktop icons share that space and step aside when a widget covers them.

<p align="center"><img src="docs/screenshots/overview.png" alt="Workspace overview" width="900"></p>

**Spotlight** searches apps, files, maths and shell commands. The **overview**
drags windows between workspaces. Alongside those: the end-4 sidebars and Control
Centre, notifications, OSD, lock screen, hot corners, an on-screen keyboard, and a
settings app with a live page for every glass uniform.

Everything renders **per-monitor in correct logical coordinates**, scaled displays
included.

---

## 🫧 The glass

The shell says *where* and *what*; the plugin decides *how it is drawn*.

```
shell (BrolliOS)                         plugin (Brolli-Glass)
  GlassRegion        ── glassrect ──▶    where each panel is
  GlassUniformBridge ── glassuniform ─▶  every look value, one --batch
  GlassSample        ── glasssample ──▶  regions to measure
                     ◀── glasssample>>   backdrop colour  (adaptive text)
                     ◀── glassstats>>    how busy it is   (readability)
```

The plugin hooks `renderLayer` and queues its own pass element directly under
each surface, so the glass always sits beneath the panel it belongs to — layer
surfaces *and* the menubar's xdg-popups. The backdrop is a `glBlitFramebuffer`
out of the frame in flight. Which panels redraw is decided once per frame, and
anything completely hidden behind an opaque window is dropped.

- **Lensing, not blur.** The look is Apple's Liquid Glass: transparent and
  refractive, with the character living at the edges.
- **Readability per panel, never per pixel.** Each panel measures its whole
  backdrop, then squashes a busy one's contrast and lifts itself slightly; the
  text on it flips black or white to match. A per-pixel floor was tried first and
  striped busy wallpapers like a zebra.
- **No glass on glass.** A panel drawn over glass already drawn this frame drops
  its own softening, per Apple's own guidance.
- **Every value is a slider** in **Settings → Liquid Glass**, pushed live.

**Measured cost** — paired runs on battery, same action with and without the
plugin, 20 s averages of GPU package power. Δ is the glass:

| scenario | with | without | **Δ GPU** |
|---|---|---|---|
| Idle, dock + widgets up | 3.37 W | 3.28 W | **+0.09 W** |
| Spotlight open, still | 3.48 W | 3.26 W | **+0.22 W** |
| Window dragged behind the dock | 4.96 W | 4.69 W | **+0.27 W** |
| Spotlight expanded, window dragged behind | 5.47 W | 4.96 W | **+0.51 W** |

Full design, the material's maths and every gotcha: **[`plugin/README.md`](plugin/README.md)**.

---

## Requirements

- **Hyprland** with the **end-4 / illogical-impulse** setup (its Lua-based Hyprland
  config, packages, fonts, services and Quickshell). Arch-based — CachyOS,
  EndeavourOS, … — is the smoothest path.
- **Quickshell** ≥ 0.2.1 (installed by the end-4 setup).
- A C++ compiler and the **Hyprland headers**, to build the plugin.
- **Fonts are not shipped** — none of them may be redistributed. The installer
  pulls SF Pro Display and Liga SF Mono from the AUR; Google Sans Flex comes
  with the end-4 base.

Details in [docs/requirements.md](docs/requirements.md).

## Install

```sh
git clone https://github.com/JolliBrolli/Brolli-Glass.git ~/Projects/Brolli-Glass
cd ~/Projects/Brolli-Glass
./install.sh
```

That is the whole desktop: the end-4 base (delegated to end-4's own installer),
then every artifact in [`manifest.toml`](manifest.toml) — icons, theme, GTK and
Qt settings, wallpapers, Hyprland config, terminal and launcher — then the glass
plugin, built to `~/brolli-glass.so`. Everything it writes is backed up before
the first change, so `./install.sh --uninstall` puts the machine back.

### Already have a rice you like?

`--profile shell` takes **only the shell**, and touches nothing else you have
set up:

```sh
./install.sh --profile shell --skip-base
```

That installs exactly two things — `~/.config/quickshell/BrolliOS` (a symlink to
this repo) and a marker-delimited block in end-4's `variables.lua` pointing
Quickshell at it — then builds the plugin. Your icons, GTK theme, wallpapers,
terminal, keybinds and **your monitor config** are left alone.

The one thing to add yourself, since it lives in the Hyprland config this
profile skips:

```lua
-- ~/.config/hypr/custom/execs.lua
hl.plugin.load(os.getenv("HOME") .. "/brolli-glass.so")
```

Without it the shell runs, but with no glass until you load the plugin by hand.

### Every flag

```sh
./install.sh --profile shell  # just the shell and its Hyprland glue
./install.sh --skip-base      # you already run end-4
./install.sh --dry-run        # print every action, change nothing
./install.sh --status         # how the live system differs from the repo
./install.sh --uninstall      # restore the original backup
./install.sh --help
```

Relog when it finishes (or `pkill -x qs; setsid -f qs -c BrolliOS`). The plugin
loads from `~/.config/hypr/custom/execs.lua` at startup; to load it now,
`hyprctl plugin load ~/brolli-glass.so`.

### Voice dictation (optional)

Hold **Right Ctrl** to dictate into the focused window, via the external
[hyprvoice](https://github.com/leonardotrapani/hyprvoice) daemon + Groq Whisper.
Setup: [docs/voice-dictation.md](docs/voice-dictation.md).

---

## Layout

| path | what |
|---|---|
| `quickshell/` | the shell — installed as `~/.config/quickshell/BrolliOS` (a symlink; edit the repo) |
| `plugin/src/brolli-glass.cpp` | the Hyprland plugin |
| `plugin/src/brolliglass.frag` | the material, read from disk at plugin load |
| `install.sh`, `manifest.toml`, `install/` | the installer |
| `NOTES.md` | how the whole thing is put together |
| `PROGRESS.md` | the work log, newest first |

## Notes & gotchas

- **Never `cp` over the loaded `.so`.** Hyprland has it mapped and the next
  unload takes the session with it. Unload → copy to a temp name → `mv` → load.
- **The plugin is pinned to its Hyprland build.** Rebuild after a Hyprland
  update: `install/scripts/build-plugin.sh`.
- **Lua-Hyprland dispatch** — this config uses the `hl.dsp.*` API; the plain
  `dispatch "focuswindow …"` form silently no-ops on a Lua-config Hyprland.
- Useful while poking at it: `hyprctl glassopt` (state, panels, draw counts).

---

## Credits

This is a small project standing on a lot of other people's work. In the order it
mattered:

**[end-4 / dots-hyprland (illogical-impulse)](https://github.com/end-4/dots-hyprland)** — the
foundation. The Quickshell module layout, the Lua Hyprland config, the package,
font and service base, and most of the desktop that isn't macOS-shaped: sidebars,
Control Centre, notifications, OSD, lock, overview, cheatsheet, on-screen
keyboard. Brolli-Glass is a derivative work of it and stays GPL-3.0 because of it.

**[Quickshell](https://quickshell.outfoxxed.me/)** (outfoxxed) — the runtime the whole shell is
written in: layer-shell surfaces, Hyprland IPC, per-monitor screens and the hot
reload that made every iteration here a save away.

**[Hyprland](https://hyprland.org/)** (vaxry and contributors) — not just the compositor: its
**plugin API is why this project exists in the cheap form it does**. Custom
`IPassElement`, the render-stage bus, function hooks and `registerHyprCtlCommand`
are all upstream, public and unpatched. Reading the renderer itself — how
`CRenderPass` grows damage around live-blur elements, how `CDamageRing` ages
buffer damage, how layer popups are walked — is what turned "draw glass mid-frame"
from an idea into something that survives a real frame loop.

**[Aghajari's Liquid Glass recreation](https://www.aghajari.com/publications/liquid-glass/)** — the
material's ancestor. The circular lens profile over a rim band, the radial
displacement, the chromatic split and the tint all come from that write-up. What
this project added on top: a centre **line** instead of a centre point (so long
panels like the dock stop smearing sideways), the per-panel readability layer, and
the same 5×5 Gaussian taken in 9 bilinear samples instead of 25.

**[ShojiWM](https://github.com/bea4dev/shoji)** (bea4dev) — studied for edge handling when the
first two attempts at corners came out split four ways and rounded off. Its
island-refract shader is also where the architecture was borrowed from in spirit:
bea4dev's `LiquidIslandQS` + ShojiWM does the same split this project ended up at
— the shell draws a silhouette, the compositor draws the glass.

**HyprGlass** — prior art, and the reason a compositor-side plugin was on the table
at all. It was running on this machine before any of this was written, tinting
shell surfaces from inside Hyprland; seeing that work is what made "let the
compositor do it" the obvious route rather than a gamble.

**[Hyprtasking](https://github.com/raybbian/hyprtasking)** (raybbian) — glass rendered over its
workspace overview until the plugin learned to honour `SRenderModifData`. Its use
of the render hints pass is what taught this plugin that a surface's box is not
necessarily where it lands on screen.

**Apple — WWDC25, *Meet Liquid Glass*** — the design targets only: lensing versus
scattering, tint and dynamic range, light/dark flipping, and the "don't put the
material on both layers" rule that became the no-glass-on-glass check. Behaviour
described, never implementation; everything about *how* ours works came from the
sources above and from measuring on this machine.

**[OpenAgentIsland](https://github.com/patheonsceo/openagentisland)** — this repo's direct
ancestor and my own earlier take on the same idea: the manifest-driven installer,
the docs layout, and the first versions of the dock, menubar and desktop widgets.
Its notch/Dynamic Island (whose interaction techniques were studied from
[Hyprfabricated](https://github.com/tr1xem/hyprfabricated)) and its Claude-agent monitor were
removed here — git history still has them.

**Also used:** the [WhiteSur icon theme](https://github.com/vinceliuice/WhiteSur-icon-theme)
(vinceliuice), which is bundled; Google Sans Flex, SF Pro Display, Liga SF Mono and
PP Editorial New, which are *not* — they are proprietary, so the installer fetches
them instead; and optionally [hyprvoice](https://github.com/leonardotrapani/hyprvoice)
(leonardotrapani) for dictation.

## License

A derivative work of end-4 / dots-hyprland, released under the **GNU General
Public License v3.0** — see [`LICENSE`](./LICENSE). If you distribute it, or a
modified version, it must stay GPL-3.0, keep these notices, and ship source.
