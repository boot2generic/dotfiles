# Lockscreen — i3lock + Neon Overlay

A custom lockscreen image is generated on demand from your wallpaper, with a
giant neon clock and the date overlaid. Pressing `Mod+Shift+x` (or
`Mod+Delete`) renders the overlay and locks the screen.

**Script:** `~/.config/lockscreen/lock.sh`
**Lock binary:** `i3lock` (apt: `i3lock`)
**Image processor:** ImageMagick (`convert`)

---

## Locking

| Keys             | Action                          |
|------------------|---------------------------------|
| `Mod+Shift+x`    | Lock the screen                 |
| `Mod+Delete`     | Lock the screen                 |

To unlock: just type your password and press `Enter`. (No need to wake the
mouse — i3lock will accept input immediately.)

---

## How the image is generated

`lock.sh`:
1. Looks up your wallpaper at `~/.config/wallpaper/wallpaper.png`.
2. Resolves the screen geometry dynamically — `xdpyinfo` first,
   `xrandr | awk '/^Screen 0/'` (the `current ...` field) second,
   `1920x1080` fallback last. A degenerate `0x0` is rejected.  The
   accent rectangle width is clamped to `min(700, screen_width)` so
   it never overflows on small screens.
3. Creates an unguessable temp path with `mktemp --suffix=.png` and
   chmods it 0600 (the predictable `/tmp/.lockscreen_<uid>.png` path
   it used to use was a multi-user race + read-confidentiality bug).
4. Uses `convert` (ImageMagick) to:
   - Tint it dark blue/cyan
   - Draw a thin cyan rule at y≈450
   - Render the time (HH:MM) in 130-pt JetBrainsMono Bold, centred
     slightly above middle, with a softer "shadow" copy behind it
   - Render the date in 28-pt Regular below the time
5. Exec's `i3lock -i "$LOCK_IMG" --nofork`. **If `convert` fails for
   any reason** (missing ImageMagick, font issue, etc.), the script
   falls back to a plain `i3lock --color 080810` so you don't end up
   with no lock at all.
6. An `EXIT INT TERM` trap removes the temp file even if the script is
   killed mid-run.

If no wallpaper is found, the script falls back to a generated gradient.

---

## Customising

Edit `~/.config/lockscreen/lock.sh`. Common tweaks:

```bash
# Bigger / smaller clock
-pointsize 130              # → 180 for huge

# Different format
TIME=$(date '+%I:%M %p')    # 12-hour with am/pm

# Different overlay colour
-fill "#ff00cc"             # magenta instead of cyan

# Different position (Center, North, NorthEast, etc.)
-gravity Center -annotate +0-200    # +X+Y offset from gravity anchor
```

---

## Auto-lock on idle

The dotfiles don't ship an auto-lock daemon by default. To add one:

```bash
# Install:
sudo apt install xss-lock xidlehook

# Add to ~/.xsession (or i3 config) before exec i3:
xss-lock --transfer-sleep-lock -- ~/.config/lockscreen/lock.sh &
xidlehook --not-when-fullscreen --not-when-audio \
    --timer 600 '~/.config/lockscreen/lock.sh' '' &
```

Locks after 10 minutes idle, but skips when audio is playing or a fullscreen
app is active (e.g. video playback).

---

## Troubleshooting

| Symptom                        | Likely fix                                            |
|--------------------------------|-------------------------------------------------------|
| `i3lock: command not found`    | `sudo apt install i3lock`                             |
| `convert: command not found`   | `sudo apt install imagemagick`                        |
| Clock font wrong               | Reinstall `fonts-jetbrains-mono`                      |
| No background image, just black| Wallpaper file missing — regenerate it (see [wallpaper](wallpaper.md)) |
| Lock takes 1–2 sec to appear   | Normal — ImageMagick is rendering the overlay         |

For a faster (but less pretty) lock, replace the body of lock.sh with:
```bash
i3lock --color=000000 --nofork
```

---

## Further reading

- `man i3lock`
- `man convert`
- [`~/.config/lockscreen/lock.sh`](../config/lockscreen/lock.sh)
