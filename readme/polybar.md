# Polybar — Status Bar

The bar at the top of the screen showing workspaces, window title, system
metrics, and the clock. i3 launches polybar at session start via the
`launch.sh` wrapper.

**Config:** `~/.config/polybar/config.ini`
**Launcher:** `~/.config/polybar/launch.sh`
**Reload after edits:** `~/.config/polybar/launch.sh`  (or i3 reload — `Mod+Shift+c`)

---

## What's on the bar (left → right)

```
workspaces | window-title    date           cpu mem eth wlan | mullvad wireguard | vol bat tray
```

| Module          | What it shows                                                |
|-----------------|--------------------------------------------------------------|
| `i3`            | Workspace tabs (click to switch)                             |
| `xwindow`       | Title of the focused window                                  |
| `date`          | Date and 24-h clock (centred)                                |
| `cpu`           | CPU usage                                                    |
| `memory`        | RAM usage                                                    |
| `eth`           | Wired link throughput; **hides when no cable**               |
| `wlan`          | Wifi signal-strength ramp + SSID + downspeed; click → editor |
| `mullvad`       | Mullvad VPN state (click to toggle / right-click for menu)   |
| `wireguard`     | Active WireGuard tunnel + endpoint (click for menu)          |
| `pulseaudio`    | Volume + mute state (scroll on it to adjust)                 |
| `battery`       | Charge level + charging glyph; **hides on desktops/VMs**     |
| `tray`          | System tray icons (nm-applet, mullvad-vpn, etc.)             |

The wifi and ethernet modules are split so a laptop on wifi never shows
a permanent red "ethernet offline" pill — `eth` only renders when an
RJ-45 cable is plugged in. Click bindings on `wlan`:

| Mouse on `wlan`  | Action                                          |
|------------------|-------------------------------------------------|
| Left-click       | Open `nm-connection-editor` (full GUI)          |
| Right-click      | Open `nmtui` in alacritty (TUI)                 |
| Middle-click     | Toggle wifi radio via `rfkill`                  |

Click bindings on `battery`:

| Mouse on `battery` | Action                                                |
|--------------------|-------------------------------------------------------|
| Left-click         | `acpi -V` in alacritty (battery + thermal + AC)       |
| Right-click        | `sudo tlp-stat -b` (charge/cycle/health detail)       |

The two VPN modules are described in detail in [`vpn.md`](vpn.md). Both are
custom/script modules that call helpers in `~/.config/polybar/scripts/`
and update at 3- and 5-second intervals respectively.

---

## Multi-monitor

The launcher (`launch.sh`) detects connected outputs via `xrandr` and starts
one bar per monitor. Disconnect/connect a monitor and re-run:

```bash
~/.config/polybar/launch.sh
```

The `[bar/main]` section has `monitor =` left blank — the launcher exports
`MONITOR=<name>` per-iteration so each instance binds to its own output.

---

## Mouse interactions

- **Click a workspace number** — switch to that workspace
- **Scroll on the volume module** — raise / lower volume
- **Click the volume module** — opens `pavucontrol` (audio mixer)
- **Click the date** — no default; you can wire a calendar popup if you like

---

## Adding / removing modules

1. Edit `~/.config/polybar/config.ini`.
2. Find the `modules-left`, `modules-center`, `modules-right` lines under
   `[bar/main]`.
3. Add or remove the module name (must match a `[module/<name>]` block).
4. Re-run `~/.config/polybar/launch.sh` to apply.

Example — add a temperature indicator (battery, eth, wlan are already
shipped):

```ini
[module/temperature]
type             = internal/temperature
interval         = 2
thermal-zone     = 0
warn-temperature = 80
format           = <ramp> <label>
label            = %temperature-c%
```

Then add `temperature` to the `modules-right` list.

If the shipped `battery` module doesn't render on a real laptop, your
hardware likely uses a different battery / adapter name. Check:
```bash
ls /sys/class/power_supply/
```
Common ThinkPad variants: `BAT0` + `ADP1` (default), `BAT1` (X1 / dual-battery
models), `AC` instead of `ADP1` (older kernels). Edit `[module/battery]`'s
`battery = ...` and `adapter = ...` in `~/.config/polybar/config.ini` to
match, then re-run `~/.config/polybar/launch.sh`.

---

## Customising the look

- Colours come from the `[colors]` section at the top of the file. Change one
  there, every module that references `${colors.<name>}` updates.
- Font is JetBrainsMono Nerd Font 10pt (covers icon glyphs natively).
  `font-3` and `font-4` are plain `JetBrains Mono` and `DejaVu Sans Mono`
  fallbacks so the bar still renders text on a fresh box where the Nerd
  Font hasn't been installed yet — the icon glyphs fall back to boxes,
  but no module disappears.
- Bar height: change `height = 32` in `[bar/main]`.
- Bar position: `top = true`. Set to `false` for a bottom bar.

---

## Troubleshooting

| Symptom                                  | Cause / fix                                              |
|------------------------------------------|----------------------------------------------------------|
| Bar shows empty boxes instead of icons   | Nerd Font missing — re-run install `terminal` phase      |
| Workspaces module empty                  | i3 socket not visible — make sure i3 is running          |
| Volume module says "no sink"             | PulseAudio not running; `pulseaudio --start`             |
| `wlan` module never appears              | No wireless interface present (VM / desktop) — expected. |
| `eth` module never appears               | No cable plugged in — module hides on disconnect.        |
| `battery` module never appears           | No `/sys/class/power_supply/BAT*` — desktop / VM, expected. |
| `battery` shows wrong charge / 0%        | Wrong `battery=` name; see "If the shipped battery module …" above. |
| Bar overlaps fullscreen apps             | Already handled — `default_border` has gap reservation   |
| Multiple bars stack on one monitor       | Old polybar instances — `pkill polybar; ~/.../launch.sh` |

---

## Further reading

- [Polybar wiki](https://github.com/polybar/polybar/wiki) — full module list and options
- `man polybar`
- [`~/.config/polybar/config.ini`](../config/polybar/config.ini)
- [`~/.config/polybar/launch.sh`](../config/polybar/launch.sh)
