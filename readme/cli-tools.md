# CLI Tools

A collection of replacement / augmenting CLI utilities the dotfiles install.
Each one is a drop-in upgrade for a classic Unix command.

---

## bat — colourised cat

Drop-in replacement for `cat` with syntax highlighting, line numbers, and a
git diff sidebar.

```bash
bat file.py             # syntax-highlighted, paged
bat --paging=never f    # no pager, just print (this is what `cat` is aliased to)
batcat file.py          # same as bat (Debian package name)
bat -A file.txt         # show whitespace / non-printables
bat -d main.py          # show only modified lines (git diff mode)
```

Aliases set in `.zshrc`:
- `cat` → `bat --paging=never`
- `catp` → `bat` (paged)

`man bat` for full options.

---

## ripgrep (rg) — faster grep

Searches respecting `.gitignore` by default. Many times faster than grep on
large repos.

```bash
rg "TODO"                       # search current dir, all files except gitignored
rg "TODO" path/                 # search in path/
rg -i "todo"                    # case-insensitive
rg -t py "regex"                # only Python files (-t lua, -t js, …)
rg -l "regex"                   # list matching files only
rg -n "regex"                   # show line numbers (default in tty)
rg -A 3 -B 1 "regex"           # context: 3 lines after, 1 before
rg --hidden                     # include hidden files (skipped by default)
rg --files                      # just list files (used by FZF_DEFAULT_COMMAND)
```

Inside nvim, `<leader>fg` invokes rg via telescope.

---

## fd-find (fd) — friendlier find

```bash
fd                                # list everything in cwd
fd README                         # match anywhere in path
fd -e py                          # files ending in .py
fd -t f -t d 'cache'              # files OR directories named *cache*
fd -H                             # include hidden
fd -E node_modules                # exclude pattern
fd -x rm                          # action: rm each match (-x runs cmd per file)
```

On Debian the binary is `fdfind`; the install script symlinks
`~/.local/bin/fd → fdfind` so `fd` works directly.

---

## grc — generic colouriser

Wraps stock commands and colourises their output by parsing it.

Aliases set in `.zshrc`:
- `netstat`, `ping`, `traceroute`, `ps`, `df`, `du`, `ifconfig`, `ip`, `dig`, `lsblk`, `lspci` all run through `grc`.

To turn it off for a single command, prefix with backslash:
```bash
\netstat -tlnp        # uncoloured
```

To stop using it permanently: comment out the aliases in `.zshrc`.

---

## htop — interactive process monitor

```bash
top      # → aliased to htop
htop
```

Inside htop:

| Keys              | Action                              |
|-------------------|-------------------------------------|
| `F2`              | Settings (columns, colours)         |
| `F3` / `/`        | Search by name                      |
| `F4`              | Filter (live)                       |
| `F5` / `t`        | Tree view                           |
| `F6` / `<`/`>`    | Sort field                          |
| `F9` / `k`        | Send signal (kill)                  |
| `F10` / `q`       | Quit                                |
| `Space`           | Tag a process (multi-action)        |
| `u`               | Filter by user                      |

Add memory bars per-NUMA: `F2 → Meters → Add`.

---

## btop — fancier process / resource monitor

`btop` is a TUI resource monitor with mouse support, per-thread CPU
graphs, GPU readout, and per-process I/O — denser than `htop` but
slower to start. Both are installed; pick by reflex.

```bash
btop                              # full-screen TUI
btop --preset 2                   # alternate layout (3 = single-pane, etc.)
btop --utf-force                  # force UTF-8 box drawing on pickier terms
```

Inside btop:

| Keys              | Action                              |
|-------------------|-------------------------------------|
| `q` / `Esc`       | Quit                                |
| `+` / `-`         | Adjust update interval              |
| `m` / `c` / `n` / `p` | Sort by mem / CPU / name / PID  |
| `f`               | Filter processes (live)             |
| `Enter`           | Show full process info              |
| `t`               | Tree view                           |
| `e`               | Toggle process command-line view    |
| `1` / `2` / `3` / `4` | Toggle CPU / memory / network / proc panel |

Customise by editing `~/.config/btop/btop.conf` (auto-created on
first run).

---

## fastfetch — system info banner

Like `neofetch`, but actively maintained. Run on shell startup to see your
system info ASCII-art:

```bash
fastfetch
```

Customise: `fastfetch --gen-config` writes `~/.config/fastfetch/config.jsonc`.

---

## lm-sensors — temperature & fan readings

```bash
sensors                            # current readings
sudo sensors-detect --auto         # one-time: probe modules to load
                                   # (the install script runs this)
```

After install, the kernel modules are loaded automatically. Polybar can
display the result via the `internal/temperature` module.

---

## net-tools (netstat, ifconfig)

Old-school networking utilities for those who reach for them by reflex.
Most users will find `ip` (from `iproute2`) more featured:

```bash
ip a                                # show all interfaces
ip route                            # routing table
ip -s link                          # interface stats
ss -tulpn                           # listening sockets (modern netstat)
```

`ports` alias = `ss -tulpn`.

---

## conky

See [conky.md](conky.md) — it's its own thing.

---

## Further reading

- `man bat`, `man rg`, `man fd`, `man htop`, `man sensors`, `man ip`, `man ss`
- [bat repo](https://github.com/sharkdp/bat)
- [ripgrep guide](https://github.com/BurntSushi/ripgrep/blob/master/GUIDE.md)
- [fd repo](https://github.com/sharkdp/fd)
- [`~/.zshrc`](../config/zsh/.zshrc) — see the alias and function sections
