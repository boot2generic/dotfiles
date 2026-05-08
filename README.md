# Cyberpunk Neon Dotfiles

A self-contained desktop environment for **Debian 12 / 13 / newer**, themed in
matching neon cyan/magenta colours across every tool. Drop the repo on a
machine, run one script, get a fully-configured i3wm + tmux + neovim setup.

```
┌────────────┬──────────────────────────────────────────────────┐
│ WM         │  i3 (tiling) + i3-gaps                           │
│ Compositor │  picom (xrender on VMs, glx on physical)         │
│ Bar        │  polybar (cyberpunk theme)                       │
│ Launcher   │  rofi                                            │
│ Notif      │  dunst                                           │
│ Lockscreen │  i3lock + ImageMagick (custom neon overlay)      │
│ Terminal   │  alacritty (JetBrainsMono Nerd Font)             │
│ Shell      │  zsh + oh-my-zsh + starship                      │
│ Multiplex  │  tmux + tpm + tmux-resurrect                     │
│ Editor     │  neovim + lazy.nvim (LSP + treesitter + cmp)     │
│ Wallpaper  │  procedurally generated (Pillow)                 │
└────────────┴──────────────────────────────────────────────────┘
```

---

## Install

Two install paths — pick whichever applies:

### A) Provision the local machine
You're sitting at the box you want to configure.
```bash
git clone <this-repo> ~/dotfiles && cd ~/dotfiles
./local_setup.sh setup                # interactive — prompted before each stage
./local_setup.sh setup --bypass       # unattended — one sudo prompt, then everything
```
Auto-detects `Debian 12+` / virt type / CPU vendor / GPU vendor (PCI
vendor IDs `10de`/`1002`/`8086`) and installs the right driver stack
(nvidia / amd / intel / hyperv / vm-guest tools), CPU microcode
(`intel-microcode` / `amd64-microcode`), Vulkan + 32-bit gaming
userland on NVIDIA + physical, and TLP / thermald / fwupd on physical.
On physical machines with a GPU, non-free is enabled via an additive
deb822 drop-in (`/etc/apt/sources.list.d/dotfiles-non-free.sources`) —
the base apt sources are never edited in place. See
[`readme/system.md`](readme/system.md) for what gets installed where.

Optional NVIDIA add-ons (physical only):

```bash
./local_setup.sh setup --cuda             # adds nvidia-cuda-toolkit (~3 GB)
./local_setup.sh setup --steam            # adds steam-installer (Debian's Steam bootstrap)
./local_setup.sh setup --cuda --steam     # both
```

### B) Provision a remote VM via SSH
You're on a controller box and want to set up a separate Debian VM.
`VM_HOST` is required — there's no default committed to git.

```bash
export VM_HOST=<ip-or-hostname>           # required
export VM_USER=<username>                 # optional (default: generic)

# One-time: install sudo + NOPASSWD on the VM (uses su for the bootstrap).
# Stash the bootstrap password in a 0600 file rather than $VM_PASS:
install -d -m 0700 ~/.config/dotfiles
umask 077 && printf '%s\n' '<password>' > ~/.config/dotfiles/vm_pass
python3 vm_automation.py bootstrap

# Then switch to SSH key auth — and remove the password file:
ssh-copy-id "${VM_USER}@${VM_HOST}"
shred -u ~/.config/dotfiles/vm_pass

# Full end-to-end install — base packages + configs + terminal stack.
python3 vm_automation.py setup [--hyperv|--physical] [--nvidia]   # interactive
python3 vm_automation.py setup --bypass                           # unattended
```

The script auto-detects whether SSH key auth works against `$VM_HOST`.
If it does, `sshpass` is never invoked. Otherwise it falls back to the
0600 password file (read into `$SSHPASS` for `sshpass -e`, never
exposed on a command line). The legacy `$VM_PASS` env var still works
for one-off use but emits a deprecation warning — env vars leak into
`ps -ef`, `/proc/<pid>/environ`, and shell history.

There is **no hardcoded password fallback** — configure key auth or
the password file before running.

Both scripts are idempotent — re-running fixes drift instead of reinstalling.

#### `local_setup.sh` vs `vm_automation.py` — feature parity

`vm_automation.py` is the older of the two scripts and is purpose-built
for provisioning a remote Debian VM over SSH. It is **not** at full
feature parity with `local_setup.sh` for physical-hardware install
paths. Specifically, `vm_automation.py` does **not** yet implement:

- GPU-vendor-specific driver bundles for Intel and AMD (the
  `--nvidia` flag installs a legacy single-package `nvidia-driver`
  only — no Vulkan / 32-bit / VA-API / open-kernel-dkms classification).
- `--cuda` and `--steam` opt-in NVIDIA add-on flags.
- deb822 drop-in for non-free — `enable_nonfree_repos()` in
  `vm_automation.py` edits `.list` / `.sources` files **in place**
  (with timestamped backups), not via an additive drop-in.
- NVIDIA open-kernel-dkms vs proprietary classification by PCI device ID.
- `nvidia-drm.modeset=1` GRUB edit + `update-initramfs` rebuild.
- 32-bit gaming userland (`i386` multiarch + `:i386` driver libs).
- `power-profiles-daemon` purge-before-TLP-install (they conflict).
- `fwupd` *availability* check in the validate phase (`fwupd` is
  installed via BASE_PACKAGES, but the validate phase has no entry
  for it yet).

Practical guidance: **on a physical laptop or desktop, run
`local_setup.sh` directly.** Use `vm_automation.py` only when the
target is a remote VM where most of those gaps don't apply (no GPU
driver, no GRUB, no LVFS firmware updates).

#### First-boot on a laptop (X11 vs Wayland)

This stack is **X11-only by design** (i3 + picom + feh + i3lock).
Debian 13's default desktop session — GNOME 48 — boots Wayland on
capable hardware (most modern Intel and AMD iGPUs). After the install
completes and `lightdm` starts:

1. At the lightdm greeter, click the gear / session-picker icon.
2. Select **`i3`** as the session.
3. Log in. Lightdm remembers the choice for subsequent logins.

If you want a Wayland-native stack on the laptop (sway, Hyprland, …),
this repo does **not** configure it — that is a parallel project. Pick
one path per machine; do not try to mix X11 i3 and a Wayland compositor
on the same user account.

#### First-boot hygiene (out of scope for the script, worth doing once)

A few baseline tasks the script intentionally does not automate, but
which belong in any "fresh install" routine:

- **LUKS full-disk encryption.** Choose this in the Debian installer
  for the laptop — see [`readme/security.md`](readme/security.md) for
  why it's a hard prerequisite.
- **Filesystem.** ext4 (Debian's default) is fine. If you want
  pre-upgrade snapshots, install on `btrfs` with subvolumes and use
  `snapper` / `timeshift`. This is an installer-time choice and isn't
  reversible without reinstalling.
- **Firmware updates.** ThinkPads (and most Lenovo / Dell desktops)
  publish BIOS/EC updates via LVFS. `apt install fwupd` is in the base
  set; refresh and review pending updates manually:
  ```bash
  sudo fwupdmgr refresh
  sudo fwupdmgr get-updates
  sudo fwupdmgr update     # only after reviewing
  ```
- **Display manager**. `local_setup.sh` enables `lightdm` and deploys
  `~/.xsession`. If you swap to a different display manager (gdm,
  sddm), the `~/.xsession` file is ignored — you'll need that DM's
  equivalent of session selection.
- **Wallpaper**. Deploy is non-hermetic for the wallpaper step: it
  tries the SHA-pinned Unsplash download first, and only falls back to
  the procedural Pillow generator when that fetch fails. Re-running
  deploy on an offline machine gives a different image than running it
  on a connected one.

#### Per-project Nix dev shells (apt stays the system PM)

Setup also installs the **Nix package manager** alongside apt — used
strictly for per-project reproducible dev shells via `nix develop` +
direnv. Apt remains the system PM (drivers, services, system tools);
Nix never overrides anything outside a project directory you've
explicitly opted into.

The everyday workflow:

```bash
# Once per project: copy a starter flake and tell direnv to load it.
cp -r ~/dotfiles/templates/python-cuda/. /path/to/your-project/
cd /path/to/your-project
direnv allow

# That's it.  cd in → tools available; cd out → tools gone.
which python   # /nix/store/...-python-3.11.../bin/python
exit-or-cd-elsewhere
which python   # /usr/bin/python3 (apt's, back to normal)
```

Skip with `--no-nix` if you don't want Nix at all — apt-only setups
still work end-to-end. See [`readme/nix.md`](readme/nix.md) and
[`templates/`](templates/) for the full model and starter flakes
(Python, Python+CUDA, Node, Rust).

#### Personal config (git, ssh, gpg) is intentionally NOT in this repo

These dotfiles configure the *desktop environment* only. Git
`user.email`, signing keys, SSH config, and GPG agent settings are
personal and live outside the repo — set them up out of band:

```bash
# Example git identity — adjust to taste
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
git config --global init.defaultBranch main
```

### Install modes

| Flag                       | Behaviour                                                       |
|----------------------------|-----------------------------------------------------------------|
| `--interactive` / `-i`     | Default when stdin is a TTY. Prints a description of each stage |
|                            | (install / deploy / terminal / validate) and asks **Y/n/q**     |
|                            | before running it. Sudo password is requested **once** at start.|
| `--bypass` / `--yes` / `-y`| End-to-end, no per-stage prompts. Sudo password is also asked   |
|                            | once at start. Default when stdin is **not** a TTY (CI, piped). |

The interactive prompts walk a new user through what's about to happen
("This stage will install ~80 packages, time: 3-10 minutes…") before
each step. Choose `n` to abort, `q` to quit, or just press `Enter` to
continue. Every stage is also a standalone subcommand (`install`,
`deploy`, `terminal`, `validate`), so you can resume from anywhere.

### Hardening (opt-in)

After `setup` works, flip from "permissive install posture" to a
hardened daily-use posture:

```bash
./local_setup.sh harden          # sudo narrowing, ufw, auto-security-updates, DoT DNS
./local_setup.sh unharden        # revert (run before re-running setup)
```

Same on the remote-VM side: `python3 vm_automation.py harden`. Read
[`readme/security.md`](readme/security.md) for the threat model, what
each step changes, and what's still on you (disk encryption, Mullvad
account creds, browser hardening).

---

## Update

Pull the repo and re-run the deploy step (no apt churn):

```bash
# Local
./local_setup.sh deploy
./local_setup.sh terminal     # re-runs nvim plugin sync, oh-my-zsh, etc.

# Remote
python3 vm_automation.py deploy-configs [--hyperv|--physical]
python3 vm_automation.py setup-terminal
```

After config changes, reload-in-place where supported:

| Tool        | Reload                                |
|-------------|---------------------------------------|
| i3          | `Mod+Shift+c` (in-place reload)       |
| i3 (full)   | `Mod+Shift+r` (restart, keeps state)  |
| polybar     | `~/.config/polybar/launch.sh`         |
| tmux        | inside tmux: prefix + `R`             |
| zsh         | `reload` (alias for `source ~/.zshrc`)|
| nvim plugins| `:Lazy sync`                          |

---

## Quick-start cheat sheet

The single most-used keybinds. Each tool has its own page with the full set.

### Window management (i3) — `Mod` is the **Super** (Windows) key
| Keys                     | Action                              |
|--------------------------|-------------------------------------|
| `Mod+Return`             | Open Alacritty                      |
| `Mod+d`                  | Rofi app launcher                   |
| `Mod+Tab`                | Rofi window switcher                |
| `Mod+e`                  | Open Thunar (file manager)          |
| `Mod+b`                  | Open Firefox (`firefox-esr`)        |
| `Mod+h/j/k/l`            | Focus left / down / up / right      |
| `Mod+Shift+h/j/k/l`      | Move window                         |
| `Mod+1..0`               | Switch to workspace 1..10           |
| `Mod+Shift+1..0`         | Move window to workspace 1..10      |
| `Mod+f`                  | Toggle fullscreen                   |
| `Mod+r`                  | Resize mode (h/j/k/l, Esc to exit)  |
| `Mod` + left-drag        | Move window with the mouse          |
| `Mod` + right-drag       | Resize window with the mouse        |
| Drag a titlebar          | Move/swap a tiled window            |
| `Mod+Shift+q`            | Kill focused window                 |
| `Mod+Shift+x` / `Mod+Del`| Lock screen                         |
| `Mod+Shift+e`            | Quit i3 (logout — confirms first)   |
| `Mod+Shift+w`            | Network: nm-connection-editor (GUI) |
| `Mod+n`                  | Network: nmtui (TUI in alacritty)   |
| `XF86WLAN` (Fn+F8)       | Toggle wifi radio (rfkill)          |
| `XF86MonBrightness*`     | Brightness up / down (5% steps)     |
| `Print` / `Mod+Print`    | Screenshot full / region            |

### Media keys
Standard `XF86Audio*` keys (laptop media row, Bluetooth headsets) work out
of the box. Desktops without those keys can use the `Mod+F-row` fallback.

| Keys                                  | Action                                |
|---------------------------------------|---------------------------------------|
| `XF86AudioRaiseVolume` / `Mod+F12`    | Volume up                             |
| `XF86AudioLowerVolume` / `Mod+F11`    | Volume down                           |
| `XF86AudioMute` / `Mod+m`             | Toggle mute                           |
| `XF86AudioMicMute`                    | Toggle microphone mute                |
| `XF86AudioPlay` / `Mod+F9`            | Play / pause                          |
| `XF86AudioNext` / `Mod+F10`           | Next track                            |
| `XF86AudioPrev` / `Mod+F8`            | Previous track                        |

### tmux — prefix is **`Ctrl-b`** (default)
| Keys              | Action                              |
|-------------------|-------------------------------------|
| prefix `\|` / `-` | Split horizontal / vertical         |
| `Ctrl-h/j/k/l`    | Move between panes (vim-aware)      |
| prefix `H/J/K/L`  | Resize current pane                 |
| prefix `r`        | Rename window + pane                |
| prefix `R`        | Reload tmux.conf                    |
| prefix `C-f`      | Fzf find file under `~` → open in nvim |
| prefix `F`        | tmux-fzf menu (sessions/windows/panes) |
| `Shift-Left/Right`| Previous / next window              |
| prefix `S`        | Choose session                      |

### Editor (neovim) — leader is **`Space`**
| Keys              | Action                              |
|-------------------|-------------------------------------|
| `<leader>ff`      | Find files (telescope)              |
| `<leader>fg`      | Live grep                           |
| `<leader>fb`      | Buffers                             |
| `<leader>e`       | Toggle file tree                    |
| `gd` / `K`        | LSP go-to-definition / hover docs   |
| `<leader>ca`      | Code action                         |
| `s` / `S`         | Flash jump / treesitter jump        |
| `<leader>w` / `q` | Save / quit                         |

### Shell (zsh) custom helpers
| Command          | What it does                                  |
|------------------|-----------------------------------------------|
| `ff [dir]`       | fzf-find a file, open in nvim                 |
| `fcd [dir]`      | fzf-find a directory, cd into it              |
| `fcp [dir]`      | fzf-find a path, copy to clipboard            |
| `mkcd <dir>`     | `mkdir -p` + `cd`                             |
| `set-title TEXT` | Set sticky terminal title (alacritty + i3)    |
| `Ctrl-X t`       | Hotkey: prefill `set-title ` on the line      |
| `Ctrl-r`         | fzf history search (overrides default)        |
| `Ctrl-t`         | fzf insert file path into command line        |
| `Alt-c`          | fzf cd into a subdirectory                    |
| Double-`Esc`     | Prepend `sudo` to current line (oh-my-zsh)    |

---

## Per-tool guides

| Topic                                  | Description                                          |
|----------------------------------------|------------------------------------------------------|
| [i3](readme/i3.md)                     | Window manager — keybinds, workspaces, layouts       |
| [tmux](readme/tmux.md)                 | Terminal multiplexer — splits, sessions, plugins     |
| [nvim](readme/nvim.md)                 | Editor — LSP, telescope, treesitter, plugins         |
| [zsh](readme/zsh.md)                   | Shell, oh-my-zsh, starship prompt, aliases, fns      |
| [alacritty](readme/alacritty.md)       | Terminal emulator — fonts, colours, keybinds         |
| [polybar](readme/polybar.md)           | Status bar — modules, restart, customising           |
| [rofi](readme/rofi.md)                 | App launcher / window switcher / dmenu replacement   |
| [picom](readme/picom.md)               | Compositor — backends, troubleshooting               |
| [dunst](readme/dunst.md)               | Notifications — invocation, history, styling         |
| [wallpaper](readme/wallpaper.md)       | Procedural cyberpunk wallpaper generator             |
| [lockscreen](readme/lockscreen.md)     | i3lock + neon overlay generator                      |
| [fzf](readme/fzf.md)                   | Fuzzy finder — keybinds, integrations, recipes       |
| [cli-tools](readme/cli-tools.md)       | bat, grc, ripgrep, fd, htop, fastfetch, lm-sensors   |
| [conky](readme/conky.md)               | Desktop hardware monitor                             |
| [vpn](readme/vpn.md)                   | Mullvad + WireGuard — install, polybar, kill switch  |
| [security](readme/security.md)         | Threat model, harden/unharden, what's still on you   |
| [system](readme/system.md)             | Audio, brightness, clipboard, network, screenshots   |
| [nix](readme/nix.md)                   | Nix package manager (apt-default, Nix-opt-in model)  |

---

## Repo layout

```
.
├── README.md                  ← you are here
├── readme/                    ← per-tool guides
├── vm_automation.py           ← remote VM setup over SSH
├── local_setup.sh             ← local-machine setup (Debian 12+)
├── config/                    ← all dotfiles, deployed to ~/.config/<name>
│   ├── i3/                    ← i3wm
│   ├── tmux/                  ← tmux.conf
│   ├── nvim/                  ← init.lua + lazy.nvim plugins
│   ├── zsh/.zshrc             ← shell config
│   ├── alacritty/             ← terminal
│   ├── polybar/               ← status bar
│   ├── rofi/                  ← launcher
│   ├── picom/                 ← compositor
│   ├── dunst/                 ← notifications
│   ├── starship/              ← prompt
│   ├── conky/                 ← HW monitor
│   ├── lockscreen/lock.sh     ← lockscreen renderer
│   ├── wallpaper/             ← Pillow wallpaper generator
│   ├── lightdm/               ← display-manager greeter theme (TEMPLATE: *.conf.in with @HOME@)
│   ├── gtk-2.0/, gtk-3.0/     ← GTK theme overrides
│   └── xorg.conf.d/           ← Hyper-V Xorg config
└── scripts/
    ├── xsession.sh            ← deployed to ~/.xsession
    └── Xresources             ← deployed to ~/.Xresources
```

---

## Theme

All tools share the **Cyberpunk Neon** palette so colours match across the bar,
prompt, terminal, editor, and lockscreen:

| Role       | Hex         |
|------------|-------------|
| Background | `#0d0d1a`   |
| Surface    | `#1a1a2e`   |
| Foreground | `#e2e2ff`   |
| Cyan (acc) | `#00e5ff`   |
| Magenta    | `#ff00cc`   |
| Green      | `#00ff41`   |
| Yellow     | `#ffcc00`   |
| Red        | `#ff0055`   |
| Purple     | `#9900ff`   |

Editing one config's palette doesn't propagate — the values are duplicated per
tool because each uses its own format. If you re-theme, search the repo for
`#0d0d1a` and friends to find every reference.

---

## Troubleshooting

| Problem                                       | Fix                                                                 |
|-----------------------------------------------|---------------------------------------------------------------------|
| `Mason install of clangd fails`               | Make sure `unzip` is installed (`sudo apt install unzip`)           |
| `nvim startup error: requires nvim-0.11`      | Pull the latest dotfiles — plugin pins were added for nvim 0.10     |
| `picom blank/black on Hyper-V`                | Ensure backend is `xrender` in `~/.config/picom/picom.conf`         |
| `polybar shows boxes instead of icons`        | JetBrainsMono Nerd Font missing — re-run `terminal` phase           |
| `tree-sitter compile errors` (`stdio.h`)      | Install `build-essential` (libc6-dev was missing)                   |
| `default shell still bash after setup`        | `sudo chsh -s "$(command -v zsh)" $USER`, then log out/in           |
| `RDP / xrdp not running`                      | Intentionally not installed — `sudo apt install xrdp xorgxrdp` then re-run `deploy-configs`/`deploy` |
| `polybar battery shows wrong %` or missing    | Wrong `BAT0`/`ADP1` for this hardware — `ls /sys/class/power_supply/`, edit `[module/battery]` to match |
| `iw / rfkill / tlp-stat: command not found`   | `/usr/sbin` not on PATH — re-source `~/.zshrc` (the dotfiles append it on login) |
| `tlp inactive on a laptop`                    | `sudo systemctl enable --now tlp` — the install script enables it only on physical hardware |
| `power-profiles-daemon active alongside TLP`  | Conflict: TLP install purges PPD on physical machines. If you re-installed PPD by hand, pick one — `sudo systemctl disable --now power-profiles-daemon` + `sudo apt purge power-profiles-daemon` to keep TLP. |
| `nvidia kernel module not loaded` after install | Reboot — driver install adds `nvidia-drm.modeset=1` to GRUB and rebuilds initramfs but the new kernel only takes effect on the next boot. |
| `Steam: not using direct rendering`           | i386 multiarch missing — `dpkg --print-foreign-architectures` should include `i386`. If not, re-run `./local_setup.sh install` (the script enables i386 on NVIDIA + physical). |
| `validate phase reports fwupd FAIL`           | `sudo apt install fwupd` then re-run validate — fwupd is in BASE_PACKAGES so this only happens if a previous install was interrupted. |
