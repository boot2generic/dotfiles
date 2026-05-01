# picom — Compositor

picom draws shadows, fades, transparency, and rounded corners on top of X11
windows. i3 itself doesn't composite — without picom, transparent terminals
look black.

**Config:** `~/.config/picom/picom.conf`
**Reload after edits:** restart picom (`pkill picom; picom -b`) — picom
doesn't watch the file. (i3's restart `Mod+Shift+r` also relaunches it.)

---

## Backends

picom supports two rendering backends:

| Backend  | When to use                                              |
|----------|----------------------------------------------------------|
| `xrender`| Software rendering. Use on **VMs / Hyper-V** — DRI2/GLX  |
|          |   isn't reliably available. Slower but works everywhere. |
| `glx`    | OpenGL rendering. Use on **physical hardware with a real GPU**. |
|          |   Faster, supports more effects.                         |

The install scripts auto-pick the right backend based on detected
virtualization. To override manually, edit the line in `picom.conf`:

```
backend = "xrender";   # or "glx"
use-damage = false;    # use-damage = true on physical GPU
```

Then `pkill picom; picom --config ~/.config/picom/picom.conf -b`.

---

## What it does on this setup

- Fades windows in and out (`fading = true`)
- Light shadows on floating windows
- Transparency for inactive windows / Alacritty
- Rounded corners
- VSync to avoid screen tearing

### Conky / Polybar exclusions

Three rules ensure conky's desktop panel and polybar don't fight
picom's animations (which used to manifest as visible flicker every
few seconds on the Hyper-V xrender backend):

```ini
# Skip the fade animation entirely
fade-exclude = [
    "class_g = 'Conky'",
    "class_g = 'Polybar'",
    "name = 'Notification'",
    "class_g ?= 'Notify-osd'"
];

# Pin them at 100% — without this, inactive-opacity = 0.92 fades them
# 92% ↔ 100% on every focus change, triggering a full-screen blit on
# xrender (use-damage=false) every time
opacity-rule = [
    …
    "100:class_g = 'Conky'",
    "100:class_g = 'Polybar'"
];

wintypes: {
    …
    # Conky uses _NET_WM_WINDOW_TYPE_DESKTOP — turn off picom effects
    # for that class entirely (conky already draws its own ARGB).
    desktop = { fade = false; shadow = false; opacity = 1; focus = false; };
};
```

---

## Common tweaks

```ini
# Stronger transparency on inactive windows
inactive-opacity        = 0.85
inactive-opacity-override = false

# Round more / less
corner-radius           = 6      # pixels

# Disable shadows entirely (cleaner look on a small screen)
shadow                  = false

# Per-class rules — never blur Firefox, full-opacity for video players
opacity-rule = [
    "100:class_g = 'firefox'",
    "100:class_g = 'mpv'",
];
```

---

## Troubleshooting

| Symptom                              | Likely fix                                          |
|--------------------------------------|-----------------------------------------------------|
| Black or transparent windows on Hyper-V | Set `backend = "xrender"`                        |
| Tearing on video                     | Set `vsync = true` in config; switch to `glx`       |
| Slow on integrated graphics          | Try `backend = "xrender"`, set `fading = false`     |
| Picom not starting                   | `picom --config ~/.config/picom/picom.conf` (no -b) |
|                                      | to see the error                                    |
| Alacritty looks black instead of dim | picom not running — check `pgrep picom`             |

---

## Further reading

- `man picom`
- [picom GitHub](https://github.com/yshui/picom)
- [`~/.config/picom/picom.conf`](../config/picom/picom.conf)
