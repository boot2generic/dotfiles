# rofi — Launcher / Switcher

rofi is the popup that appears when you press `Mod+d`. It can launch apps,
switch windows, replace `dmenu`, run shell commands, and be themed (this
repo ships a Cyberpunk Neon theme inline).

**Config:** `~/.config/rofi/config.rasi`
**Reload after edits:** automatic — next invocation picks up the new config

---

## Default invocations from i3

| Keys             | Mode    | What it does                                  |
|------------------|---------|-----------------------------------------------|
| `Mod+d`          | `drun`  | Apps with icons (parsed from `.desktop` files)|
| `Mod+Tab`        | `window`| Switch to an open window                      |

---

## Inside rofi

| Keys                  | Action                                  |
|-----------------------|-----------------------------------------|
| Type to filter        | Fuzzy match (configured)                |
| `Up` / `Down`         | Move cursor                             |
| `Enter`               | Launch / switch to selected             |
| `Shift-Enter`         | Launch in alternate way                 |
| `Tab` / `Shift-Tab`   | Cycle modes (drun ↔ run ↔ window)       |
| `Esc`                 | Close                                   |
| `Ctrl-h` / `Ctrl-w`   | Delete char / word                      |

---

## Other modes

You can call rofi directly with any mode:

```bash
rofi -show run        # raw shell commands
rofi -show drun       # apps (default)
rofi -show window     # window switcher (= Mod+Tab)
rofi -show ssh        # SSH known_hosts launcher
rofi -show combi      # all modes combined
```

To make a quick `dmenu` replacement (pick an item from stdin):

```bash
echo -e "yes\nno\nmaybe" | rofi -dmenu -p "Decide"
```

---

## Themes

The dotfiles use an inline theme (no external `.rasi` import — sidesteps
path resolution issues). To swap theme, replace the `* { … }` block with a
new palette. The repo also ships starter themes under
`~/.config/rofi/themes/`.

---

## Customising

Open `~/.config/rofi/config.rasi`. Common tweaks:

```rasi
configuration {
    lines: 10;            // number of visible items
    matching: "fuzzy";    // alternatives: "normal", "regex", "glob"
    sort: true;           // best matches first
    case-sensitive: false;
}

* {
    font: "JetBrains Mono 11";
    bg:   #0d0d1a;       // change for a different theme
    cyan: #00e5ff;       // primary accent
}
```

Save → next `Mod+d` shows the change.

---

## Replacing rofi-as-dmenu in scripts

Many existing scripts on the internet use `dmenu`. rofi is a drop-in:

```bash
# Old:
choice=$(echo -e "a\nb\nc" | dmenu -p "Pick:")
# New:
choice=$(echo -e "a\nb\nc" | rofi -dmenu -p "Pick")
```

---

## Further reading

- `man rofi`
- `man 5 rofi-script`        — for custom modes
- `man 5 rofi-theme`         — for theme syntax
- [rofi repo](https://github.com/davatorium/rofi)
- [`~/.config/rofi/config.rasi`](../config/rofi/config.rasi)
