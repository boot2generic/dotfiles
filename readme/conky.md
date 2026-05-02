# conky — Desktop Hardware Monitor

A single floating, transparent panel anchored top-right that shows
CPU/RAM/disk/network plus listening ports + active connections in real
time. Useful when polybar's small modules aren't enough.

**Config:** `~/.config/conky/conky.conf` (single panel — earlier versions
shipped a second `conky-listen.conf` for listening ports; that's been
merged into the main panel).

**Helper scripts (`~/.config/conky/`):**
- `listenports.py` — runs `sudo -n ss -nlp` (falls back to plain `ss`
  if sudo is denied) to list TCP/UDP listening ports + the process
  holding each one
- `netstat.py` — runs `sudo -n ss -nip` (same fallback) to show
  established connections + per-connection bandwidth (diffed across
  conky polls)
- `newprocs.py` — diffs `/proc` against the previous poll and shows
  recently-started PIDs (no sudo needed; `/proc/<pid>/comm` is
  world-readable)

**Launcher:** `~/.config/conky/launch.sh` does two things:
1. `pkill -u $UID -x conky` (with bounded wait + SIGKILL fallback)
2. `conky -c conky.conf -d`

That's it.  No `xdotool windowlower`, no `xprop -spy` daemon, no
`wmctrl` calls.  The reason this works is **`own_window_type =
'override'`**: conky asks the X server to set its window's
override-redirect flag, which tells the WM "leave this window
alone".  i3 then never manages it — it doesn't tile it, raise it
on focus events, or restack it when other apps map.  Conky just
sits on the desktop layer where it was put, drawing on top of the
wallpaper.

### Lessons from the previous detour

An earlier attempt switched `own_window_type` to `'desktop'` to
chase a flicker symptom; that broke stacking because i3 doesn't
actively *lower* desktop-type windows — it only ignores them in
its tiling layout.  Every newly-mapped app then ended up above
conky in X stacking order.  Increasingly elaborate workarounds
followed (one-shot `xdotool windowlower`, then an `xprop -spy`
daemon to re-lower on every window event) until it became clear
that the **flicker root cause was in picom, not conky**, and
reverting to `'override'` removed the entire stacking problem at
once.

### What about the flicker, then?

Fixed in `picom.conf`, not here:
- `fade-exclude = [ "class_g = 'Conky'", "class_g = 'Polybar'", … ]`
  — picom's fade animation no longer triggers on every conky
  redraw
- `opacity-rule = [ …, "100:class_g = 'Conky'", "100:class_g = 'Polybar'" ]`
  — pin opacity at 100% so picom never blends conky between
  92% (inactive-opacity) and 100% on focus changes (which on
  Hyper-V's xrender backend = full-screen blit each time)
- `update_interval = 5` (was 2) in `conky.conf` — fewer
  paints/second, lower paint pressure overall

`wmctrl` and `x11-utils` (xprop, xwininfo, xdpyinfo) are kept in
`BASE_PACKAGES` — they're useful diagnostic tools and small enough
not to bother removing.

### Why conky doesn't flicker any more

Earlier symptoms — visible flicker every few seconds — were caused
by **picom**, not conky:
- `fading = true` re-runs the fade animation on every focus event;
  conky's redraw triggered focus events, which fanned out a fade
  across all visible windows.
- `inactive-opacity = 0.92` had picom blend conky's opacity on every
  focus change.
- No `wintypes.desktop` rule meant picom applied default fade +
  shadow to conky's desktop window.
- Hyper-V's xrender backend with `use-damage = false` means every
  one of those triggers became a full-screen blit.

`picom.conf` now has three new rules that fix this:
```
fade-exclude = [ "class_g = 'Conky'", "class_g = 'Polybar'", … ];
opacity-rule = [ …, "100:class_g = 'Conky'", "100:class_g = 'Polybar'" ];
wintypes: { …; desktop = { fade = false; shadow = false; opacity = 1; focus = false; }; };
```
plus `update_interval` is now 5 (was 3) so even when the panel does
repaint, it does so less often.

### Mod+Shift+c picks up changes

Conky's autostart line in i3 is `exec_always` + `launch.sh`, and
picom's autostart is `exec_always` with a `pkill -x picom` first, so
**`Mod+Shift+c` cycles both** with the latest configs.  No logout
required after a `local_setup.sh deploy`.

**Killing the panel:** `pkill conky` (or `~/.config/conky/launch.sh` to
restart it without the i3 reload roundtrip).

---

## Default layout

Sections rendered in order, top to bottom:

1. **SYSTEM** — hostname / kernel / uptime
2. **CPU** — model, usage bar, freq, temperature (if available)
3. **MEMORY** — RAM and swap usage bars
4. **DISK** — `/` usage + I/O rates
5. **NETWORK** — IP + up/down speeds + sparkline graphs (per interface)
6. **LISTENING PORTS** — `proto :port  process` for every bound socket
7. **CONNECTIONS** — per-connection direction + remote + process + live bandwidth
8. **NEW PROCESSES** — PIDs that appeared since the previous poll
9. **TOP PROCESSES** — top 5 by CPU/MEM

All transparent over the wallpaper, no window decoration.

---

## Autostart

The panel autostarts from the i3 config on session login via
`exec_always --no-startup-id ~/.config/conky/launch.sh`.  Because it's
`exec_always` (not just `exec`), pressing `Mod+Shift+c` to reload i3
also runs `launch.sh` again, which `pkill conky`s the previous panel
and starts a fresh one.  This is what makes config changes pick up
without logging out.

To turn **off** autostart, comment out the line and reload i3
(`Mod+Shift+c`).

To run conky manually for debugging (foreground, with errors visible):

```bash
pkill conky
conky -c ~/.config/conky/conky.conf            # no -d so errors land in stderr
```

### Width and column truncation

The panel is **460 px wide** by default — chosen so the CONNECTIONS
table (proto, direction, port, remote, ↑/↓ rates, process) fits
without clipping the trailing process name.  Earlier revs shipped 310
px which truncated `systemd-resolved` to `systemd-reso` even when
there was screen real estate available.

Process names from `ss -p` are limited to 24 chars in `listenports.py`
and `netstat.py` (Linux's `TASK_COMM_LEN-1` is 15, so 24 covers every
real-world name with headroom).  In the connections table, the process
column is the **last** field on the line — that way a longer-than-
expected name only risks clipping its own trailing characters at the
panel edge, never displacing the bandwidth columns.

To make the panel wider/narrower, edit `minimum_width` and
`maximum_width` in `~/.config/conky/conky.conf` and reload i3.

---

## Customising the panel

`conky.conf` is a Lua table. Top of the file:

```lua
conky.config = {
    alignment       = 'top_right',     -- top_left, bottom_right, etc.
    gap_x           = 20,              -- pixels from screen edge
    gap_y           = 50,
    minimum_width   = 250,
    minimum_height  = 700,
    own_window      = true,
    own_window_type = 'desktop',
    -- …
};

conky.text = [[
${color #00e5ff}NEON SYS${color}
$hr
…
]];
```

The `conky.text` block is a templating language with variables like
`$cpu`, `$mem`, `${memperc}`, `${top name 1}`, etc. Reference:
`man conky` (search "Variables").

---

## Useful variables

| Variable                  | What it shows                      |
|---------------------------|------------------------------------|
| `${time %H:%M}`           | Current time                       |
| `${cpu cpu0}` / `${cpu}`  | CPU usage % (specific core / all)  |
| `${cpubar 4,100}`         | CPU bar, height 4 px, width 100 px |
| `${mem}` / `${memperc}`   | RAM used / used %                  |
| `${swap}` / `${swapperc}` | Swap used / used %                 |
| `${fs_used /} / ${fs_size /}`| Disk used / total              |
| `${downspeed wlan0}`      | Network DL on wlan0                |
| `${upspeed wlan0}`        | Network UL                         |
| `${addr eth0}`            | IP address                         |
| `${top name 1}`           | Top-CPU process name               |
| `${top mem name 1}`       | Top-RAM process name               |
| `${color #00e5ff}…`       | Colour switch (hex)                |
| `${font JetBrains Mono:size=10}`| Font switch                  |

---

## Reload / restart

conky doesn't auto-reload — kill and restart after edits:

```bash
pkill conky && conky -d
```

---

## Troubleshooting

| Symptom                                | Cause / fix                                       |
|----------------------------------------|---------------------------------------------------|
| Conky panel doesn't appear             | `conky -d` didn't start. Run without `-d` to see  |
|                                        | errors: `conky -c ~/.config/conky/conky.conf`     |
| Panel appears but is black not transparent | `own_window_argb_visual = true` and             |
|                                        | `own_window_transparent = true` need picom running|
| Glyphs look wrong                      | Nerd Font missing — re-install                    |
| Conky steals window focus              | `own_window_type = 'desktop'` (not 'normal')      |

---

## Further reading

- `man conky`
- [conky GitHub](https://github.com/brndnmtthws/conky)
- [Awesome Conky configs](https://github.com/brndnmtthws/conky/wiki) for inspiration
- [`~/.config/conky/conky.conf`](../config/conky/conky.conf)
