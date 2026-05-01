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
[ session-name ]  workspaces  | window-title …                  cpu  mem  net  vol  date  time
```

| Module          | What it shows                                       |
|-----------------|-----------------------------------------------------|
| `i3`            | Workspace tabs (click to switch)                    |
| `xwindow`       | Title of the focused window                         |
| `cpu`           | CPU usage                                           |
| `memory`        | RAM usage                                           |
| `network`       | Connection status (wired interface)                 |
| `mullvad`       | Mullvad VPN state (click to toggle / right-click for menu) |
| `wireguard`     | Active WireGuard tunnel + endpoint (click for menu) |
| `pulseaudio`    | Volume + mute state (scroll on it to adjust)        |
| `date`          | Date and 24-h clock                                 |
| `tray`          | System tray icons (NetworkManager, etc.)            |

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

Example — add a battery indicator:

```ini
[module/battery]
type    = internal/battery
battery = BAT0
adapter = ADP1
```

Then add `battery` to the `modules-right` list.

---

## Customising the look

- Colours come from the `[colors]` section at the top of the file. Change one
  there, every module that references `${colors.<name>}` updates.
- Font is JetBrainsMono Nerd Font 10pt (covers icon glyphs natively).
- Bar height: change `height = 32` in `[bar/main]`.
- Bar position: `top = true`. Set to `false` for a bottom bar.

---

## Troubleshooting

| Symptom                                  | Cause / fix                                              |
|------------------------------------------|----------------------------------------------------------|
| Bar shows empty boxes instead of icons   | Nerd Font missing — re-run install `terminal` phase      |
| Workspaces module empty                  | i3 socket not visible — make sure i3 is running          |
| Volume module says "no sink"             | PulseAudio not running; `pulseaudio --start`             |
| Network always says "disconnected"       | `interface-type = wired` — change to `wireless` for Wi-Fi|
| Bar overlaps fullscreen apps             | Already handled — `default_border` has gap reservation   |
| Multiple bars stack on one monitor       | Old polybar instances — `pkill polybar; ~/.../launch.sh` |

---

## Further reading

- [Polybar wiki](https://github.com/polybar/polybar/wiki) — full module list and options
- `man polybar`
- [`~/.config/polybar/config.ini`](../config/polybar/config.ini)
- [`~/.config/polybar/launch.sh`](../config/polybar/launch.sh)
