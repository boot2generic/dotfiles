#!/usr/bin/env bash
# local_setup.sh — local mirror of vm_automation.py.
#
# Provisions the *current* machine with the same i3/polybar/picom/zsh/neovim
# stack that vm_automation.py installs on the remote dev VM, but runs
# everything locally — no SSH, no pexpect.
#
# Supported: Debian 12 (bookworm), Debian 13 (trixie), and future Debian
# releases. Other distros are rejected — they tend to be missing packages
# (alacritty, fastfetch, hyperv-daemons) that the dotfiles assume.
#
# Auto-detects:
#   • Virtualization : hyperv | vm (kvm/qemu/vmware/vbox/xen) | physical
#   • GPU vendor    : nvidia | amd | intel | none
# and installs the matching driver/agent stack:
#   • nvidia   → nvidia-driver + nvidia-settings (enables non-free apt)
#   • amd      → firmware-amd-graphics + libdrm-amdgpu1 + mesa-va-drivers
#   • intel    → intel-media-va-driver-non-free + i965-va-driver
#   • hyperv   → hyperv-daemons + Hyper-V Xorg config (10-hyperv.conf)
#   • vm       → qemu-guest-agent / open-vm-tools / virtualbox-guest-utils
#                depending on the detected hypervisor
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
#   ./local_setup.sh harden           # OPT-IN: narrow sudo, ufw, auto-updates,
#                                     #          systemd-resolved + DoT (Quad9)
#   ./local_setup.sh unharden         # revert harden (re-broaden sudoers etc.)
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
#

set -euo pipefail

# ============================================================
# Paths and constants
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="${SCRIPT_DIR}/config"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
LOG_DIR="${TMPDIR:-/tmp}"

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
  ( while true; do sudo -n true; sleep 60; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap '[[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
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
  # Inspect every PCI device whose class is VGA / 3D / Display and pick the
  # first vendor we recognise.  Order matters: we prefer nvidia → amd →
  # intel, since on a hybrid graphics laptop the discrete GPU is usually
  # the one we want drivers for.
  local pci
  pci="$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display' || true)"
  GPU_RAW="$pci"
  if   echo "$pci" | grep -qi nvidia;       then GPU_VENDOR="nvidia"
  elif echo "$pci" | grep -Eqi 'amd|ati';   then GPU_VENDOR="amd"
  elif echo "$pci" | grep -qi intel;        then GPU_VENDOR="intel"
  else                                           GPU_VENDOR="none"
  fi
}

print_hardware() {
  echo
  log "Detection summary"
  printf "    %-12s %s\n" "Virt type"   "$VIRT_TYPE"
  printf "    %-12s %s\n" "Hypervisor"  "${VM_HYPERVISOR:-n/a}"
  printf "    %-12s %s\n" "DMI vendor"  "${DMI_VENDOR:-unknown}"
  printf "    %-12s %s\n" "DMI product" "${DMI_PRODUCT:-unknown}"
  printf "    %-12s %s\n" "GPU vendor"  "$GPU_VENDOR"
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
  # X server + display infrastructure
  xorg xserver-xorg x11-xserver-utils xinit xvfb dbus-x11
  # WM + compositor + bar + launcher
  i3 polybar picom rofi
  # Terminal emulator
  alacritty
  # Notifications
  dunst libnotify-bin
  # Display manager
  lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings
  # Wallpaper + screenshots
  feh scrot
  # Fonts
  fonts-jetbrains-mono fonts-font-awesome
  fonts-material-design-icons-iconfont
  # GTK themes + icons
  adwaita-icon-theme papirus-icon-theme lxappearance
  # File manager + network applet
  thunar gvfs network-manager-gnome network-manager
  # Web browser — Debian ships Firefox as `firefox-esr` (not `firefox`).
  # The i3 Mod+b binding launches firefox-esr directly.  To swap, edit
  # the binding in ~/.config/i3/config after installing your alternate
  # (mullvad-browser, chromium, …).
  firefox-esr
  # Audio + media-key controls.  `pactl` (pulseaudio) handles volume;
  # `playerctl` talks MPRIS so play/pause/next/prev work for any media
  # player (Spotify, mpv, Firefox, VLC, …).
  pulseaudio pavucontrol playerctl
  # WireGuard VPN — userland (`wg`, `wg-quick`).  Drop a config into
  # /etc/wireguard/<name>.conf and `sudo wg-quick up <name>`.  Kernel
  # module ships in modern Debian kernels, no DKMS needed.
  wireguard wireguard-tools
  # Utilities
  numlockx arandr xclip xdotool brightnessctl
  i3lock imagemagick python3-pil
  # wmctrl + x11-utils (xprop / xwininfo / xdpyinfo) — kept around
  # as desktop-environment diagnostic tools.  An earlier revision of
  # config/conky/launch.sh used them for a keep-below daemon; that's
  # gone now (own_window_type='override' means the WM ignores conky
  # entirely — no manual lowering required).
  wmctrl x11-utils
  # Terminal stack
  tmux neovim zsh fzf ripgrep fd-find
  # build-essential = gcc + g++ + make + libc6-dev — required to compile
  # telescope-fzf-native and treesitter parsers
  build-essential
  nodejs npm
  # Shell tools
  rsync curl wget git htop fastfetch
  # Pretty CLI
  bat grc net-tools lm-sensors conky-all iproute2
  # Detection helpers
  pciutils dmidecode
  # Archive tools — Mason needs `unzip` to extract clangd's release zip.
  # Without it, `:Mason` install of clangd silently fails with
  # "spawn: unzip … unzip is not executable".
  unzip
)

# Driver / agent packages by detected category
NVIDIA_PACKAGES=(nvidia-driver nvidia-settings)
AMD_PACKAGES=(firmware-amd-graphics libdrm-amdgpu1 mesa-va-drivers
              xserver-xorg-video-amdgpu)
INTEL_PACKAGES=(intel-media-va-driver-non-free i965-va-driver
                xserver-xorg-video-intel)
HYPERV_PACKAGES=(hyperv-daemons)
QEMU_PACKAGES=(qemu-guest-agent spice-vdagent xserver-xorg-video-qxl)
VMWARE_PACKAGES=(open-vm-tools open-vm-tools-desktop xserver-xorg-video-vmware)
VBOX_PACKAGES=(virtualbox-guest-utils virtualbox-guest-x11)

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

enable_nonfree() {
  # Required for nvidia-driver and some firmware blobs.
  #
  # SECURITY: every file we modify gets a timestamped backup
  # (<path>.bak.YYYYMMDD-HHMMSS, mode 0600) BEFORE the in-place edit.
  # apt source mods can wedge `apt update`; a one-liner rollback is
  # always preferable to git-bisecting a config repo at 2 AM.
  #
  # Auto-prune: delete backups older than 30 days so they don't
  # accumulate forever.  Apt only reads *.list / *.sources so the
  # *.bak.* files themselves are inert as far as apt is concerned.
  sudo find /etc/apt -maxdepth 2 -name '*.bak.*' -mtime +30 -delete \
    2>/dev/null || true

  local files=(/etc/apt/sources.list /etc/apt/sources.list.d/*.list
               /etc/apt/sources.list.d/*.sources)
  log "Enabling non-free + non-free-firmware components …"
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    local needs_edit=0
    if [[ "$f" == *.list ]] && grep -qE '^deb ' "$f" \
       && ! grep -qE 'non-free-firmware' "$f"; then
      needs_edit=1
    elif [[ "$f" == *.sources ]] && grep -qE '^Components:' "$f" \
         && ! grep -qE 'non-free-firmware' "$f"; then
      needs_edit=1
    fi
    if [[ "$needs_edit" == 1 ]]; then
      sudo install -m 0600 "$f" "${f}.bak.${ts}"
      if [[ "$f" == *.list ]]; then
        sudo sed -i \
          's/^\(deb .*main\)\(.*\)$/\1 contrib non-free non-free-firmware\2/' "$f"
      else
        sudo sed -i \
          '/^Components:/ s/$/ contrib non-free non-free-firmware/' "$f"
      fi
      log "  edited ${f}  (backup: ${f}.bak.${ts})"
    fi
  done
}

driver_packages_for() {
  # Echo the package list for the detected GPU + virt combo.
  local pkgs=()

  case "$GPU_VENDOR" in
    nvidia) pkgs+=("${NVIDIA_PACKAGES[@]}") ;;
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

  printf '%s\n' "${pkgs[@]}"
}

# Pinned fingerprint of Mullvad's apt-repo signing key.  See:
#   https://mullvad.net/en/help/install-mullvad-app-linux
# Override with $MULLVAD_KEY_FINGERPRINT if Mullvad rotates the key
# (very rare — happens once every few years).
# Mullvad's apt repo signing key (primary, 4096-bit RSA, created 2016).
# Verified by inspecting `gpg --show-keys` against the live keyring on a
# trusted host AND cross-checking with Mullvad's published page:
#   https://mullvad.net/en/help/install-mullvad-app-linux
MULLVAD_KEY_FINGERPRINT="${MULLVAD_KEY_FINGERPRINT:-A1198702FC3E0A09A9AE5B75D5A1D4F266DE8DDF}"

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
    warn "Mullvad keyring failed pinning check:"
    warn "  expected exactly 1 key with fingerprint $MULLVAD_KEY_FINGERPRINT"
    warn "  saw $nkeys key(s):"
    while IFS= read -r fp; do warn "    $fp"; done <<<"$fps"
    warn "If Mullvad rotated their key, update MULLVAD_KEY_FINGERPRINT in"
    warn "local_setup.sh (or set MULLVAD_KEY_FINGERPRINT=<new> in env)."
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

install_phase() {
  ensure_sudo
  if [[ "$GPU_VENDOR" == "nvidia" ]]; then
    enable_nonfree
  fi
  apt_update
  apt_install "base" "${BASE_PACKAGES[@]}"

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
}

# ============================================================
# Config deployment
# ============================================================
CONFIG_MAP=(
  "i3:.config/i3"
  "polybar:.config/polybar"
  "picom:.config/picom"
  "rofi:.config/rofi"
  "alacritty:.config/alacritty"
  "dunst:.config/dunst"
  "gtk-3.0:.config/gtk-3.0"
  "wallpaper:.config/wallpaper"
  "tmux:.config/tmux"
  "nvim:.config/nvim"
  "starship:.config/starship"
  "conky:.config/conky"
  "lockscreen:.config/lockscreen"
)

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

deploy_phase() {
  ensure_sudo
  log "Deploying config files …"
  local entry name dest
  for entry in "${CONFIG_MAP[@]}"; do
    name="${entry%%:*}"
    dest="${entry#*:}"
    deploy_one "$name" "$dest"
  done

  # Single-file copies
  local gtk2_src="${DOTFILES_DIR}/gtk-2.0/gtkrc"
  [[ -f "$gtk2_src" ]] && { cp "$gtk2_src" "${HOME}/.gtkrc-2.0"; ok ".gtkrc-2.0"; }

  local xsess="${SCRIPTS_DIR}/xsession.sh"
  if [[ -f "$xsess" ]]; then
    install -m 0755 "$xsess" "${HOME}/.xsession"
    ok ".xsession"
  fi

  local xres="${SCRIPTS_DIR}/Xresources"
  [[ -f "$xres" ]] && { cp "$xres" "${HOME}/.Xresources"; ok ".Xresources"; }

  local zshrc_src="${DOTFILES_DIR}/zsh/.zshrc"
  [[ -f "$zshrc_src" ]] && { cp "$zshrc_src" "${HOME}/.zshrc"; ok ".zshrc"; }

  # Mark every shell helper executable.  rsync usually preserves perms,
  # but if anything came in via scp or a manual copy the +x bit can be
  # lost — re-applying it here is cheap and idempotent.
  chmod +x "${HOME}/.config/polybar/launch.sh"      2>/dev/null || true
  chmod +x "${HOME}/.config/conky/launch.sh"        2>/dev/null || true
  chmod +x "${HOME}/.config/lockscreen/lock.sh"     2>/dev/null || true
  chmod +x "${HOME}/.config/wallpaper/download_wallpaper.sh" 2>/dev/null || true
  chmod +x "${HOME}/.config/i3/scripts/"*.sh        2>/dev/null || true
  chmod +x "${HOME}/.config/polybar/scripts/"*.sh   2>/dev/null || true

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

  patch_picom_backend

  # Wallpaper: prefer the curated Unsplash hacker image
  # (download_wallpaper.sh, SHA-256 pinned).  If the download fails —
  # offline install, CDN unreachable, hash mismatch the user hasn't
  # acked — fall back to the procedural Pillow generator so we always
  # leave ~/.config/wallpaper/wallpaper.png in place.
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

  # Hyper-V Xorg config (only on Hyper-V)
  local hv_src="${DOTFILES_DIR}/xorg.conf.d/10-hyperv.conf"
  if [[ "$VIRT_TYPE" == "hyperv" && -f "$hv_src" ]]; then
    log "Deploying Hyper-V Xorg config …"
    sudo install -d /etc/X11/xorg.conf.d
    sudo install -m 0644 "$hv_src" /etc/X11/xorg.conf.d/10-hyperv.conf
    ok "/etc/X11/xorg.conf.d/10-hyperv.conf"
  else
    sudo rm -f /etc/X11/xorg.conf.d/10-hyperv.conf 2>/dev/null || true
  fi

  # LightDM greeter
  local lightdm_src="${DOTFILES_DIR}/lightdm/lightdm-gtk-greeter.conf"
  if [[ -f "$lightdm_src" ]]; then
    sudo install -m 0644 "$lightdm_src" /etc/lightdm/lightdm-gtk-greeter.conf
    ok "lightdm greeter config"
  fi

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

  log "Enabling lightdm …"
  sudo systemctl enable lightdm >/dev/null 2>&1 || true
  ok "lightdm enabled (run \`sudo systemctl start lightdm\` to start now)"
}

# ============================================================
# Terminal stack: tpm / oh-my-zsh / starship / nerd font / shell
# ============================================================
install_nerd_font() {
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
  # SECURITY: don't pipe install.sh from starship.rs.  Instead pull the
  # arch-specific tarball directly from the GitHub release, verify its
  # SHA256 against the published sidecar, and only then extract.  This
  # turns a "trust whatever HTTP returns" install into a tamper-evident
  # one — a compromised CDN can't ship a backdoored binary without also
  # compromising the GitHub release.
  log "Installing starship (verified SHA256) …"
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
  tmp="$(mktemp -d)"
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
}

# ============================================================
# Validation
# ============================================================
declare -a VAL_CHECKS=(
  # Use `sudo -ln` (list permissions) — exits 0 whenever the user has
  # ANY passwordless capability, so this works in both broad-sudo
  # (install mode) and narrow-sudo (post-harden) configurations.
  # `sudo -n true` would have falsely failed on a hardened system because
  # /usr/bin/true isn't on the narrow allowlist.
  "sudo (NOPASSWD)|sudo -ln 2>/dev/null | grep -q NOPASSWD"
  "i3|command -v i3"
  "polybar|command -v polybar"
  "picom|command -v picom"
  "rofi|command -v rofi"
  "alacritty|command -v alacritty"
  "dunst|command -v dunst"
  "feh|command -v feh"
  "lightdm enabled|systemctl is-enabled lightdm"
  "~/.xsession|test -x ${HOME}/.xsession"
  "~/.config/i3/config|test -f ${HOME}/.config/i3/config"
  "wallpaper|test -f ${HOME}/.config/wallpaper/wallpaper.png"
  "lockscreen script|test -x ${HOME}/.config/lockscreen/lock.sh"
  "rofi config|test -f ${HOME}/.config/rofi/config.rasi"
  "polybar config|test -f ${HOME}/.config/polybar/config.ini"
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
  "polybar mullvad-status|test -x ${HOME}/.config/polybar/scripts/mullvad-status.sh"
  "polybar wireguard-status|test -x ${HOME}/.config/polybar/scripts/wireguard-status.sh"
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
  tmp="$(mktemp)"
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
harden_uu() {
  log "Enabling unattended-upgrades for Debian-Security only…"
  if ! dpkg -l unattended-upgrades 2>/dev/null | grep -q '^ii'; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      unattended-upgrades apt-listchanges >"${LOG_DIR}/apt_uu.log" 2>&1 \
      || { warn "unattended-upgrades install failed"; return 1; }
  fi
  # The default 50unattended-upgrades file already restricts to security;
  # we just turn on the periodic timer that drives it.
  sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  sudo systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
  ok "unattended-upgrades enabled (security patches will install automatically)"
}

unharden_uu() {
  log "Disabling unattended-upgrades…"
  sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
  sudo systemctl disable --now unattended-upgrades.service >/dev/null 2>&1 || true
  ok "unattended-upgrades disabled"
}

# --- 4. systemd-resolved + Quad9 DoT ------------------------
# Quad9 chosen for the malware-blocking + privacy-preserving defaults
# (no logging in EU operations, fast, supports DoT and DNSSEC).  The
# user can swap to Cloudflare/Google by editing the conf file.
harden_dns() {
  log "Configuring systemd-resolved with Quad9 DoT + DNSSEC …"
  if ! command -v resolvectl >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-resolved \
      >"${LOG_DIR}/apt_resolved.log" 2>&1 \
      || { warn "systemd-resolved install failed"; return 1; }
  fi
  sudo install -d -m 0755 /etc/systemd/resolved.conf.d
  sudo tee /etc/systemd/resolved.conf.d/dnsovertls.conf >/dev/null <<'EOF'
# Managed by ./local_setup.sh harden.
# Quad9 (9.9.9.9) blocks known-malicious domains and runs in low-log
# Switzerland.  149.112.112.112 is its IPv6 / secondary endpoint.
# Cloudflare's 1.1.1.1 is the fallback if Quad9 is unreachable.
[Resolve]
DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net
FallbackDNS=1.1.1.1#one.one.one.one
DNSOverTLS=yes
DNSSEC=allow-downgrade
Cache=yes
DNSStubListener=yes
EOF
  # Repoint /etc/resolv.conf at resolved's stub.
  sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  # Remove the dhcpcd static line we may have added during the earlier
  # DNS-recovery step (otherwise dhcpcd will fight resolved every renew).
  if [[ -f /etc/dhcpcd.conf ]]; then
    sudo sed -i '/^static domain_name_servers=/d' /etc/dhcpcd.conf
    grep -q '^nohook resolv.conf' /etc/dhcpcd.conf 2>/dev/null \
      || echo 'nohook resolv.conf' | sudo tee -a /etc/dhcpcd.conf >/dev/null
  fi
  sudo systemctl enable --now systemd-resolved >/dev/null
  sudo systemctl restart systemd-resolved
  ok "DNS → Quad9 over DoT (DNSSEC); resolvectl status to verify"
}

unharden_dns() {
  log "Reverting DNS to dhcpcd-managed Cloudflare/Google …"
  sudo rm -f /etc/systemd/resolved.conf.d/dnsovertls.conf
  sudo systemctl restart systemd-resolved >/dev/null 2>&1 || true
  if [[ -f /etc/dhcpcd.conf ]]; then
    sudo sed -i '/^nohook resolv.conf/d' /etc/dhcpcd.conf
    grep -q '^static domain_name_servers=' /etc/dhcpcd.conf 2>/dev/null \
      || echo 'static domain_name_servers=1.1.1.1 8.8.8.8' \
         | sudo tee -a /etc/dhcpcd.conf >/dev/null
  fi
  # Repoint resolv.conf at a plain file dhcpcd will rewrite.
  sudo rm -f /etc/resolv.conf
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' \
    | sudo tee /etc/resolv.conf >/dev/null
  ok "DNS reverted to plain UDP via dhcpcd"
}

# --- harden orchestrator ------------------------------------
harden_phase() {
  ensure_sudo
  log "Running security-hardening pass — narrow sudoers, ufw, "
  log "unattended-upgrades, DNS-over-TLS.  Reverse with \`unharden\`."
  harden_uu  || warn "(unattended-upgrades step had warnings)"
  harden_dns || warn "(DNS step had warnings)"
  harden_ufw || warn "(ufw step had warnings)"
  harden_sudo || die  "(sudoers step failed — refusing to leave system half-hardened)"
  echo
  ok "Hardening complete."
  log "Verify: \`sudo -l\`, \`sudo ufw status\`, \`resolvectl status\`,"
  log "        \`systemctl status unattended-upgrades.service\`"
}

unharden_phase() {
  ensure_sudo
  log "Reverting hardening — broad sudoers, ufw off, "
  log "auto-upgrades off, DNS back to dhcpcd."
  unharden_sudo
  unharden_ufw
  unharden_uu
  unharden_dns
  echo
  ok "Hardening reverted (suitable for re-running setup)."
}

validate_phase() {
  log "Running validation checks …"
  echo
  local failures=0
  local entry label cmd
  for entry in "${VAL_CHECKS[@]}"; do
    label="${entry%%|*}"
    cmd="${entry#*|}"
    if bash -c "$cmd" >/dev/null 2>&1; then
      printf "  [ ok ]  %s\n" "$label"
    else
      printf "  [FAIL]  %s\n" "$label"
      failures=$((failures + 1))
    fi
  done

  # Hardware-conditional checks
  if [[ "$VIRT_TYPE" == "hyperv" ]]; then
    if [[ -f /etc/X11/xorg.conf.d/10-hyperv.conf ]]; then
      printf "  [ ok ]  hyperv Xorg config\n"
    else
      printf "  [FAIL]  hyperv Xorg config\n"; failures=$((failures + 1))
    fi
  fi
  if [[ "$GPU_VENDOR" == "nvidia" ]]; then
    if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
      printf "  [ ok ]  nvidia-smi reports GPU\n"
    else
      printf "  [FAIL]  nvidia-smi (driver may need reboot)\n"
      failures=$((failures + 1))
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
  • Install ~80 desktop & terminal packages (i3, polybar, alacritty,
    neovim, zsh, picom, dunst, …)
  • If GPU detected: install matching driver stack (nvidia/amd/intel)
  • If virtualised: install hypervisor guest tools (qemu-guest-agent,
    open-vm-tools, hyperv-daemons, …)
  • Install Mullvad VPN from its official apt repo
  • Install WireGuard userland (wg, wg-quick)
  • Time: 3–10 minutes (depends on network)
EOF
      ;;
    deploy)
      cat <<EOF
This stage will:
  • Copy this repo's ./config/* into ~/.config/
  • Patch picom backend (xrender for VMs, glx for physical GPUs)
  • Generate the desktop wallpaper (procedural cyberpunk PNG)
  • Deploy the Hyper-V Xorg config (only on Hyper-V)
  • Configure xrdp if it's installed (otherwise skipped)
  • Enable the lightdm display manager
  • Time: < 30 seconds
EOF
      ;;
    terminal)
      cat <<EOF
This stage will:
  • Download JetBrainsMono Nerd Font (~25 MB) → ~/.local/share/fonts/
  • Install oh-my-zsh + zsh-autosuggestions + zsh-syntax-highlighting
  • Install starship prompt → ~/.local/bin/starship
  • Install tpm (tmux plugin manager) and the listed tmux plugins
  • Set zsh as your default shell (via \`usermod -s\`)
  • Pre-install neovim plugins + treesitter parsers (headless)
  • Time: 1–3 minutes
EOF
      ;;
    validate)
      cat <<EOF
This stage will:
  • Run ~40 sanity checks: tools installed, configs in place, services
    enabled, default shell, fonts, VPN tools, polybar helpers
  • Read-only — no system changes
  • Time: < 5 seconds
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
# Default for `setup` is INTERACTIVE.  If stdin isn't a TTY (piped, SSH
# without -t, CI), we silently flip to bypass — otherwise read would hang
# the entire pipeline waiting for input that's never coming.
if [[ -t 0 ]]; then INTERACTIVE=1; else INTERACTIVE=0; fi

_MODE_FLAG_SEEN=""    # tracks --interactive vs --bypass to detect conflict

while [[ $# -gt 0 ]]; do
  case "$1" in
    setup|detect|install|deploy|terminal|validate|harden|unharden)
      ACTION="$1" ;;
    --hyperv)   FORCE_VIRT="hyperv" ;;
    --vm)       FORCE_VIRT="vm" ;;
    --physical) FORCE_VIRT="physical" ;;
    --nvidia)   FORCE_GPU="nvidia" ;;
    --amd)      FORCE_GPU="amd" ;;
    --intel)    FORCE_GPU="intel" ;;
    --no-gpu)   FORCE_GPU="none" ;;
    --no-drivers) NO_DRIVERS=1 ;;
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

# ============================================================
# Main
# ============================================================
# Bootstrap detection tools first (lspci / dmidecode) — they live in tiny
# packages and we need them for the detect_* functions to be accurate on a
# fresh Debian install.  Skipped on `detect`/`validate` if they're already
# present.
ensure_detection_tools
detect_virt
detect_gpu
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

    echo
    ok "Local setup complete."
    if [[ "$GPU_VENDOR" == "nvidia" ]]; then
      warn "NVIDIA driver installed — reboot before starting an X session."
    fi
    ;;
esac
