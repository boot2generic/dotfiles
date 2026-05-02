# Alacritty — Terminal Emulator

Alacritty is a GPU-accelerated terminal — fast scrolling, true colour, no
config file format other than TOML. It's the terminal i3 spawns when you
press `Mod+Return`.

**Config:** `~/.config/alacritty/alacritty.toml`
**Reload after edits:** automatic — saves trigger a live reload, no restart needed

---

## Built-in keybinds (in this dotfiles set)

| Keys                  | Action                                |
|-----------------------|---------------------------------------|
| `Ctrl-Shift-c`        | Copy selection                        |
| `Ctrl-Shift-v`        | Paste                                 |
| `Ctrl-+` / `Ctrl-=`   | Increase font size                    |
| `Ctrl--`              | Decrease font size                    |
| `Ctrl-0`              | Reset font size                       |
| `F11`                 | Toggle fullscreen                     |

Plus alacritty's defaults:
- `Shift-PgUp` / `Shift-PgDn` — scrollback
- `Ctrl-Shift-Space` — vi mode (h/j/k/l + searching, `/` and `?`)
- `Ctrl-Shift-f` / `Ctrl-Shift-b` — search forward / back

---

## Selecting and copying

- **Triple-click** — select line
- **Double-click** — select word
- **Click + drag** — select range
- Released selection auto-copies to the **PRIMARY** X selection (paste with
  middle-click). Use `Ctrl-Shift-c` to copy to **CLIPBOARD** instead.

---

## What's customised in this config

| Setting          | Value                                                 |
|------------------|-------------------------------------------------------|
| Font             | JetBrainsMono Nerd Font, 11pt                         |
| Window padding   | 12 px (x), 10 px (y)                                  |
| Opacity          | 0.92 (light transparency, picom does the rest)        |
| Scrollback       | 10 000 lines                                          |
| Cursor           | Blinking block, 600 ms interval                       |
| Mouse            | Hides on typing                                       |
| Colour palette   | Cyberpunk Neon (background `#0d0d1a`, accent `#00e5ff`)|

The Nerd Font variant covers all the icon glyphs polybar/starship use.
Install location: `~/.local/share/fonts/NerdFonts/`.

---

## Customising

Edit `~/.config/alacritty/alacritty.toml`. Save → instant live reload.

```toml
# Bigger default font
[font]
size = 13.0

# Real fullscreen-on-launch
[window]
startup_mode = "Fullscreen"

# Solid background
[window]
opacity = 1.0
```

To add a custom keybinding:

```toml
[[keyboard.bindings]]
key  = "T"
mods = "Control|Shift"
action = "SpawnNewInstance"
```

The Action enum is documented at
[`alacritty.toml(5)`](https://github.com/alacritty/alacritty/blob/master/extra/man/alacritty.5.scd)
or `man 5 alacritty`.

---

## Troubleshooting

| Symptom                                  | Likely cause / fix                                         |
|------------------------------------------|------------------------------------------------------------|
| Blocks/missing chars in polybar/prompt   | Nerd Font not installed — re-run `terminal` install phase  |
| `error: invalid TOML` on launch          | Syntax error in `alacritty.toml` — check the line shown    |
| Choppy scrolling on Hyper-V              | Disable transparency (`opacity = 1.0`) — picom xrender +   |
|                                          |   alpha can be expensive in software rendering             |
| Black screen on launch                   | GPU driver mismatch — try `--config /dev/null` to verify   |

---

## Further reading

- `man alacritty`
- `man 5 alacritty`
- [Alacritty repo](https://github.com/alacritty/alacritty)
- [`~/.config/alacritty/alacritty.toml`](../config/alacritty/alacritty.toml)
