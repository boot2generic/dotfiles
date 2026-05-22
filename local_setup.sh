#!/usr/bin/env bash
# local_setup.sh                              ── Install Path A ──
#
# Provisions the *current* machine with the full desktop stack — runs
# locally, no SSH, no pexpect.  Two desktop paths:
#
#   • --desktop=i3      (default) — X11 + i3 + polybar + picom + rofi
#                         + dunst + lightdm + pulseaudio.  The
#                         original cyberpunk stack; behaviour is
#                         byte-identical to pre-Plasma versions of
#                         this script.
#   • --desktop=plasma            — KDE Plasma 6 on Wayland + KWin
#                         + sddm + pipewire + konsole + dolphin +
#                         kde-config-screenlocker.  Recommended on
#                         physical desktops with NVIDIA + multi-
#                         monitor / high-refresh-rate panels.
#
# All non-WM configs (alacritty, nvim, tmux, conky, wallpaper, zsh
# stack) carry over identically between the two paths.  See
# readme/plasma.md for the Plasma-specific details and NVIDIA-on-
# Wayland gotchas.
#
# Use case: you're sitting at the box you want to configure (laptop or
# desktop) and you want the FULL desktop install: drivers, fonts,
# display manager, hardening flow, the works.
#
# Compared to:
#   • Path B (vm_automation.py):     remote-via-SSH, full GUI.  Older,
#                                    intentionally not at full parity
#                                    with this script — see README's
#                                    "Feature-parity matrix".
#   • Path C (provision-server.sh):  remote-via-SSH, shell-only.
#   • Path D (install-shell.sh):     local, shell-only.  Subset of
#                                    what this script does.
#
# See README.md "Feature-parity matrix" for the full capability table.
#
# Supported: Debian 12 (bookworm), Debian 13 (trixie), and future Debian
# releases. Other distros are rejected — they tend to be missing packages
# (alacritty, fastfetch, hyperv-daemons) that the dotfiles assume.
#
# Auto-detects (PCI vendor IDs: 10de=NVIDIA, 1002=AMD, 8086=Intel):
#   • CPU vendor    : intel | amd | other            (microcode pkg)
#   • Virtualization : hyperv | vm (kvm/qemu/vmware/vbox/xen) | physical
#   • GPU vendor    : nvidia | amd | intel | none
# and installs the matching driver/agent stack:
#   • nvidia   → kernel module classified by PCI device ID:
#                 ≥ 0x1E00 (Turing+/RTX 20+) → nvidia-open-kernel-dkms;
#                 older silicon → proprietary `nvidia-driver`.  Falls
#                 back to proprietary if the open package isn't in apt.
#                 Always also: nvidia-driver-libs(:i386), libvulkan1
#                 (+:i386), mesa-vulkan-drivers (+:i386),
#                 libgl1-mesa-dri:i386, vulkan-tools, mesa-utils,
#                 nvidia-vaapi-driver, firmware-misc-nonfree,
#                 nvidia-settings.  i386 multiarch is enabled
#                 automatically.  GRUB gets nvidia-drm.modeset=1
#                 (with timestamped backup + update-grub +
#                 update-initramfs).  Optional: `--cuda`
#                 (nvidia-cuda-toolkit) and `--steam` (steam-installer).
#   • amd      → firmware-amd-graphics, libdrm-amdgpu1, mesa-va-drivers,
#                xserver-xorg-video-amdgpu, firmware-misc-nonfree,
#                amd64-microcode
#   • intel    → intel-media-va-driver  (the package was renamed from
#                `-non-free` in trixie; bookworm still has the legacy
#                name, but the script targets trixie+),
#                i965-va-driver, xserver-xorg-video-intel,
#                firmware-misc-nonfree, intel-microcode
#   • hyperv   → hyperv-daemons + Hyper-V Xorg config (10-hyperv.conf)
#   • vm       → qemu-guest-agent / open-vm-tools / virtualbox-guest-utils
#                depending on the detected hypervisor
#
# Non-free apt access (physical + GPU only) is granted via a deb822
# drop-in at /etc/apt/sources.list.d/dotfiles-non-free.sources — the
# base /etc/apt/sources.list / debian.sources is never edited in place.
# Removing the drop-in cleanly disables every component this script
# added.
#
# Does NOT install xrdp.  Install it manually if you want to inspect the
# desktop over RDP — `deploy` will pick up an existing xrdp install.
#
# Usage:
#   ./local_setup.sh                  # full setup, INTERACTIVE by default
#   ./local_setup.sh detect           # print detection summary and exit
#   ./local_setup.sh install          # apt install (base + drivers) only
#   ./local_setup.sh deploy           # deploy ./config → ~/.config
#   ./local_setup.sh terminal         # tmux/nvim/zsh stack only
#   ./local_setup.sh validate         # post-install checks
#   ./local_setup.sh harden           # OPT-IN: narrow sudo, ufw, auto security
#                                     #          updates, auditd rules,
#                                     #          systemd-resolved + DoT (Quad9)
#   ./local_setup.sh unharden         # revert harden (re-broaden sudoers etc.)
#   ./local_setup.sh --show-overrides # list per-host overrides currently in
#                                     # effect under ~/.config/dotfiles-local/
#
# Mode flags (only meaningful for `setup`):
#   --interactive | -i                Default — explain + confirm each stage.
#                                     Sudo password is requested ONCE at start.
#   --bypass | --yes | -y             Run end-to-end with no per-stage prompts.
#                                     Sudo password is also asked once at start.
#                                     (When stdin is not a TTY, --bypass is
#                                     forced automatically — keeps SSH + CI
#                                     pipelines unblocked.)
#
# Override flags (any subcommand):
#   --hyperv | --vm | --physical      Force virt type
#   --nvidia | --amd | --intel | --no-gpu
#                                     Force GPU vendor
#   --no-drivers                      Skip GPU driver install entirely
#   --cuda                            (NVIDIA + physical) also install
#                                     nvidia-cuda-toolkit (~3 GB).
#                                     For ML/CUDA development workloads.
#   --steam                           (NVIDIA + physical) also install
#                                     steam-installer (Debian's Steam
#                                     bootstrap).  Skip if you prefer
#                                     Flatpak Steam.
#   --desktop=i3 | --desktop=plasma   Select the desktop stack to
#                                     install + deploy + validate.
#                                     `--i3` and `--plasma` are
#                                     shorthand for the same.  Default
#                                     is i3.  Picking `plasma` swaps:
#                                       - apt set: plasma-desktop +
#                                         kwin-wayland + sddm +
#                                         pipewire + xwayland + …
#                                       - lightdm → sddm
#                                       - pulseaudio → pipewire-pulse
#                                       - i3/polybar/picom/rofi/dunst
#                                         configs → plasma equivalents
#                                       - On NVIDIA + physical: extra
#                                         kernel-cmdline + initramfs
#                                         + modprobe.d + systemd
#                                         pieces for Wayland-safe
#                                         suspend/resume.
#   --no-nix                          Skip the Nix package manager
#                                     install.  Default is to install
#                                     Nix in multi-user (daemon) mode +
#                                     direnv + nix-direnv for per-
#                                     project flake-based dev shells.
#                                     Apt remains the system PM either
#                                     way.
#   --no-wifi-takeover                After all other phases finish,
#                                     `setup` checks whether wifi is
#                                     `unmanaged` (Debian installer
#                                     parked it under ifupdown +
#                                     wpa_supplicant) AND whether
#                                     credentials are recoverable from
#                                     /etc/network/interfaces.  If both,
#                                     it runs scripts/take-over-wifi.sh
#                                     to hand the device to NM so
#                                     polybar's wlan pill works.
#                                     The takeover pre-imports the SSID
#                                     and PSK into NM BEFORE stopping
#                                     wpa_supplicant, so the network
#                                     reconnects automatically — no
#                                     stranded sessions.  Pass this
#                                     flag to skip that step (e.g. on
#                                     a system where you've already
#                                     done it manually, or where wifi
#                                     creds live somewhere else).
#
# Environment variables:
#   DOTFILES_NO_LOCAL=1                Disable the ~/.config/dotfiles-local/
#                                     overlay for one run.  Useful when
#                                     debugging — confirms whether a
#                                     misbehaviour is in the repo configs
#                                     or in your per-host overrides.
#

set -euo pipefail

# ============================================================
# Paths and constants
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="${SCRIPT_DIR}/config"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
# Per-run private log dir.  Was `${TMPDIR:-/tmp}` (world-readable, predictable
# names) — the install drops ~30 logs (apt_install_*.log, nvim_lazy.log,
# nerd-fonts-sha256.txt, etc.) into LOG_DIR, and several contain package /
# mirror metadata you don't necessarily want readable by other local users.
# mktemp -d creates the dir mode 0700 already on Debian; chmod 700 is belt-and-
# braces.  Dir is INTENTIONALLY kept after the run for postmortem (it lives
# under TMPDIR which tmpfiles.d cleans on reboot anyway).
LOG_DIR="$(mktemp -d -t dotfiles-setup.XXXXXX)" \
    || { echo "[!!] mktemp -d failed — cannot continue" >&2; exit 1; }
chmod 700 "$LOG_DIR" 2>/dev/null || true

# Colour helpers (only when stdout is a TTY)
if [[ -t 1 ]]; then
  C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'
  C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
  C_OK= ; C_WARN= ; C_ERR= ; C_DIM= ; C_RST=
fi

log()  { echo "${C_DIM}[*]${C_RST} $*"; }
ok()   { echo "${C_OK}[ok]${C_RST} $*"; }
warn() { echo "${C_WARN}[!]${C_RST} $*" >&2; }
err()  { echo "${C_ERR}[!!]${C_RST} $*" >&2; }
die()  { err "$*"; exit 1; }

# ============================================================
# Sanity checks
# ============================================================
if [[ $EUID -eq 0 ]]; then
  die "Run as a regular user — sudo will be invoked where needed."
fi
command -v apt-get >/dev/null 2>&1 || die "apt-get not found — Debian only."
command -v sudo    >/dev/null 2>&1 || die "sudo not installed."

# Distro guard: Debian 12+ only. Reading /etc/os-release is canonical.
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
else
  die "/etc/os-release missing — cannot identify distro."
fi
if [[ "${ID:-}" != "debian" ]]; then
  die "Unsupported distro: ID=${ID:-unknown}. This script supports Debian 12+ only."
fi
DEB_MAJOR="${VERSION_ID%%.*}"
if [[ -z "$DEB_MAJOR" ]] || (( DEB_MAJOR < 12 )); then
  die "Unsupported Debian version: ${VERSION_ID:-unknown}. Need Debian 12 or newer."
fi
log "Debian ${VERSION_ID:-?} (${VERSION_CODENAME:-?}) detected"

ensure_sudo() {
  # Fast path: NOPASSWD already grants access — no TTY, no keepalive needed.
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  # Otherwise prime creds once so subsequent calls don't reprompt mid-run.
  # `sudo -v` needs a TTY when `Defaults use_pty` is set, which is the
  # default on Ubuntu/Debian — so this path only works in interactive runs.
  sudo -v || die "sudo authentication failed (configure NOPASSWD or run interactively)."
  # BOUNDED keepalive: the old `while true; do … sleep 60; done` would
  # outlive a `kill -9` of the parent (the EXIT trap doesn't fire on
  # SIGKILL) and keep refreshing sudo's timestamp until next reboot.
  # Cap at SUDO_KEEPALIVE_MINUTES (default 90) — long enough for the
  # slowest end-to-end install (nvidia + nvim + everything), short
  # enough that an orphaned keepalive isn't an indefinite leak.
  local minutes="${SUDO_KEEPALIVE_MINUTES:-90}"
  ( for _ in $(seq 1 "$minutes"); do sudo -n true 2>/dev/null || exit 0; sleep 60; done ) &
  SUDO_KEEPALIVE_PID=$!
  # Trap HUP/INT/TERM in addition to EXIT so common kill paths (Ctrl-C,
  # `kill <pid>`, ssh disconnect → SIGHUP) also reap the child.  `kill -9`
  # remains uncatchable, but the bounded loop above caps that scenario.
  trap '[[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT HUP INT TERM
}

# ============================================================
# Hardware / virtualization detection
# ============================================================
# Sets globals: VIRT_TYPE (hyperv|vm|physical), VM_HYPERVISOR (kvm/qemu/...
# or empty), GPU_VENDOR (nvidia|amd|intel|none).

detect_virt() {
  # Map systemd-detect-virt's output to our three coarse categories:
  #   • hyperv   — Microsoft Hyper-V / Azure (special Xorg config needed)
  #   • vm       — any other virt (kvm/qemu/vmware/vbox/xen/lxc/…)
  #   • physical — bare metal (only category that uses GPU drivers)
  local virt
  virt="$(systemd-detect-virt 2>/dev/null || echo none)"
  VM_HYPERVISOR="$virt"
  case "$virt" in
    microsoft) VIRT_TYPE="hyperv" ;;
    none)      VIRT_TYPE="physical" ;;
    *)         VIRT_TYPE="vm" ;;
  esac

  # Cross-check via DMI: some Hyper-V images don't expose "microsoft" via
  # systemd-detect-virt but DO set the DMI vendor/product fields, so we
  # double-check those before declaring the box "physical".
  local vendor product
  vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo)"
  product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo)"
  if [[ "$VIRT_TYPE" == "physical" ]]; then
    if [[ "${vendor,,}" == *microsoft* || "${product,,}" == *"virtual machine"* ]]; then
      VIRT_TYPE="hyperv"; VM_HYPERVISOR="microsoft"
    fi
  fi
  DMI_VENDOR="$vendor"
  DMI_PRODUCT="$product"
}

ensure_detection_tools() {
  # Hardware detection runs BEFORE the base apt install, so on a pristine
  # Debian box `lspci` and `dmidecode` may not exist yet.  Without them
  # `detect_gpu` would mis-report `GPU_VENDOR=none` on an actual GPU box,
  # silently skipping driver install.  Bootstrap the two tiny detection
  # tools up front if they're missing.
  if ! command -v lspci >/dev/null 2>&1 || ! command -v dmidecode >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      log "Installing pciutils + dmidecode (needed for hardware detection) …"
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        pciutils dmidecode >"${LOG_DIR}/apt_detection_tools.log" 2>&1 || \
        warn "could not install detection tools — GPU detection may misread"
    else
      warn "detection tools missing and no sudo — GPU detection may misread"
    fi
  fi
}

detect_gpu() {
  # Inspect every PCI device whose class is VGA / 3D / Display and pick
  # the first vendor we recognise.  Order matters: we prefer
  # nvidia → amd → intel, since on a hybrid graphics laptop the
  # discrete GPU is usually the one we want drivers for.
  #
  # We match by VENDOR PCI ID (the 4-hex prefix in `[vendor:device]`),
  # NOT by vendor *name*, because the previous text match ('amd|ati')
  # falsely hit every line containing "compatible" — `lspci -nn` always
  # prints "VGA compatible controller", which contains the substring
  # "ati".  The vendor IDs are stable forever.
  #
  # Vendor IDs:  NVIDIA = 10de   AMD/ATI = 1002   Intel = 8086
  local pci
  pci="$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display' || true)"
  GPU_RAW="$pci"
  if   echo "$pci" | grep -qE '\[10de:'; then GPU_VENDOR="nvidia"
  elif echo "$pci" | grep -qE '\[1002:'; then GPU_VENDOR="amd"
  elif echo "$pci" | grep -qE '\[8086:'; then GPU_VENDOR="intel"
  else                                        GPU_VENDOR="none"
  fi
}

classify_nvidia_gen() {
  # Map an NVIDIA GPU to "open" (Turing+) vs "proprietary" (Pascal-) by
  # its PCI device ID, which detect_gpu() captured into $GPU_RAW via
  # `lspci -nn`.  Format of a relevant line:
  #
  #   01:00.0 VGA compatible controller [0300]: NVIDIA Corporation
  #     GA102 [GeForce RTX 3090] [10de:2204] (rev a1)
  #
  # We pull the four-hex-digit device id after `10de:` and compare it
  # against 0x1E00.  Turing's first id is 0x1E02 (TU102); everything
  # numerically >= 0x1E00 in NVIDIA's allocation is Turing or newer.
  # Falls back to "proprietary" on any parse failure — strictly safer
  # than installing the open module on a GPU it doesn't support.
  local id_hex id_dec
  # `|| true` swallows grep's exit-1 on no match — set -o pipefail
  # would otherwise abort the whole script when this function is
  # unexpectedly called on a non-NVIDIA GPU_RAW.
  id_hex="$(echo "${GPU_RAW:-}" \
              | grep -oE '\[10de:[0-9a-fA-F]{4}\]' \
              | head -1 \
              | tr -d '[]' \
              | awk -F: '{print tolower($2)}' || true)"
  if [[ -z "$id_hex" ]]; then
    echo "proprietary"
    return
  fi
  id_dec=$(printf '%d' "0x${id_hex}" 2>/dev/null || echo 0)
  if (( id_dec >= 7680 )); then   # 0x1E00
    echo "open"
  else
    echo "proprietary"
  fi
}

detect_cpu() {
  # CPU vendor drives whether we install thermald (Intel-only thermal
  # daemon) — on AMD the dameon is a no-op, so we skip it to keep the
  # apt graph minimal.  /proc/cpuinfo is always present and parsable.
  local vendor
  vendor="$(awk -F: '/^vendor_id/ {gsub(/ /,"",$2); print $2; exit}' \
              /proc/cpuinfo 2>/dev/null)"
  case "${vendor:-}" in
    GenuineIntel) CPU_VENDOR="intel" ;;
    AuthenticAMD) CPU_VENDOR="amd"   ;;
    *)            CPU_VENDOR="other" ;;
  esac
}

print_hardware() {
  echo
  log "Detection summary"
  printf "    %-12s %s\n" "Virt type"   "$VIRT_TYPE"
  printf "    %-12s %s\n" "Hypervisor"  "${VM_HYPERVISOR:-n/a}"
  printf "    %-12s %s\n" "DMI vendor"  "${DMI_VENDOR:-unknown}"
  printf "    %-12s %s\n" "DMI product" "${DMI_PRODUCT:-unknown}"
  printf "    %-12s %s\n" "GPU vendor"  "$GPU_VENDOR"
  printf "    %-12s %s\n" "CPU vendor"  "${CPU_VENDOR:-unknown}"
  printf "    %-12s %s\n" "Desktop"     "${DESKTOP:-i3}"
  if [[ -n "${GPU_RAW:-}" ]]; then
    while IFS= read -r line; do
      printf "    %-12s %s\n" "  PCI" "${line:0:90}"
    done <<<"$GPU_RAW"
  fi
  echo
}

# ============================================================
# Package lists  (kept in sync with vm_automation.py BASE_PACKAGES)
# ============================================================
BASE_PACKAGES=(
  # Terminal emulator (used as the default terminal under both desktops)
  alacritty
  # Fonts
  fonts-jetbrains-mono fonts-font-awesome
  fonts-material-design-icons-iconfont
  # GTK themes + icons (GTK apps run under either desktop)
  adwaita-icon-theme papirus-icon-theme
  # Web browser — Debian ships Firefox as `firefox-esr` (not `firefox`).
  # The i3 Mod+b binding launches firefox-esr directly.  To swap, edit
  # the binding in ~/.config/i3/config after installing your alternate
  # (mullvad-browser, chromium, …).
  firefox-esr
  # MPRIS media-key controller — same tool drives the i3 media scripts
  # and Plasma's media-key shortcuts.  Player-agnostic (Spotify, mpv,
  # Firefox, VLC, …).
  playerctl
  # WireGuard VPN — userland (`wg`, `wg-quick`).  Drop a config into
  # /etc/wireguard/<name>.conf and `sudo wg-quick up <name>`.  Kernel
  # module ships in modern Debian kernels, no DKMS needed.
  wireguard wireguard-tools
  # NetworkManager backbone — shared by both desktops.  The X11
  # `nm-applet` (network-manager-gnome) lives in DESKTOP_I3_PACKAGES;
  # Plasma uses `plasma-nm` in DESKTOP_PLASMA_PACKAGES instead.
  network-manager
  # Brightness control — works under both X11 and Wayland.
  brightnessctl
  # Network diagnostics + radio toggle.  `iw` exposes signal/bitrate/SSID
  # for low-level wifi troubleshooting (`iw dev wlan0 link`); `rfkill`
  # backs the XF86WLAN keybind that toggles the wireless radio.
  iw rfkill
  # Battery / power management.  TLP is the canonical ThinkPad win:
  # default profile drops idle power 20-40% with no user config.
  # `acpi` gives a one-line battery summary used by polybar's fallback;
  # `powertop` is on-demand only (run `sudo powertop` to audit drains).
  tlp tlp-rdw acpi powertop btop
  # Terminal stack
  tmux neovim zsh fzf ripgrep fd-find
  # build-essential = gcc + g++ + make + libc6-dev — required to compile
  # telescope-fzf-native and treesitter parsers
  build-essential
  nodejs npm
  # Shell tools
  rsync curl wget git htop fastfetch
  # Pretty CLI — conky-all stays in common; it runs under Xwayland on
  # the plasma path via a kwin rule (see patch_conky_window_type).
  bat grc net-tools lm-sensors conky-all iproute2
  # Detection helpers
  pciutils dmidecode
  # Firmware updates via LVFS — `fwupdmgr refresh && fwupdmgr get-updates`
  # surfaces vendor BIOS/EC updates on Lenovo / Dell / Framework /
  # Gigabyte / etc.  Installing the package alone has no effect; it's
  # the user's call whether to actually apply pending updates.  Tiny
  # package, harmless in a VM.
  fwupd
  # Storage health monitoring.  Both packages are tiny and become
  # essential the moment the user has more than one drive.
  #   smartmontools — `smartctl -a /dev/sdX` reports SMART attributes.
  #   nvme-cli      — `nvme list`, `nvme smart-log /dev/nvmeXn1`.
  smartmontools nvme-cli
  # direnv — auto-loads a per-directory environment when you `cd` into
  # a project.  Paired with `nix-direnv` (installed by install_nix
  # later) this turns `flake.nix` files into transparent dev shells.
  direnv
  # Archive tools — Mason needs `unzip` to extract clangd's release zip.
  unzip
  # X11 utilities — useful as diagnostics under Plasma too (xprop /
  # xwininfo work against Xwayland clients).
  x11-utils
)

# DESKTOP_I3_PACKAGES — installed only when DESKTOP=i3 (default).
# X11 server + WM + compositor + bar + launcher + notifications + DM +
# lockscreen + file manager + pulseaudio audio stack.  Plasma users
# don't get any of these — KWin/Plasma/sddm/dolphin/kscreenlocker
# from DESKTOP_PLASMA_PACKAGES replace them.
DESKTOP_I3_PACKAGES=(
  # X server + display infrastructure
  xorg xserver-xorg x11-xserver-utils xinit xvfb dbus-x11
  # WM + compositor + bar + launcher (all X11-only)
  i3 polybar picom rofi
  # Notifications
  dunst libnotify-bin
  # Display manager
  lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings
  # Wallpaper + screenshots
  feh scrot
  # GTK theming UI
  lxappearance
  # File manager + X11 network-applet (tray)
  thunar gvfs network-manager-gnome
  # Audio (PulseAudio + GTK mixer UI)
  pulseaudio pavucontrol
  # X11-only utilities + lockscreen
  numlockx arandr xclip xdotool
  i3lock imagemagick python3-pil
  # WM diagnostics
  wmctrl
)

# DESKTOP_PLASMA_PACKAGES — installed only when DESKTOP=plasma.
# Wayland-native KDE Plasma 6 stack with SDDM, PipeWire audio, Qt
# Wayland support, and a small set of native KDE apps that integrate
# via KIO/KWallet.  Plasma's panel + KNotifications + KRunner +
# kscreenlocker replace polybar/dunst/rofi/i3lock — none of those
# X11 packages are installed on this path.
#
# NOT included — KWin tiling scripts (Polonium / Bismuth / Krohnkite).
# Polonium is the actively-maintained i3-style tiling KWin script for
# Plasma 6, but as of Debian Trixie it is NOT packaged in apt
# (`apt-cache search ^polonium` returns nothing; Bismuth was dropped
# during the Plasma 5→6 transition).  We deliberately do NOT pull in
# a tiling layer from a third-party source (KDE Store ZIP, GitHub
# release tarball) because:
#   • There's no signed-package update path — drift between users.
#   • Polonium claims Meta+H/V/F/M/etc., which collides with our
#     Meta+1..4 / Meta+Q / Meta+Return / Meta+. bindings and would
#     either re-fight the kglobalaccel conflict resolver every
#     session or silently demote our keys.
#   • The cyberpunk dotfiles already give an i3-flavoured workflow
#     via four virtual desktops + Meta-prefix hotkeys; floating
#     window placement is the only piece that differs from i3.
# If a future Debian release ships Polonium, add it here and document
# which Meta+ keys it claims by default in readme/plasma.md.
DESKTOP_PLASMA_PACKAGES=(
  # Core Plasma 6 desktop.  Both compositor backends are installed:
  #   • kwin-wayland — the default + headline target (NVIDIA + multi-
  #                    monitor + high-refresh).
  #   • kwin-x11     — fallback when KMS is unreliable.  Specifically:
  #                    - Hyper-V Generation 2 VMs without Enhanced
  #                      Session work-around
  #                    - VirtualBox with default VBoxVGA (no KMS)
  #                    - Older Intel/AMD iGPUs (pre-Skylake/Vega)
  #                    Without kwin-x11 installed, /usr/share/xsessions/
  #                    plasmax11.desktop is listed in SDDM but launching
  #                    it fails (no compositor).  Small download, big UX
  #                    payoff for VM users.
  plasma-desktop plasma-workspace plasma-workspace-data
  kwin-wayland kwin-x11 kwin-style-breeze
  # Display manager (replaces lightdm)
  sddm sddm-theme-breeze
  # Wayland support — Xwayland for legacy X11 apps (incl. conky), Qt
  # Wayland platform plugin for Qt apps.
  xwayland qt6-wayland
  # PipeWire audio stack — pipewire-pulse provides the pulseaudio
  # client-library shim, so existing pulseaudio clients (pactl, mpv,
  # firefox) keep working.  apt's Conflicts/Replaces resolution will
  # remove pulseaudio when this set lands.
  pipewire pipewire-pulse wireplumber pavucontrol-qt
  # Wayland clipboard CLI (wl-copy / wl-paste) — replaces xclip
  wl-clipboard
  # Screenshot tool (KWin-integrated) — replaces scrot
  kde-spectacle
  # Native KDE apps — light footprint; integrate with KIO/KWallet.
  konsole dolphin kwallet6 polkit-kde-agent-1
  # Lock screen daemon — replaces i3lock.
  kde-config-screenlocker
  # plasma-apply-* live here; used by config/plasma/apply-theme.sh.
  kde-cli-tools
  # kdialog — rendering target for config/plasma/cheatsheet.sh (the
  # Meta+/ "cyberpunk hotkey cheatsheet" popup that lists our shipped
  # global shortcuts).  Not in kde-cli-tools on Debian Trixie (it
  # ships as its own package).  cheatsheet.sh degrades to a terminal
  # printout if kdialog is missing, so install doesn't hard-fail —
  # but the popup UX requires this package.
  kdialog
  # qdbus6 binary — apply-theme.sh uses it to send a plasma-script over
  # the org.kde.plasmashell D-Bus interface to set panel height +
  # autohide.  Without it, the panel-resize step is skipped silently
  # and the user gets the default 44 px taskbar.
  qdbus-qt6
  # python3-dbus — apply-theme.sh batches every kglobalaccel
  # setShortcut call through config/plasma/kga_push.py, which opens
  # ONE D-Bus session connection and drives every setShortcut down it.
  # The previous implementation forked dbus-send 17 times per session
  # start (~170 ms wall clock); the Python helper is ~25-35 ms.  If
  # python3-dbus is missing, apply-theme.sh falls back to the legacy
  # dbus-send loop transparently, so install does not hard-fail — but
  # the fast path requires this package.
  python3-dbus
  # kquitapp6 / kstart6 live in libkf6dbusaddons-bin on Debian Trixie
  # (NOT in kde-cli-tools — the Debian split surprises plasma users
  # coming from Arch).  apply-theme.sh uses them to live-reload
  # kglobalaccel after writing kglobalshortcutsrc, so the new
  # Meta+1..4 / Meta+Return bindings take effect without a logout.
  libkf6dbusaddons-bin
  # kwriteconfig6 — used by deploy_phase to MERGE our shipped
  # kglobalshortcutsrc keys into the user's existing one (rather than
  # overwriting and nuking the dozens of plasma factory bindings the
  # user actively relies on: volume keys, media keys, Sleep, KRunner).
  # It also drives a few other surgical config touches in apply-theme.
  # Already pulled in transitively by powerdevil's dep chain on most
  # systems, but listing it explicitly guards against future split.
  libkf6config-bin
  # UPower — registers the org.freedesktop.UPower D-Bus service that
  # powerdevil queries for battery + lid + adapter state.  Critically,
  # `powerdevil` does NOT Recommends: upower (it Recommends:
  # power-profiles-daemon — which we explicitly DO NOT want, because it
  # conflicts with TLP), so apt's --no-install-recommends doesn't help
  # and the dependency must be listed by name.  Without UPower the
  # symptoms on a T14 (or any laptop) are:
  #   • Battery widget shows "no batteries detected"
  #   • Lid-close action does nothing
  #   • Screen never blanks / suspends on idle
  #   • powerdevil's journal floods with "org.freedesktop.UPower was
  #     not provided by any .service files"
  # No-op on the desktop (3080 Ti box) — UPower happily reports an
  # empty device list when there's no battery, and the AC-adapter info
  # it provides is still useful for sleep events.
  upower
  # Theming — Plasma side + GTK app integration so firefox / thunderbird
  # / GIMP etc. render with the active Plasma color scheme rather than
  # falling back to plain Adwaita.
  breeze breeze-cursor-theme breeze-icon-theme kf6-breeze-icon-theme
  breeze-gtk-theme kde-config-gtk-style
  # System monitor (Plasma-native, replaces polybar CPU/mem modules)
  plasma-systemmonitor
  # Plasma system-tray applets — network + audio.
  plasma-nm plasma-pa
  # CRITICAL Recommends of plasma-desktop that --no-install-recommends
  # in apt_install drops.  Without these, the user gets a broken-feeling
  # Plasma install:
  #   • systemsettings    — the actual System Settings application.
  #                          Without it there is NO GUI for any Plasma
  #                          config.  Mandatory.
  #   • kscreen           — display-config KCM in System Settings.
  #                          Without it the user cannot set monitor
  #                          refresh rate / scale / position / arrangement
  #                          (kscreen-doctor CLI is the only fallback).
  #                          This is the headline 3080 Ti use case —
  #                          mandatory.
  #   • powerdevil        — power management daemon.  Battery widget,
  #                          lid action, suspend-on-idle, screen-blank
  #                          timeout — all gone without it.  Mandatory
  #                          on laptops (T14); useful on desktops.
  #   • kde-config-sddm   — System Settings → SDDM page.  Configure
  #                          autologin / session default / theme via GUI.
  #   • xdg-desktop-portal-kde — portal API so Flatpak + GTK file
  #                          dialogs use the Plasma file picker /
  #                          screenshot picker / file open native UI.
  #   • kinfocenter       — System Settings → About this system.  Quick
  #                          NVIDIA driver version / OpenGL / Vulkan
  #                          info — handy 3080 Ti diagnostics.
  #   • bluedevil         — Bluetooth applet + KCM.  T14 needs it.
  #   • kio-extras        — Dolphin support for sftp:// / smb:// /
  #                          fish:// / mtp:// — remote file access.
  #   • ksshaskpass       — GUI prompt for SSH key passphrase via
  #                          kwallet.  No effect for keys without
  #                          passphrases; nice UX for keys with.
  systemsettings kscreen powerdevil kde-config-sddm
  xdg-desktop-portal-kde kinfocenter bluedevil kio-extras ksshaskpass
)

# Driver / agent packages by detected category
#
# Two Nvidia kernel-module paths:
#   • "open"        — Turing (RTX 20-series, GTX 16-series) and newer.
#                     Uses NVIDIA's open-source kernel module.  Required
#                     for KMS + Wayland on modern setups; preferred on
#                     X11 too.  Package: nvidia-open-kernel-dkms.
#   • "proprietary" — Maxwell, Pascal, Volta and older.  The open
#                     module does not support these GPUs at all.
#                     Package: nvidia-driver (legacy closed module).
# Generation is classified at install time by classify_nvidia_gen()
# from the PCI device ID — no static array of GPU names to maintain.
#
# In addition, on physical NVIDIA boxes we install a gaming + workstation
# userland (NVIDIA_PACKAGES_GAMING) — see comments on that array.
NVIDIA_PACKAGES_OPEN=(nvidia-open-kernel-dkms nvidia-driver-libs nvidia-settings)
NVIDIA_PACKAGES_PROP=(nvidia-driver nvidia-settings)

# Gaming + workstation userland for NVIDIA on physical hardware.
# Requires i386 multiarch (enable_i386_arch); driver_packages_for()
# refuses to add this list otherwise so apt doesn't fail on :i386 deps.
#
# What each piece does:
#   - nvidia-driver-libs:i386      32-bit libGL/libEGL/Vulkan ICD —
#                                  REQUIRED for Steam, Proton, Wine,
#                                  DXVK/VKD3D, and any 32-bit game.
#   - libvulkan1 / libvulkan1:i386 native + 32-bit Vulkan loader.
#   - mesa-vulkan-drivers          software Vulkan (lavapipe) — used as
#   - mesa-vulkan-drivers:i386     a fallback by Vulkan loaders so that
#                                  non-NVIDIA Vulkan-only apps don't
#                                  fail to find ANY ICD.
#   - vulkan-tools                 vulkaninfo / vkcube — diagnostics.
#   - nvidia-vaapi-driver          NVDEC → VA-API shim.  Lets Firefox,
#                                  Chromium, mpv hardware-decode H.264,
#                                  HEVC, AV1 on the GPU instead of CPU.
#                                  Cuts CPU usage on YouTube to 1-2%.
#   - firmware-misc-nonfree        misc firmware (occasional NVIDIA
#                                  microcode requires this).
#   - libgl1-mesa-dri:i386         32-bit Mesa GL — DRI fallback for
#                                  apps that bypass libGLX_nvidia.
#
# We deliberately do NOT install:
#   - nvidia-cuda-toolkit          large; opt in with --cuda.
#   - steam-installer              Debian's Steam launcher; opt in with
#                                  --steam (you may prefer Flatpak).
NVIDIA_PACKAGES_GAMING=(
  nvidia-driver-libs:i386
  libvulkan1 libvulkan1:i386
  mesa-vulkan-drivers mesa-vulkan-drivers:i386
  libgl1-mesa-dri:i386
  vulkan-tools
  mesa-utils                # glxinfo / glxgears for OpenGL diagnostics
  nvidia-vaapi-driver
  firmware-misc-nonfree
)
NVIDIA_PACKAGES_CUDA=(nvidia-cuda-toolkit)
# steam-installer pulls in 32-bit deps automatically.  gamemode is the
# Feral Interactive daemon that auto-tunes CPU governor + I/O priority
# when a launched process calls into libgamemode (Steam Proton honors it
# via the `gamemoderun %command%` launch wrapper) — meaningful FPS
# uplift on Ryzen + Nvidia gaming setups, no-op when nothing's calling
# in.  Bundling with --steam since both are gaming-tier packages.
NVIDIA_PACKAGES_STEAM=(steam-installer gamemode)
AMD_PACKAGES=(firmware-amd-graphics libdrm-amdgpu1 mesa-va-drivers
              xserver-xorg-video-amdgpu firmware-misc-nonfree)
# Intel (T14 iGPU and similar):
#   • intel-media-va-driver  — VA-API driver for Gen8+ iGPUs (UHD/Iris
#     Xe).  Was named `intel-media-va-driver-non-free` in Debian 12;
#     renamed and moved to `main` in Debian 13.  Required for hardware
#     video decode/encode in mpv, Firefox (with VA-API enabled), etc.
#   • i965-va-driver         — Legacy Gen3-Gen7 iGPUs.  Cheap to add
#                              and harmless on newer hardware.
#   • xserver-xorg-video-intel — Xorg DDX driver.  Optional on modern
#                              kernels (modesetting works), but having
#                              it lets users opt in via Xorg.conf.
#   • firmware-misc-nonfree  — Intel iGPU firmware blobs (needed for
#                              full functionality on many SKUs).
#                              Lives in non-free-firmware.
#   • intel-microcode        — CPU microcode updates (Spectre/Meltdown
#                              mitigations etc.).  Lives in
#                              non-free-firmware.
INTEL_PACKAGES=(intel-media-va-driver i965-va-driver
                xserver-xorg-video-intel firmware-misc-nonfree)
HYPERV_PACKAGES=(hyperv-daemons)
QEMU_PACKAGES=(qemu-guest-agent spice-vdagent xserver-xorg-video-qxl)
VMWARE_PACKAGES=(open-vm-tools open-vm-tools-desktop xserver-xorg-video-vmware)
VBOX_PACKAGES=(virtualbox-guest-utils virtualbox-guest-x11)

# Per-CPU-vendor packages.  Two distinct concerns here:
#
#   1. CPU MICROCODE (security-critical, every physical machine).
#      Installs Spectre/Meltdown mitigations + post-release CPU bug
#      fixes (Zenbleed, Reptar, Downfall, etc.) loaded by the kernel
#      at early boot.  Decoupled from GPU vendor — a Ryzen 3950x +
#      RTX 3080 Ti box still needs amd64-microcode even though
#      GPU_VENDOR=nvidia.  Lives in non-free-firmware.
#
#   2. Thermal/power daemons (Intel-only).  thermald reads MSRs that
#      only exist on Intel CPUs; on AMD it's a no-op so we skip it.
#      Pointless inside a VM (no hardware thermals exposed).
INTEL_CPU_MICROCODE=(intel-microcode)
AMD_CPU_MICROCODE=(amd64-microcode)
INTEL_CPU_PACKAGES=(thermald)

# ============================================================
# Install phase
# ============================================================
apt_update() {
  log "apt update …"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq \
    >"${LOG_DIR}/apt_update.log" 2>&1 \
    || { tail -20 "${LOG_DIR}/apt_update.log"; die "apt update failed"; }
}

apt_install() {
  local label="$1"; shift
  local pkgs=("$@")
  [[ ${#pkgs[@]} -eq 0 ]] && return 0
  log "Installing ${label} (${#pkgs[@]} packages) …"
  if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
       --no-install-recommends "${pkgs[@]}" \
       >"${LOG_DIR}/apt_install_${label}.log" 2>&1; then
    ok "${label} installed"
  else
    tail -30 "${LOG_DIR}/apt_install_${label}.log"
    err "${label} install failed — see ${LOG_DIR}/apt_install_${label}.log"
    return 1
  fi
}

enable_i386_arch() {
  # Steam, Proton, Wine, and most older Linux-native games are 32-bit.
  # On Debian, multiarch is opt-in: i386 packages are only resolvable
  # after `dpkg --add-architecture i386` and a subsequent `apt update`.
  # We do this BEFORE apt_update so the index already lists i386
  # candidates by the time the gaming-userland install runs.
  #
  # Idempotent: dpkg --print-foreign-architectures lists what's already
  # active, so we no-op on re-runs.
  if dpkg --print-foreign-architectures 2>/dev/null \
       | grep -qx 'i386'; then
    ok "i386 multiarch already enabled"
    return 0
  fi
  log "Adding i386 multiarch (Steam, 32-bit Vulkan/GL libs) …"
  sudo dpkg --add-architecture i386 \
    && ok "i386 architecture added (apt_update will refresh the index)" \
    || { warn "dpkg --add-architecture i386 failed"; return 1; }
}

enable_nonfree() {
  # Enable contrib + non-free + non-free-firmware as an additive
  # deb822-format drop-in at /etc/apt/sources.list.d/dotfiles-non-free.sources.
  # Required for nvidia-driver and some firmware blobs.
  #
  # Why a drop-in instead of editing /etc/apt/sources.list in place:
  #   • Debian 13's installer can produce either legacy `.list` or modern
  #     `.sources` (deb822) base files; the previous in-place sed only
  #     handled both via two branches and was easy to break.
  #   • A single drop-in is purely additive — apt reads sources.list AND
  #     every *.sources file in sources.list.d/, so we never touch the
  #     base config.  Removing the drop-in fully reverses the change.
  #   • A typo can't wedge `apt update` for the base sources.
  #
  # SECURITY: the drop-in is owned by root (via sudo install) and is the
  # only file we add.  No backups required since we never modify any
  # existing apt source; a partial failure leaves the system in its
  # original state.  Auto-prune of old *.bak.* (created by the previous
  # in-place edit) keeps things tidy after upgrade.
  sudo find /etc/apt -maxdepth 2 -name '*.bak.*' -mtime +30 -delete \
    2>/dev/null || true

  local drop=/etc/apt/sources.list.d/dotfiles-non-free.sources
  if [[ -f "$drop" ]] \
     && grep -q 'non-free-firmware' "$drop" 2>/dev/null \
     && grep -q 'non-free' "$drop" 2>/dev/null \
     && grep -q 'contrib' "$drop" 2>/dev/null; then
    ok "non-free drop-in already present at $drop"
    return 0
  fi

  local codename
  codename="${VERSION_CODENAME:-}"
  if [[ -z "$codename" ]]; then
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  fi
  if [[ -z "$codename" ]]; then
    warn "could not determine Debian codename; refusing to write apt drop-in"
    return 1
  fi

  log "Adding contrib/non-free/non-free-firmware drop-in: ${drop}"
  # URIs use https://.  apt's signing (Signed-By:) already protects
  # against tampering; https additionally hides which Debian packages
  # you're installing from passive on-path observers (ISP, captive
  # portal, coffee-shop wifi, etc.).  deb.debian.org and
  # security.debian.org both have valid HTTPS certs.
  sudo tee "$drop" >/dev/null <<EOF
# Managed by local_setup.sh (enable_nonfree).
# Adds contrib + non-free + non-free-firmware components additively, so
# the base /etc/apt/sources.list (or /etc/apt/sources.list.d/debian.sources)
# is never modified.  Remove this file to disable:
#   sudo rm /etc/apt/sources.list.d/dotfiles-non-free.sources && sudo apt update
Types: deb
URIs: https://deb.debian.org/debian
Suites: ${codename} ${codename}-updates
Components: contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: ${codename}-security
Components: contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  sudo chmod 0644 "$drop"
  ok "non-free drop-in installed at $drop"
}

driver_packages_for() {
  # Echo the package list for the detected GPU + virt + CPU combo.
  local pkgs=()

  case "$GPU_VENDOR" in
    nvidia)
      local gen; gen="$(classify_nvidia_gen)"
      # On Turing+ we want the open-kernel module, but the package name
      # has churned across Debian releases.  If the apt index doesn't
      # know `nvidia-open-kernel-dkms` (e.g. older release, alternate
      # package naming, non-free not yet refreshed), silently fall back
      # to the proprietary stack rather than crash the install.
      if [[ "$gen" == "open" ]] \
         && apt-cache show nvidia-open-kernel-dkms >/dev/null 2>&1; then
        pkgs+=("${NVIDIA_PACKAGES_OPEN[@]}")
      else
        if [[ "$gen" == "open" ]]; then
          warn "nvidia-open-kernel-dkms not in apt index — falling back to proprietary"
        fi
        pkgs+=("${NVIDIA_PACKAGES_PROP[@]}")
      fi
      # Gaming + workstation userland — only on physical hardware,
      # only when i386 multiarch is actually enabled.  The :i386 deps
      # would otherwise fail with "package not found".  In a VM the
      # whole list is pointless (no GPU passthrough).
      if [[ "$VIRT_TYPE" == "physical" ]] \
         && dpkg --print-foreign-architectures 2>/dev/null \
              | grep -qx 'i386'; then
        pkgs+=("${NVIDIA_PACKAGES_GAMING[@]}")
        if [[ "${WANT_CUDA:-0}" == "1" ]] \
           && apt-cache show nvidia-cuda-toolkit >/dev/null 2>&1; then
          pkgs+=("${NVIDIA_PACKAGES_CUDA[@]}")
        fi
        if [[ "${WANT_STEAM:-0}" == "1" ]] \
           && apt-cache show steam-installer >/dev/null 2>&1; then
          pkgs+=("${NVIDIA_PACKAGES_STEAM[@]}")
        fi
      fi
      ;;
    amd)    pkgs+=("${AMD_PACKAGES[@]}") ;;
    intel)  pkgs+=("${INTEL_PACKAGES[@]}") ;;
  esac

  case "$VIRT_TYPE" in
    hyperv) pkgs+=("${HYPERV_PACKAGES[@]}") ;;
    vm)
      case "$VM_HYPERVISOR" in
        kvm|qemu)        pkgs+=("${QEMU_PACKAGES[@]}") ;;
        vmware)          pkgs+=("${VMWARE_PACKAGES[@]}") ;;
        oracle|virtualbox) pkgs+=("${VBOX_PACKAGES[@]}") ;;
      esac
      ;;
  esac

  # CPU microcode — install on every physical machine, keyed only on
  # CPU vendor.  This decouples it from GPU detection so e.g. a Ryzen
  # box with an Nvidia GPU still gets amd64-microcode.  Both packages
  # live in non-free-firmware, which enable_nonfree() turned on.
  if [[ "$VIRT_TYPE" == "physical" ]]; then
    case "$CPU_VENDOR" in
      intel) pkgs+=("${INTEL_CPU_MICROCODE[@]}") ;;
      amd)   pkgs+=("${AMD_CPU_MICROCODE[@]}") ;;
    esac
  fi

  # thermald only on physical Intel boxes — pointless inside a VM where
  # MSRs aren't exposed, and irrelevant on AMD where it doesn't run.
  if [[ "$VIRT_TYPE" == "physical" && "$CPU_VENDOR" == "intel" ]]; then
    pkgs+=("${INTEL_CPU_PACKAGES[@]}")
  fi

  printf '%s\n' "${pkgs[@]}"
}

# ============================================================
# Mullvad apt-repo signing-key fingerprint pin
# ============================================================
# Source of truth for the current fingerprint:
#     https://mullvad.net/en/help/install-mullvad-app-linux
# Mullvad rotates this key only on a multi-year cadence — but when
# they do, the install path here will fail loudly until the constant
# below is updated to match the new published value.  That is the
# correct security posture: pinning means we never silently accept a
# replacement key, even one signed with the same email.
#
# If you see "Mullvad keyring failed pinning check" during install:
#   1. Open the URL above in a browser on a trusted machine.
#   2. Compare the published fingerprint with the one printed by the
#      script (it shows BOTH the expected and the seen values).
#   3. If the published value has changed, update this constant and
#      commit.  If it has NOT changed, treat the mismatch as suspicious
#      (CDN tampering, captive-portal interception) and retry on a
#      different network before bypassing.
#
# Override at runtime — useful while testing a rotation before
# committing the change to git:
#     MULLVAD_KEY_FINGERPRINT=<new-fp> ./local_setup.sh install
MULLVAD_KEY_FINGERPRINT="${MULLVAD_KEY_FINGERPRINT:-A1198702FC3E0A09A9AE5B75D5A1D4F266DE8DDF}"
MULLVAD_KEY_URL_DOC="https://mullvad.net/en/help/install-mullvad-app-linux"

install_mullvad() {
  # Install Mullvad VPN from the official apt repo so `apt upgrade` keeps
  # it current.  Idempotent — re-running is a no-op once installed.
  #
  # Security:
  # - Keyring is downloaded over HTTPS, then we verify its GPG fingerprint
  #   matches MULLVAD_KEY_FINGERPRINT before adding the apt source.
  #   Mismatch = abort with NO state written (no half-configured repo).
  # - signed-by= scoping in the .list file means apt only trusts this key
  #   for the Mullvad repo, never globally.
  #
  # Failures are best-effort (Mullvad is optional UX) — the wider
  # install_phase swallows the return code.
  if dpkg -l mullvad-vpn 2>/dev/null | grep -q '^ii'; then
    ok "mullvad-vpn already installed"
    return 0
  fi
  log "Installing Mullvad VPN (apt repo) …"
  sudo install -d -m 0755 /etc/apt/keyrings
  if ! sudo curl -fsSL https://repository.mullvad.net/deb/mullvad-keyring.asc \
       -o /etc/apt/keyrings/mullvad-keyring.asc; then
    warn "could not fetch Mullvad keyring — skipping"
    return 1
  fi

  # Verify fingerprint.  Use --with-colons so the format is stable
  # across GPG versions.
  #
  # SECURITY: we require the keyring to contain EXACTLY ONE PRIMARY key
  # matching our pin.  A multi-primary keyring during a rotation
  # transition would otherwise let an attacker prepend a benign key
  # with the expected fingerprint and append a second, malicious one.
  #
  # gpg --with-colons emits a `pub:` line per primary public-key block
  # and `sub:` lines for subkeys (Mullvad's keyring legitimately has
  # one primary + 2 subkeys), each followed by its own `fpr:` line.
  # We track the most-recent block type and only collect `fpr:` lines
  # that follow a `pub:`.
  local fps nkeys
  fps="$(gpg --show-keys --with-colons /etc/apt/keyrings/mullvad-keyring.asc \
          2>/dev/null \
        | awk -F: '
              /^pub:/ {p=1; next}
              /^sub:/ {p=0}
              /^fpr:/ && p {print $10; p=0}
          ')"
  nkeys="$(printf '%s\n' "$fps" | grep -c .)"
  if [[ "$nkeys" -ne 1 ]] || [[ "$fps" != "$MULLVAD_KEY_FINGERPRINT" ]]; then
    err "Mullvad keyring failed pinning check — refusing to install."
    err "  expected exactly 1 primary key:"
    err "      $MULLVAD_KEY_FINGERPRINT"
    err "  found $nkeys primary key(s):"
    while IFS= read -r fp; do err "      ${fp:-<empty>}"; done <<<"$fps"
    err ""
    err "What to do next:"
    err "  1. Compare the expected fingerprint with the value Mullvad"
    err "     publishes at:"
    err "        ${MULLVAD_KEY_URL_DOC}"
    err "  2. If Mullvad has rotated the key, update the pinned"
    err "     MULLVAD_KEY_FINGERPRINT in local_setup.sh (or set the"
    err "     env var MULLVAD_KEY_FINGERPRINT=<new-fp>) and re-run."
    err "  3. If Mullvad has NOT rotated, treat the mismatch as a"
    err "     compromise indicator: do not install, retry from a"
    err "     different network, and consider reporting to Mullvad."
    sudo rm -f /etc/apt/keyrings/mullvad-keyring.asc
    return 1
  fi
  ok "Mullvad keyring verified (1 key, fingerprint $MULLVAD_KEY_FINGERPRINT)"

  local arch codename
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [signed-by=/etc/apt/keyrings/mullvad-keyring.asc arch=${arch}] https://repository.mullvad.net/deb/stable ${codename} main" \
    | sudo tee /etc/apt/sources.list.d/mullvad.list > /dev/null
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq \
       >"${LOG_DIR}/apt_mullvad_update.log" 2>&1 \
    || { warn "apt update failed after adding Mullvad repo"; return 1; }
  if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mullvad-vpn \
       >"${LOG_DIR}/apt_mullvad.log" 2>&1; then
    ok "Mullvad VPN installed"
    log "Run \`mullvad account login <number>\` to activate"
  else
    tail -10 "${LOG_DIR}/apt_mullvad.log" || true
    warn "Mullvad install failed — see ${LOG_DIR}/apt_mullvad.log"
    return 1
  fi
}

add_nvidia_modeset() {
  # Append `nvidia-drm.modeset=1` to GRUB_CMDLINE_LINUX_DEFAULT in
  # /etc/default/grub, then update-grub + update-initramfs.
  #
  # Why this matters:
  #   • Required for Wayland on NVIDIA (DRM kernel mode setting).
  #   • Strongly recommended on X11 too — fixes most tearing, eliminates
  #     the "blank screen on resume from suspend" class of bugs, and
  #     enables HW cursor planes.
  #   • Without it, the X server falls back to UMS (User Mode Setting),
  #     which is functional but visibly worse on physical hardware.
  #
  # Idempotent: skips work if the option is already present anywhere in
  # the file (someone may have added it manually with a custom layout).
  # Backup the original /etc/default/grub before editing so a botched
  # update-grub on an exotic kernel doesn't leave the user without a
  # known-good config to restore from.
  local grub=/etc/default/grub
  if [[ ! -f "$grub" ]]; then
    warn "$grub not found — skipping nvidia-drm.modeset=1"
    return 0
  fi
  if sudo grep -q 'nvidia-drm\.modeset=1' "$grub"; then
    ok "nvidia-drm.modeset=1 already present in $grub"
    return 0
  fi
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  sudo install -m 0644 "$grub" "${grub}.bak.${ts}"
  log "Adding nvidia-drm.modeset=1 to $grub (backup: ${grub}.bak.${ts})"
  # Append inside the existing GRUB_CMDLINE_LINUX_DEFAULT="..." quotes.
  # If it's empty (=""), this still produces ' nvidia-drm.modeset=1' —
  # the leading space is harmless to the kernel cmdline parser.
  sudo sed -i -E \
    's/^(GRUB_CMDLINE_LINUX_DEFAULT=")([^"]*)"/\1\2 nvidia-drm.modeset=1"/' \
    "$grub"
  if ! sudo grep -q 'nvidia-drm\.modeset=1' "$grub"; then
    warn "sed did not modify GRUB_CMDLINE_LINUX_DEFAULT in $grub — manual edit required"
    return 1
  fi
  sudo update-grub >"${LOG_DIR}/update-grub.log" 2>&1 \
    || warn "update-grub failed — see ${LOG_DIR}/update-grub.log"
  sudo update-initramfs -u >"${LOG_DIR}/update-initramfs.log" 2>&1 \
    || warn "update-initramfs failed — see ${LOG_DIR}/update-initramfs.log"
  ok "nvidia-drm.modeset=1 added; reboot required to take effect"
}

add_nvidia_fbdev() {
  # Append `nvidia-drm.fbdev=1` to GRUB_CMDLINE_LINUX_DEFAULT.  Required
  # for clean fbcon under nvidia-drm on Wayland: without it, the kernel
  # framebuffer console doesn't switch through nvidia-drm cleanly,
  # producing a visible flash + corruption on the tty→sddm→plasma
  # handoff and (on some monitors) a black screen until VT switch.
  # Companion to nvidia-drm.modeset=1.  Idempotent.  Plasma-only gate.
  local grub=/etc/default/grub
  if [[ ! -f "$grub" ]]; then
    warn "$grub not found — skipping nvidia-drm.fbdev=1"
    return 0
  fi
  if sudo grep -q 'nvidia-drm\.fbdev=1' "$grub"; then
    ok "nvidia-drm.fbdev=1 already present in $grub"
    return 0
  fi
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  sudo install -m 0644 "$grub" "${grub}.bak.${ts}"
  log "Adding nvidia-drm.fbdev=1 to $grub (backup: ${grub}.bak.${ts})"
  sudo sed -i -E \
    's/^(GRUB_CMDLINE_LINUX_DEFAULT=")([^"]*)"/\1\2 nvidia-drm.fbdev=1"/' \
    "$grub"
  if ! sudo grep -q 'nvidia-drm\.fbdev=1' "$grub"; then
    warn "sed did not add nvidia-drm.fbdev=1 — manual edit required"
    return 1
  fi
  sudo update-grub >"${LOG_DIR}/update-grub-fbdev.log" 2>&1 \
    || warn "update-grub failed — see ${LOG_DIR}/update-grub-fbdev.log"
  ok "nvidia-drm.fbdev=1 added; reboot required to take effect"
}

add_nvidia_early_kms() {
  # Add nvidia / nvidia_modeset / nvidia_uvm / nvidia_drm to
  # /etc/initramfs-tools/modules so they load in the initial ramdisk.
  # On Wayland with KMS this eliminates the early-boot flash and fixes
  # a class of sddm races where the greeter starts before nvidia-drm
  # has exposed its DRM connector.  Idempotent.  Plasma-only gate.
  local mods=/etc/initramfs-tools/modules
  if [[ ! -f "$mods" ]]; then
    warn "$mods not found — skipping early-KMS"
    return 0
  fi
  local want=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
  local missing=() m
  for m in "${want[@]}"; do
    if ! sudo grep -qE "^[[:space:]]*${m}([[:space:]]|$)" "$mods"; then
      missing+=("$m")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "nvidia early-KMS modules already in $mods"
    return 0
  fi
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  sudo install -m 0644 "$mods" "${mods}.bak.${ts}"
  log "Adding ${missing[*]} to $mods (backup: ${mods}.bak.${ts})"
  # Single trailing block so it's easy to identify and remove.  Each
  # module on its own line is the documented format.
  {
    printf '\n# cyberpunk dotfiles — nvidia Wayland early KMS\n'
    printf '%s\n' "${missing[@]}"
  } | sudo tee -a "$mods" >/dev/null
  sudo update-initramfs -u >"${LOG_DIR}/update-initramfs-kms.log" 2>&1 \
    || warn "update-initramfs failed — see ${LOG_DIR}/update-initramfs-kms.log"
  ok "nvidia early-KMS modules added; reboot required"
}

add_nvidia_pm_options() {
  # Drop a modprobe.d file telling the nvidia kernel module to preserve
  # video memory across suspend/resume.  Without this, Wayland sessions
  # often resume with corrupted textures or fail to repaint.  Then
  # enable Debian's three companion systemd units (shipped by the
  # nvidia-driver package but not enabled by default) that wire into
  # systemd-suspend to do the actual save/restore.  Plasma-only gate.
  local conf=/etc/modprobe.d/nvidia-power-management.conf
  if sudo test -f "$conf" \
     && sudo grep -q 'NVreg_PreserveVideoMemoryAllocations=1' "$conf"; then
    ok "nvidia PreserveVideoMemoryAllocations already set in $conf"
  else
    log "Writing $conf"
    printf 'options nvidia NVreg_PreserveVideoMemoryAllocations=1\n' \
      | sudo install -m 0644 /dev/stdin "$conf"
    ok "wrote $conf — reboot required to take effect"
    sudo update-initramfs -u >"${LOG_DIR}/update-initramfs-pm.log" 2>&1 \
      || warn "update-initramfs failed — see ${LOG_DIR}/update-initramfs-pm.log"
  fi
  # Enable the three nvidia suspend/resume/hibernate units that pair
  # with the PreserveVideoMemoryAllocations option.  Each is independent
  # and silently absent on older driver packages; tolerate missing units.
  local unit
  for unit in nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service; do
    if systemctl list-unit-files "$unit" 2>/dev/null | grep -q "^${unit}"; then
      sudo systemctl enable "$unit" >/dev/null 2>&1 \
        && ok "$unit enabled" \
        || warn "$unit failed to enable"
    fi
  done
}

# --- NVIDIA Wayland session environment ------------------------------
# Drop /etc/environment.d/95-nvidia-wayland.conf onto NVIDIA boxes so
# every graphical-session.target child inherits the VRR / cursor /
# Firefox-Wayland tunables.  Read by pam_systemd at user-session start
# (see environment.d(5)) — NOT by /etc/environment (which only login(1)
# / sshd shells see).  Idempotent: `install -D` overwrites in place.
#
# Gated on GPU_VENDOR=nvidia.  On the Intel-only T14 this is a no-op
# that logs and returns 0; the file never lands in /etc/environment.d/.
#
# Source-of-truth lives in config/system/etc/environment.d/95-nvidia-
# wayland.conf — that file has the per-variable comment header.  Edit
# the source, re-run `./local_setup.sh deploy`; the deployed copy is
# overwritten.
deploy_nvidia_wayland_env() {
  if [[ "$GPU_VENDOR" != "nvidia" ]]; then
    log "GPU_VENDOR=$GPU_VENDOR — skipping NVIDIA Wayland env drop-in"
    return 0
  fi
  local src="${DOTFILES_DIR}/system/etc/environment.d/95-nvidia-wayland.conf"
  if [[ ! -f "$src" ]]; then
    warn "$src missing — skipping nvidia-wayland env"
    return 1
  fi
  sudo install -D -m 0644 -o root -g root "$src" \
       /etc/environment.d/95-nvidia-wayland.conf
  ok "/etc/environment.d/95-nvidia-wayland.conf (VRR/G-Sync, cursor, Firefox Wayland)"
  log "  Log out + back in for new env vars to apply (pam_systemd reads at session start)"
}

# --- Plasma 6 explicit-sync (NVIDIA 555+) ----------------------------
# Turn on the Wayland explicit-sync protocol in kwinrc.  Without it,
# every GL frame on NVIDIA does an implicit fence wait that serialises
# the whole compositor on the slowest client — visibly stutters on
# multi-window scenes on the desktop's 3-monitor 1440p/240Hz setup.
#
# Version landscape (as of Debian Trixie + recent NVIDIA):
#   • Plasma / KWin  6.1.x      — supports the protocol, ships it OFF;
#                                 needs [Wayland] EnableExplicitSync=true
#                                 in kwinrc to opt in.
#   • Plasma / KWin  6.2+       — ships it ON BY DEFAULT when both
#                                 sides support it (NVIDIA driver 555+).
#                                 Setting the key is harmless — KWin
#                                 reads it but the default is already
#                                 the same value, so the key is a no-op.
#   • NVIDIA driver  < 555      — protocol unsupported by the driver;
#                                 KWin silently falls back to implicit
#                                 sync regardless of this key.  Setting
#                                 it is still harmless.
#
# Strategy: ALWAYS write the key when on the plasma + nvidia path.
# Idempotency + a single code path wins over fragile version-detection
# in bash.  The key lives in [Wayland] (NOT [Compositing] — KWin 6.x
# moved Wayland-protocol toggles into the [Wayland] group; see
# kwinwaylandconfig.kcfg upstream).
#
# REMOVE THIS FUNCTION when:
#   • Debian's plasma-workspace stable is >= 6.3 across all targets
#     (every Plasma 6.3 build of KWin enables explicit-sync uncondition-
#     ally), AND
#   • The minimum NVIDIA driver in apt is >= 580 (no installed user is
#     stuck on a pre-555 driver where the key was needed as a workaround).
# At that point the kwinrc key is pure overhead.
enable_plasma_explicit_sync() {
  if [[ "$DESKTOP" != "plasma" ]]; then
    return 0
  fi
  if [[ "$GPU_VENDOR" != "nvidia" ]]; then
    log "GPU_VENDOR=$GPU_VENDOR — skipping Plasma explicit-sync toggle"
    return 0
  fi
  if ! have kwriteconfig6; then
    warn "kwriteconfig6 missing — cannot set kwinrc EnableExplicitSync."
    warn "Install libkf6config-bin and re-run \`./local_setup.sh deploy\`."
    return 1
  fi
  local f="${HOME}/.config/kwinrc"
  kwriteconfig6 --file "$f" --group Wayland \
    --key EnableExplicitSync true
  ok ".config/kwinrc [Wayland] EnableExplicitSync=true (NVIDIA explicit-sync)"
}

install_phase() {
  ensure_sudo
  # Enable non-free / non-free-firmware on any physical machine.
  # Multiple consumers depend on it being on:
  #   • NVIDIA      — nvidia-driver, nvidia-open-kernel-dkms (non-free)
  #   • CPU intel   — intel-microcode (non-free-firmware)
  #   • CPU amd     — amd64-microcode (non-free-firmware)
  #   • All vendors — firmware-misc-nonfree (WiFi, BT, audio codecs,
  #                   touchpads, etc.)
  # We turn it on whenever VIRT=physical, regardless of GPU vendor —
  # earlier this was gated to NVIDIA, which silently dropped microcode
  # on AMD-CPU + Nvidia-GPU and Intel-CPU + AMD-GPU boxes.
  # enable_nonfree() is idempotent, VMs skip — guest tools live in main.
  #
  # Hard-fail if enable_nonfree errors: silently continuing to the
  # driver install would later fail with "Unable to locate package",
  # producing a much more confusing error.
  if [[ "$VIRT_TYPE" == "physical" ]]; then
    enable_nonfree || die "enable_nonfree failed — refusing to proceed"
  fi
  if [[ "$GPU_VENDOR" == "nvidia" && "$VIRT_TYPE" == "physical" ]]; then
    # i386 must be enabled BEFORE apt_update so the package index
    # picks up :i386 candidates in this same install run.  NVIDIA-
    # only — Intel/AMD don't need 32-bit driver libs unless the user
    # also wants Steam, which isn't on by default.
    enable_i386_arch
  fi
  apt_update
  apt_install "base" "${BASE_PACKAGES[@]}"

  # Desktop-stack packages — picked by $DESKTOP (default i3).
  #   • i3      → X11 stack (xorg, i3, polybar, picom, lightdm, …)
  #   • plasma  → KDE Plasma 6 Wayland stack (plasma-desktop, kwin-
  #               wayland, sddm, pipewire, xwayland, …)
  # apt's Conflicts/Replaces handles the pulseaudio→pipewire swap on
  # the plasma path; no manual purge needed.
  case "$DESKTOP" in
    i3)     apt_install "desktop (i3)"     "${DESKTOP_I3_PACKAGES[@]}" ;;
    plasma) apt_install "desktop (plasma)" "${DESKTOP_PLASMA_PACKAGES[@]}" ;;
    *)      die "Unknown DESKTOP=$DESKTOP (expected i3 or plasma)" ;;
  esac

  # Mullvad VPN — best-effort.  We don't `|| true` inside the function so
  # the user sees the warning, but install_phase keeps going either way.
  install_mullvad || true

  if [[ "$NO_DRIVERS" == 1 ]]; then
    log "Skipping driver install (--no-drivers)"
    return 0
  fi

  local drivers=()
  mapfile -t drivers < <(driver_packages_for)
  if [[ ${#drivers[@]} -gt 0 ]]; then
    apt_install "drivers" "${drivers[@]}"
  else
    log "No extra driver packages required for this hardware"
  fi

  # Set nvidia-drm.modeset=1 only when we actually installed an NVIDIA
  # driver on a physical box.  Pointless inside a VM (no real GPU to
  # mode-set) and skipped on --no-drivers / --no-gpu since the kernel
  # module won't be present.
  if [[ "$GPU_VENDOR" == "nvidia" && "$VIRT_TYPE" == "physical" \
        && "$NO_DRIVERS" != 1 ]]; then
    add_nvidia_modeset
    # Extra Wayland-specific NVIDIA tweaks — only meaningful on the
    # plasma path.  On i3 these would all be no-ops or counterproductive
    # (early-KMS is fine but not needed; the suspend services are
    # specifically for Wayland session preservation).
    if [[ "$DESKTOP" == "plasma" ]]; then
      add_nvidia_fbdev
      add_nvidia_early_kms
      add_nvidia_pm_options
    fi
  fi

  enable_power_services
  ensure_user_groups
  trigger_backlight_udev
  ensure_nm_managed
}

ensure_nm_managed() {
  # Diagnose-only.  We do NOT auto-flip interfaces from `unmanaged` to
  # NM-managed during install_phase: doing so kills any active wifi
  # session that another backend (iwd / wpa_supplicant / ifupdown) was
  # holding, which (a) instantly drops the network the install script
  # itself is using, and (b) leaves NM with no saved profile to
  # reconnect — net result is a brick until the user manually
  # connects via nmcli.  We learned this the loud way once.
  #
  # Instead: print a clear diagnostic line per non-managed interface
  # so the user can decide what to do (and when).  The recovery flow
  # is documented in readme/system.md → "WiFi shows unmanaged".
  if ! command -v nmcli >/dev/null 2>&1; then
    return 0
  fi
  local devs
  devs="$(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null \
            | awk -F: '$3 == "unmanaged" {print $1 ":" $2}' || true)"
  if [[ -z "$devs" ]]; then
    ok "NetworkManager: every device is managed"
    return 0
  fi
  warn "NetworkManager has unmanaged interfaces:"
  while IFS=: read -r dev typ; do
    [[ -z "$dev" ]] && continue
    warn "    $dev ($typ)  — currently driven by another backend"
  done <<<"$devs"
  warn "If your wifi/ethernet works as-is, leave it alone.  If you want"
  warn "polybar's wlan pill to render and wifi-menu.sh to drive the"
  warn "device, see readme/system.md → 'WiFi shows unmanaged' for the"
  warn "manual takeover procedure (iwd-aware, won't drop your session)."
}

auto_wifi_takeover() {
  # Run scripts/take-over-wifi.sh non-interactively at the end of
  # `setup`, but ONLY when:
  #   • wifi exists and is currently `unmanaged` (the bug we're fixing)
  #   • SSID + PSK are recoverable from /etc/network/interfaces (so
  #     the takeover script's pre-import step has something to import,
  #     guaranteeing NM autoconnects after the backend swap and the
  #     network is never lost)
  #   • the user didn't pass --no-wifi-takeover
  #   • we're not in a VM (no point — VMs have virtio-net, not wifi)
  # If creds aren't extractable we deliberately do NOTHING and print
  # a clear warning, because forcing a takeover without a saved profile
  # is exactly the failure mode that bricked the user's session once
  # already.  The user can then run the takeover manually after putting
  # creds where the script can find them.
  if [[ "${WANT_WIFI_TAKEOVER:-1}" != 1 ]]; then
    log "Skipping wifi takeover (--no-wifi-takeover)"
    return 0
  fi
  if [[ "$VIRT_TYPE" != "physical" ]]; then
    return 0
  fi
  if ! command -v nmcli >/dev/null 2>&1; then
    return 0
  fi

  local wifi_iface state
  wifi_iface="$(nmcli -t -f DEVICE,TYPE device 2>/dev/null \
                | awk -F: '$2 == "wifi" {print $1; exit}' || true)"
  [[ -z "$wifi_iface" ]] && return 0   # no wifi card — nothing to do

  state="$(nmcli -t -f DEVICE,STATE device 2>/dev/null \
           | awk -F: -v d="$wifi_iface" '$1==d {print $2; exit}' || true)"
  if [[ "$state" != "unmanaged" && "$state" != "unavailable" ]]; then
    log "wifi ($wifi_iface) is already managed by NM — no takeover needed"
    return 0
  fi

  # Are credentials recoverable?  We accept TWO sources, in priority
  # order:
  #
  #   (a) /etc/network/interfaces has a wpa-psk/passphrase/password
  #       line — the takeover script's pre-import path picks it up
  #       and creates an NM profile from it.
  #   (b) NM already has at least one saved 802-11-wireless connection
  #       (`/etc/NetworkManager/system-connections/*.nmconnection`).
  #       This catches the realistic post-install state where the user
  #       configured wifi via nmtui or System Settings, AND something
  #       else (a downstream package's postinst, an explicit user
  #       `systemctl start wpa_supplicant`, the netifrc backend) has
  #       since started a standalone wpa_supplicant.service that's now
  #       holding the device, leaving `nmcli device status` reporting
  #       `unavailable`.  In that case takeover is SAFE: stopping
  #       wpa_supplicant.service hands the device back to NM, which
  #       autoconnects via the existing saved profile.  This is the
  #       exact situation that caused the user-visible "plasma network
  #       widget shows nothing" bug on the T14.
  local has_creds=0
  local has_nm_profile=0
  if [[ -r /etc/network/interfaces ]] \
     && sudo grep -qE '^[[:space:]]*wpa-(psk|passphrase|password)[[:space:]]+' \
            /etc/network/interfaces 2>/dev/null; then
    has_creds=1
  fi
  if nmcli -t -f TYPE connection show 2>/dev/null \
     | grep -q '^802-11-wireless$'; then
    has_nm_profile=1
  fi
  if (( has_creds == 0 && has_nm_profile == 0 )); then
    warn "wifi ($wifi_iface) is unmanaged but no creds are recoverable:"
    warn "  • /etc/network/interfaces has no wpa-psk line"
    warn "  • NetworkManager has no saved 802-11-wireless profile"
    warn "Refusing to auto-takeover (would leave you offline)."
    warn "If you want plasma-nm / polybar's wlan pill to work, run:"
    warn "    ${SCRIPT_DIR}/scripts/take-over-wifi.sh"
    warn "after manually putting the SSID + PSK in a place the script"
    warn "can read (or be ready to type them at its prompt)."
    return 0
  fi

  local script="${SCRIPT_DIR}/scripts/take-over-wifi.sh"
  if [[ ! -x "$script" ]]; then
    warn "$script not found / not executable — skipping wifi takeover"
    return 0
  fi

  log "Wifi is unmanaged + creds recoverable → running takeover non-interactively …"
  # `--yes` skips the confirm prompt; the script's pre-import step
  # imports the SSID/PSK from /etc/network/interfaces into NM first,
  # so when wpa_supplicant stops and NM is restarted the network
  # reconnects automatically (autoconnect=yes on the imported profile).
  if "$script" --yes; then
    ok "wifi takeover succeeded — polybar wlan pill should now render"
  else
    warn "wifi takeover failed — see ${script} output above"
    warn "Wifi may have been left in a broken state.  Run the takeover"
    warn "manually after diagnosing: ${SCRIPT_DIR}/scripts/diagnose-wifi.sh"
  fi
}

trigger_backlight_udev() {
  # `brightnessctl`'s Debian package ships
  #   /lib/udev/rules.d/90-brightnessctl.rules
  # which chgrp's /sys/class/backlight/*/brightness to `video` and
  # adds g+w on the `add` event.  In normal operation the package
  # postinst calls `udevadm trigger` so the rule fires immediately;
  # in practice it sometimes doesn't (manual install, --no-triggers
  # apt option, layered images where /sys was already populated, etc.)
  # The symptom is: user is in `video`, brightnessctl runs without
  # error, brightness doesn't change because the sysfs node is still
  # root:root mode 644.  Re-triggering is idempotent and cheap.
  [[ "$VIRT_TYPE" == "physical" ]] || return 0
  command -v udevadm >/dev/null 2>&1 || return 0
  [[ -d /sys/class/backlight ]] && \
    [[ -n "$(ls -A /sys/class/backlight 2>/dev/null)" ]] || return 0
  log "Re-triggering backlight udev rules …"
  sudo udevadm control --reload-rules >/dev/null 2>&1 || true
  sudo udevadm trigger --subsystem-match=backlight >/dev/null 2>&1 || true
  ok "backlight udev rules reloaded"
}

ensure_user_groups() {
  # Some hardware-control utilities require the invoking user to be in
  # specific Unix groups so the kernel's udev rules can hand out write
  # access to /sys and /dev nodes:
  #   • video   — /sys/class/backlight/*/brightness (brightnessctl udev
  #               rule chgrp's these to `video`).  Without it,
  #               `brightnessctl set ±5%` silently no-ops on a laptop —
  #               sysfs returns EACCES, brightnessctl prints to stderr,
  #               but i3 doesn't surface that and the user sees "key
  #               does nothing".  Debian only puts the FIRST install-time
  #               user into `video`; users created with `useradd` later
  #               are not added automatically.
  # Skipped in VMs — no real backlight, no rule needed.
  # Idempotent: usermod -aG is a no-op for an existing membership.
  # Note: group membership only takes effect after the user re-logs in
  # (more precisely, after a fresh login session is started).  We log a
  # reminder when we changed anything.
  [[ "$VIRT_TYPE" == "physical" ]] || return 0
  local grp need_logout=0
  for grp in video; do
    if id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$grp"; then
      ok "$USER is already in group: $grp"
      continue
    fi
    if sudo usermod -aG "$grp" "$USER" 2>/dev/null; then
      ok "added $USER to group: $grp"
      need_logout=1
    else
      warn "failed to add $USER to group: $grp — brightness keys may no-op"
    fi
  done
  if (( need_logout )); then
    warn "group changes require a logout (or reboot) to take effect"
  fi
}

enable_power_services() {
  # TLP — power-saving daemon.  Defaults are sane for laptops and give a
  # 20-40% idle-power win on ThinkPads with no user tuning.  Skipped
  # inside VMs (no battery) and on hyperv (host owns power).
  #
  # CONFLICT: power-profiles-daemon (PPD) and TLP both manage CPU
  # frequency, platform profile, and battery thresholds — they MUST
  # NOT run together.  GNOME 48 (the Debian 13 default desktop) pulls
  # PPD in via task-gnome-desktop, so a fresh T14 install commonly has
  # PPD installed even before we get here.  We purge it before enabling
  # TLP so that whichever was running first doesn't fight us.  If the
  # user prefers PPD's GNOME-integrated UX, they should skip the dotfile
  # install on that machine — these dotfiles are opinionated about TLP.
  if [[ "$VIRT_TYPE" != "physical" ]]; then
    log "Skipping TLP enable — not a physical machine"
  else
    if dpkg -l power-profiles-daemon 2>/dev/null | grep -q '^ii'; then
      log "Removing power-profiles-daemon (conflicts with TLP) …"
      sudo systemctl disable --now power-profiles-daemon \
        >/dev/null 2>&1 || true
      sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y \
        power-profiles-daemon >"${LOG_DIR}/apt_ppd_purge.log" 2>&1 \
        || warn "power-profiles-daemon purge failed — see ${LOG_DIR}/apt_ppd_purge.log"
    fi
    if dpkg -l tlp 2>/dev/null | grep -q '^ii'; then
      sudo systemctl enable --now tlp >/dev/null 2>&1 \
        && ok "tlp enabled (power management active)" \
        || warn "tlp enable failed — check \`systemctl status tlp\`"
    fi
  fi
  # thermald — Intel-only; only present in apt graph when detect_cpu
  # said "intel" AND we're physical, so the dpkg gate is sufficient.
  if dpkg -l thermald 2>/dev/null | grep -q '^ii'; then
    sudo systemctl enable --now thermald >/dev/null 2>&1 \
      && ok "thermald enabled (Intel thermal protection active)" \
      || warn "thermald enable failed — check \`systemctl status thermald\`"
  fi
}

# ============================================================
# Config deployment
# ============================================================
CONFIG_MAP_COMMON=(
  "alacritty:.config/alacritty"
  "gtk-3.0:.config/gtk-3.0"
  "wallpaper:.config/wallpaper"
  "tmux:.config/tmux"
  "nvim:.config/nvim"
  "starship:.config/starship"
  "conky:.config/conky"
)

# i3 path — X11-only configs that have no Wayland/Plasma equivalent.
# lockscreen is i3lock + ImageMagick neon overlay; under plasma, the
# user gets kscreenlocker driven by config/plasma/kscreenlockerrc.
CONFIG_MAP_I3=(
  "i3:.config/i3"
  "polybar:.config/polybar"
  "picom:.config/picom"
  "rofi:.config/rofi"
  "dunst:.config/dunst"
  "lockscreen:.config/lockscreen"
)

# Plasma path — `config/plasma/*` deploys piece-by-piece to ~/.config
# and ~/.local/share/.  apply-theme.sh runs after to live-apply the
# color scheme and wallpaper (no-op if plasmashell isn't running).
# The autostart entries (deployed separately via deploy_templated_file
# below — they contain @HOME@ that must be substituted at deploy time,
# because the XDG Desktop Entry spec has no %h field code) ensure conky
# launches under KDE and apply-theme re-runs idempotently on subsequent
# logins.
#
# IMPORTANT: this array is intentionally EMPTY.  Every plasma file is
# deployed as an individual install -D in the plasma branch of
# deploy_phase, because deploy_one uses `rsync -a --delete` and the
# Plasma-side destinations (~/.local/share/color-schemes/,
# ~/.local/share/konsole/, ~/.config/autostart/) are SHARED dirs that
# other tools (System Settings, Discover, KDE Connect, password
# managers, …) populate.  Using --delete there would silently wipe
# the user's neighboring schemes / profiles / autostart entries on
# every deploy.  Keep this empty unless a future plasma config lives
# in a dotfiles-exclusive subdirectory.
CONFIG_MAP_PLASMA=()

deploy_one() {
  local src_name="$1" dest_rel="$2"
  local src="${DOTFILES_DIR}/${src_name}"
  local dest="${HOME}/${dest_rel}"
  if [[ ! -e "$src" ]]; then
    echo "    [skip] ${src_name} — not found"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  # --delete keeps the deploy in sync (orphan files on the destination
  # get removed when their source disappears, e.g. when conky-listen.conf
  # was retired).  --exclude filters dev cruft that shouldn't deploy:
  # Python bytecode caches, git metadata, macOS metadata.
  rsync -a --delete \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        --exclude='.git' \
        --exclude='.DS_Store' \
        "${src}/" "${dest}/" 2>/dev/null \
    || cp -rT "$src" "$dest"
  echo "    [ok] ${src_name} → ~/${dest_rel}"
}

# ============================================================
# Per-host override layer (~/.config/dotfiles-local/)
# ============================================================
# Users with per-machine state (e.g. a 28px conky panel on a 1080p
# laptop vs. a 36px panel on a 4K desktop) drop overrides into
# ~/.config/dotfiles-local/<thing>/.  Anything there is rsync'd OVER
# the repo-deployed files at the end of deploy_phase, so the local
# override wins without us having to fork the repo per host.
#
# Convention:
#   ~/.config/dotfiles-local/conky/conky.conf  →  overrides
#   ~/.config/conky/conky.conf                  (repo-deployed)
#
# The override dir is INTENTIONALLY outside the repo (user-managed,
# not git-tracked).  On a clean install nothing exists and apply_local_overrides
# is a no-op except for creating the empty dir + README.
#
# Scope is tight: only files under ~/.config/<...> are layered.  System
# files under /etc/ are NOT overridable via this mechanism — those go
# through the harden/install paths with explicit sudo writes, and a
# user-writable override file would defeat the security intent.
#
# Escape hatch:  DOTFILES_NO_LOCAL=1 ./local_setup.sh  disables the
# overlay step entirely for the current run.

# Path constant.  Single source of truth so --show-overrides + deploy_phase
# can't drift out of sync.
DOTFILES_LOCAL_DIR="${HOME}/.config/dotfiles-local"

# Write the explainer README on first install.  We refuse to overwrite
# an existing README so the user can replace it with their own notes
# (e.g. "machine = T14, panel=28px, see scripts/foo.sh") without us
# clobbering them on every re-run.
_write_local_overrides_readme() {
  local readme="${DOTFILES_LOCAL_DIR}/README"
  [[ -e "$readme" ]] && return 0
  cat > "$readme" <<'EOF'
# ~/.config/dotfiles-local/
#
# Per-host overrides applied AFTER `./local_setup.sh deploy` rsyncs the
# repo-shipped configs.  Use this dir for machine-specific tweaks that
# you don't want to commit to the dotfiles repo.
#
# Layout — mirrors ~/.config/:
#
#   ~/.config/dotfiles-local/conky/conky.conf
#       overrides  ~/.config/conky/conky.conf
#
#   ~/.config/dotfiles-local/polybar/config.ini
#       overrides  ~/.config/polybar/config.ini
#
# Mechanics:
#   • deploy_phase() rsyncs config/<thing>/ → ~/.config/<thing>/ (with
#     --delete: orphaned files in ~/.config/<thing>/ are removed).
#   • Then apply_local_overrides() rsyncs ~/.config/dotfiles-local/<thing>/
#     → ~/.config/<thing>/ (WITHOUT --delete: overrides only add or
#     replace; they don't strip repo files that have no local mate).
#
# To disable for a single run:
#   DOTFILES_NO_LOCAL=1 ./local_setup.sh
#
# To list overrides currently in effect:
#   ./local_setup.sh --show-overrides
#
# What NOT to put here:
#   • Anything under /etc/ — system files use a separate (sudo install)
#     path and intentionally can't be overridden by user-writable files.
#   • Secrets — this dir is mode 0700 by default but it lives under
#     $HOME; treat it like the rest of ~/.config (not a vault).
EOF
  chmod 0644 "$readme" 2>/dev/null || true
}

# Ensure ~/.config/dotfiles-local/ exists.  Called from deploy_phase and
# --show-overrides; idempotent.
ensure_local_overrides_dir() {
  local fresh=0
  [[ -d "$DOTFILES_LOCAL_DIR" ]] || fresh=1
  mkdir -p "$DOTFILES_LOCAL_DIR"
  chmod 0700 "$DOTFILES_LOCAL_DIR" 2>/dev/null || true
  # Only write the README on FIRST creation — see comment above.
  if (( fresh )); then
    _write_local_overrides_readme
    log "Created ${DOTFILES_LOCAL_DIR}/ (per-host override layer; see README)"
  fi
}

# Apply user-managed overrides on top of repo-deployed configs.
# Honoured by deploy_phase().  Skipped entirely under DOTFILES_NO_LOCAL=1.
# Tightly scoped to ~/.config/ — refuses to touch /etc/ or paths outside
# $HOME even if the user creates weird subdirs.
apply_local_overrides() {
  if [[ "${DOTFILES_NO_LOCAL:-0}" == "1" ]]; then
    log "DOTFILES_NO_LOCAL=1 — skipping per-host override layer"
    return 0
  fi
  ensure_local_overrides_dir
  # Nothing to do if user hasn't dropped any overrides.
  shopt -s nullglob
  local sub overrode=0
  for sub in "${DOTFILES_LOCAL_DIR}"/*/; do
    local name dest
    name="$(basename "$sub")"
    # Skip metadata-y names that aren't config subtrees.
    [[ "$name" == "README" || "$name" == ".git" ]] && continue
    dest="${HOME}/.config/${name}"
    # SAFETY: refuse to write outside ~/.config.  If a malicious or
    # mistyped symlink in the override tree resolves elsewhere, bail.
    case "$(readlink -f "$dest" 2>/dev/null || echo "$dest")" in
      "${HOME}/.config/"*) ;;
      *) warn "    [skip] override ${name} — resolves outside ~/.config"; continue ;;
    esac
    mkdir -p "$dest"
    # NOTE: NO --delete here.  Overrides should ADD/REPLACE files, not
    # remove repo-shipped files that the user didn't bother to override.
    rsync -a \
          --exclude='__pycache__' \
          --exclude='*.pyc' \
          --exclude='.git' \
          --exclude='.DS_Store' \
          "$sub" "${dest}/" 2>/dev/null || true
    echo "    [override] ${DOTFILES_LOCAL_DIR}/${name}/  →  ~/.config/${name}/"
    overrode=1
  done
  shopt -u nullglob
  if (( overrode == 0 )); then
    log "  (no per-host overrides under ${DOTFILES_LOCAL_DIR}/)"
  fi
}

# List files currently differing from repo defaults due to local overrides.
# Driven by --show-overrides.  Read-only; safe to run any time.
show_overrides() {
  ensure_local_overrides_dir
  echo "Per-host overrides under ${DOTFILES_LOCAL_DIR}/"
  echo "(comparing against repo source in ${DOTFILES_DIR}/)"
  echo
  shopt -s nullglob
  local sub any=0
  for sub in "${DOTFILES_LOCAL_DIR}"/*/; do
    local name="$(basename "$sub")"
    [[ "$name" == "README" || "$name" == ".git" ]] && continue
    local repo_src="${DOTFILES_DIR}/${name}"
    if [[ ! -d "$repo_src" ]]; then
      echo "  [extra]    ${name}/  (no repo source — overrides add files only)"
      any=1
      continue
    fi
    # Walk the override tree and diff each file against the repo source.
    local f rel
    while IFS= read -r -d '' f; do
      rel="${f#${sub}}"
      if [[ ! -f "${repo_src}/${rel}" ]]; then
        echo "  [add]      ${name}/${rel}  (not present in repo)"
      elif ! cmp -s "$f" "${repo_src}/${rel}"; then
        echo "  [override] ${name}/${rel}"
      else
        echo "  [same]     ${name}/${rel}  (identical to repo — override is a no-op)"
      fi
      any=1
    done < <(find "$sub" -type f -print0 2>/dev/null)
  done
  shopt -u nullglob
  if (( any == 0 )); then
    echo "  (no overrides; ${DOTFILES_LOCAL_DIR}/ is empty)"
  fi
  echo
  echo "Disable for one run:  DOTFILES_NO_LOCAL=1 ./local_setup.sh"
}

patch_picom_backend() {
  # xrender for VMs (no GLX/DRI2 reliably), glx for physical
  local conf="${HOME}/.config/picom/picom.conf"
  [[ -f "$conf" ]] || return 0
  if [[ "$VIRT_TYPE" == "physical" && "$GPU_VENDOR" != "none" ]]; then
    sed -i 's/^backend.*=.*/backend = "glx";/'    "$conf"
    sed -i 's/^use-damage.*=.*/use-damage = true;/' "$conf"
    ok "picom backend → glx"
  else
    sed -i 's/^backend.*=.*/backend = "xrender";/' "$conf"
    sed -i 's/^use-damage.*=.*/use-damage = false;/' "$conf"
    ok "picom backend → xrender"
  fi
}

patch_conky_window_type() {
  # Runtime swap of `own_window_type` in the deployed conky.conf, mirroring
  # the patch_picom_backend pattern.  Why this needs to differ:
  #
  #   • i3   (X11/EWMH)   — 'override' produces an unmanaged window that
  #                         i3 ignores entirely.  Correct under X11.
  #   • plasma (Wayland)  — under XWayland, neither 'override' nor
  #                         'desktop' work: KWin maps both into stacking
  #                         layers BELOW plasmashell's desktop wallpaper
  #                         layer, so conky's window disappears (process
  #                         keeps running — you see it in `ps` — but the
  #                         window is buried).  The fix is to use
  #                         'normal' (a managed window) and let KWin
  #                         rules in config/plasma/kwinrulesrc force it
  #                         below + skip-taskbar / skip-pager /
  #                         skip-switcher + no border + no focus.  See
  #                         the [conky-desktop-pin] section there for
  #                         the rule keys.
  #
  # Single conky.conf in the repo → patched in place after deploy.
  local conf="${HOME}/.config/conky/conky.conf"
  [[ -f "$conf" ]] || return 0
  case "$DESKTOP" in
    plasma)
      sed -i "s/own_window_type[[:space:]]*=[[:space:]]*'[^']*'/own_window_type    = 'normal'/" "$conf"
      ok "conky own_window_type → normal (plasma; kwinrulesrc pins layer)"
      ;;
    i3|*)
      sed -i "s/own_window_type[[:space:]]*=[[:space:]]*'[^']*'/own_window_type    = 'override'/" "$conf"
      ok "conky own_window_type → override (i3)"
      ;;
  esac
}

# Substitute @HOME@ in a template and root-install the result to $dest.
# Used for kscreenlockerrc + lightdm greeter — both reference $HOME paths
# without embedding the user's actual home in the repo file.  Python
# str.replace beats sed/awk/bash here for the same reason documented at
# the lightdm site: $HOME may contain `&`, `\`, or the sed delimiter.
deploy_templated_file() {
  local src="$1" dest="$2" mode="${3:-0644}"
  [[ -f "$src" ]] || return 0
  local tmp; tmp="$(mktemp)" || die "mktemp failed for $src"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN
  HOME="$HOME" TPL_IN="$src" python3 -c '
import os, sys
sys.stdout.write(
    open(os.environ["TPL_IN"]).read()
    .replace("@HOME@", os.environ["HOME"])
)
' > "$tmp" \
    || die "template substitution failed for $src"
  if [[ "$dest" == /etc/* ]]; then
    sudo install -m "$mode" "$tmp" "$dest"
  else
    install -D -m "$mode" "$tmp" "$dest"
  fi
  ok "$dest (templated for \$HOME)"
}

# ============================================================
# Laptop chassis detection
# ============================================================
# DMI chassis-type encoding (SMBIOS spec §7.4.1):
#   8 = portable   9 = laptop   10 = notebook   14 = sub-notebook
# Anything else (3 = desktop, 4 = low-profile, 6 = mini-tower, …) is
# NOT a laptop and skips mobile-specific deploys (suspend hooks, dock
# auto-layout, lid-switch tweaks, …).  Cheap to call; no caching needed.
is_laptop_chassis() {
  local chassis
  chassis="$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || echo)"
  [[ "$chassis" =~ ^(8|9|10|14)$ ]]
}

# ============================================================
# L2 — Suspend / resume hygiene hook (laptops only)
# ============================================================
# Drops /usr/lib/systemd/system-sleep/cyberpunk-suspend.sh into place;
# systemd-suspend.service auto-invokes anything under that directory
# with $1=pre|post and $2=<sleep-action>, so NO unit / timer is needed.
# The script logs to journal under tag `cyberpunk-suspend` and
# best-effort restarts plasma-kscreen.service on the resume path if any
# DRM outputs vanished across suspend (the dock-didn't-re-enumerate
# failure mode we hit on the T14).  Idempotent — re-running overwrites.
deploy_suspend_hook() {
  if ! is_laptop_chassis; then
    log "non-laptop chassis ($(cat /sys/class/dmi/id/chassis_type 2>/dev/null)); skipping suspend hook"
    return 0
  fi
  local src="${DOTFILES_DIR}/system/usr/lib/systemd/system-sleep/cyberpunk-suspend.sh"
  if [[ ! -f "$src" ]]; then
    warn "${src} missing — skipping suspend hook deploy"
    return 0
  fi
  sudo install -D -m 0755 -o root -g root "$src" \
       /usr/lib/systemd/system-sleep/cyberpunk-suspend.sh
  ok "/usr/lib/systemd/system-sleep/cyberpunk-suspend.sh (journalctl -t cyberpunk-suspend)"
}

# ============================================================
# L6 — Dock auto-layout (laptops only)
# ============================================================
# Drops the udev rule + handler script.  The handler runs as root from
# udev's RUN+=, then `runuser -u <graphical-user>`'s into the user's
# DBUS session to invoke kscreen-doctor.  Layouts are persisted under
# ~/.config/dotfiles/dock-layouts/<dock-hash>.json (per-machine state,
# NOT in the repo); ~/.config/dotfiles-local/dock-layouts/ takes
# precedence if populated, mirroring apply_local_overrides convention.
#
# On first connect with no saved layout, the handler SAVES the current
# layout — so the user docks-once-with-monitors-arranged and every
# subsequent re-dock auto-applies.
#
# Idempotent — install + udevadm reload + trigger every deploy.
deploy_dock_handler() {
  if ! is_laptop_chassis; then
    log "non-laptop chassis; skipping dock auto-layout hook"
    return 0
  fi
  local sh_src="${DOTFILES_DIR}/system/usr/local/bin/cyberpunk-dock-handler.sh"
  local rule_src="${DOTFILES_DIR}/system/etc/udev/rules.d/95-cyberpunk-dock.rules"
  if [[ ! -f "$sh_src" || ! -f "$rule_src" ]]; then
    warn "dock handler sources missing under ${DOTFILES_DIR}/system/ — skipping"
    return 0
  fi
  sudo install -D -m 0755 -o root -g root "$sh_src" \
       /usr/local/bin/cyberpunk-dock-handler.sh
  ok "/usr/local/bin/cyberpunk-dock-handler.sh"
  sudo install -D -m 0644 -o root -g root "$rule_src" \
       /etc/udev/rules.d/95-cyberpunk-dock.rules
  ok "/etc/udev/rules.d/95-cyberpunk-dock.rules"
  # Apply without reboot.  `control --reload-rules` re-reads rule files;
  # `trigger` re-fires `add` for devices already on the bus so a
  # currently-attached dock picks up the new rule immediately.
  # Best-effort — udev failures shouldn't abort the deploy.
  sudo udevadm control --reload-rules 2>/dev/null \
    || warn "udevadm control --reload-rules failed"
  sudo udevadm trigger --subsystem-match=usb --action=add 2>/dev/null \
    || warn "udevadm trigger failed"
  log "  dock layouts → ~/.config/dotfiles/dock-layouts/<hash>.json"
  log "  override via   ~/.config/dotfiles-local/dock-layouts/<hash>.json"
  log "  inspect events:  journalctl -t cyberpunk-dock -f"
}

deploy_phase() {
  ensure_sudo
  log "Deploying config files (desktop=${DESKTOP}) …"
  local entry name dest

  # NVIDIA Wayland env vars — system-wide file under /etc/environment.d/.
  # Gated internally on GPU_VENDOR=nvidia; no-op + log on Intel/AMD-only
  # boxes (e.g. T14).  Applies to BOTH desktops (i3 + plasma) because
  # the env vars are session-wide and only meaningful when the NVIDIA
  # driver is loaded — harmless on i3 if someone reverse-runs that path.
  deploy_nvidia_wayland_env || warn "(nvidia-wayland env step had warnings)"

  # Common configs — deployed regardless of desktop.
  for entry in "${CONFIG_MAP_COMMON[@]}"; do
    name="${entry%%:*}"
    dest="${entry#*:}"
    deploy_one "$name" "$dest"
  done

  # Desktop-specific config trees.
  case "$DESKTOP" in
    i3)
      for entry in "${CONFIG_MAP_I3[@]}"; do
        name="${entry%%:*}"
        dest="${entry#*:}"
        deploy_one "$name" "$dest"
      done
      ;;
    plasma)
      for entry in "${CONFIG_MAP_PLASMA[@]}"; do
        name="${entry%%:*}"
        dest="${entry#*:}"
        deploy_one "$name" "$dest"
      done
      # Single-file Plasma configs (live at ~/.config/<name>, not under
      # a subdir).  Each is a direct copy; idempotent re-runs overwrite.
      local plasma_src="${DOTFILES_DIR}/plasma"
      local f
      # kdeglobals / kwinrc / kwinrulesrc / plasmarc / konsolerc /
      # breezerc — full-file overwrite is safe.  These contain only
      # OUR theme tunables (cyberpunk colours, kwin desktops/effects,
      # window rules for conky); plasma's runtime additions go in
      # other files (plasma-org.kde.plasma.desktop-appletsrc,
      # kactivitymanagerdrc, …) that we deliberately don't touch.
      for f in kdeglobals kwinrc kwinrulesrc plasmarc konsolerc breezerc; do
        if [[ -f "${plasma_src}/${f}" ]]; then
          install -D -m 0644 "${plasma_src}/${f}" "${HOME}/.config/${f}"
          ok ".config/${f}"
        fi
      done

      # Plasma explicit-sync — must run AFTER the kwinrc install above
      # so we merge our key into the file we just shipped (not into a
      # stale plasma-default that the install -D would then overwrite).
      # No-op when GPU_VENDOR != nvidia (T14 path).  See function header
      # for the KWin / NVIDIA version-detection rationale.
      enable_plasma_explicit_sync || warn "(explicit-sync toggle had warnings)"

      # kglobalshortcutsrc gets MERGED, not overwritten, because plasma
      # auto-populates it with dozens of factory defaults the user
      # actively relies on:
      #   • [plasmashell]          — Activities, KRunner (Alt+Space)
      #   • [org_kde_powerdevil]   — Sleep / Hibernate / Lock / PowerOff
      #   • [kmix]                 — XF86Audio* volume keys
      #   • [mediacontrol]         — Play / Pause / Next / Prev keys
      #   • [KDE Keyboard Layout Switcher]
      #   • [ksmserver]            — Logout (Ctrl+Alt+Del)
      # A full-file overwrite would silently nuke all of those.  Use
      # kwriteconfig6 to surgically set ONLY the keys our shipped
      # kglobalshortcutsrc owns (Meta+1..4 desktop switching,
      # Meta+Shift+1..4 window-to-desktop, Meta+Return → alacritty,
      # Meta+comma/period cycle, Meta+Tab overview, Meta+Q → close
      # window) plus the plasmashell unbindings that pre-empt
      # kglobalaccel's conflict resolver (see kglobalshortcutsrc
      # header comment for why those nones are load-bearing), and
      # preserve the rest of the file as plasma left it.
      if [[ -f "${plasma_src}/kglobalshortcutsrc" ]] \
         && have kwriteconfig6; then
        local f="${HOME}/.config/kglobalshortcutsrc"
        local n
        for n in 1 2 3 4; do
          kwriteconfig6 --file "$f" --group kwin \
            --key "Switch to Desktop $n" "Meta+$n,none,Switch to Desktop $n"
          kwriteconfig6 --file "$f" --group kwin \
            --key "Window to Desktop $n" "Meta+Shift+$n,none,Window to Desktop $n"
          # plasma ships these bound to Meta+N by default — kglobalaccel's
          # conflict resolver picks plasmashell over kwin on tie, which
          # silently demotes our Switch-to-Desktop bindings.  Force unbind.
          kwriteconfig6 --file "$f" --group plasmashell \
            --key "activate task manager entry $n" \
            "none,none,Activate Task Manager Entry $n"
        done
        kwriteconfig6 --file "$f" --group kwin \
          --key "Switch One Desktop to the Right" \
          "Meta+period,Meta+Ctrl+Right,Switch One Desktop to the Right"
        kwriteconfig6 --file "$f" --group kwin \
          --key "Switch One Desktop to the Left" \
          "Meta+comma,Meta+Ctrl+Left,Switch One Desktop to the Left"
        kwriteconfig6 --file "$f" --group kwin \
          --key "Overview" "Meta+Tab,Meta+W,Toggle Overview"
        # Close focused window — i3's $mod+Shift+q minus the Shift.
        # Alt+F4 stays as secondary so legacy workflows still work.
        kwriteconfig6 --file "$f" --group kwin \
          --key "Window Close" "Meta+Q,Alt+F4,Close Window"
        # Plasma ships Meta+Q → Show Activity Switcher by default; clear
        # it so our Window Close above wins the conflict resolver.
        kwriteconfig6 --file "$f" --group plasmashell \
          --key "manage activities" "none,none,Show Activity Switcher"
        # Plasma ships Meta+. → emojier _launch by default; clear it so
        # our `Switch One Desktop to the Right` (Meta+period) takes.
        # kglobalaccel refuses to reassign a service _launch's key on
        # setShortcut, so this clear is load-bearing for Meta+. — DON'T
        # remove it without testing the cycle binding still works.
        kwriteconfig6 --file "$f" --group "services" \
          --group "org.kde.plasma.emojier.desktop" --key "_launch" \
          "none,none,Emoji Selector"
        # services][Alacritty.desktop][_launch] — the canonical Plasma
        # surface for "global hotkey launches a .desktop file".
        kwriteconfig6 --file "$f" --group "services" \
          --group "Alacritty.desktop" --key "_launch" \
          "Meta+Return,none,Alacritty"
        # services][cyberpunk-cheatsheet.desktop][_launch] — Meta+/
        # launches the cheatsheet popup (Plasma equivalent of i3's
        # `bindsym $mod+slash exec`).  The .desktop file is deployed
        # to ~/.local/share/applications/ above.
        kwriteconfig6 --file "$f" --group "services" \
          --group "cyberpunk-cheatsheet.desktop" --key "_launch" \
          "Meta+Slash,none,Cyberpunk hotkey cheatsheet"
        ok ".config/kglobalshortcutsrc (merged via kwriteconfig6)"
      elif [[ -f "${plasma_src}/kglobalshortcutsrc" ]]; then
        # Fallback: kwriteconfig6 missing (apt list raced terminal_phase).
        # Only install if NO existing file — refuse to clobber.
        if [[ ! -f "${HOME}/.config/kglobalshortcutsrc" ]]; then
          install -D -m 0644 "${plasma_src}/kglobalshortcutsrc" \
            "${HOME}/.config/kglobalshortcutsrc"
          ok ".config/kglobalshortcutsrc (fresh — kwriteconfig6 unavailable)"
        else
          warn "kwriteconfig6 missing AND ~/.config/kglobalshortcutsrc"
          warn "exists — skipping rather than clobber.  Re-run after"
          warn "\`sudo apt install libkf6config-bin\` (which ships"
          warn "kwriteconfig6) to apply our hotkey defaults."
        fi
      fi
      # CyberpunkCyan color scheme → ~/.local/share/color-schemes/
      # Individual file copy (NOT rsync --delete) — that directory is
      # shared with any color schemes the user installed manually via
      # System Settings → Colors → Get New… or third-party packages.
      if [[ -f "${plasma_src}/color-schemes/CyberpunkCyan.colors" ]]; then
        install -D -m 0644 \
          "${plasma_src}/color-schemes/CyberpunkCyan.colors" \
          "${HOME}/.local/share/color-schemes/CyberpunkCyan.colors"
        ok ".local/share/color-schemes/CyberpunkCyan.colors"
      fi
      # Konsole profile + colorscheme → ~/.local/share/konsole/
      # Same rationale: this directory may have other user-installed
      # profiles (downloaded from KDE Store, or set up manually); we
      # only own the two CyberpunkCyan.* files.
      local kf
      for kf in CyberpunkCyan.profile CyberpunkCyan.colorscheme; do
        if [[ -f "${plasma_src}/konsole/${kf}" ]]; then
          install -D -m 0644 "${plasma_src}/konsole/${kf}" \
            "${HOME}/.local/share/konsole/${kf}"
          ok ".local/share/konsole/${kf}"
        fi
      done
      # kscreenlockerrc — templated (@HOME@ → real $HOME for wallpaper path)
      deploy_templated_file \
        "${plasma_src}/kscreenlockerrc" \
        "${HOME}/.config/kscreenlockerrc" 0644
      # XDG autostart entries — templated.  Both files carry @HOME@ in
      # their Exec= line because the XDG Desktop Entry spec does NOT
      # define %h as a field code (the standard ones are %f/%F/%u/%U/
      # %i/%c/%k); KIO's launcher does not substitute %h and the launch
      # would fail.  Substituting @HOME@ → real $HOME at deploy time is
      # the only correct fix here.  apply-theme.sh lives at ~/.config/
      # plasma/apply-theme.sh and is referenced by cyberpunk-theme.desktop.
      deploy_templated_file \
        "${plasma_src}/autostart/conky.desktop" \
        "${HOME}/.config/autostart/conky.desktop" 0644
      deploy_templated_file \
        "${plasma_src}/autostart/cyberpunk-theme.desktop" \
        "${HOME}/.config/autostart/cyberpunk-theme.desktop" 0644
      install -D -m 0755 "${plasma_src}/apply-theme.sh" \
        "${HOME}/.config/plasma/apply-theme.sh"
      ok ".config/plasma/apply-theme.sh"
      # kga_push.py — Python helper that apply-theme.sh invokes to
      # push every kglobalaccel binding over a SINGLE D-Bus session
      # connection.  Replaces the previous 17-sequential-dbus-send
      # loop; see comments in apply-theme.sh and kga_push.py.  Needs
      # python3-dbus (in DESKTOP_PLASMA_PACKAGES) — apply-theme.sh
      # falls back to the legacy dbus-send loop if the import fails.
      install -D -m 0755 "${plasma_src}/kga_push.py" \
        "${HOME}/.config/plasma/kga_push.py"
      ok ".config/plasma/kga_push.py"
      # kscreen-baseline.py — Python helper that apply-theme.sh
      # invokes to apply per-monitor refresh / VRR / HDR baseline
      # (D3 + D7).  The baseline JSON itself lives at
      # ~/.config/dotfiles/kscreen-baseline.json and is intentionally
      # NOT in the repo — it's per-machine state generated by the
      # user via `kscreen-baseline.py --snapshot` after configuring
      # monitors in System Settings → Display.  See the script's
      # docstring for the two-phase usage model.
      install -D -m 0755 "${plasma_src}/kscreen-baseline.py" \
        "${HOME}/.config/plasma/kscreen-baseline.py"
      ok ".config/plasma/kscreen-baseline.py"
      # cheatsheet.sh — Meta+/ popup script that re-renders the
      # cyberpunk-dotfiles shortcuts table from ~/.config/
      # kglobalshortcutsrc each invocation (single source of truth).
      install -D -m 0755 "${plasma_src}/cheatsheet.sh" \
        "${HOME}/.config/plasma/cheatsheet.sh"
      ok ".config/plasma/cheatsheet.sh"
      # cyberpunk-cheatsheet.desktop — templated like the autostart
      # entries because its Exec= line carries @HOME@ (XDG Desktop
      # Entry spec has no %h field code).  Deployed to
      # ~/.local/share/applications/ so kglobalaccel can resolve the
      # `[services][cyberpunk-cheatsheet.desktop] _launch=Meta+/`
      # entry in kglobalshortcutsrc.
      deploy_templated_file \
        "${plasma_src}/cyberpunk-cheatsheet.desktop" \
        "${HOME}/.local/share/applications/cyberpunk-cheatsheet.desktop" 0644
      ;;
  esac

  # Single-file copies — common to both desktops.
  local gtk2_src="${DOTFILES_DIR}/gtk-2.0/gtkrc"
  [[ -f "$gtk2_src" ]] && { cp "$gtk2_src" "${HOME}/.gtkrc-2.0"; ok ".gtkrc-2.0"; }

  # ~/.xsession is X11-only — only deploy on the i3 path.  Under SDDM +
  # Plasma Wayland session, ~/.xsession is ignored anyway, but leaving
  # a stale one around can confuse a misbehaving session-picker.
  if [[ "$DESKTOP" == "i3" ]]; then
    local xsess="${SCRIPTS_DIR}/xsession.sh"
    if [[ -f "$xsess" ]]; then
      install -m 0755 "$xsess" "${HOME}/.xsession"
      ok ".xsession"
    fi
    local xres="${SCRIPTS_DIR}/Xresources"
    [[ -f "$xres" ]] && { cp "$xres" "${HOME}/.Xresources"; ok ".Xresources"; }
  fi

  local zshrc_src="${DOTFILES_DIR}/zsh/.zshrc"
  [[ -f "$zshrc_src" ]] && { cp "$zshrc_src" "${HOME}/.zshrc"; ok ".zshrc"; }

  # Mark every shell helper executable.  rsync usually preserves perms,
  # but if anything came in via scp or a manual copy the +x bit can be
  # lost — re-applying it here is cheap and idempotent.  Each chmod is
  # guarded with `2>/dev/null || true` so missing-on-this-desktop paths
  # (e.g. polybar/lockscreen on plasma) don't fail the deploy.
  chmod +x "${HOME}/.config/polybar/launch.sh"      2>/dev/null || true
  chmod +x "${HOME}/.config/conky/launch.sh"        2>/dev/null || true
  chmod +x "${HOME}/.config/lockscreen/lock.sh"     2>/dev/null || true
  chmod +x "${HOME}/.config/wallpaper/download_wallpaper.sh" 2>/dev/null || true
  chmod +x "${HOME}/.config/i3/scripts/"*.sh        2>/dev/null || true
  chmod +x "${HOME}/.config/polybar/scripts/"*.sh   2>/dev/null || true
  chmod +x "${HOME}/.config/plasma/apply-theme.sh"  2>/dev/null || true
  chmod +x "${HOME}/.config/plasma/cheatsheet.sh"   2>/dev/null || true
  chmod +x "${HOME}/.config/plasma/kga_push.py"     2>/dev/null || true

  # SECURITY: WireGuard config files contain a private key in cleartext.
  # `wg-quick` actually refuses to bring an interface up if the .conf is
  # group/world-readable, but the warning is easy to miss.  Force 0600
  # owned by root — and 0700 on the directory itself — so even a future
  # `chmod -R` mistake doesn't expose the private keys.
  if [[ -d /etc/wireguard ]]; then
    sudo chown -R root:root /etc/wireguard 2>/dev/null || true
    sudo chmod 700 /etc/wireguard 2>/dev/null || true
    sudo find /etc/wireguard -type f -name '*.conf' \
      -exec chmod 600 {} + 2>/dev/null || true
  fi
  # Also tighten the user's own zsh history if it already exists.
  # (.zshrc does this on every shell start, but doing it during deploy
  # closes the gap before the first new shell is spawned.)
  [[ -f "${HOME}/.zsh_history" ]] && chmod 600 "${HOME}/.zsh_history" \
    2>/dev/null || true

  # Desktop-specific config patches.
  case "$DESKTOP" in
    i3) patch_picom_backend ;;
  esac
  # Always patch conky window type — the function handles both desktops.
  # Must run after deploy so rsync doesn't overwrite the patched config.
  patch_conky_window_type

  # Wallpaper: prefer the curated Unsplash hacker image
  # (download_wallpaper.sh, SHA-256 pinned).  If the download fails —
  # offline install, CDN unreachable, hash mismatch the user hasn't
  # acked — fall back to the procedural Pillow generator so we always
  # leave ~/.config/wallpaper/wallpaper.png in place.  The same PNG is
  # consumed by feh (i3) and Plasma (kscreenlockerrc + apply-theme.sh).
  if [[ -x "${HOME}/.config/wallpaper/download_wallpaper.sh" ]] \
       && bash "${HOME}/.config/wallpaper/download_wallpaper.sh" \
            >"${LOG_DIR}/wallpaper.log" 2>&1; then
    ok "wallpaper (Unsplash, hacker theme)"
  elif [[ -f "${HOME}/.config/wallpaper/generate_wallpaper.py" ]]; then
    warn "online wallpaper download failed — using procedural generator"
    python3 "${HOME}/.config/wallpaper/generate_wallpaper.py" \
      --width 1920 --height 1080 \
      --output "${HOME}/.config/wallpaper/wallpaper.png" \
      && ok "wallpaper (procedural)" \
      || warn "wallpaper generation also failed (see ${LOG_DIR}/wallpaper.log)"
  else
    warn "no wallpaper source available"
  fi

  mkdir -p "${HOME}/Pictures"

  # Hyper-V Xorg config — only meaningful on Hyper-V with the i3/Xorg
  # stack.  Under plasma+Wayland Hyper-V there's no Xorg config to write;
  # plasma users on Hyper-V should rely on the hyperv-daemons + KMS.
  local hv_src="${DOTFILES_DIR}/xorg.conf.d/10-hyperv.conf"
  if [[ "$VIRT_TYPE" == "hyperv" && "$DESKTOP" == "i3" && -f "$hv_src" ]]; then
    log "Deploying Hyper-V Xorg config …"
    sudo install -d /etc/X11/xorg.conf.d
    sudo install -m 0644 "$hv_src" /etc/X11/xorg.conf.d/10-hyperv.conf
    ok "/etc/X11/xorg.conf.d/10-hyperv.conf"
  else
    sudo rm -f /etc/X11/xorg.conf.d/10-hyperv.conf 2>/dev/null || true
  fi

  # Display manager + greeter config — split by $DESKTOP.
  case "$DESKTOP" in
    i3)
      # LightDM greeter — template substitution.  See deploy_templated_file
      # for why this uses python3 str.replace and not sed/awk/bash.
      deploy_templated_file \
        "${DOTFILES_DIR}/lightdm/lightdm-gtk-greeter.conf.in" \
        "/etc/lightdm/lightdm-gtk-greeter.conf" 0644

      # If xrdp happens to be installed (manually), wire it up to ~/.xsession
      if dpkg -l xrdp 2>/dev/null | grep -q '^ii'; then
        log "xrdp detected — configuring (start service, add ssl-cert group)"
        sudo usermod -aG ssl-cert "$USER" 2>/dev/null || true
        sudo usermod -aG ssl-cert xrdp  2>/dev/null || true
        sudo systemctl enable --now xrdp 2>/dev/null || true
        sudo systemctl restart xrdp 2>/dev/null || true
        ok "xrdp configured"
      else
        log "xrdp not installed (intentional) — skipping"
      fi

      # Disable sddm (if a prior plasma install left it enabled) BEFORE
      # enabling lightdm.  display-manager.service is a single-target
      # systemd alias; whichever DM was enabled last "wins" the symlink,
      # so two enabled DMs leaves the boot session ambiguous.  Symmetric
      # to the lightdm-disable in the plasma branch below.
      if systemctl list-unit-files sddm.service 2>/dev/null | grep -q '^sddm.service'; then
        sudo systemctl disable sddm >/dev/null 2>&1 || true
        ok "sddm disabled"
      fi

      log "Enabling lightdm …"
      sudo systemctl enable lightdm >/dev/null 2>&1 || true
      ok "lightdm enabled (run \`sudo systemctl start lightdm\` to start now)"
      ;;
    plasma)
      # SDDM dropin (Wayland default session, breeze theme) — root-owned.
      local sddm_src="${DOTFILES_DIR}/sddm/10-wayland.conf"
      if [[ -f "$sddm_src" ]]; then
        sudo install -d -m 0755 /etc/sddm.conf.d
        sudo install -m 0644 "$sddm_src" /etc/sddm.conf.d/10-wayland.conf
        ok "/etc/sddm.conf.d/10-wayland.conf"
      fi

      # Disable lightdm (if present from a previous i3 install) BEFORE
      # enabling sddm — two DMs both `enabled` leaves systemd ambiguous
      # about which one display-manager.service should point at.
      if systemctl list-unit-files lightdm.service 2>/dev/null | grep -q '^lightdm.service'; then
        sudo systemctl disable lightdm >/dev/null 2>&1 || true
        ok "lightdm disabled"
      fi

      log "Enabling sddm …"
      sudo systemctl enable sddm >/dev/null 2>&1 || true
      ok "sddm enabled (run \`sudo systemctl start sddm\` to start now)"

      # Live-apply theme + wallpaper if plasmashell is already running
      # (e.g. re-deploying from a plasma session).  Otherwise the
      # cyberpunk-theme.desktop autostart entry picks it up on first
      # plasma login.  Both paths are idempotent.
      if [[ -x "${HOME}/.config/plasma/apply-theme.sh" ]]; then
        "${HOME}/.config/plasma/apply-theme.sh" || true
      fi
      ;;
  esac

  # Mobile-only system hooks — chassis-gated inside each helper.  Runs
  # AFTER the desktop deploy so an `--desktop=plasma` Plasma session is
  # already in place to talk to (kscreen-doctor needs a Plasma session
  # bus to be useful).  No-op on desktops / VMs.
  deploy_suspend_hook
  deploy_dock_handler

  # Per-host overrides — final layer.  See apply_local_overrides() for
  # the rationale + DOTFILES_NO_LOCAL escape hatch.  Runs AFTER all
  # other deploy steps so it overlays cleanly over both common +
  # desktop-specific configs, including the Plasma single-file writes
  # above.  Tightly scoped to ~/.config/.
  apply_local_overrides
}

# ============================================================
# Terminal stack: tpm / oh-my-zsh / starship / nerd font / shell
# ============================================================
install_nerd_font() {
  # We deliberately install the *Nerd Font* JetBrainsMono variant from
  # the upstream `ryanoasis/nerd-fonts` release rather than Debian's
  # `fonts-jetbrains-mono` apt package.  They are NOT the same font:
  #   • fonts-jetbrains-mono (apt, already in BASE_PACKAGES) is the
  #     plain JetBrains Mono — used by lightdm, gtk theming, and any
  #     fontconfig consumer that asks for "JetBrains Mono".
  #   • The Nerd Font patched build adds Material/FontAwesome/DevIcons
  #     glyphs in the Unicode Private Use Area.  i3 title bars,
  #     polybar, alacritty, rofi all rely on those PUA glyphs to render
  #     icons (battery indicator, vpn status, app prefixes …).  Without
  #     this build, those slots render as tofu boxes.
  # Debian does not ship the Nerd-patched build in any of its repos
  # (bookworm, trixie, or experimental as of writing), so a manual
  # download is the only path.  We make it tamper-evident below.
  if fc-list 2>/dev/null | grep -qi 'JetBrainsMonoNerd'; then
    ok "JetBrainsMono Nerd Font already installed"
    return 0
  fi
  log "Installing JetBrainsMono Nerd Font …"
  mkdir -p "${HOME}/.local/share/fonts/NerdFonts"
  local rel="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.3.0"
  local zip="${LOG_DIR}/JetBrainsMono.zip"
  local sums="${LOG_DIR}/nerd-fonts-sha256.txt"

  # SECURITY: Nerd Fonts ships a single SHA-256.txt manifest covering
  # every font zip in a release.  We download the zip + the manifest,
  # extract the line for our specific zip, and verify with sha256sum -c.
  # If GitHub releases were ever tampered with, the manifest hash would
  # need to be re-signed in lockstep — protects against simple CDN
  # poisoning of the .zip alone.
  curl -fsSL "$rel/JetBrainsMono.zip" -o "$zip" \
    || { warn "Nerd Font zip download failed"; return 1; }
  curl -fsSL "$rel/SHA-256.txt"       -o "$sums" \
    || { warn "Nerd Font SHA-256 manifest download failed"; return 1; }

  local expected
  expected="$(awk '$2=="JetBrainsMono.zip" {print $1}' "$sums" | head -1)"
  if [[ -z "$expected" ]]; then
    warn "JetBrainsMono.zip not listed in SHA-256.txt — refusing to install"
    return 1
  fi
  if ! ( cd "$LOG_DIR" \
         && echo "$expected  JetBrainsMono.zip" | sha256sum -c - >/dev/null
       ); then
    warn "JetBrainsMono.zip SHA-256 mismatch — refusing to install"
    return 1
  fi
  ok "JetBrainsMono.zip SHA-256 verified ($expected)"

  python3 - "$zip" <<'PYEOF'
import sys, zipfile, pathlib
dest = pathlib.Path.home() / ".local/share/fonts/NerdFonts"
dest.mkdir(parents=True, exist_ok=True)
z = zipfile.ZipFile(sys.argv[1])
n = 0
for f in z.namelist():
    if f.endswith(".ttf") and "NerdFont" in f:
        z.extract(f, dest); n += 1
print(f"extracted {n} TTFs")
PYEOF
  fc-cache -f "${HOME}/.local/share/fonts/" >/dev/null 2>&1 || true
  ok "JetBrainsMono Nerd Font installed"
}

install_omz() {
  if [[ -f "${HOME}/.oh-my-zsh/oh-my-zsh.sh" ]]; then
    ok "oh-my-zsh already installed"
    return 0
  fi
  log "Cloning oh-my-zsh …"
  # SECURITY: avoid `curl ... | sh`.  The upstream install.sh just clones
  # this repo and writes a default ~/.zshrc — we overwrite that .zshrc
  # later anyway, so cloning is functionally equivalent and avoids
  # piping arbitrary remote shell into our user.
  rm -rf "${HOME}/.oh-my-zsh"
  if git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git \
       "${HOME}/.oh-my-zsh" >"${LOG_DIR}/omz.log" 2>&1; then
    ok "oh-my-zsh cloned"
  else
    warn "oh-my-zsh clone failed (see ${LOG_DIR}/omz.log)"
    return 1
  fi
}

install_zsh_plugins() {
  local custom="${HOME}/.oh-my-zsh/custom"
  local plugin repo dest
  for plugin in zsh-autosuggestions zsh-syntax-highlighting; do
    case "$plugin" in
      zsh-autosuggestions)     repo="https://github.com/zsh-users/zsh-autosuggestions" ;;
      zsh-syntax-highlighting) repo="https://github.com/zsh-users/zsh-syntax-highlighting" ;;
    esac
    dest="${custom}/plugins/${plugin}"
    if [[ -d "$dest" ]]; then
      ok "${plugin} already present"
    else
      git clone --depth=1 "$repo" "$dest" >/dev/null 2>&1 \
        && ok "$plugin" || warn "$plugin clone failed"
    fi
  done
}

install_starship() {
  if command -v starship >/dev/null 2>&1 \
     || [[ -x "${HOME}/.local/bin/starship" ]]; then
    ok "starship already installed"
    return 0
  fi

  # PREFERRED PATH: install via apt.  Debian 13 (trixie) ships starship
  # in main — using it removes the manual SHA-256 dance, places the
  # binary under apt's upgrade path, and avoids a privileged write into
  # /usr/local/bin/.  We check apt-cache first to avoid the noisy
  # `Unable to locate package` failure on Debian 12 (bookworm), which
  # does not ship starship in main.
  if apt-cache show starship >/dev/null 2>&1; then
    log "Installing starship from apt …"
    if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
         --no-install-recommends starship \
         >"${LOG_DIR}/apt_starship.log" 2>&1; then
      ok "starship installed via apt"
      return 0
    else
      tail -10 "${LOG_DIR}/apt_starship.log" || true
      warn "apt install starship failed — falling back to tarball"
    fi
  else
    log "starship not in apt (likely pre-trixie) — using tarball fallback"
  fi

  # FALLBACK PATH (Debian 12 / older / apt failure): pull the arch-
  # specific tarball directly from the GitHub release, verify its
  # SHA256 against the published sidecar, and only then extract.  This
  # turns a "trust whatever HTTP returns" install into a tamper-evident
  # one — a compromised CDN can't ship a backdoored binary without also
  # compromising the GitHub release.  We never pipe install.sh.
  log "Installing starship from GitHub release (verified SHA256) …"
  mkdir -p "${HOME}/.local/bin"
  local arch tarball url tmp
  arch="$(uname -m)"
  case "$arch" in
    x86_64)  tarball="starship-x86_64-unknown-linux-gnu.tar.gz" ;;
    aarch64) tarball="starship-aarch64-unknown-linux-gnu.tar.gz" ;;
    armv7l)  tarball="starship-arm-unknown-linux-musleabihf.tar.gz" ;;
    *) warn "starship: unsupported arch '$arch'"; return 1 ;;
  esac
  url="https://github.com/starship/starship/releases/latest/download/${tarball}"
  tmp="$(mktemp -d)" || { warn "starship: mktemp -d failed"; return 1; }
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  if ! curl -fsSL "$url"            -o "$tmp/starship.tar.gz" \
    || ! curl -fsSL "${url}.sha256" -o "$tmp/starship.tar.gz.sha256"; then
    warn "starship: download failed"
    return 1
  fi
  ( cd "$tmp" \
    && echo "$(awk '{print $1}' starship.tar.gz.sha256)  starship.tar.gz" \
       | sha256sum -c - >/dev/null
  ) || { warn "starship: SHA256 mismatch — refusing to install"; return 1; }
  tar -C "$tmp" -xzf "$tmp/starship.tar.gz" starship
  install -m 0755 "$tmp/starship" "${HOME}/.local/bin/starship"
  ok "starship → ~/.local/bin/starship  (SHA256 verified)"
}

install_tpm() {
  if [[ -d "${HOME}/.tmux/plugins/tpm" ]]; then
    ok "tpm already cloned"
  else
    git clone --depth=1 https://github.com/tmux-plugins/tpm \
      "${HOME}/.tmux/plugins/tpm" >/dev/null 2>&1 \
      && ok "tpm cloned" || warn "tpm clone failed"
  fi
  TMUX_PLUGIN_MANAGER_PATH="${HOME}/.tmux/plugins" \
    "${HOME}/.tmux/plugins/tpm/bin/install_plugins" >/dev/null 2>&1 \
    && ok "tmux plugins installed" || warn "tmux plugin install warnings (non-fatal)"
}

symlink_debian_aliases() {
  # Debian renames fd→fdfind and bat→batcat; restore canonical names locally.
  mkdir -p "${HOME}/.local/bin"
  if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
    ln -sf "$(command -v fdfind)" "${HOME}/.local/bin/fd"
    ok "fd → fdfind"
  fi
  if command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
    ln -sf "$(command -v batcat)" "${HOME}/.local/bin/bat"
    ok "bat → batcat"
  fi
}

set_default_shell() {
  local zsh_path current
  zsh_path="$(command -v zsh 2>/dev/null || true)"
  current="$(getent passwd "$USER" | cut -d: -f7)"
  if [[ "$current" == *zsh* ]]; then
    ok "default shell already zsh ($current)"
    return 0
  fi
  if [[ -z "$zsh_path" || "${zsh_path:0:1}" != "/" ]]; then
    warn "zsh not found in PATH — install base packages first"
    return 1
  fi
  sudo usermod -s "$zsh_path" "$USER" \
    && ok "default shell → $zsh_path" \
    || warn "usermod -s failed"
}

nvim_plugin_sync() {
  if ! command -v nvim >/dev/null 2>&1; then
    warn "nvim not installed — skipping plugin sync"
    return 0
  fi
  log "Pre-installing neovim plugins + treesitter parsers (headless) …"
  # TSUpdateSync blocks until parsers compile; without it, auto_install
  # fires async and parsers may not be ready when headless nvim exits.
  nvim --headless '+Lazy! sync' '+TSUpdateSync' +qa \
    >"${LOG_DIR}/nvim_lazy.log" 2>&1 || true
  local n_plug n_pars
  n_plug="$(ls "${HOME}/.local/share/nvim/lazy/" 2>/dev/null | wc -l)"
  n_pars="$(ls "${HOME}/.local/share/nvim/lazy/nvim-treesitter/parser/" 2>/dev/null | wc -l)"
  if [[ "$n_plug" -gt 0 ]]; then
    ok "${n_plug} neovim plugin(s), ${n_pars} treesitter parser(s)"
  else
    warn "neovim plugin sync produced no plugins (see ${LOG_DIR}/nvim_lazy.log)"
  fi
}

install_nix() {
  # Install the Nix package manager (daemon mode) on top of Debian and
  # wire up direnv + nix-direnv for per-project flake-based dev shells.
  #
  # Coexists with apt — apt remains the system package manager.  The
  # only "everyday" Nix command becomes `nix develop` (auto-activated
  # by direnv when you cd into a project with a `flake.nix`).  See
  # `templates/` for starter flakes and `readme/nix.md` for the model.
  #
  # Skip this step entirely with `./local_setup.sh setup --no-nix`.
  if [[ "${WANT_NIX:-1}" != 1 ]]; then
    log "Skipping Nix install (--no-nix)"
    return 0
  fi

  # ── Detect a prior Nix install BEFORE deciding to run the installer.
  #
  # The previous version of this function only checked `command -v nix`.
  # That misses a common case: Nix IS installed (full multi-user
  # install — /nix/store, daemon unit, /etc/profile.d/nix.sh all
  # present), but the in-flight `bash` running this script hasn't
  # sourced /etc/profile.d/nix.sh yet, so `command -v nix` returns
  # false.  Re-running the installer in that state hits the
  # "backup-file-already-exists" guard and aborts the whole stage.
  #
  # We treat ANY of these as "Nix is here, don't curl|sh":
  #   • `command -v nix`                                    (on PATH)
  #   • /nix/var/nix/profiles/default/bin/nix              (canonical)
  #   • /nix/store dir exists                              (store)
  #   • /etc/profile.d/nix.sh exists                       (sourcing hook)
  #   • the `nixbld` group exists                          (multi-user)
  # If any are present, we source the profile script and skip ahead to
  # configuring flakes + nix-direnv (idempotent re-runs of the rest).
  local nix_present=0
  if command -v nix >/dev/null 2>&1 \
     || [[ -x /nix/var/nix/profiles/default/bin/nix ]] \
     || [[ -d /nix/store ]] \
     || [[ -f /etc/profile.d/nix.sh ]] \
     || getent group nixbld >/dev/null 2>&1; then
    nix_present=1
  fi

  if (( nix_present )); then
    # Pull the daemon profile into THIS shell so subsequent `nix
    # profile install` calls below work without forcing a logout.
    if ! command -v nix >/dev/null 2>&1 && [[ -f /etc/profile.d/nix.sh ]]; then
      # shellcheck disable=SC1091
      . /etc/profile.d/nix.sh
    fi
    if command -v nix >/dev/null 2>&1; then
      ok "Nix already installed ($(nix --version 2>/dev/null | head -1)) — skipping installer"
    else
      # Half-installed state: store/group exist but no runnable `nix`.
      # We refuse to run the installer here because it would collide
      # with the leftover backup files (see step 1 of readme/nix.md
      # uninstall).  The user has to either fully uninstall first or
      # fix their PATH.  We DO continue — the rest of the function
      # (flakes config, direnv hook) is harmless without nix on PATH.
      warn "Nix state on disk but \`nix\` not on PATH — partial install."
      warn "  /nix/store : $([[ -d /nix/store ]]                    && echo yes || echo no)"
      warn "  profile.d  : $([[ -f /etc/profile.d/nix.sh ]]         && echo yes || echo no)"
      warn "  nixbld grp : $(getent group nixbld >/dev/null         && echo yes || echo no)"
      warn "Skipping curl|sh installer (would trip its backup-file guard)."
      warn "Open a new shell to test \`nix --version\`; if missing, see"
      warn "readme/nix.md for full-uninstall instructions and re-run."
    fi
  else
    log "Installing Nix (daemon mode) — Debian official installer …"
    # SECURITY note on `curl | sh`: Nix's installer is the canonical
    # exception to the no-curl-pipe rule.  Mitigations we apply:
    #   • --proto '=https' --tlsv1.2 — refuse downgrades on the wire.
    #   • Multi-user (daemon) install — Nix store is root-owned, so a
    #     post-install compromise can't poison /nix/store without
    #     root.
    #   • TLS pinning to nixos.org via curl + system CA bundle.
    # The canonical alternative (Determinate Systems installer) is
    # also `curl | sh`; same security model.  Users who want stronger
    # supply-chain assurance can verify the installer's signature
    # manually before running this script.
    if ! sh <(curl --proto '=https' --tlsv1.2 -sSfL \
                   https://nixos.org/nix/install) \
           --daemon --no-channel-add --yes \
           >"${LOG_DIR}/nix_install.log" 2>&1; then
      tail -30 "${LOG_DIR}/nix_install.log" || true
      warn "Nix install failed — see ${LOG_DIR}/nix_install.log"
      return 1
    fi
    ok "Nix daemon installed (multi-user mode)"
    if [[ -f /etc/profile.d/nix.sh ]]; then
      # shellcheck disable=SC1091
      . /etc/profile.d/nix.sh
    fi
  fi

  # Per-user nix.conf — enable flakes + the unified `nix` CLI.  Does
  # not need root (system /etc/nix/nix.conf is left untouched).
  install -d -m 0755 "${HOME}/.config/nix"
  if ! grep -q 'experimental-features.*\(nix-command\|flakes\)' \
         "${HOME}/.config/nix/nix.conf" 2>/dev/null; then
    cat >> "${HOME}/.config/nix/nix.conf" <<'EOF'
# Enable flakes + the unified `nix` CLI.  Both required for the
# `nix develop` / `nix shell` / `nix run` workflow.
experimental-features = nix-command flakes
EOF
    ok "flakes enabled in ~/.config/nix/nix.conf"
  fi

  # nix-direnv — fast cached `use flake` integration for direnv.
  # Without it, `direnv reload` re-evaluates the flake from scratch
  # every time you cd in (slow on Python+CUDA flakes).  Idempotent.
  local nd_rc="${HOME}/.nix-profile/share/nix-direnv/direnvrc"
  if [[ ! -f "$nd_rc" ]]; then
    log "Installing nix-direnv via nix profile …"
    if ! command -v nix >/dev/null 2>&1; then
      warn "nix not on PATH — skipping nix-direnv (open a new shell and re-run)"
    elif nix profile install nixpkgs#nix-direnv \
           >"${LOG_DIR}/nix_direnv.log" 2>&1; then
      ok "nix-direnv installed"
    else
      tail -20 "${LOG_DIR}/nix_direnv.log" || true
      warn "nix-direnv install failed — see ${LOG_DIR}/nix_direnv.log"
    fi
  fi

  # direnv glue: tell direnv to source nix-direnv's `use flake` impl.
  install -d -m 0755 "${HOME}/.config/direnv"
  if [[ -f "$nd_rc" ]] \
     && ! grep -qF "$nd_rc" "${HOME}/.config/direnv/direnvrc" 2>/dev/null; then
    echo "source $nd_rc" >> "${HOME}/.config/direnv/direnvrc"
    ok "nix-direnv sourced from ~/.config/direnv/direnvrc"
  fi

  # Helpful hint: where the starter flakes live in this repo.
  if [[ -d "${SCRIPT_DIR}/templates" ]]; then
    log "Starter flakes available at ${SCRIPT_DIR}/templates/"
    log "  cp -r ${SCRIPT_DIR}/templates/python /path/to/your/project/"
    log "  cd /path/to/your/project/ && direnv allow"
  fi
}

terminal_phase() {
  ensure_sudo
  log "Setting up terminal tools …"
  install_nerd_font
  symlink_debian_aliases
  install_tpm
  install_omz
  install_zsh_plugins
  install_starship
  # OMZ install OVERWRITES ~/.zshrc; restore ours after.
  local zshrc_src="${DOTFILES_DIR}/zsh/.zshrc"
  [[ -f "$zshrc_src" ]] && { cp "$zshrc_src" "${HOME}/.zshrc"; ok ".zshrc redeployed"; }
  set_default_shell
  sudo sensors-detect --auto >"${LOG_DIR}/sensors.log" 2>&1 || true
  ok "sensors-detect done"
  nvim_plugin_sync
  install_nix
}

# ============================================================
# Validation
# ============================================================
# Common checks — relevant under either desktop.  Terminal stack, CLI
# tooling, VPN, network backbone, hardware diagnostics.
declare -a VAL_CHECKS_COMMON=(
  # Use `sudo -ln` (list permissions) — exits 0 whenever the user has
  # ANY passwordless capability, so this works in both broad-sudo
  # (install mode) and narrow-sudo (post-harden) configurations.
  # `sudo -n true` would have falsely failed on a hardened system because
  # /usr/bin/true isn't on the narrow allowlist.
  "sudo (NOPASSWD)|sudo -ln 2>/dev/null | grep -q NOPASSWD"
  "alacritty|command -v alacritty"
  "wallpaper|test -f ${HOME}/.config/wallpaper/wallpaper.png"
  "tmux|command -v tmux"
  "neovim|command -v nvim"
  "zsh|command -v zsh"
  "fzf|command -v fzf"
  "starship|command -v starship || test -x ${HOME}/.local/bin/starship"
  "oh-my-zsh|test -d ${HOME}/.oh-my-zsh"
  "tpm|test -d ${HOME}/.tmux/plugins/tpm"
  "tmux config|test -f ${HOME}/.config/tmux/tmux.conf"
  "nvim config|test -f ${HOME}/.config/nvim/init.lua"
  "~/.zshrc|test -f ${HOME}/.zshrc"
  "starship config|test -f ${HOME}/.config/starship/starship.toml"
  "default shell zsh|getent passwd $USER | cut -d: -f7 | grep -q zsh"
  "bat|command -v bat || command -v batcat"
  "grc|command -v grc"
  "netstat|command -v netstat"
  "conky|command -v conky"
  "conky launch.sh|test -x ${HOME}/.config/conky/launch.sh"
  "lm-sensors|command -v sensors"
  "conky config|test -f ${HOME}/.config/conky/conky.conf"
  "mullvad CLI|command -v mullvad"
  "mullvad daemon|systemctl is-active mullvad-daemon"
  "wg-quick|command -v wg-quick"
  "wg|command -v wg"
  "NetworkManager active|systemctl is-active NetworkManager"
  "nmcli|command -v nmcli"
  # iw / rfkill / powertop / tlp-stat live in /usr/sbin, which is NOT on
  # a non-root user's PATH on Debian (see /etc/profile).  Fall back to a
  # direct test on the absolute path so the validation passes for a
  # regular user without forcing them to source root's profile.
  "iw|command -v iw || test -x /usr/sbin/iw"
  "rfkill|command -v rfkill || test -x /usr/sbin/rfkill"
  "acpi|command -v acpi"
  "powertop|command -v powertop || test -x /usr/sbin/powertop"
  "fwupd|command -v fwupdmgr || test -x /usr/bin/fwupdmgr"
  "direnv|command -v direnv"
)

# i3 path — X11 stack: WM, compositor, bar, launcher, notifications,
# screenshot, DM, lockscreen script, polybar helper scripts.
declare -a VAL_CHECKS_I3=(
  "i3|command -v i3"
  "polybar|command -v polybar"
  "picom|command -v picom"
  "rofi|command -v rofi"
  "dunst|command -v dunst"
  "feh|command -v feh"
  "lightdm enabled|systemctl is-enabled lightdm"
  "~/.xsession|test -x ${HOME}/.xsession"
  "~/.config/i3/config|test -f ${HOME}/.config/i3/config"
  "lockscreen script|test -x ${HOME}/.config/lockscreen/lock.sh"
  "rofi config|test -f ${HOME}/.config/rofi/config.rasi"
  "polybar config|test -f ${HOME}/.config/polybar/config.ini"
  "polybar mullvad-status|test -x ${HOME}/.config/polybar/scripts/mullvad-status.sh"
  "polybar wireguard-status|test -x ${HOME}/.config/polybar/scripts/wireguard-status.sh"
  "nm-applet|command -v nm-applet"
  "nm-connection-editor|command -v nm-connection-editor"
)

# Plasma path — KDE Plasma 6 Wayland: WM/compositor (kwin_wayland), DM
# (sddm), native apps, pipewire audio, Wayland clipboard, and deployed
# theme/config files.  Checks that lightdm has been disabled (otherwise
# display-manager.service is ambiguous — both DMs claim the alias).
declare -a VAL_CHECKS_PLASMA=(
  "plasma-desktop|dpkg -l plasma-desktop 2>/dev/null | grep -q '^ii'"
  "kwin_wayland|command -v kwin_wayland"
  "kwin_x11 (VM fallback)|command -v kwin_x11"
  "systemsettings (GUI config)|command -v systemsettings"
  "kscreen (display config — required for monitor setup)|dpkg -l kscreen 2>/dev/null | grep -q '^ii'"
  "powerdevil (power mgmt)|dpkg -l powerdevil 2>/dev/null | grep -q '^ii'"
  "xdg-desktop-portal-kde|dpkg -l xdg-desktop-portal-kde 2>/dev/null | grep -q '^ii'"
  "breeze-gtk-theme|dpkg -l breeze-gtk-theme 2>/dev/null | grep -q '^ii'"
  "sddm enabled|systemctl is-enabled sddm"
  "lightdm not active|! systemctl is-enabled lightdm 2>/dev/null | grep -qx enabled"
  "konsole|command -v konsole"
  "dolphin|command -v dolphin"
  "kde-spectacle|command -v spectacle"
  "kwallet6|dpkg -l kwallet6 2>/dev/null | grep -q '^ii'"
  "polkit-kde-agent-1|test -x /usr/bin/polkit-kde-authentication-agent-1 || test -x /usr/libexec/polkit-kde-authentication-agent-1"
  "pipewire-pulse|command -v pipewire-pulse"
  "wireplumber|command -v wireplumber"
  "wl-clipboard|command -v wl-copy"
  "qt6-wayland|test -f /usr/lib/x86_64-linux-gnu/qt6/plugins/platforms/libqwayland-generic.so || test -f /usr/lib/qt6/plugins/platforms/libqwayland-generic.so"
  "Xwayland|command -v Xwayland"
  "plasma-nm|test -f /usr/lib/x86_64-linux-gnu/qt6/plugins/plasma/applets/plasma_applet_org.kde.plasma.networkmanagement.so || dpkg -l plasma-nm 2>/dev/null | grep -q '^ii'"
  "plasma-pa|dpkg -l plasma-pa 2>/dev/null | grep -q '^ii'"
  "kdeglobals|test -f ${HOME}/.config/kdeglobals"
  "kwinrc|test -f ${HOME}/.config/kwinrc"
  "kwinrulesrc (conky pin)|test -f ${HOME}/.config/kwinrulesrc"
  "kscreenlockerrc|test -f ${HOME}/.config/kscreenlockerrc"
  "CyberpunkCyan color scheme|test -f ${HOME}/.local/share/color-schemes/CyberpunkCyan.colors"
  "konsole CyberpunkCyan profile|test -f ${HOME}/.local/share/konsole/CyberpunkCyan.profile"
  "apply-theme.sh|test -x ${HOME}/.config/plasma/apply-theme.sh"
  "conky autostart|test -f ${HOME}/.config/autostart/conky.desktop"
  "cyberpunk-theme autostart|test -f ${HOME}/.config/autostart/cyberpunk-theme.desktop"
  "/etc/sddm.conf.d/10-wayland.conf|test -f /etc/sddm.conf.d/10-wayland.conf"
)

# ============================================================
# harden / unharden — opt-in security tightening
# ============================================================
# `setup` itself uses NOPASSWD ALL and a permissive base config to keep
# the install pipeline frictionless.  After install, the user can opt
# into a tighter security posture by running `./local_setup.sh harden`,
# which:
#
#   1. Replaces /etc/sudoers.d/<user> with a narrow Cmnd_Alias allowing
#      only the dotfiles' actual runtime/maintenance commands without a
#      password — everything else (including `sudo bash`) prompts.
#   2. Installs ufw with a default-deny INPUT policy + allow-rule for
#      already-established connections + an explicit ssh allow for the
#      user's current SSH peer (so the in-progress session survives).
#   3. Installs `unattended-upgrades` and configures it to apply only
#      Debian-Security packages automatically.  Doesn't touch reboot
#      behaviour — that's a per-user tradeoff.
#   4. Installs systemd-resolved + Quad9 over DNS-over-TLS with DNSSEC
#      validation.  Removes the dhcpcd `static domain_name_servers=` line
#      we may have added during DNS-recovery so resolved owns DNS.
#
# `./local_setup.sh unharden` reverses each of these (broad NOPASSWD
# back, ufw disable, unattended-upgrades disabled, dhcpcd DNS restored).
# Both sub-commands are idempotent and safe to re-run.

# --- 1. Sudoers narrowing -----------------------------------
# Path layout: we keep /etc/sudoers.d/<user> as the canonical sudoers
# file; harden writes the narrow form, unharden writes the broad form.
# The sudoers files are validated with `visudo -cf` BEFORE being
# installed, because a syntactically-broken sudoers file can lock the
# user out of root entirely.
_sudoers_narrow() {
  cat <<EOF
# /etc/sudoers.d/${USER}  —  NARROW ruleset
# Generated by ./local_setup.sh harden on $(date -Iseconds)
#
# Allows the dotfiles' runtime + day-to-day maintenance commands without
# a password.  Anything else still prompts — including \`sudo -i\`,
# \`sudo bash\`, \`sudo su\`, \`sudo nano /etc/...\`, etc.

Cmnd_Alias DOTFILES_VPN = \\
    /usr/bin/wg-quick up *,            \\
    /usr/bin/wg-quick down *,          \\
    /usr/bin/wg show,                  \\
    /usr/bin/wg show *,                \\
    /usr/bin/systemctl start  wg-quick@*, \\
    /usr/bin/systemctl stop   wg-quick@*, \\
    /usr/bin/systemctl status wg-quick@*, \\
    /usr/bin/ls /etc/wireguard,        \\
    /usr/bin/ls /etc/wireguard/

# SECURITY: \`apt-get -y install *\` would let the user
# \`sudo apt-get -y install ./malicious.deb\` and gain root via
# postinst — a near-complete sudoers escape.  The hardened set keeps
# only the read-only / cache-cleaning operations.  Re-running setup or
# installing new packages from now on requires \`unharden\` first (or
# \`sudo apt …\` with a real password prompt — which is the point).
Cmnd_Alias DOTFILES_APT = \\
    /usr/bin/apt-get update,           \\
    /usr/bin/apt-get clean,            \\
    /usr/bin/apt-get autoclean

Cmnd_Alias DOTFILES_SVC = \\
    /usr/bin/systemctl restart polybar, \\
    /usr/bin/systemctl restart picom,   \\
    /usr/bin/systemctl restart lightdm

# Network introspection — used by conky's listenports.py and netstat.py.
# \`ss -p\` shows process names for sockets owned by other users only when
# run as root.  Read-only commands; safe to NOPASSWD.
Cmnd_Alias DOTFILES_NET = \\
    /usr/bin/ss -nlp,                  \\
    /usr/bin/ss -nip,                  \\
    /usr/bin/ss -tl -nlp,              \\
    /usr/bin/ss -ul -nlp,              \\
    /usr/bin/ss -ta -nip,              \\
    /usr/bin/ss -ua -nip,              \\
    /usr/bin/ss -wa -nip

${USER} ALL=(root) NOPASSWD: DOTFILES_VPN, DOTFILES_APT, DOTFILES_SVC, DOTFILES_NET
EOF
}

_sudoers_broad() {
  cat <<EOF
# /etc/sudoers.d/${USER}  —  BROAD ruleset (default during install)
# Generated by ./local_setup.sh unharden on $(date -Iseconds)
#
# WARNING: this allows any command as root without a password.  Use
# this ONLY while installing or re-provisioning the system.  Run
# \`./local_setup.sh harden\` to tighten as soon as you're done.

${USER} ALL=(ALL) NOPASSWD: ALL
EOF
}

_install_sudoers_file() {
  local content="$1" tmp
  # mktemp failure here is dangerous: a missing $tmp would cause `printf
  # > $tmp` to fail with a confusing error AND leave /etc/sudoers.d/$USER
  # in whatever state it was.  Hard-fail so the user notices.
  tmp="$(mktemp)" || die "mktemp failed in _install_sudoers_file"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN
  printf '%s\n' "$content" > "$tmp"
  # Validate before installing — a broken sudoers file can permanently
  # break sudo for this user.
  if ! sudo visudo -c -f "$tmp" >/dev/null; then
    err "sudoers content failed visudo -c — refusing to install"
    return 1
  fi
  sudo install -m 0440 -o root -g root "$tmp" "/etc/sudoers.d/${USER}"
}

harden_sudo() {
  log "Narrowing /etc/sudoers.d/${USER} (NOPASSWD limited to VPN + apt + svc)…"
  _install_sudoers_file "$(_sudoers_narrow)" \
    && ok "sudoers narrowed (run \`./local_setup.sh unharden\` to revert; see readme/security.md for the post-narrow recovery flow)"
}

unharden_sudo() {
  log "Restoring broad NOPASSWD sudoers (install-mode)…"
  _install_sudoers_file "$(_sudoers_broad)" \
    && ok "sudoers re-broadened (suitable for setup re-runs)"
}

# --- 2. ufw firewall ----------------------------------------
# Order matters: ALWAYS allow ssh BEFORE enable, otherwise we lock our
# own SSH session out of the box.  `ufw enable` from inside an SSH
# session is well-tested as long as the allow rule precedes it.
harden_ufw() {
  log "Configuring ufw (allow SSH, deny everything else inbound)…"
  # Same PATH note as unharden_ufw — refer to ufw by absolute path
  # because /usr/sbin isn't on a non-root user's PATH.
  if ! dpkg -l ufw 2>/dev/null | grep -q '^ii'; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ufw \
      >"${LOG_DIR}/apt_ufw.log" 2>&1 \
      || { warn "ufw install failed — see ${LOG_DIR}/apt_ufw.log"; return 1; }
  fi
  sudo /usr/sbin/ufw default deny incoming   >/dev/null
  sudo /usr/sbin/ufw default allow outgoing  >/dev/null
  sudo /usr/sbin/ufw allow ssh               >/dev/null   # <-- BEFORE enable
  sudo /usr/sbin/ufw --force enable          >/dev/null
  ok "ufw enabled (SSH allowed, everything else denied inbound)"
}

unharden_ufw() {
  # `command -v ufw` misses `/usr/sbin/ufw` because non-root users on
  # Debian don't have /usr/sbin in PATH by default.  Check by absolute
  # path AND by `dpkg -l` to be safe.
  if dpkg -l ufw 2>/dev/null | grep -q '^ii'; then
    sudo /usr/sbin/ufw --force disable >/dev/null \
      && ok "ufw disabled"
  else
    log "ufw not installed — nothing to do"
  fi
}

# --- 3. Unattended-upgrades ---------------------------------
# Two files live in /etc/apt/apt.conf.d/:
#   • 50unattended-upgrades — WHAT to upgrade (origins, blacklists, mail,
#     reboot policy).  Shipped as config/system/etc/apt/apt.conf.d/...
#     and installed verbatim via `sudo install -m 0644`.
#   • 20auto-upgrades       — WHETHER the periodic timer fires daily.
#     Generated inline here because it's a 3-line file with no per-host
#     variability worth tracking in the repo.
#
# Rollback (after harden):
#   sudo rm /etc/apt/apt.conf.d/20auto-upgrades
#   sudo apt-get install --reinstall unattended-upgrades   # restore distro 50-file
#
# Email notifications: configured only if `mailx` is on the host.  Without
# mailx, MailReport would queue messages into /var/mail/root that never
# get delivered — journal logs (`journalctl -u unattended-upgrades`) are
# the audit trail in that case.
harden_uu() {
  log "Enabling unattended-upgrades for Debian-Security only…"
  if ! dpkg -l unattended-upgrades 2>/dev/null | grep -q '^ii'; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      unattended-upgrades apt-listchanges >"${LOG_DIR}/apt_uu.log" 2>&1 \
      || { warn "unattended-upgrades install failed"; return 1; }
  fi
  # Drop the security-only origin policy.  The repo file is canonical;
  # use `sudo install` (NOT `cp`) so mode + ownership are predictable.
  local src50="${DOTFILES_DIR}/system/etc/apt/apt.conf.d/50unattended-upgrades"
  if [[ -f "$src50" ]]; then
    sudo install -D -m 0644 -o root -g root "$src50" \
         /etc/apt/apt.conf.d/50unattended-upgrades
    ok "/etc/apt/apt.conf.d/50unattended-upgrades (security-only origins)"
  else
    warn "${src50} missing — keeping distro default 50unattended-upgrades"
  fi
  # Mail-on-change ONLY if mailx is present.  Drop-in is a separate file
  # so it's easy to spot in `ls /etc/apt/apt.conf.d/` and trivially
  # removable by hand.
  if have mailx || have bsd-mailx || have s-nail; then
    sudo install -D -m 0644 /dev/stdin \
         /etc/apt/apt.conf.d/51unattended-upgrades-mail <<EOF
// Generated by ./local_setup.sh harden — root mail is delivered locally
// via mailx.  Edit the address below to forward off-box.
Unattended-Upgrade::Mail "root";
Unattended-Upgrade::MailReport "on-change";
EOF
    ok "/etc/apt/apt.conf.d/51unattended-upgrades-mail (mailx present)"
  else
    sudo rm -f /etc/apt/apt.conf.d/51unattended-upgrades-mail
    log "  (no mailx — mail disabled; use \`journalctl -u unattended-upgrades\`)"
  fi
  # Drive the periodic timer.  Daily apt update + daily upgrade.
  sudo install -D -m 0644 /dev/stdin /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
// Generated by ./local_setup.sh harden.
// Remove this file (or set values to "0") to halt automatic upgrades:
//     sudo rm /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  sudo systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
  ok "unattended-upgrades enabled (security patches will install automatically)"
}

unharden_uu() {
  log "Disabling unattended-upgrades…"
  sudo install -D -m 0644 /dev/stdin /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
  sudo rm -f /etc/apt/apt.conf.d/51unattended-upgrades-mail
  sudo systemctl disable --now unattended-upgrades.service >/dev/null 2>&1 || true
  ok "unattended-upgrades disabled"
}

# --- 3b. auditd rules ---------------------------------------
# Drop /etc/audit/rules.d/dotfiles.rules from the repo and ask augenrules
# to reload.  On Debian 13, `augenrules --load` is the canonical apply
# step — it concatenates everything under rules.d/ and atomically swaps
# /etc/audit/audit.rules, then nudges auditd.  Falls back to a service
# restart if augenrules is unavailable (very old systems).
#
# Rule contents live in config/system/etc/audit/rules.d/dotfiles.rules.
# To grep for events afterward:
#   sudo ausearch -k identity      # passwd/shadow/group writes
#   sudo ausearch -k sudoers       # sudoers edits
#   sudo ausearch -k modules       # kernel module load/unload
#   sudo ausearch -k mount         # mount/umount syscalls
#   sudo ausearch -k privesc       # sudo/su exec — OPT-IN, see rules file
harden_auditd() {
  log "Configuring auditd rules (identity, sudoers, modules, mount)…"
  if ! dpkg -l auditd 2>/dev/null | grep -q '^ii'; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      auditd audispd-plugins >"${LOG_DIR}/apt_auditd.log" 2>&1 \
      || { warn "auditd install failed — see ${LOG_DIR}/apt_auditd.log"; return 1; }
  fi
  local src="${DOTFILES_DIR}/system/etc/audit/rules.d/dotfiles.rules"
  if [[ ! -f "$src" ]]; then
    warn "${src} missing — refusing to deploy empty audit ruleset"
    return 1
  fi
  sudo install -D -m 0640 -o root -g root "$src" \
       /etc/audit/rules.d/dotfiles.rules
  # Apply.  augenrules is preferred; failure isn't fatal because the
  # rules will still load on next auditd start.
  if have augenrules; then
    if ! sudo augenrules --load >"${LOG_DIR}/augenrules.log" 2>&1; then
      warn "augenrules --load reported issues — see ${LOG_DIR}/augenrules.log"
      sudo systemctl restart auditd >/dev/null 2>&1 || true
    fi
  else
    sudo systemctl restart auditd >/dev/null 2>&1 || true
  fi
  sudo systemctl enable auditd >/dev/null 2>&1 || true
  ok "auditd rules loaded (\`sudo auditctl -l\` to inspect, \`ausearch -k <key>\` to query)"
}

unharden_auditd() {
  log "Removing dotfiles auditd rules…"
  if [[ -f /etc/audit/rules.d/dotfiles.rules ]]; then
    sudo rm -f /etc/audit/rules.d/dotfiles.rules
    if have augenrules; then
      sudo augenrules --load >/dev/null 2>&1 || true
    else
      sudo systemctl restart auditd >/dev/null 2>&1 || true
    fi
    ok "auditd dotfiles.rules removed (other rules.d/ files preserved)"
  else
    log "  /etc/audit/rules.d/dotfiles.rules absent — nothing to do"
  fi
}

# --- 4. systemd-resolved + DNS-over-TLS (opportunistic) ------
# Goal: encrypted DNS lookups (TCP/853) when the network supports it,
# graceful fall-back to plain DNS when it doesn't.  The threat model is
# passive on-path observers on untrusted networks (coffee-shop wifi etc).
#
# Why opportunistic, not strict: a strict `DNSOverTLS=yes` policy would
# break name resolution on any network that blocks TCP/853 -- including
# captive-portal pages we need to load to even authenticate.  The cost
# of opportunistic mode is that a hostile network CAN RST-downgrade us
# to plain DNS; check_dot() in conky/health.py surfaces that state.
#
# Why NetworkManager-aware: on Debian, NM owns /etc/resolv.conf by
# default and rewrites it every connection event.  We drop a
# `dns=systemd-resolved` conf.d file telling NM to push DNS into
# resolved via D-Bus instead -- preserves per-link DNS (VPN, corporate)
# while letting our global DoT settings ride on top.
#
# Why hostname-pinned servers (`1.1.1.1#cloudflare-dns.com`): the `#name`
# is the SNI/cert-CN hint resolved uses to verify the TLS connection.
# Without it, opportunistic mode can't validate the cert.
#
# Per-host overlay: if
#   ~/.config/dotfiles-local/etc/systemd/resolved.conf.d/cyberpunk-dot.conf
# exists, that file is deployed instead of the repo template -- useful
# for hosts on a corporate split-horizon DNS or a Pi-hole.
harden_dot() {
  log "Configuring systemd-resolved with opportunistic DoT + DNSSEC …"

  # Step 1: VALIDATE installability BEFORE touching /etc/resolv.conf.
  # If apt fails halfway through, the user keeps working DNS.  Order
  # of operations matters here -- a Ctrl-C between the install and the
  # symlink swap leaves a recoverable state.
  if ! command -v resolvectl >/dev/null 2>&1; then
    log "  systemd-resolved not present — installing …"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-resolved \
      >"${LOG_DIR}/apt_resolved.log" 2>&1 \
      || { warn "systemd-resolved install failed — see ${LOG_DIR}/apt_resolved.log"; return 1; }
    ok "  systemd-resolved installed"
  else
    log "  systemd-resolved already present"
  fi

  # Step 2: pick the source file.  Per-host overlay wins so corporate
  # / Pi-hole hosts can override without committing secrets.
  local repo_src="${DOTFILES_DIR}/system/etc/systemd/resolved.conf.d/cyberpunk-dot.conf"
  local local_src="${HOME}/.config/dotfiles-local/etc/systemd/resolved.conf.d/cyberpunk-dot.conf"
  local src="$repo_src"
  if [[ -f "$local_src" ]]; then
    src="$local_src"
    log "  using per-host overlay: ${local_src}"
  fi
  if [[ ! -f "$src" ]]; then
    warn "${src} missing — refusing to deploy DoT without a template"
    return 1
  fi

  # Step 3: deploy resolved drop-in.  `install -D` is atomic at the
  # file level (write-temp + rename) so a Ctrl-C mid-write can't leave
  # a half-written conf.
  sudo install -D -m 0644 -o root -g root "$src" \
       /etc/systemd/resolved.conf.d/cyberpunk-dot.conf
  ok "  /etc/systemd/resolved.conf.d/cyberpunk-dot.conf"

  # Step 4: tell NetworkManager to back off /etc/resolv.conf and push
  # DNS into resolved instead.  Without this NM will overwrite our
  # symlink on the next connection event.
  local nm_src="${DOTFILES_DIR}/system/etc/NetworkManager/conf.d/cyberpunk-dns.conf"
  if [[ -f "$nm_src" ]]; then
    sudo install -D -m 0644 -o root -g root "$nm_src" \
         /etc/NetworkManager/conf.d/cyberpunk-dns.conf
    ok "  /etc/NetworkManager/conf.d/cyberpunk-dns.conf (dns=systemd-resolved)"
  else
    warn "${nm_src} missing — NM may overwrite /etc/resolv.conf"
  fi

  # Step 5: enable + start resolved BEFORE swapping resolv.conf, so
  # the stub at 127.0.0.53 is actually listening when we point at it.
  sudo systemctl enable --now systemd-resolved >/dev/null 2>&1 \
    || { warn "failed to start systemd-resolved"; return 1; }
  ok "  systemd-resolved running"

  # Step 6: point /etc/resolv.conf at the resolved stub.  `ln -sf` is
  # atomic on the same filesystem (POSIX-mandated rename semantics) --
  # there's no window where /etc/resolv.conf doesn't exist.
  #
  # Defensive: some hardening guides (Lynis, the resolvconf-immutable
  # recipe in CIS) suggest `chattr +i /etc/resolv.conf`.  If a user did
  # that, `ln -sf` returns EPERM and the symlink never gets created --
  # silently leaving DNS routed to whatever the immutable file says.
  # Drop the immutable bit first; harmless no-op when not set.  Errors
  # swallowed because tmpfs/overlay roots don't support chattr at all.
  if [[ -e /etc/resolv.conf ]] && ! [[ -L /etc/resolv.conf ]]; then
    sudo chattr -i /etc/resolv.conf 2>/dev/null || true
  fi
  sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  ok "  /etc/resolv.conf → /run/systemd/resolve/stub-resolv.conf"

  # Step 7: reload NM so it picks up the dns=systemd-resolved setting.
  # RELOAD, not restart -- restart drops the current connection mid-run.
  sudo systemctl reload NetworkManager >/dev/null 2>&1 || true

  # Step 8: nudge resolved to re-read the drop-in (it does so on
  # restart anyway, but we want the new conf live NOW for verification).
  sudo systemctl restart systemd-resolved >/dev/null 2>&1 || true

  ok "DNS-over-TLS active (opportunistic).  Verify: \`resolvectl status\`"
  log "  on a network without DoT support this falls back to plain DNS —"
  log "  check the DoT line in conky/health.py to see which mode is live."
}

unharden_dot() {
  log "Reverting systemd-resolved DoT configuration …"

  # Remove our drop-ins first so a service reload doesn't re-apply
  # them.  Both files are owned by us (not the systemd-resolved
  # package), so plain rm is safe.
  if [[ -f /etc/systemd/resolved.conf.d/cyberpunk-dot.conf ]]; then
    sudo rm -f /etc/systemd/resolved.conf.d/cyberpunk-dot.conf
    ok "  removed /etc/systemd/resolved.conf.d/cyberpunk-dot.conf"
  fi
  if [[ -f /etc/NetworkManager/conf.d/cyberpunk-dns.conf ]]; then
    sudo rm -f /etc/NetworkManager/conf.d/cyberpunk-dns.conf
    ok "  removed /etc/NetworkManager/conf.d/cyberpunk-dns.conf"
  fi

  # Drop the resolv.conf symlink BEFORE stopping resolved.  Otherwise
  # everything that calls getaddrinfo() between the disable and the NM
  # reload would silently fail (stub listener gone, no nameserver).
  if [[ -L /etc/resolv.conf ]]; then
    sudo rm -f /etc/resolv.conf
    log "  removed stub symlink at /etc/resolv.conf"
  fi

  # Reload NetworkManager -- now that the dns= override is gone, NM
  # reverts to writing /etc/resolv.conf directly with the DHCP-supplied
  # nameservers from the active connection.  Reload (not restart) keeps
  # the current connection up.
  sudo systemctl reload NetworkManager >/dev/null 2>&1 || true
  # Some NM versions only rewrite resolv.conf on a connection-state
  # change, not on a config reload.  If the file still isn't there,
  # kick the active connection to force a rewrite.
  if [[ ! -e /etc/resolv.conf ]]; then
    local conn
    conn=$(nmcli -t -f NAME connection show --active 2>/dev/null | head -1)
    if [[ -n "$conn" ]]; then
      log "  asking NM to refresh /etc/resolv.conf via 'nmcli connection up'"
      sudo nmcli connection up "$conn" >/dev/null 2>&1 || true
    fi
  fi

  # Disable resolved last.  If anything above failed, the user still
  # has the stub listener as a working DNS source while they debug.
  sudo systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
  ok "DNS-over-TLS reverted (NM now owns /etc/resolv.conf again)"
}

# --- harden orchestrator ------------------------------------
harden_phase() {
  ensure_sudo
  log "Running security-hardening pass — narrow sudoers, ufw, "
  log "unattended-upgrades, DNS-over-TLS.  Reverse with \`unharden\`."
  harden_uu     || warn "(unattended-upgrades step had warnings)"
  harden_auditd || warn "(auditd step had warnings)"
  harden_dot    || warn "(DNS-over-TLS step had warnings)"
  harden_ufw    || warn "(ufw step had warnings)"
  harden_sudo   || die  "(sudoers step failed — refusing to leave system half-hardened)"
  echo
  ok "Hardening complete."
  log "Verify: \`sudo -l\`, \`sudo ufw status\`, \`resolvectl status\`,"
  log "        \`systemctl status unattended-upgrades.service\`,"
  log "        \`sudo auditctl -l\` (ausearch -k identity|sudoers|modules|mount)"
}

unharden_phase() {
  ensure_sudo
  log "Reverting hardening — broad sudoers, ufw off, "
  log "auto-upgrades off, DNS back to NM-managed plain resolvers."
  unharden_sudo
  unharden_ufw
  unharden_uu
  unharden_auditd
  unharden_dot
  echo
  ok "Hardening reverted (suitable for re-running setup)."
}

validate_phase() {
  log "Running validation checks (desktop=${DESKTOP}) …"
  echo
  local failures=0
  local entry label cmd

  # Build the active list: common + desktop-specific.
  local -a active=()
  active+=("${VAL_CHECKS_COMMON[@]}")
  case "$DESKTOP" in
    i3)     active+=("${VAL_CHECKS_I3[@]}") ;;
    plasma) active+=("${VAL_CHECKS_PLASMA[@]}") ;;
  esac

  for entry in "${active[@]}"; do
    label="${entry%%|*}"
    cmd="${entry#*|}"
    if bash -c "$cmd" >/dev/null 2>&1; then
      printf "  [ ok ]  %s\n" "$label"
    else
      printf "  [FAIL]  %s\n" "$label"
      failures=$((failures + 1))
    fi
  done

  # Nix package manager — only validated when nix is actually present.
  # If the user opted out with --no-nix during setup, nix isn't
  # installed, and we silently skip these checks (no FAIL noise).
  # Once nix IS present, we additionally verify nix-direnv + flakes
  # are wired so a fresh-clone deploy behaves end-to-end.
  if command -v nix >/dev/null 2>&1 \
     || [[ -x /nix/var/nix/profiles/default/bin/nix ]]; then
    printf "  [ ok ]  nix package manager installed\n"
    if [[ -f "${HOME}/.nix-profile/share/nix-direnv/direnvrc" ]]; then
      printf "  [ ok ]  nix-direnv hooked into direnv\n"
    else
      printf "  [FAIL]  nix-direnv missing (~/.nix-profile/share/nix-direnv/direnvrc)\n"
      failures=$((failures + 1))
    fi
    if grep -q 'experimental-features.*\(nix-command\|flakes\)' \
         "${HOME}/.config/nix/nix.conf" 2>/dev/null; then
      printf "  [ ok ]  flakes enabled in ~/.config/nix/nix.conf\n"
    else
      printf "  [FAIL]  flakes not enabled in ~/.config/nix/nix.conf\n"
      failures=$((failures + 1))
    fi
  fi

  # Hardware-conditional checks
  if [[ "$VIRT_TYPE" == "hyperv" ]]; then
    if [[ -f /etc/X11/xorg.conf.d/10-hyperv.conf ]]; then
      printf "  [ ok ]  hyperv Xorg config\n"
    else
      printf "  [FAIL]  hyperv Xorg config\n"; failures=$((failures + 1))
    fi
  fi
  if [[ "$GPU_VENDOR" == "nvidia" ]]; then
    # nvidia-smi can succeed even when the kernel module isn't loaded
    # (stale binary on PATH) — explicitly verify the module first so a
    # post-install pre-reboot state is reported as "reboot required"
    # rather than a misleading "ok".
    if lsmod 2>/dev/null | grep -qE '^nvidia(_open)?\s'; then
      printf "  [ ok ]  nvidia kernel module loaded\n"
    else
      printf "  [FAIL]  nvidia kernel module not loaded (reboot required)\n"
      failures=$((failures + 1))
    fi
    if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
      printf "  [ ok ]  nvidia-smi reports GPU\n"
    else
      printf "  [FAIL]  nvidia-smi (driver may need reboot)\n"
      failures=$((failures + 1))
    fi
    if grep -q 'nvidia-drm\.modeset=1' /proc/cmdline 2>/dev/null; then
      printf "  [ ok ]  nvidia-drm.modeset=1 active on running kernel\n"
    else
      printf "  [FAIL]  nvidia-drm.modeset=1 not on cmdline (reboot required)\n"
      failures=$((failures + 1))
    fi
    # NVIDIA-Wayland extras — only meaningful (and only added by
    # install_phase) on the plasma path.  Each fail message points at
    # the specific install_phase helper that should have set it.
    if [[ "$DESKTOP" == "plasma" && "$VIRT_TYPE" == "physical" ]]; then
      if grep -q 'nvidia-drm\.fbdev=1' /proc/cmdline 2>/dev/null; then
        printf "  [ ok ]  nvidia-drm.fbdev=1 active on running kernel\n"
      else
        printf "  [FAIL]  nvidia-drm.fbdev=1 not on cmdline (reboot required; see add_nvidia_fbdev)\n"
        failures=$((failures + 1))
      fi
      if sudo test -f /etc/modprobe.d/nvidia-power-management.conf \
         && sudo grep -q 'NVreg_PreserveVideoMemoryAllocations=1' \
              /etc/modprobe.d/nvidia-power-management.conf 2>/dev/null; then
        printf "  [ ok ]  NVreg_PreserveVideoMemoryAllocations=1 set\n"
      else
        printf "  [FAIL]  NVreg_PreserveVideoMemoryAllocations missing (see add_nvidia_pm_options)\n"
        failures=$((failures + 1))
      fi
      if grep -qE '^[[:space:]]*nvidia_drm([[:space:]]|$)' \
           /etc/initramfs-tools/modules 2>/dev/null; then
        printf "  [ ok ]  nvidia early-KMS modules in initramfs\n"
      else
        printf "  [FAIL]  nvidia early-KMS modules missing (see add_nvidia_early_kms)\n"
        failures=$((failures + 1))
      fi
      # The three nvidia-suspend units; report any that aren't enabled
      # (they're independent — older driver packages ship only a subset).
      local sunit
      for sunit in nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service; do
        if systemctl list-unit-files "$sunit" 2>/dev/null | grep -q "^${sunit}"; then
          if systemctl is-enabled "$sunit" >/dev/null 2>&1; then
            printf "  [ ok ]  %s enabled\n" "$sunit"
          else
            printf "  [FAIL]  %s not enabled (see add_nvidia_pm_options)\n" "$sunit"
            failures=$((failures + 1))
          fi
        fi
      done
    fi
    # Gaming/workstation userland — only checked on physical hosts
    # where we'd actually have installed it.
    if [[ "$VIRT_TYPE" == "physical" ]]; then
      if dpkg --print-foreign-architectures 2>/dev/null | grep -qx 'i386'; then
        printf "  [ ok ]  i386 multiarch enabled (Steam, Proton)\n"
      else
        printf "  [FAIL]  i386 multiarch missing (Steam/Proton won't run)\n"
        failures=$((failures + 1))
      fi
      # vulkaninfo prints a NVIDIA "deviceName" line when the Vulkan
      # ICD is wired up correctly.  Skip on a fresh post-install
      # pre-reboot state — `vulkaninfo` may fail loudly there too.
      if command -v vulkaninfo >/dev/null \
         && vulkaninfo --summary 2>/dev/null | grep -qi 'nvidia'; then
        printf "  [ ok ]  Vulkan reports NVIDIA device\n"
      else
        printf "  [FAIL]  vulkaninfo can't see the NVIDIA GPU (reboot? driver?)\n"
        failures=$((failures + 1))
      fi
      # 32-bit GL — checks the file exists since we can't run a 32-bit
      # process from a 64-bit script trivially.
      if [[ -e /usr/lib/i386-linux-gnu/libGL.so.1 ]] \
         || dpkg -l nvidia-driver-libs:i386 2>/dev/null \
              | grep -q '^ii'; then
        printf "  [ ok ]  32-bit GL libraries present\n"
      else
        printf "  [FAIL]  no 32-bit libGL — Steam will not start games\n"
        failures=$((failures + 1))
      fi
    fi
  fi
  # tlp + thermald only relevant on physical machines.  thermald layers
  # an additional Intel-only condition on top.
  if [[ "$VIRT_TYPE" == "physical" ]]; then
    if systemctl is-active tlp >/dev/null 2>&1; then
      printf "  [ ok ]  tlp service active\n"
    else
      printf "  [FAIL]  tlp service (run: sudo systemctl enable --now tlp)\n"
      failures=$((failures + 1))
    fi
    # Battery sysfs presence — ThinkPads expose BAT0 (most) or BAT1
    # (some X1 / dual-battery models).  Either is fine; at least one
    # must exist on a laptop or our polybar battery module won't render.
    if compgen -G '/sys/class/power_supply/BAT*' >/dev/null; then
      printf "  [ ok ]  battery detected (%s)\n" \
        "$(ls -d /sys/class/power_supply/BAT* 2>/dev/null \
            | xargs -n1 basename | tr '\n' ' ')"
    else
      # Desktops have no battery; only flag this on Intel laptops where
      # we'd otherwise expect one.  Heuristic: chassis type via DMI.
      local chassis
      chassis="$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || echo)"
      # Chassis types 8/9/10/14 = portable/laptop/notebook/sub-notebook
      if [[ "$chassis" =~ ^(8|9|10|14)$ ]]; then
        printf "  [FAIL]  no battery detected on a laptop chassis\n"
        failures=$((failures + 1))
      fi
    fi
    if [[ "$CPU_VENDOR" == "intel" ]]; then
      if systemctl is-active thermald >/dev/null 2>&1; then
        printf "  [ ok ]  thermald active\n"
      else
        printf "  [FAIL]  thermald (run: sudo systemctl enable --now thermald)\n"
        failures=$((failures + 1))
      fi
    fi
  fi

  echo
  if [[ "$failures" -eq 0 ]]; then
    ok "All checks passed"
  else
    err "${failures} check(s) failed"
  fi
  return "$failures"
}

# ============================================================
# Stage prompting (interactive vs bypass)
# ============================================================
# `setup` runs four sequential stages.  In interactive mode (default) we
# print a description of each stage and ask the user "[Y/n/q]" before
# running it; in bypass mode we run them all back-to-back.  Either way,
# sudo authentication happens once at the start (via ensure_sudo) so the
# user's password is only ever entered a single time.

# Print "what this stage will do" — purely informational text shown above
# the y/n prompt.  Centralising the descriptions keeps install/deploy/
# terminal/validate documentation in lock-step with the actual code.
describe_stage() {
  case "$1" in
    install)
      cat <<EOF
This stage will:
  • Run \`apt-get update\` to refresh the package index
  • Install the common base packages (alacritty, neovim, zsh, tmux,
    fonts, network/audio backbone, hardware diagnostics, …)
  • Install the desktop stack for --desktop=${DESKTOP}:
      i3      → xorg, i3, polybar, picom, rofi, dunst, lightdm,
                pulseaudio, i3lock, feh, thunar (X11 stack)
      plasma  → plasma-desktop, kwin-wayland, sddm, pipewire,
                xwayland, qt6-wayland, konsole, dolphin,
                kde-config-screenlocker, wl-clipboard, breeze
  • If GPU detected: install matching driver stack (nvidia/amd/intel).
    For NVIDIA on physical hardware, additionally:
      - Enable i386 multiarch (Steam, Proton, 32-bit games)
      - Install 32-bit GL/Vulkan + native Vulkan + nvidia-vaapi-driver
        (browser/mpv hardware video decode) + mesa-utils (glxinfo)
      - Pick nvidia-open-kernel-dkms for Turing+, proprietary otherwise
      - Append nvidia-drm.modeset=1 to the GRUB cmdline (reboot required)
      - --cuda also installs nvidia-cuda-toolkit (~3 GB, opt-in)
      - --steam also installs steam-installer (Debian's Steam bootstrap)
    For NVIDIA on physical hardware + --desktop=plasma, also:
      - Append nvidia-drm.fbdev=1 to the GRUB cmdline
      - Add nvidia early-KMS modules to initramfs
      - Set NVreg_PreserveVideoMemoryAllocations=1 in modprobe.d
      - Enable nvidia-suspend / -resume / -hibernate systemd units
  • If virtualised: install hypervisor guest tools (qemu-guest-agent,
    open-vm-tools, hyperv-daemons, …)
  • Install Mullvad VPN from its official apt repo
  • Install WireGuard userland (wg, wg-quick)
  • Install power management: TLP + acpi + powertop
    (thermald added on Intel hardware; power-profiles-daemon purged
    if installed — it conflicts with TLP)
  • Install network helpers: iw, rfkill (NetworkManager already in base)
  • Time: 3–10 minutes (depends on network), longer with --cuda
EOF
      ;;
    deploy)
      cat <<EOF
This stage will:
  • Copy this repo's common ./config/* into ~/.config/ (alacritty,
    tmux, nvim, starship, wallpaper, conky, gtk-3.0)
  • Deploy the --desktop=${DESKTOP} configs:
      i3      → ./config/{i3,polybar,picom,rofi,dunst,lockscreen} +
                ~/.xsession + lightdm greeter config + lightdm enable
      plasma  → ./config/plasma/{kdeglobals,kwinrc,kwinrulesrc,
                plasmarc,konsolerc,kscreenlockerrc,color-schemes/,
                konsole/,autostart/,apply-theme.sh} +
                /etc/sddm.conf.d/10-wayland.conf +
                lightdm disable + sddm enable +
                conky own_window_type → 'normal' patch
  • Generate the desktop wallpaper (Unsplash → procedural fallback)
  • Configure xrdp if it's installed (otherwise skipped)
  • Time: < 30 seconds
EOF
      ;;
    terminal)
      cat <<EOF
This stage will:
  • Download JetBrainsMono Nerd Font (~25 MB) → ~/.local/share/fonts/
  • Install oh-my-zsh + zsh-autosuggestions + zsh-syntax-highlighting
  • Install starship prompt (apt on trixie, tarball fallback on bookworm)
  • Install tpm (tmux plugin manager) and the listed tmux plugins
  • Set zsh as your default shell (via \`usermod -s\`)
  • Pre-install neovim plugins + treesitter parsers (headless)
  • Install Nix package manager (multi-user daemon) + nix-direnv for
    per-project flake-based dev shells (apt stays the system PM).
    Skip with --no-nix.
  • Time: 1–3 minutes (4–6 with Nix install on first run)
EOF
      ;;
    validate)
      cat <<EOF
This stage will:
  • Run ~40 sanity checks: tools installed, configs in place, services
    enabled, default shell, fonts, VPN tools, polybar helpers
  • Read-only — no system changes
  • Time: < 5 seconds

After validate, on physical machines with a wifi card stuck in
NetworkManager state 'unmanaged' (caused by Debian's installer
storing wifi creds in /etc/network/interfaces under ifupdown),
\`setup\` runs scripts/take-over-wifi.sh non-interactively to hand
the device to NM.  The takeover pre-imports the SSID + PSK into NM
first so reconnection is automatic — no stranded sessions.  Skipped
on \`--no-wifi-takeover\` and on systems where creds aren't in
/etc/network/interfaces.
EOF
      ;;
  esac
}

# Stage titles used in the "STAGE n/4" header.
stage_title() {
  case "$1" in
    install)  echo "Install packages + drivers + VPN" ;;
    deploy)   echo "Deploy configuration files" ;;
    terminal) echo "Set up terminal stack (zsh / nvim / starship)" ;;
    validate) echo "Run validation checks" ;;
  esac
}

# Run one stage with the right wrapper based on $INTERACTIVE.
#
# Usage: run_stage <num> <total> <stage-key> <function-to-call>
#   <stage-key> matches the case branches in describe_stage / stage_title.
#
# In interactive mode: print header + description, ask Y/n/q, run if yes.
# In bypass mode:      print header only, run unconditionally.
run_stage() {
  local n="$1" total="$2" key="$3" fn="$4"

  printf '\n%s\n' "════════════════════════════════════════════════════════"
  printf '  STAGE %d/%d — %s\n' "$n" "$total" "$(stage_title "$key")"
  printf '%s\n' "════════════════════════════════════════════════════════"

  if [[ "$INTERACTIVE" == 1 ]]; then
    describe_stage "$key"
    echo
    local ans
    read -rp "Run this stage now? [Y/n/q] " ans || ans="q"
    case "${ans:-Y}" in
      [Nn]*)
        warn "Stage skipped — aborting setup."
        warn "(Run individual subcommands like \`./local_setup.sh deploy\` to"
        warn " resume from a specific stage later.)"
        exit 0
        ;;
      [Qq]*) warn "Quit at user request."; exit 0 ;;
    esac
  else
    log "(--bypass: running automatically)"
  fi

  "$fn"
}

# ============================================================
# Argument parsing
# ============================================================
ACTION="setup"
FORCE_VIRT=""
FORCE_GPU=""
NO_DRIVERS=0
WANT_CUDA=0
WANT_STEAM=0
WANT_NIX=1
WANT_WIFI_TAKEOVER=1
# Desktop stack selection.  Default is `i3` (the original cyberpunk
# X11 stack — unchanged for existing users).  `plasma` switches the
# install_phase + deploy_phase + validate_phase to KDE Plasma 6 on
# Wayland with SDDM + PipeWire.  See readme/plasma.md.
DESKTOP="i3"
# Default for `setup` is INTERACTIVE.  If stdin isn't a TTY (piped, SSH
# without -t, CI), we silently flip to bypass — otherwise read would hang
# the entire pipeline waiting for input that's never coming.
if [[ -t 0 ]]; then INTERACTIVE=1; else INTERACTIVE=0; fi

_MODE_FLAG_SEEN=""    # tracks --interactive vs --bypass to detect conflict

while [[ $# -gt 0 ]]; do
  case "$1" in
    setup|detect|install|deploy|terminal|validate|harden|unharden)
      ACTION="$1" ;;
    --show-overrides)
      # Read-only inspection of ~/.config/dotfiles-local/.  Implemented
      # as a flag (not a sub-command) so it composes with --desktop=...
      # if the user wants to see what would apply for that path.
      ACTION="show-overrides" ;;
    --hyperv)   FORCE_VIRT="hyperv" ;;
    --vm)       FORCE_VIRT="vm" ;;
    --physical) FORCE_VIRT="physical" ;;
    --nvidia)   FORCE_GPU="nvidia" ;;
    --amd)      FORCE_GPU="amd" ;;
    --intel)    FORCE_GPU="intel" ;;
    --no-gpu)   FORCE_GPU="none" ;;
    --no-drivers) NO_DRIVERS=1 ;;
    --cuda)       WANT_CUDA=1 ;;
    --steam)      WANT_STEAM=1 ;;
    --no-nix)     WANT_NIX=0 ;;
    --no-wifi-takeover) WANT_WIFI_TAKEOVER=0 ;;
    --desktop=*)  DESKTOP="${1#--desktop=}" ;;
    --plasma)     DESKTOP="plasma" ;;
    --i3)         DESKTOP="i3" ;;
    --interactive|-i)
      [[ "$_MODE_FLAG_SEEN" == "bypass" ]] \
        && die "--interactive and --bypass are mutually exclusive"
      INTERACTIVE=1; _MODE_FLAG_SEEN="interactive" ;;
    --bypass|--yes|-y)
      [[ "$_MODE_FLAG_SEEN" == "interactive" ]] \
        && die "--interactive and --bypass are mutually exclusive"
      INTERACTIVE=0; _MODE_FLAG_SEEN="bypass" ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

# Validate desktop selection — fail fast before any apt/sudo work.
case "$DESKTOP" in
  i3|plasma) ;;
  *) die "Unknown --desktop=$DESKTOP (expected: i3, plasma)" ;;
esac

# ============================================================
# Main
# ============================================================
# Read-only sub-commands short-circuit BEFORE detection / sudo / apt.
# --show-overrides just inspects ~/.config/dotfiles-local/ and exits —
# no reason to drag the user through `ensure_detection_tools` (which can
# apt-install lspci/dmidecode on a fresh box) for a 1-second diff.
if [[ "$ACTION" == "show-overrides" ]]; then
  show_overrides
  exit 0
fi

# Bootstrap detection tools first (lspci / dmidecode) — they live in tiny
# packages and we need them for the detect_* functions to be accurate on a
# fresh Debian install.  Skipped on `detect`/`validate` if they're already
# present.
ensure_detection_tools
detect_virt
detect_gpu
detect_cpu
[[ -n "$FORCE_VIRT" ]] && VIRT_TYPE="$FORCE_VIRT"
[[ -n "$FORCE_GPU"  ]] && GPU_VENDOR="$FORCE_GPU"
print_hardware

case "$ACTION" in
  detect)
    : ;;
  install)
    install_phase ;;
  deploy)
    deploy_phase ;;
  terminal)
    terminal_phase ;;
  validate)
    validate_phase ;;
  harden)
    harden_phase ;;
  unharden)
    unharden_phase ;;
  show-overrides)
    # Read-only — no sudo, no apt, no rsync.  Exits straight after.
    show_overrides
    exit 0 ;;
  setup)
    # Print mode banner so the user knows which path they're on, and pre-
    # authenticate sudo once.  Both modes go through ensure_sudo here so
    # the user's password is requested at most a single time, even though
    # downstream phases each invoke `sudo` many times.
    if [[ "$INTERACTIVE" == 1 ]]; then
      log "Interactive mode — you'll be asked before each stage runs."
      log "(use --bypass to install everything without per-stage prompts)"
    else
      log "Bypass mode — installing without further prompts."
      log "(authentication happens once now; everything else is unattended)"
    fi
    ensure_sudo

    run_stage 1 4 install  install_phase
    run_stage 2 4 deploy   deploy_phase
    run_stage 3 4 terminal terminal_phase
    # validate is read-only; failures shouldn't abort the pipeline (it's
    # the LAST stage anyway, so just report and move on).
    run_stage 4 4 validate validate_phase || true

    # Auto-wifi-takeover runs AFTER all four stages — by this point all
    # apt downloads, git clones, oh-my-zsh fetch, nvim plugin sync, etc.
    # are done, so a brief network reconfiguration is safe.  Skipped
    # unless wifi is `unmanaged` AND creds are recoverable.  See
    # auto_wifi_takeover() for the safety conditions.
    auto_wifi_takeover || true

    echo
    ok "Local setup complete."
    if [[ "$GPU_VENDOR" == "nvidia" ]]; then
      warn "NVIDIA driver installed — reboot before starting an X session."
    fi
    ;;
esac
