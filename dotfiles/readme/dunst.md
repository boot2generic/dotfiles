# dunst — Notifications

Lightweight notification daemon. Whenever an app calls
`org.freedesktop.Notifications` (e.g. via `notify-send`), dunst pops a
toast in the top-right.

**Config:** `~/.config/dunst/dunstrc`
**Reload after edits:** `pkill dunst` — i3 will autostart it again, or
`dunst &` manually.

---

## Sending a notification

```bash
notify-send "Title" "Body of the notification"

# Urgency: low / normal / critical (red border)
notify-send -u critical "Build failed" "See ./build.log"

# Stay on screen 10 seconds
notify-send -t 10000 "Heads-up" "Check polybar"

# With an icon (uses any icon name from your icon theme)
notify-send -i firefox "Reload" "Page updated"
```

Many programs send notifications automatically:
- `dunst` itself shows notifications about updates
- IDEs / build tools
- Email clients
- nm-applet (network connect/disconnect)
- Power-management (`systemctl suspend` etc.)

---

## Interacting with notifications

| Keys                 | Action                                |
|----------------------|---------------------------------------|
| `Ctrl+space`         | Close the topmost notification        |
| `Ctrl+Shift+space`   | Close ALL notifications               |
| `Ctrl+grave` ( `` ` ``) | Show notification history          |
| `Ctrl+Shift+period`  | Run the notification's default action |

(These are dunst's defaults — confirm by `cat ~/.config/dunst/dunstrc | grep -A1 '^\[shortcuts\]'`.)

Click on a notification to perform its default action. Right-click to
dismiss.

---

## Customising the look

`dunstrc` is grouped into:

- `[global]` — geometry, position, font, colours, behaviour
- `[urgency_low]` `[urgency_normal]` `[urgency_critical]` — per-urgency styling
- `[some_app_rule]` — match by `appname=…` and override fields

Common tweaks:

```ini
[global]
font          = JetBrains Mono 10
geometry      = "300x5-20+30"   # WxH-X+Y from the top-right corner
transparency  = 5
frame_color   = "#00e5ff"
separator_color = frame
follow        = mouse           # multi-monitor: appears on focused screen

[urgency_critical]
background = "#0d0d1a"
foreground = "#ff0055"
frame_color = "#ff0055"
timeout    = 0                  # never auto-close
```

After editing, `pkill dunst && dunst &` (or just log out/in).

---

## Troubleshooting

| Symptom                            | Fix                                                       |
|------------------------------------|-----------------------------------------------------------|
| `notify-send` does nothing         | Check `pgrep dunst`. If empty, `dunst &`.                 |
| Notifications appear in wrong place| Edit `geometry` / set `follow = mouse`                    |
| Glyph squares                      | Nerd Font missing                                         |
| Always-on-top problem with full-screen apps | Set `dmenu = none` & `mouse_left_click = close` |

---

## Further reading

- `man 5 dunst`
- [dunst wiki](https://github.com/dunst-project/dunst/wiki)
- [`~/.config/dunst/dunstrc`](../config/dunst/dunstrc)
