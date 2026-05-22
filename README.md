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

Four install paths.  The decision tree below picks the right one in 30 seconds; the **feature-parity matrix** further down has the full capability table.

### Decision tree

```
Are you provisioning THIS machine (sitting at the console / SSH'd in)?
├── Yes — full desktop with X11 + i3 + polybar + picom (the original)
│         → Path A:  ./local_setup.sh setup
├── Yes — full desktop with KDE Plasma 6 + Wayland + SDDM + PipeWire
│         (recommended for NVIDIA + multi-monitor + high-refresh-rate)
│         → Path A:  ./local_setup.sh setup --plasma
│           (see readme/plasma.md for details)
├── Yes — and you only want the SHELL stack (zsh, tmux, nvim, starship)
│         → Path D:  ./scripts/install-shell.sh
│           (also handles --offline using a pre-built bundle)
└── No, you're on a controller box reaching a remote machine via SSH
    ├── Remote is a desktop VM (you want the full GUI on it)
    │     → Path B:  python3 vm_automation.py setup
    └── Remote is a server (shell-only, no GUI)
          → Path C:  ./scripts/provision-server.sh user@host
```

### Feature-parity matrix

What each path supports, at a glance.  Rows are capabilities; cells are `✓` (supported), `–` (not applicable / out of scope), or `✗` (could in principle but isn't implemented).

| Capability | A. local_setup.sh | B. vm_automation.py | C. provision-server.sh | D. install-shell.sh |
|---|:-:|:-:|:-:|:-:|
| **Target stack** | full GUI | full GUI | shell-only | shell-only |
| **Target location** | local | remote (SSH) | remote (SSH) | local |
| **Desktop choice** (`--desktop=i3 \| plasma`) | ✓ | ✗ (i3 only) | – | – |
| **Plasma 6 Wayland + SDDM + PipeWire** | ✓ (`--plasma`) | ✗ | – | – |
| **NVIDIA-Wayland kernel pieces** (fbdev, early-KMS, PM) | ✓ (plasma + nvidia) | ✗ | – | – |
| **Distros — Debian/Ubuntu** (apt) | ✓ | ✓ | ✓ | ✓ |
| **Distros — RHEL/Rocky/Alma/Fedora** (dnf) | – | – | ✓ | ✓ |
| **Online install** | ✓ | ✓ | ✓ | ✓ |
| **Offline install** (`--offline` + `bundle/`) | ✗ | ✗ | ✗ | ✓ |
| **NVIDIA drivers + 32-bit Vulkan + modeset** | ✓ | basic | – | – |
| **`--cuda` (CUDA toolkit)** | ✓ | ✗ | – | – |
| **`--steam` (steam-installer + gamemode)** | ✓ | ✗ | – | – |
| **CPU microcode (intel/amd64)** | ✓ | ✗ | – | – |
| **NVIDIA open-kernel-dkms classification** | ✓ | ✗ | – | – |
| **deb822 drop-in for non-free** | ✓ | ✗ (in-place sed) | – | – |
| **i386 multiarch + 32-bit gaming libs** | ✓ | ✗ | – | – |
| **Mullvad VPN install** | ✓ | ✓ | – | – |
| **TLP / power-profiles-daemon coexistence** | ✓ | ✗ | – | – |
| **fwupd + LVFS firmware updates** | ✓ | ✓ | – | – |
| **NetworkManager wifi takeover** | ✓ (auto, opt-out) | – | – | – |
| **Idempotent re-runs** | ✓ | ✓ | ✓ | ✓ |
| **`--dry-run`** | per-stage | – | ✓ | ✓ |
| **Nix package manager + flakes** | ✓ (`--no-nix` opts out) | ✗ | ✗ | ✗ |
| **direnv + nix-direnv** | ✓ | – | ✓ | ✓ |
| **oh-my-zsh + plugins** | ✓ | ✓ | ✓ (`--no-omz` opts out) | ✓ (`--no-omz` opts out) |
| **starship prompt** | ✓ | ✓ | ✓ | ✓ |
| **tmux + tpm + plugins** | ✓ | ✓ | ✓ | ✓ |
| **neovim + lazy.nvim sync** | ✓ | ✓ | ✓ (`--no-nvim` opts out) | ✓ (`--no-nvim` opts out) |
| **Validate phase (~50 checks)** | ✓ | ✓ | – | – |
| **Harden / unharden** (sudoers + ufw + DoT + auto-updates + auditd) | ✓ | ✓ | – | – |
| **Laptop suspend + dock hooks** (chassis-gated; T14) | ✓ | ✗ | – | – |
| **NVIDIA Wayland session env + explicit-sync** (NVIDIA-only) | ✓ (`--plasma`) | ✗ | – | – |
| **Per-monitor refresh / VRR / HDR baseline** (`kscreen-baseline.py`) | ✓ (`--plasma`) | ✗ | – | – |

**Where shell-only paths share code:** Path C and Path D both source `scripts/lib/install-common.sh` for package lists, distro detection, oh-my-zsh / tpm / starship / fd-bat-symlink / default-shell logic.  Adding a tool there propagates to both.

**Where the full-GUI paths diverge:** Path A is the canonical implementation; Path B is the older SSH-pexpect mirror and is intentionally NOT at full feature parity (see the `✗` cells above).  If you want the modern full-GUI behavior on a remote VM, the recommended workflow is: `git push` your dotfiles repo, `git clone` it on the VM, run `./local_setup.sh setup --bypass` there directly.  Path B is kept for the niche case of fully unattended end-to-end setup of a virgin VM via pexpect.

### Application installs (Phase 0)

A second install layer lives beside the per-host overrides: a
manifest-driven application installer at
[`config/apps/`](config/apps/README.md). One TOML file per third-party
app, four install methods (`apt`, `apt-pinned-repo`, `github-release`,
`direct-deb`), schema-validated, with pinned GPG fingerprints + SHA-256
hashes that get verified before anything lands on disk. The dispatcher
([`scripts/install-apps.sh`](scripts/install-apps.sh)) filters by the
machine profile set (`common` always; `t14` on DMI chassis 8/9/10/14;
`desktop` on detected NVIDIA) and shells out to one of four adapters
under `scripts/install-methods/`.

Phase 0 ships infrastructure only — the dispatcher, four adapters, three
pin-workflow scripts, and three migrated existing pins (starship,
JetBrains Mono Nerd Font, Mullvad VPN). No new apps are installed yet;
the existing inline install paths in `local_setup.sh` keep working.

```bash
./scripts/install-apps.sh --list                 # what would run on this machine
./scripts/install-apps.sh --app starship --dry-run
./scripts/verify-pins.sh                         # 0 fresh / 1 stale / 2 bad / 3 typo
./scripts/refresh-pins.sh --all                  # weekly cron; mutates TOML, never commits
./scripts/refresh-keys.sh --app mullvad-vpn      # interactive, single-app key rotation
```

A stale or failing pin shows up in three places: the conky HEALTH
overlay's `supply chain` row (see "Beyond install — monitoring +
drift" below), `scripts/dotfiles-doctor.sh`'s new SUPPLY CHAIN section,
and `scripts/audit.sh`'s `pins` row. See
[`config/apps/README.md`](config/apps/README.md) for the field-by-field
schema, the add-an-app workflow, and how the dispatcher hands off to
each adapter. The supply-chain trust pillars (apt repo signing, SHA-256
pinning, optional GPG `VALIDSIG`) are documented in
[`readme/security.md`](readme/security.md) → "Application install
supply chain".

### Beyond install — monitoring + drift

After install, two surfaces keep watch over the machine:

- **Conky security overlay** (always-on, top-right of screen) — the HEALTH panel now
  rolls in critical-file drift (`/etc/{passwd,shadow,sudoers,sudoers.d/}`, authorized_keys,
  systemd units, cron.d/), 24 h SUID/SGID drift across the rootfs (cached so it doesn't
  re-scan every cycle), recent `sudo` invocations (separate from the existing failed-sudo
  counter), a daemon → interactive-shell parent-anomaly check, and a **DoT** row
  (`check_dot`) that parses `resolvectl status` and reports OK when `+DNSOverTLS` is
  active on the default-route link, WARN when it has been downgraded to plain DNS
  (`-DNSOverTLS`), and DIM when systemd-resolved isn't running. The netstat panel
  flags periodic-reconnect **beacons** (`⏱` marker) when a `(ip, port, proc)` triple has
  re-opened ≥4 times with a coefficient-of-variation under 0.15. The listenports panel
  paints any listener whose binary lives outside `/usr/`, `/snap/`, `/var/lib/flatpak/`
  (or whose `exe` ends in `(deleted)`) in red. See [`readme/security.md`](readme/security.md)
  → "Conky security monitoring" for the full check list.
- **CLI counterparts** — `scripts/audit.sh` (drift-only) and `scripts/dotfiles-doctor.sh`
  (full one-page report) cover the same ground from SSH or cron. See the scripts table
  below.

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

After all four stages finish, `setup` runs an automatic `auto_wifi_takeover`
step on physical machines whose wifi is stuck in NetworkManager state
`unmanaged` (Debian's installer parked it under ifupdown +
wpa_supplicant) **and** whose SSID/PSK are recoverable from
`/etc/network/interfaces`. The takeover pre-imports the credentials
into NM as an autoconnect profile *before* stopping the old backend, so
the network reconnects automatically and you're never stranded
mid-flight. Skip with `--no-wifi-takeover`:

```bash
./local_setup.sh setup --no-wifi-takeover  # leave the wifi backend alone
```

If the credentials aren't extractable, the auto-takeover deliberately
does nothing and prints a hint to run `scripts/take-over-wifi.sh`
manually. See [`readme/system.md`](readme/system.md) → "WiFi shows
'unmanaged'" for the manual flow + rollback instructions.

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

### C) Provision a shell-only remote server (SSH dev box, lab VM, …)

You have a Debian / Ubuntu / Rocky / Alma / Fedora server you only
ever SSH into. You want the same `zsh` + `oh-my-zsh` + `starship` +
`tmux` + `nvim` + CLI utilities you have on your laptop, but no GUI
junk (no X11, no polybar, no fonts, no display manager).

```bash
ssh-copy-id user@host                                          # one-time, key auth required
./scripts/provision-server.sh user@host                        # full shell setup
./scripts/provision-server.sh user@host --no-nvim              # skip nvim (older distros, nvim<0.9)
./scripts/provision-server.sh user@host --dry-run              # see what it would do
./scripts/provision-server.sh user@host --no-omz               # slim zsh, no oh-my-zsh
```

The remote needs **passwordless sudo** for the user (test:
`ssh user@host 'sudo -n true'` should exit 0). Re-run any time to
update — the script is idempotent and only does work where state
has drifted.

What gets installed: `zsh tmux neovim fzf ripgrep fd-find bat git
curl wget rsync htop unzip nodejs python3 grc direnv` plus
`build-essential`/`@development-tools` for compiling tree-sitter
parsers. Plus `starship` (apt/dnf where available, upstream installer
elsewhere), `oh-my-zsh` + `zsh-autosuggestions` + `zsh-syntax-highlighting`,
`tpm` + tmux plugins, and `lazy.nvim` plugins synced headlessly.

What gets deployed (subset of `config/`): `~/.zshrc`,
`~/.config/{starship,tmux,nvim}/`. **No** i3/polybar/picom/rofi/etc.
— those are GUI-only, useless on a server.

#### Offline / air-gapped servers

For servers with **no outbound internet access** (lab gear, secured
networks, sneakernet-only boxes), build a bundle on a connected box
of the *same distro and architecture*, copy the whole dotfiles dir
to the offline target, and run `install-shell.sh --offline`:

```bash
# On a connected build box (Debian/Ubuntu, matching arch):
./scripts/build-bundle.sh

# This creates ./bundle/ (~150-250 MB) containing:
#   bundle/debs/         — every .deb the install needs (incl. transitive deps)
#   bundle/git/          — oh-my-zsh, plugins, tpm clones
#   bundle/starship/     — release binary + sha256
#   bundle/manifest.txt  — distro/arch metadata read at install time

# Sneakernet the dotfiles dir (incl. bundle/) to the target.
# rsync, scp from a bridge, USB stick — whatever fits.

# On the offline target:
./scripts/install-shell.sh --offline
```

`install-shell.sh` works locally (no SSH) and supports both modes:

| Invocation | What it does |
|---|---|
| `./scripts/install-shell.sh`             | Full online install — apt/dnf, github clones, upstream starship |
| `./scripts/install-shell.sh --offline`   | Reads `bundle/`, no network calls. Apt-distros only. |
| `./scripts/install-shell.sh --no-nvim`   | Skip neovim setup (older distros, `nvim < 0.9`) |
| `./scripts/install-shell.sh --no-omz`    | Skip oh-my-zsh — slim zsh + plugins only |
| `./scripts/install-shell.sh --dry-run`   | Show what would happen without doing it |

The offline install path also works for the use case "I'm sitting at
the console of an air-gapped box; I copied the dotfiles in via USB."

**Bundle tamper-evidence (opt-in GPG signing).** `bundle/manifest.sha256`
is the integrity anchor — every file in the bundle is hashed into it,
and `install-shell.sh --offline` verifies hashes before installing
anything. sha256 catches bitrot but not a deliberate swap of bundle +
manifest together. Set `BUNDLE_SIGNING_KEY=<keyid>` when building to
emit a detached armored signature next to the manifest:

```bash
BUNDLE_SIGNING_KEY=ABCD1234 ./scripts/build-bundle.sh
# → bundle/manifest.sha256 + bundle/manifest.sha256.asc
```

`install-shell.sh --offline` auto-verifies the `.asc` if it's present
and `gpg` is installed; without `BUNDLE_SIGNING_KEY` the bundle stays
unsigned and only the hash check runs (the existing
`INSTALL_SKIP_BUNDLE_CHECK=1` escape hatch still bypasses both layers
if you really need to).

Caveats baked into `--offline`:
- **Bundle and target must match**: same distro, same major version,
  same architecture. The manifest is checked at install time — arch
  mismatches abort with a clear error.
- **`nvim` plugin sync is skipped** under `--offline` (lazy.nvim
  reaches GitHub during `:Lazy sync`). Pre-built plugins can be
  bundled separately, or pass `--no-nvim` to suppress the warning.
- **dpkg dependency drift on mismatched build / target**: if the
  build box and the offline target diverge enough that the bundled
  .debs reference transitive deps the target doesn't have, dpkg
  leaves half-configured packages and `apt-get install -f` can't fix
  it (it would need to fetch the missing deps from the network, which
  is exactly what's not available). When this happens, `install-shell.sh`
  prints a 3-paragraph diagnostic pointing at:
  - `sudo dpkg --audit` and `dpkg -l | grep -E '^iU|^iF'` to inspect
    the half-installed state,
  - `sudo tail -50 /tmp/install-shell-dpkg.log` for the raw dpkg output,
  and three resolution paths (rebuild bundle to match target, copy
  missing .debs in manually, or get the target online briefly so
  `apt-get install -f -y` can complete).
- `provision-server.sh` (remote-via-SSH path) does not currently
  support `--offline`. Workaround: rsync the dotfiles dir + bundle
  to the offline server, then SSH in and run `install-shell.sh
  --offline` locally there.

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

#### First-boot — picking i3 vs Plasma

The repo ships **two** desktop stacks. Pick one per machine with the
`--desktop=` flag at install time:

- **`--desktop=i3`** (default) — X11 + i3 + polybar + picom + rofi + dunst
  + lightdm + pulseaudio. The original cyberpunk stack. Use on laptops,
  iGPU machines, and anywhere you want minimal overhead and full
  keyboard-driven control. Behaviour is byte-identical to pre-Plasma
  versions of this script.
- **`--desktop=plasma`** — KDE Plasma 6 on Wayland + KWin + SDDM +
  PipeWire + konsole/dolphin/kscreenlocker. Recommended for **physical
  desktops with discrete NVIDIA cards and multi-monitor / high-refresh
  setups**, where Wayland's mixed-refresh-rate handling is the headline
  win. See [`readme/plasma.md`](readme/plasma.md) for the full details
  including NVIDIA-on-Wayland kernel pieces, theming layers, and
  multi-monitor configuration.

After install completes:

- i3 path: lightdm greeter → pick `i3` session → log in. Lightdm
  remembers the choice for subsequent logins.
- plasma path: sddm greeter → `Plasma (Wayland)` is the default
  session, click *Log in*. SDDM persists the choice.

You can switch between stacks on the same machine by re-running
`./local_setup.sh setup --i3` or `… --plasma`; the deploy phase
swaps the active DM and patches the conky window-type accordingly.
Both desktops' configs coexist on disk after either install. Do not
log into BOTH stacks under the same user account during the same boot
— some daemons (kwallet vs gnome-keyring, knotifications vs dunst)
will fight for the same dbus name.

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
./local_setup.sh harden          # sudo narrowing, ufw, DoT DNS, auto-security-updates, auditd
./local_setup.sh unharden        # revert (run before re-running setup)
```

`harden` now wires up three additional layers alongside the sudoers /
ufw pieces:

- **unattended-upgrades — Debian-Security only.** The dropped
  `50unattended-upgrades` allowlists *only* `Debian-Security` origins,
  so daily auto-installs cover CVEs without silently pulling
  point-release feature changes underneath you. Reverts cleanly via
  `unharden`.
- **auditd rules** — `config/system/etc/audit/rules.d/dotfiles.rules`
  watches writes to `/etc/{passwd,shadow,group,gshadow}` and
  `/etc/sudoers*`, kernel module load/unload (b64 + b32), and
  mount/umount. Query with `sudo ausearch -k identity|sudoers|modules|mount`.
- **DNS-over-TLS via systemd-resolved** (`harden_dot`, replaces the
  older `harden_dns` path). Installs `systemd-resolved` if missing,
  drops `config/system/etc/systemd/resolved.conf.d/cyberpunk-dot.conf`
  (`DNSOverTLS=opportunistic`, `DNSSEC=allow-downgrade`, Cloudflare +
  Quad9 with SNI hints, Google `8.8.8.8` as plain fallback), drops
  `config/system/etc/NetworkManager/conf.d/cyberpunk-dns.conf`
  (`dns=systemd-resolved`), atomically symlinks
  `/etc/resolv.conf → /run/systemd/resolve/stub-resolv.conf` (running
  `chattr -i` first in case an older hardening guide pinned it
  immutable), and reloads NM. `unharden_dot` is the exact inverse.
  Opportunistic mode keeps captive portals working at the cost of
  RST-downgradability — the conky DoT row tells you when you've been
  downgraded.

Same on the remote-VM side: `python3 vm_automation.py harden`. Read
[`readme/security.md`](readme/security.md) for the threat model, what
each step changes, and what's still on you (disk encryption, Mullvad
account creds, browser hardening), and [`readme/system.md`](readme/system.md)
→ "Hardening extras" for the unattended-upgrades + auditd `ausearch`
recipes.

### Per-host overrides (`~/.config/dotfiles-local/`)

Anything you drop under `~/.config/dotfiles-local/<thing>/…` is
rsync'd OVER the repo defaults during `deploy_phase` (no `--delete`,
so overrides only add/replace — they never strip repo files).
This is the seam for machine-specific tweaks that don't belong in git
(`alacritty.toml` font size on a 4K monitor, an extra polybar module,
a `tmux.conf` snippet for one box). On first install the deploy phase
auto-writes a short README to `~/.config/dotfiles-local/README`
explaining the convention.

```bash
./local_setup.sh --show-overrides   # list [add]/[override]/[same]/[extra] entries
DOTFILES_NO_LOCAL=1 ./local_setup.sh deploy   # one-shot bypass for a clean repo deploy
```

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
| [cli-tools](readme/cli-tools.md)       | bat, grc, ripgrep, fd, htop, btop, fastfetch, lm-sensors |
| [conky](readme/conky.md)               | Desktop hardware monitor                             |
| [vpn](readme/vpn.md)                   | Mullvad + WireGuard — install, polybar, kill switch  |
| [security](readme/security.md)         | Threat model, harden/unharden, what's still on you   |
| [system](readme/system.md)             | Audio, brightness, clipboard, network, screenshots   |
| [nix](readme/nix.md)                   | Nix package manager (apt-default, Nix-opt-in model)  |

The `scripts/` directory holds smaller utilities that don't have their
own page yet. The most-used ones, with one-line summaries:

| Script                                | What it does                                                          |
|---------------------------------------|-----------------------------------------------------------------------|
| `scripts/provision-server.sh`         | Shell-only install on a remote server over SSH (Debian/Ubuntu/RHEL family). See README install path **C**. |
| `scripts/install-shell.sh`            | Shell-only install on THIS machine. `--offline` consumes the bundle from `build-bundle.sh`. |
| `scripts/build-bundle.sh`             | Builds `bundle/` (apt .debs + git clones + starship tarball) on a connected box for offline installs. `BUNDLE_SIGNING_KEY=<keyid>` emits a detached GPG signature over `manifest.sha256`. |
| `scripts/audit.sh`                    | "Did anything change since I last ran this?" — diffs the current ports / kernel modules / critical-file hashes / SUID inventory against the baselines under `~/.config/conky/baseline-*.txt`. Flags: `--json`, `--refresh-baseline <name>`. Exit 0 OK / non-zero BAD — cron-friendly. Drift semantics intentionally match `health.py`'s same-named checks. |
| `scripts/dotfiles-doctor.sh`          | One-page workstation health report (DRIFT + SYSTEM + NETWORK + DEPLOY sections); the standalone counterpart to the conky HEALTH panel. Shells out to `audit.sh` for the drift block. Flags: `--brief`, `--no-color`. Nagios-style exit codes (0 OK / 1 WARN / 2 BAD). |
| `scripts/take-over-wifi.sh`           | Hands wifi from ifupdown / iwd / wpa_supplicant / systemd-networkd to NetworkManager — pre-imports SSID/PSK from `/etc/network/interfaces` into NM before stopping the old backend so reconnect is automatic. Run by `local_setup.sh setup` automatically when applicable; can also be invoked by hand. `--revert` undoes the takeover (restores the most recent `/etc/network/interfaces.bak.<TS>`, removes the NM conf.d snippet, re-enables the prior backend). |
| `scripts/diagnose-wifi.sh`            | Read-only diagnostic dump for "wifi isn't working". Redacts wpa-psk / wpa-passphrase / wpa-password / wpa-preshared-key / wpa-wep-key* / wpa-eappsk / wpa-identity / wpa-anonymous-identity / wpa-private-key* / wpa-pin and replaces wpa-passphrase-file / wpa-psk-file paths with `<REDACTED-PATH>`. Safe to paste into a bug report. |
| `scripts/install-apps.sh`             | Manifest-driven application installer. Discovers `config/apps/*.toml`, resolves the machine profile (`common`/`t14`/`desktop`), and dispatches each app to its method adapter under `scripts/install-methods/`. Flags: `--all` (default), `--app NAME`, `--list`, `--dry-run`, `--profile NAME`, `--help`. Adapter contract: exit 0 success/intentional-skip, 1 pre-flight failure, 2 installation error. See [`config/apps/README.md`](config/apps/README.md). |
| `scripts/verify-pins.sh`              | Read-only verification of every `config/apps/<name>.toml` pin block — sha256 / GPG fingerprint / freshness against `last_refreshed + refresh_after_days`. Called by `install-apps.sh` (pre-flight), `audit.sh`, `dotfiles-doctor.sh`, and conky's `check_pins()`. Exit codes are the contract: 0 ok, 1 stale, 2 verification fail, 3 `--app NAME` matched no manifest. Flags: `--all`, `--app NAME`, `--json`, `--strict-fresh` (stale → exit 2 for cron). |
| `scripts/refresh-pins.sh`             | Periodic pin refresher — pulls upstream metadata, rewrites `last_refreshed` (and version + sha256 for `github-release` on a tag bump) in-place into the TOML. **Never** auto-commits — a clean `git diff` is the review surface. Per-method behaviour: `apt` skipped, `apt-pinned-repo` runs a scoped `apt-get update` (bumps date if signed Release verifies; logs CRITICAL on key rotation), `github-release` recomputes SHAs on tag drift, `direct-deb` does a HEAD liveness check only. Flags: `--all`, `--app NAME`, `--method NAME`, `--dry-run`, `--quiet`. |
| `scripts/refresh-keys.sh`             | Interactive, manual-only, single-app keyring rotation for `apt-pinned-repo` apps. Downloads `key_url`, compares fingerprints, on accept atomically swaps `config/system/etc/apt/keyrings/<keyring_file>` and updates `key_fingerprint` in the TOML. Append-only audit log at `~/.cache/dotfiles/key-rotations.log`. No `--all` by design — each rotation is its own security event. Flags: `--app NAME` (required), `--yes`. |

### System hooks deployed under `config/system/`

`deploy_phase` lays down a small set of root-owned hooks, each gated so
it's a silent no-op when the host can't use it:

| Source (in repo)                                                             | Deployed to                                                | Gated on                          | What it does |
|------------------------------------------------------------------------------|------------------------------------------------------------|-----------------------------------|--------------|
| `config/system/usr/lib/systemd/system-sleep/cyberpunk-suspend.sh`            | same path under `/`                                        | DMI chassis 8/9/10/14 (laptops)   | L2 — snapshots connected outputs pre-suspend, restarts `plasma-kscreen.service` on resume when outputs went missing (the T14 dock + Wayland re-enumerate bug). Journal tag `cyberpunk-suspend`. |
| `config/system/usr/local/bin/cyberpunk-dock-handler.sh` + `config/system/etc/udev/rules.d/95-cyberpunk-dock.rules` | same paths under `/`                                       | DMI chassis 8/9/10/14 (laptops)   | L6 — udev rule (Lenovo TB4 Dock Gen 1, `17ef:3082`; commented templates for other Lenovo docks + a broad-USB-hub escape hatch) fires the handler under `systemd-run --no-block --collect`. First plug learns the current layout to `~/.config/dotfiles/dock-layouts/<hash>.json`, subsequent plugs restore it; unplug falls back to internal-panel-only. Journal tag `cyberpunk-dock`. |
| `config/system/etc/environment.d/95-nvidia-wayland.conf`                     | same path under `/`                                        | `GPU_VENDOR=nvidia`               | D1 — sets `__GL_GSYNC_ALLOWED=1`, `__GL_VRR_ALLOWED=1`, `WLR_NO_HARDWARE_CURSORS=1`, `MOZ_ENABLE_WAYLAND=1`. Read by `pam_systemd` at graphical-session start; logout/login required. |
| (no file — `kwriteconfig6` writes `~/.config/kwinrc`)                        | `~/.config/kwinrc` `[Wayland] EnableExplicitSync=true`     | `--plasma` + `GPU_VENDOR=nvidia`  | D2 — opt-in for KWin 6.1.x; a documented no-op on 6.2+ where the protocol is already default-on with NVIDIA 555+. Always-write, no version-detection. |
| `config/plasma/kscreen-baseline.py`                                          | `~/.config/plasma/kscreen-baseline.py`                     | plasma + `kscreen-doctor` present | D3/D7/D8 — per-monitor mode + VRR + HDR baseline driver. CLI: `--snapshot` (capture current state to `~/.config/dotfiles/kscreen-baseline.json`, per-machine, NOT in repo), `apply` (default; silent no-op when no baseline), `--show`, `--reset`, `--enable-hdr <output>`, `--disable-hdr <output>`. `apply-theme.sh` calls `apply` after scale enforcement, then compares connected-output count to the baseline and `qdbus6 /KWin reconfigure`s on shortage; cross-machine baselines (different `machine_id`) skip recovery rather than locking it out. |
| `config/system/etc/systemd/resolved.conf.d/cyberpunk-dot.conf` + `config/system/etc/NetworkManager/conf.d/cyberpunk-dns.conf` | same paths under `/`                                       | `--harden`                        | X6 — DNS-over-TLS via systemd-resolved (opportunistic, DNSSEC=allow-downgrade). `harden_dot()` replaces the older `harden_dns` path; the conky HEALTH `DoT` row tracks the live state. |

---

## Repo layout

```
.
├── README.md                  ← you are here
├── readme/                    ← per-tool guides
├── vm_automation.py           ← remote VM setup over SSH
├── local_setup.sh             ← local-machine setup (Debian 12+)
├── config/                    ← all dotfiles, deployed to ~/.config/<name>
│   ├── apps/                  ← per-app TOML manifests (Phase 0 dispatcher input)
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
│   ├── plasma/                ← Plasma 6 / Wayland configs + apply-theme.sh + kscreen-baseline.py
│   ├── sddm/                  ← SDDM greeter theming
│   ├── system/                ← root-owned drop-ins (suspend hook, dock udev, NVIDIA env, resolved DoT, NM,
│   │                            apt keyrings under etc/apt/keyrings/, apt sources under etc/apt/sources.list.d/)
│   ├── gtk-2.0/, gtk-3.0/     ← GTK theme overrides
│   └── xorg.conf.d/           ← Hyper-V Xorg config
└── scripts/
    ├── xsession.sh            ← deployed to ~/.xsession
    ├── Xresources             ← deployed to ~/.Xresources
    ├── provision-server.sh    ← shell-only setup of a remote server over SSH
    ├── install-shell.sh       ← shell-only setup of THIS machine (online or --offline)
    ├── build-bundle.sh        ← builds bundle/ for `install-shell.sh --offline`
    ├── install-apps.sh        ← Phase 0 application-install dispatcher (reads config/apps/*.toml)
    ├── install-methods/       ← per-method adapters (apt, apt-pinned-repo, github-release, direct-deb)
    ├── verify-pins.sh         ← read-only pin verification (exit 0/1/2/3 = ok/stale/bad/typo)
    ├── refresh-pins.sh        ← periodic pin refresher (rewrites TOML in place, never commits)
    ├── refresh-keys.sh        ← manual, interactive, single-app keyring rotation
    ├── audit.sh               ← drift-diff vs ~/.config/conky/baseline-*.txt (cron-friendly; pins pseudo-baseline)
    ├── dotfiles-doctor.sh     ← one-page health report (DRIFT / SUPPLY CHAIN / SYSTEM / NETWORK / DEPLOY)
    ├── take-over-wifi.sh      ← hands wifi from ifupdown/iwd/wpa_supplicant to NM (--revert undoes)
    └── diagnose-wifi.sh       ← read-only wifi diagnostic dump (PSK-redacted)
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
