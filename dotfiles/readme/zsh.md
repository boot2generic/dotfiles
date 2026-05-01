# zsh — Shell, oh-my-zsh, Starship

The shell stack:

- **zsh** — interactive shell (replaces bash)
- **oh-my-zsh** — framework for zsh, manages plugins
- **starship** — cross-shell prompt (handles all the visual prompt stuff)
- **zsh-autosuggestions** — fish-style inline grey suggestion
- **zsh-syntax-highlighting** — colour the command line as you type

**Configs:**
- `~/.zshrc` (deployed from `config/zsh/.zshrc`)
- `~/.config/starship/starship.toml`
- `~/.oh-my-zsh/` (cloned by the install script)

**Reload after edits:** `reload` (alias for `source ~/.zshrc`)

---

## Default shell

The install script runs `usermod -s /usr/bin/zsh $USER`. New terminal sessions
start in zsh. To set it manually:

```bash
sudo chsh -s "$(command -v zsh)" $USER
# log out and back in
```

To get back to bash temporarily: just type `bash`. To revert permanently:
`chsh -s /bin/bash`.

---

## What's the prompt showing me?

Starship (`~/.config/starship/starship.toml`) renders a multi-line prompt with:

- Username and host (when in SSH or container)
- Current directory (truncated to keep prompt narrow)
- Git branch and dirty/clean status
- Active language version (Python venv, Node version, Rust, etc.)
- Last command's exit code (red ✗ on failure)
- Job count (when ≥1 background job)
- Cmd duration (when > 1 s)
- A `❯` prompt char in cyan (turns red after a failed command)

To customise, edit `~/.config/starship/starship.toml`. Run `starship explain`
to see what each module would render right now. Full reference:
[starship.rs/config](https://starship.rs/config/).

---

## Tab completion

| Keys              | Action                                    |
|-------------------|-------------------------------------------|
| `Tab`             | Complete / show menu                      |
| Second `Tab`      | Cycle through completion menu             |
| `Shift+Tab`       | Cycle backward                            |
| `Esc`             | Cancel menu                               |

Case-insensitive (`m:{a-zA-Z}={A-Za-z}`) and shows colourised file types from
`LS_COLORS`.

---

## History

50 000 entries; deduplicated; shared across sessions in real time
(`SHARE_HISTORY` is on). Commands starting with a space don't get saved.

| Keys              | Action                                  |
|-------------------|-----------------------------------------|
| `Up` / `Down`     | Walk through history                    |
| `Ctrl-r`          | fzf history search (interactive)        |
| `!!`              | Repeat last command                     |
| `!$`              | Last argument of previous command       |
| `!*`              | All arguments of previous command       |

---

## fzf integration

`Ctrl-r/t/Alt-c` get rebound by `fzf.zsh` (sourced if present):

| Keys              | Action                                          |
|-------------------|-------------------------------------------------|
| `Ctrl-r`          | Fuzzy search shell history                      |
| `Ctrl-t`          | Fuzzy-find a file → insert its path             |
| `Alt-c`           | Fuzzy-find a directory → cd into it             |

`FZF_DEFAULT_COMMAND` uses ripgrep when available, else fd. Hidden files are
included; `.git/` is excluded.

---

## oh-my-zsh plugins enabled

| Plugin                      | What it does                                                  |
|-----------------------------|---------------------------------------------------------------|
| `git`                       | Adds many `g*` aliases (e.g. `gs` = `git status`)             |
| `sudo`                      | Press **Esc twice** to prepend `sudo ` to the line            |
| `colored-man-pages`         | Coloured `man` output                                         |
| `command-not-found`         | "Did you mean…" suggestions when a command isn't installed    |
| `docker`                    | Tab-completion for docker subcommands                         |
| `fzf`                       | The Ctrl-r/t/Alt-c bindings above                             |
| `zsh-autosuggestions`       | Grey inline suggestion from history; `→` accepts              |
| `zsh-syntax-highlighting`   | Real-time colouring (commands green when valid, red if not)   |

Add or remove plugins by editing the `plugins=(…)` line in `~/.zshrc` and
running `reload`.

---

## Aliases (configured in this dotfiles set)

### Editor
- `vim`, `vi`, `v` → `nvim`

### Listing
- `ls` → `ls --color=auto`
- `ll` → `ls -alFh`         (long, all, classified, human sizes)
- `la` → `ls -A`            (all except `.` and `..`)
- `l`  → `ls -lh`
- `lt` → `ls -alFht`        (sorted by mtime)

### Navigation
- `..`, `...`, `....` → `cd ..`, `../..`, `../../..`
- `~` → `cd ~`

### Grep
- `grep`, `fgrep`, `egrep` all colour-output by default

### Git (built-in OMZ aliases)
- `g`, `gs`, `ga`, `gc`, `gp`, `gl`, `gd`
  - + many more from the `git` plugin (`git`, `gco`, `gcb`, `gst`, etc.)

### tmux
- `t`, `ta <name>`, `tl`, `tn <name>`

### System
- `free` → `free -h`
- `top` → `htop`
- `ports` → `ss -tulpn`
- `df` → `grc df -h` (or `df -h` if grc not installed)
- `du` → `grc du -h`

### `bat` (cat with syntax highlighting)
- `cat` → `bat --paging=never`  (syntax-coloured no-pager cat)
- `catp` → `bat`                (paged version)

### `grc` (generic colouriser; if installed)
- `netstat`, `ping`, `traceroute`, `ps`, `df`, `du`, `ifconfig`, `ip`, `dig`, `lsblk`, `lspci` all coloured

---

## Custom functions

| Function           | What it does                                                  |
|--------------------|---------------------------------------------------------------|
| `mkcd <dir>`       | `mkdir -p <dir>` and `cd` into it                             |
| `ff [dir]`         | fzf-pick a file under `[dir]`, open in nvim                   |
| `fcd [dir]`        | fzf-pick a directory under `[dir]`, cd to it                  |
| `fcp [dir]`        | fzf-pick any path, copy it to clipboard                       |
| `set-title <text>` | Set the alacritty/i3 title bar to `<text>` (sticky — survives `cd` and command runs).  Without args, restore oh-my-zsh's auto-titling. |
| `reload`           | re-source `~/.zshrc`                                          |
| `zshconfig`        | open `~/.zshrc` in nvim                                       |

### Hotkeys (zsh ZLE)

| Keys      | Action                                                              |
|-----------|---------------------------------------------------------------------|
| `Ctrl-X t`| Prefill `set-title ` on the command line (cursor at end). Type the title and press Enter. |
| `Ctrl-r`  | fzf history search (oh-my-zsh fzf plugin)                           |
| `Ctrl-t`  | fzf file picker (insert path into command line)                     |
| `Alt-c`   | fzf cd-to-directory                                                 |
| Double-`Esc` | Prepend `sudo` to the current command (oh-my-zsh `sudo` plugin)  |

`Ctrl-X t` was chosen because it's unbound by default in both stock zsh
and oh-my-zsh — it doesn't collide with any existing binding (verified
with `bindkey "^Xt"` returning empty before our edit).  `set-title`
itself is **not** named `title` because oh-my-zsh defines its own
internal `title` function and calls it from `precmd`/`preexec` hooks
on every prompt; using a different name keeps OMZ's auto-titling
working when you want it.

---

## Customising

Edit `~/.zshrc`. The file is small and structured (history, completion, fzf,
aliases, functions, prompt — in that order). After editing:

```bash
reload
# or
source ~/.zshrc
```

To add a new alias permanently, append it to the Aliases section. To add a
function, define it next to `mkcd`/`ff`/`fcd`. To change a plugin set, edit
`plugins=(…)` and `reload`.

If you want a different prompt, edit `~/.config/starship/starship.toml`. To
switch off starship entirely, comment out `eval "$(starship init zsh)"`.

---

## Further reading

- `man zshall` (~thousands of pages — search inside)
- [Oh My Zsh wiki](https://github.com/ohmyzsh/ohmyzsh/wiki)
- [Starship config docs](https://starship.rs/config/)
- [`~/.zshrc`](../config/zsh/.zshrc) — the complete config in this repo
