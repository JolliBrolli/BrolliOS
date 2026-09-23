# Requirements

_What you need before installing, and what the installer will set up for you._

## The short version

An **Arch-based distribution** — CachyOS, EndeavourOS, Arch itself — running
**Hyprland** on Wayland.

This is developed on CachyOS. Other Arch derivatives should work. Ubuntu and
Debian are **not supported yet**; see [below](#other-distributions).

## What you need already

| Requirement | Why |
| --- | --- |
| Arch-based distro with `pacman` | The end-4 base installer targets Arch |
| Python 3.11 or newer | The installer reads `manifest.toml` with `tomllib` |
| `git`, `tar`, `zstd` | Cloning, and unpacking the icon theme |

The installer checks all of these before touching anything and stops with a
clear message if one is missing.

## What the installer sets up

**The end-4 base**, if you do not already have it. This brings Hyprland,
Quickshell, matugen and the base fonts. The installer does not reimplement it —
it clones and runs end-4's own installer, because theirs is maintained and a
copy here would rot. It needs `sudo` and takes a while.

If you already run end-4, skip it:

```bash
./install.sh --skip-base
```

**Everything else** comes from this repo: the shell, the WhiteSur icon themes,
the MatugenGlass theme, wallpapers, Hyprland keybinds and rules, and the
terminal and launcher configs. The full list is on
[What it installs](what-it-installs.md).

## Fonts

None are shipped — none of them may be redistributed. `install.sh` runs
`install/scripts/fonts.sh`, which installs what is packaged and names what is
not:

| font | where it comes from |
|---|---|
| Google Sans Flex — the shell UI | the end-4 base already installs it |
| SF Pro Display — GTK and system | AUR: `otf-san-francisco` |
| Liga SF Mono — the terminal | AUR: `nerd-fonts-sf-mono-ligatures` |
| PP Editorial New — serif only | free for personal use at pangrampangram.com; no package |

Anything you put in `assets/fonts-local/` is installed as-is. That directory is
gitignored, so your copies stay on your machine. A missing font is not fatal —
fontconfig falls back and the desktop still runs.

## Optional extras

- **Zen browser** — gets matching traffic lights automatically if it is installed.

## Other distributions

Ubuntu and Debian are not supported today. The blocker is Quickshell: it is not
packaged for either, it needs Qt 6.6 or newer, and it links against private Qt
APIs so it must be rebuilt against every Qt point release or it crashes on an
ABI mismatch.

end-4 now has a multi-distro installer that has been tested on Debian 13, so the
base is plausible. The rest is being worked on as its own project.
