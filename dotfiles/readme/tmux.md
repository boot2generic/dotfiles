# tmux — Terminal Multiplexer

tmux gives you persistent shells you can detach from, attach to from another
terminal, split into panes, and group into sessions. If you SSH from a flaky
network, a tmux session survives the disconnect — reconnect and `tmux attach`.

**Config:** `~/.config/tmux/tmux.conf` (deployed from `config/tmux/tmux.conf`)
**Reload after edits:** inside tmux: prefix + `R`

> **Prefix is `Ctrl-b`** (tmux's default). Every binding below that says
> "prefix" means: press `Ctrl-b`, release, then press the next key.

---

## First-time use

```bash
tmux                      # start a new unnamed session
tmux new -s work          # named session
tmux ls                   # list sessions
tmux attach -t work       # re-attach (or 'tmux a' for short)
tmux kill-session -t work # nuke a session
```

Aliases in `.zshrc`:
- `t` → tmux
- `ta <name>` → attach
- `tl` → list
- `tn <name>` → new

---

## Splits and panes

| Keys                | Action                                          |
|---------------------|-------------------------------------------------|
| prefix `\|`         | Split pane horizontally (side-by-side)          |
| prefix `-`          | Split pane vertically (stacked)                 |
| `Ctrl-h/j/k/l`      | Move between panes (no prefix; vim-aware)       |
| prefix `h/j/k/l`    | Same, with prefix                               |
| prefix `H/J/K/L`    | Resize current pane (5 cells)                   |
| prefix `q`          | Show pane numbers (then press a number to jump) |
| prefix `x`          | Kill pane                                       |

The `Ctrl-hjkl` bindings detect if vim/nvim is the active program and
forward the keystroke to it instead — so you can move between tmux panes
*and* nvim splits with the same chord. (Magic via the
[`vim-tmux-navigator`](https://github.com/christoomey/vim-tmux-navigator)
detection trick built into the config.)

---

## Windows (tabs)

A "window" in tmux is a tab — a screen full of panes.

| Keys                | Action                                  |
|---------------------|-----------------------------------------|
| prefix `c`          | New window (in current path)            |
| `Shift+Left`        | Previous window                         |
| `Shift+Right`       | Next window                             |
| prefix `Tab`        | Last window (toggle)                    |
| prefix `b`          | Choose-window menu                      |
| prefix `r`          | Rename current window AND pane          |
| prefix `W`          | Rename window only                      |
| prefix `X`          | Kill entire window                      |
| prefix `1..9`       | Jump to window N                        |

---

## Sessions

| Keys             | Action                                            |
|------------------|---------------------------------------------------|
| prefix `S`       | Choose session menu (interactive)                 |
| prefix `N`       | New session (prompts for name)                    |
| prefix `$`       | Rename current session                            |
| prefix `d`       | Detach (session keeps running, your terminal exits)|

---

## Copy mode (vi-style)

| Keys              | Action                                       |
|-------------------|----------------------------------------------|
| prefix `Enter`    | Enter copy mode                              |
| `h/j/k/l`         | Move cursor                                  |
| `/` / `?`         | Search forward / backward                    |
| `v`               | Begin selection (char-wise)                  |
| `V`               | Begin selection (line-wise)                  |
| `Ctrl-v`          | Begin selection (block)                      |
| `y`               | Copy selection to system clipboard (xclip)   |
| `Y`               | Copy from cursor to end of line              |
| `Esc`             | Cancel selection                             |
| `q`               | Leave copy mode                              |

Mouse mode is on, so you can also click-and-drag to select; release to copy
to the system clipboard. (Configured via `tmux-yank`.)

---

## fzf integrations

These bindings pop a fzf panel in a new window — pick something, the new
window self-closes.

| Keys              | Picks                                       | Action                                   |
|-------------------|---------------------------------------------|------------------------------------------|
| prefix `C-f`      | Files under `~`                             | Open in `$EDITOR` (nvim)                 |
| prefix `C-p`      | Any path under `~`                          | Paste path into the previous pane        |
| prefix `C-g`      | Live grep across common code files in `~`   | Open the matched file at the matched line |
| prefix `F`        | tmux-fzf plugin                             | Sessions / windows / panes / commands / keybinds / clipboard / processes |

> Earlier versions of this config used `prefix C-f` for the tmux-fzf
> plugin, which collided with the custom file picker (the plugin won
> because it loads last). The plugin was moved to `prefix F`.

---

## Persistence (resurrect + continuum)

The config auto-saves every 10 minutes via `tmux-continuum`:

| Keys               | Action                                     |
|--------------------|--------------------------------------------|
| prefix `Ctrl-s`    | Save session NOW                           |
| prefix `Ctrl-r`    | Restore last saved session                 |

After a reboot, just run `tmux` and your old layout/processes come back
automatically (continuum-restore is on). Pane contents and nvim sessions
are also restored.

---

## Misc

| Keys              | Action                                   |
|-------------------|------------------------------------------|
| prefix `R`        | Reload `tmux.conf`                       |
| prefix `t`        | Big neon clock (Esc to dismiss)          |
| prefix `?`        | List every keybinding                    |
| prefix `:`        | Tmux command prompt                      |

---

## Customising

Open `~/.config/tmux/tmux.conf`, change a binding, hit prefix + `R`.

```tmux
# Example: re-add the old C-a prefix on top of C-b
set -g prefix2 C-a
bind C-a send-prefix
```

Plugins are managed by [tpm](https://github.com/tmux-plugins/tpm). After
adding a `set -g @plugin '…'` line:

| Keys              | Action                                |
|-------------------|---------------------------------------|
| prefix `I`        | Install new plugins                   |
| prefix `U`        | Update plugins                        |
| prefix `Alt-u`    | Uninstall removed plugins             |

---

## Further reading

- `man tmux`
- [tmux wiki](https://github.com/tmux/tmux/wiki)
- [`/home/generic/.config/tmux/tmux.conf`](../config/tmux/tmux.conf) — the canonical source
