# fzf — Fuzzy Finder

`fzf` is a generic fuzzy filter. Pipe anything in, get an interactive picker.
It's the backbone for half the keybindings in this dotfiles set — telescope
in nvim, the tmux session menu, `Ctrl-r` history search, and more.

**Configured via:** `~/.zshrc` (`FZF_DEFAULT_OPTS`, `FZF_DEFAULT_COMMAND`)
**Theme colours** are pre-set to match the cyberpunk palette.

---

## Direct invocation

```bash
fzf                       # filter your command's stdin
fzf < file.txt            # pick a line from a file
ls | fzf                  # pick a filename
ps aux | fzf              # pick a process
```

Inside the picker:

| Keys              | Action                              |
|-------------------|-------------------------------------|
| Type to filter    | Subsequence match (case-insensitive)|
| `Ctrl-j` / `↓`    | Down one item                       |
| `Ctrl-k` / `↑`    | Up one item                         |
| `Tab`             | Multi-select (mark)                 |
| `Shift-Tab`       | Multi-deselect                      |
| `Enter`           | Confirm                             |
| `Esc` / `Ctrl-c`  | Cancel                              |
| `Ctrl-/`          | Toggle preview pane                 |

---

## Shell key bindings (in zsh, via OMZ's `fzf` plugin)

These work at any shell prompt:

| Keys              | Action                                        |
|-------------------|-----------------------------------------------|
| `Ctrl-r`          | Fuzzy search shell history                    |
| `Ctrl-t`          | Fuzzy-pick a file → insert its path           |
| `Alt-c`           | Fuzzy-pick a directory → cd into it           |
| `**<Tab>`         | Fuzzy-complete the previous word              |

`Ctrl-t` and `**<Tab>` use `FZF_DEFAULT_COMMAND` to source the file list:
ripgrep first, fd second, find as fallback. Hidden files included; `.git/`
excluded.

---

## Custom shell helpers (defined in `.zshrc`)

| Function       | What it does                                              |
|----------------|-----------------------------------------------------------|
| `ff [dir]`     | Fuzzy-pick a file under `[dir]` → open in nvim            |
| `fcd [dir]`    | Fuzzy-pick a directory → cd into it                       |
| `fcp [dir]`    | Fuzzy-pick any path → copy to clipboard (xclip)           |

Example:
```
$ ff src                    # interactive file picker rooted at ./src
$ fcd ~/projects            # interactive directory picker
$ fcp ~/Documents           # copy a path to clipboard
```

---

## tmux integration

Inside tmux:

| Keys              | Action                                          |
|-------------------|-------------------------------------------------|
| prefix `C-f`      | tmux-fzf menu (sessions/windows/panes/keys/clipboard) |
| prefix `C-p`      | Fuzzy-pick a path → paste into the previous pane |
| prefix `C-g`      | Live grep across `$HOME` code → open at line    |

See [tmux.md](tmux.md) for details.

---

## Theme

Colours and behaviour configured in `~/.zshrc`:

```sh
export FZF_DEFAULT_OPTS="
  --color=bg+:#1a1a2e,bg:#0d0d1a,spinner:#00e5ff,hl:#00e5ff
  --color=fg:#e2e2ff,header:#00e5ff,info:#ff00cc,pointer:#00e5ff
  --color=marker:#00ff41,fg+:#e2e2ff,prompt:#00e5ff,hl+:#00ff41
  --color=border:#00e5ff
  --border=rounded
  --prompt='  '
  --pointer=' '
  --marker='● '
  --height=60%
  --layout=reverse
  --info=inline
"
```

Edit any of those and `reload` to apply.

---

## Useful one-off recipes

```bash
# Switch git branches interactively
git checkout $(git branch | fzf)

# Kill a process
kill $(ps aux | fzf | awk '{print $2}')

# Pick & copy a directory path to clipboard
find ~ -type d | fzf | xclip -selection clipboard

# Open recent files in nvim
nvim $(rg --files --no-messages | fzf -m)    # -m = multi-select

# Shell-history scrollback (built-in: Ctrl-r)
```

`-m` enables multi-select (`Tab` to mark). `--preview "head -100 {}"` pops a
preview pane on the right.

---

## Further reading

- `man fzf`
- [fzf README](https://github.com/junegunn/fzf) — extensive examples
- [`~/.zshrc`](../config/zsh/.zshrc) — see the fzf, helpers, and Functions sections
