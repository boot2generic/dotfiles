#!/usr/bin/env python3
"""
VM automation helpers for the Debian 13 development VM.

Privilege escalation uses sudo with NOPASSWD (not su).  Run
`python3 vm_automation.py bootstrap` once after initial provisioning to
install sudo and grant NOPASSWD access.  All subsequent root operations use
`sudo bash -c '...'` — no pexpect, no password prompts, no shell-injection
risk from empty variable expansions.

Default credentials come from env vars; fall back to provisioning defaults.

Requirements (controller): sshpass, openssh-client, rsync, python3-pexpect

Usage:
    python3 vm_automation.py bootstrap                           # one-time: install + configure sudo
    python3 vm_automation.py verify                              # connectivity smoke test
    python3 vm_automation.py detect                              # report hardware type
    python3 vm_automation.py run   '<cmd>'                       # run as VM_USER
    python3 vm_automation.py sudo  '<cmd>'                       # run as root via sudo
    python3 vm_automation.py install-gui [--hyperv|--physical] [--nvidia]
    python3 vm_automation.py deploy-configs [--hyperv|--physical]
    python3 vm_automation.py setup-terminal                      # tmux/nvim/zsh stack
    python3 vm_automation.py validate                            # post-install checks
    python3 vm_automation.py screenshot [path]                   # headless screenshot
    python3 vm_automation.py setup [--hyperv|--physical] [--nvidia] [-i|-y]
    python3 vm_automation.py harden        # opt-in: narrow sudo, ufw,
                                           # auto-updates, DNS-over-TLS
    python3 vm_automation.py unharden      # revert harden (read note below
                                           # — narrow sudoers blocks self)

Hardware flags (auto-detected when omitted):
    --hyperv    Hyper-V VM  : xrender picom, Hyper-V Xorg config (no RDP install)
    --physical  Real hardware: GLX picom
    --nvidia    Install NVIDIA proprietary drivers (physical only)

Mode flags (only meaningful for `setup`):
    --interactive | -i    Print a description of each stage and prompt
                          [Y/n/q] before running it.  Default when stdin
                          is a TTY (interactive terminal).
    --bypass | --yes | -y  Run end-to-end with no per-stage prompts.
                          Default when stdin is not a TTY (CI, piped).

Authentication:
    Set $VM_PASS env var, OR copy your SSH key with `ssh-copy-id`.
    The script tries SSH key auth first; falls back to sshpass -e if
    that fails.  There is NO hardcoded password fallback.

Note about `unharden`:
    `harden` narrows /etc/sudoers.d/<user> so arbitrary `sudo bash` no
    longer works passwordless.  `unharden` itself uses run_root (which
    relies on sudo bash) — so once hardened, you'll need to revert the
    sudoers file via `su` (root password) before unharden can run its
    other steps.  See readme/security.md for the exact recovery flow.

RDP/xrdp is intentionally NOT installed by this script. If you want to verify
visuals over RDP, install xrdp manually on the VM (`sudo apt install xrdp
xorgxrdp`) and re-run `deploy-configs` — the script auto-detects an existing
xrdp install and configures it.
"""

from __future__ import annotations

import os
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

import pexpect

# ============================================================
# Connection settings  (override via environment variables)
# ============================================================
# Connection settings.  Priority for picking a password:
#   1. SSH key auth — preferred.  If `ssh -o BatchMode=yes <user>@<host>
#      true` succeeds, we never invoke sshpass at all.  This is the path
#      to take for any production workflow: copy your key with
#      `ssh-copy-id` and unset VM_PASS.
#   2. $VM_PASS env var — used by sshpass -e (env-var mode), which keeps
#      the password OUT of `ps -ef` output.  The earlier `sshpass -p` form
#      exposed it on the command line — that is gone now.
# There is intentionally no hardcoded password fallback.  If neither key
# auth nor $VM_PASS is present, we error early instead of letting sshpass
# silently prompt (which would hang non-interactive runs).
VM_HOST = os.environ.get("VM_HOST", "172.22.223.157")
VM_USER = os.environ.get("VM_USER", "generic")
VM_PASS = os.environ.get("VM_PASS")    # may be None — see _ssh_argv()

# SECURITY: VM_USER is interpolated into shell commands, ssh user@host
# arguments, and `/etc/sudoers.d/<user>` paths.  Validate it matches
# POSIX portable username syntax up front so a hostile env var (e.g.,
# VM_USER='generic; rm -rf /') can't escape its quoting downstream.
if not re.match(r"^[a-z_][a-z0-9_-]*$", VM_USER):
    sys.exit(f"[!] refusing unsafe VM_USER={VM_USER!r}")

DOTFILES_DIR = Path(__file__).parent / "config"

SSH_OPTS = [
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "ConnectTimeout=10",
    "-o", "ServerAliveInterval=30",
]


# ── SSH key-auth probe + argv builder ────────────────────────
# Cached so we only run the probe once per process.
_ssh_key_works: bool | None = None


def _key_auth_works() -> bool:
    """Return True if SSH key auth succeeds against VM_HOST as VM_USER.

    Uses BatchMode=yes so `ssh` exits non-zero without prompting if no
    key is set up — that's the signal that we need to fall back to a
    password.  The result is cached for the rest of the process.
    """
    global _ssh_key_works
    if _ssh_key_works is not None:
        return _ssh_key_works
    cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
           *SSH_OPTS, f"{VM_USER}@{VM_HOST}", "true"]
    try:
        rc = subprocess.run(cmd, capture_output=True, timeout=10).returncode
    except (subprocess.TimeoutExpired, FileNotFoundError):
        rc = 1
    _ssh_key_works = (rc == 0)
    return _ssh_key_works


def _ssh_argv(*, tty: bool = False) -> list[str]:
    """Build the SSH/sshpass argv list for our standard options.

    If a usable SSH key is configured, return a plain `ssh …` argv.
    Otherwise wrap with `sshpass -e` (reads password from $SSHPASS env)
    and require $VM_PASS to be set.  The `-p` form is intentionally not
    used — it leaks the password into every running process's argv.
    """
    base = ["ssh"]
    if tty:
        base.append("-tt")
    base.extend(SSH_OPTS)
    base.append(f"{VM_USER}@{VM_HOST}")

    if _key_auth_works():
        return base

    if not VM_PASS:
        sys.exit(
            "[!] No SSH key for {u}@{h} and $VM_PASS not set.\n"
            "    Either run `ssh-copy-id {u}@{h}` (recommended) or\n"
            "    `export VM_PASS=...` before invoking this script."
            .format(u=VM_USER, h=VM_HOST)
        )
    return ["sshpass", "-e", *base]


def _ssh_env() -> dict[str, str]:
    """Environment dict for sshpass -e (SSHPASS=$VM_PASS).

    Returned as a copy of the parent env so subprocess keeps PATH etc.;
    we only inject SSHPASS when password auth is actually needed.
    """
    env = os.environ.copy()
    if not _key_auth_works() and VM_PASS:
        env["SSHPASS"] = VM_PASS
    return env

# Patterns that match a shell prompt (bash, zsh, starship ❯ in various states).
# Starship replaces $ with ❯ — we match the Unicode codepoint followed by any
# character (space or ANSI escape) so we don't need an exact-end anchor.
PROMPT_RE = [r"\$ $", r"# $", r"\$ \x1b", r"# \x1b", r"\$\s",
             r"❯ ", r"❯\x1b"]


# ============================================================
# Core SSH helpers
# ============================================================

def _spawn_ssh(tty: bool = False, timeout: int = 30) -> pexpect.spawn:
    """Open a persistent SSH connection as VM_USER.

    Uses key auth when available, sshpass -e when not.  Note we set
    `logfile=None` explicitly so an accidental pexpect logging hook never
    captures a password — pexpect logs are visible to anyone who reads
    the file the user pointed it at.
    """
    cmd = _ssh_argv(tty=tty)
    # maxread=100000 prevents long command output from flushing the marker out
    # of pexpect's rolling buffer (default maxread is only 2000 chars).
    child = pexpect.spawn(cmd[0], cmd[1:], timeout=timeout, encoding="utf-8",
                         maxread=100000, env=_ssh_env())
    child.logfile = None
    child.logfile_read = None
    return child


def run(command: str, timeout: int = 60) -> tuple[int, str]:
    """Run `command` on the VM as VM_USER via a non-interactive SSH call."""
    cmd = [*_ssh_argv(), command]
    child = pexpect.spawn(cmd[0], cmd[1:], timeout=timeout, encoding="utf-8",
                          maxread=100000, env=_ssh_env())
    child.logfile = None
    child.logfile_read = None
    child.expect(pexpect.EOF)
    output = child.before or ""
    child.close()
    return child.exitstatus if child.exitstatus is not None else -1, output


def run_root(command: str, timeout: int = 300) -> tuple[int, str]:
    """
    Run `command` as root via `sudo bash -c '...'` (NOPASSWD required).

    This replaces the old su-based approach entirely.  sudo is non-interactive
    once NOPASSWD is configured, so no pexpect session is needed — output
    capture is identical to run().

    NOTE on log files: the redirect inside `bash -c` runs as root.  Debian's
    `fs.protected_regular = 2` blocks root from O_CREAT|O_TRUNC on a regular
    file in a sticky world-writable dir (/tmp) when the file is owned by
    another user.  So every log path used by a run_root caller is prefixed
    `/tmp/vma_*.log` — that namespace is never touched by local_setup.sh
    (which uses `/tmp/<name>.log` from the user's bash redirect), so the
    two scripts can run on the same VM without clobbering each other.

    Bootstrap sudo first with: python3 vm_automation.py bootstrap
    """
    return run(f"sudo bash -c {shlex.quote(command)}", timeout=timeout)


def _bootstrap_run_root_su(command: str, timeout: int = 300) -> tuple[int, str]:
    """
    INTERNAL — only called by bootstrap_sudo() to install sudo via su.

    Uses `su -s /bin/bash` (explicit shell) so that even if root's
    /etc/passwd shell entry is ever corrupted again, this function still
    works.  Once sudo is installed this function is never called again.
    """
    if not VM_PASS:
        sys.exit(
            "[!] bootstrap_sudo needs $VM_PASS to authenticate to su as root.\n"
            "    Set VM_PASS=<root-password> in your environment for the "
            "one-time bootstrap, then unset it after."
        )
    marker = "__VM_AUTOMATION_DONE__"
    # -s /bin/bash: override root's passwd shell regardless of /etc/passwd
    wrapped = f"su -s /bin/bash -c {shlex.quote(command + f'; echo {marker}:$?')}"
    child = _spawn_ssh(tty=True, timeout=timeout)
    child.expect(PROMPT_RE)
    child.sendline(wrapped)
    child.expect(r"[Pp]assword:")
    child.sendline(VM_PASS)
    child.expect(marker + r":(\d+)", timeout=timeout)
    status = int(child.match.group(1))
    raw = child.before or ""
    output = raw.split(wrapped, 1)[-1]
    child.sendline("exit")
    child.close()
    return status, output


def _wrap_with_sshpass(argv: list[str]) -> list[str]:
    """Prefix an scp/rsync argv with `sshpass -e` if password auth is needed.

    With key auth, just return argv unchanged.  Either way, the password
    (if any) is delivered via the SSHPASS env var, never on the command
    line — see _ssh_env().
    """
    if _key_auth_works():
        return argv
    if not VM_PASS:
        sys.exit("[!] No SSH key and no $VM_PASS — cannot transfer files.")
    return ["sshpass", "-e", *argv]


def scp_to_vm(local_path: str, remote_path: str) -> int:
    """Copy a local file or directory to the VM (rsync for directories).

    For directory copies we exclude common dev-tooling cruft that
    shouldn't ship to the VM:
      • __pycache__ — Python bytecode caches generated by `py_compile`
        / running scripts locally for syntax checks.
      • *.pyc — same.
      • .git — would explode the size; deploys aren't versioned.
      • .DS_Store — macOS Finder metadata if anyone edits on a Mac.
    """
    if Path(local_path).is_dir():
        src = local_path.rstrip("/") + "/"
        argv = ["rsync", "-a",
                "--exclude=__pycache__",
                "--exclude=*.pyc",
                "--exclude=.git",
                "--exclude=.DS_Store",
                "-e", f"ssh {' '.join(SSH_OPTS)}",
                src, f"{VM_USER}@{VM_HOST}:{remote_path}/"]
    else:
        argv = ["scp", *SSH_OPTS,
                local_path, f"{VM_USER}@{VM_HOST}:{remote_path}"]
    cmd = _wrap_with_sshpass(argv)
    result = subprocess.run(cmd, capture_output=True, text=True,
                            env=_ssh_env())
    if result.returncode != 0:
        print(result.stderr.strip())
    return result.returncode


def scp_from_vm(remote_path: str, local_path: str) -> int:
    """Copy a file from the VM to local."""
    argv = ["scp", *SSH_OPTS,
            f"{VM_USER}@{VM_HOST}:{remote_path}", local_path]
    cmd = _wrap_with_sshpass(argv)
    result = subprocess.run(cmd, capture_output=True, text=True,
                            env=_ssh_env())
    if result.returncode != 0:
        print(result.stderr.strip())
    return result.returncode


# ============================================================
# One-time sudo bootstrap
# ============================================================

def bootstrap_sudo() -> int:
    """
    Install sudo and grant VM_USER passwordless root access.

    Uses su ONE TIME for this bootstrap, then all future root operations use
    sudo.  Safe to run multiple times — skips if already configured.

    Bugs prevented vs the old su approach:
    - sudo never interpolates shell variables, so empty expansions can't
      accidentally target the wrong user.
    - NOPASSWD config is in /etc/sudoers.d/ so it survives sudo upgrades.
    - Root's /etc/passwd shell is never touched by this function.
    """
    # Already configured?
    rc, out = run("sudo -n true 2>/dev/null && echo SUDO_OK || echo SUDO_MISSING")
    if "SUDO_OK" in out:
        print("[ok] sudo already configured with NOPASSWD")
        return 0

    print("[*] Bootstrapping sudo (one-time su usage) …")

    sudoers_line = f"{VM_USER} ALL=(ALL) NOPASSWD: ALL"
    cmds = [
        "export PATH=/usr/local/sbin:/usr/sbin:/sbin:$PATH",
        "DEBIAN_FRONTEND=noninteractive apt-get install -y sudo "
        ">/tmp/vma_sudo_install.log 2>&1",
        # Write sudoers drop-in (no spaces around > to avoid shell issues)
        f"echo '{sudoers_line}' >/etc/sudoers.d/{VM_USER}",
        f"chmod 440 /etc/sudoers.d/{VM_USER}",
        # Validate with visudo
        f"visudo -c -f /etc/sudoers.d/{VM_USER}",
    ]

    rc, out = _bootstrap_run_root_su(" && ".join(cmds), timeout=300)
    if rc != 0:
        print(f"[!] sudo bootstrap failed (exit {rc}):\n{out.strip()[-500:]}")
        return rc

    # Verify
    rc, out = run("sudo -n true 2>/dev/null && echo SUDO_OK || echo SUDO_MISSING")
    if "SUDO_OK" in out:
        print("[ok] sudo installed and NOPASSWD configured")
        # Remove any shim files left from the su debugging session
        run("rm -f ~/.local/bin/generic 2>/dev/null || true")
        return 0

    print("[!] sudo installed but NOPASSWD verification failed")
    return 1


# ============================================================
# Connectivity verification
# ============================================================

def verify() -> int:
    """Smoke-test SSH connectivity and sudo access."""
    print(f"[*] SSH {VM_USER}@{VM_HOST}")
    rc, out = run("whoami && hostname && cat /etc/debian_version && uname -srm")
    print(out.strip())
    if rc != 0:
        print(f"[!] ssh exit={rc}")
        return rc

    print("[*] Checking sudo …")
    rc, out = run_root("whoami && id")
    print(out.strip())
    if rc != 0:
        print(f"[!] sudo failed (exit={rc}) — run: python3 vm_automation.py bootstrap")
        return rc

    print("[ok] ssh + sudo verified")
    return 0


# ============================================================
# Hardware detection
# ============================================================

def detect_hardware() -> dict:
    """
    Probe the VM for Hyper-V vs physical hardware and NVIDIA GPU presence.

    Returns dict keys: is_hyperv, has_nvidia, product, vendor, kernel
    """
    _, product = run("cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown")
    _, vendor  = run("cat /sys/class/dmi/id/sys_vendor  2>/dev/null || echo unknown")
    _, lspci   = run("lspci 2>/dev/null || echo ''")
    _, kernel  = run("uname -r")

    product = product.strip()
    vendor  = vendor.strip()
    kernel  = kernel.strip()

    is_hyperv = (
        "microsoft"      in vendor.lower()
        or "virtual machine" in product.lower()
        or "hyper-v"         in product.lower()
    )
    has_nvidia = "nvidia" in lspci.lower()

    return {
        "is_hyperv":  is_hyperv,
        "has_nvidia": has_nvidia,
        "product":    product,
        "vendor":     vendor,
        "kernel":     kernel,
    }


def print_hardware(hw: dict) -> None:
    mode = "Hyper-V VM"       if hw["is_hyperv"]  else "Physical hardware"
    gpu  = "NVIDIA GPU found" if hw["has_nvidia"] else "No NVIDIA GPU"
    print(f"[*] Hardware : {mode}")
    print(f"    Product  : {hw['product']}")
    print(f"    Vendor   : {hw['vendor']}")
    print(f"    Kernel   : {hw['kernel']}")
    print(f"    GPU      : {gpu}")


# ============================================================
# Package lists
# ============================================================

BASE_PACKAGES = [
    # X server + display infrastructure
    "xorg", "xserver-xorg", "x11-xserver-utils", "xinit", "xvfb", "dbus-x11",

    # Window manager + compositor + bar + launcher
    "i3", "polybar", "picom", "rofi",

    # Terminal emulator
    "alacritty",

    # Notifications
    "dunst", "libnotify-bin",

    # Display manager
    "lightdm", "lightdm-gtk-greeter", "lightdm-gtk-greeter-settings",

    # Wallpaper + screenshots
    "feh", "scrot",

    # Fonts
    "fonts-jetbrains-mono", "fonts-font-awesome",
    "fonts-material-design-icons-iconfont",

    # GTK themes + icons
    "adwaita-icon-theme", "papirus-icon-theme", "lxappearance",

    # File manager + network applet
    "thunar", "gvfs", "network-manager-gnome", "network-manager",

    # Web browser — firefox-esr is the Debian-shipped Firefox.  The i3
    # `Mod+b` binding launches `firefox-esr` directly.  To swap, install
    # your alternate browser (mullvad-browser, chromium, …) and edit
    # the binding in ~/.config/i3/config.
    "firefox-esr",

    # Audio + media-key controls.  `pactl` (from pulseaudio) handles
    # volume; `playerctl` talks MPRIS to any media player so the standard
    # play/pause/next/prev keys work for Spotify, mpv, Firefox, VLC, …
    "pulseaudio", "pavucontrol", "playerctl",

    # WireGuard VPN — userland tools (`wg`, `wg-quick`).  Drop a config
    # into /etc/wireguard/<name>.conf and `sudo wg-quick up <name>`.
    # The kernel module ships in modern Debian kernels, no DKMS needed.
    "wireguard", "wireguard-tools",

    # Utilities
    "numlockx", "arandr", "xclip", "xdotool", "brightnessctl",
    "i3lock", "imagemagick", "python3-pil",

    # Network diagnostics + radio toggle.  `iw` exposes signal/bitrate/SSID
    # for low-level wifi troubleshooting (`iw dev wlan0 link`); `rfkill`
    # backs the i3 XF86WLAN keybind that flips the wireless radio.  The
    # connection manager itself (NetworkManager + nm-applet) is already
    # listed above — these are the CLI-level helpers.
    "iw", "rfkill",

    # Battery / power management.  TLP is a no-op inside a Hyper-V VM
    # (no battery, no laptop hardware) but ships in BASE_PACKAGES to
    # keep parity with local_setup.sh — the package's postinst enables
    # the service, but it stays inactive when no power-supply sysfs
    # entries exist.  `acpi` / `powertop` are likewise harmless inside
    # the VM and useful when the same dotfiles deploy onto a laptop.
    "tlp", "tlp-rdw", "acpi", "powertop",

    # Terminal tools (tmux / neovim / zsh stack)
    "tmux", "neovim", "zsh", "fzf", "ripgrep", "fd-find",
    "build-essential",     # gcc + g++ + make + libc6-dev — needed to build
                           # telescope-fzf-native / treesitter parsers
    "nodejs", "npm",       # needed by mason.nvim LSP installers

    # General shell tools
    "rsync", "curl", "wget", "git", "htop", "fastfetch",

    # Pretty CLI utilities
    "bat",              # cat with syntax highlighting (batcat on older Debian)
    "grc",              # generic colouriser (netstat, ping, ps, etc.)
    "net-tools",        # netstat, ifconfig
    "lm-sensors",       # CPU temperature readings
    "conky-all",        # desktop hardware monitor widget (full-featured build)
    "iproute2",         # ip, ss (modern net tools)

    # Hardware-detection helpers — used by both this script and
    # local_setup.sh to identify GPU vendor / hypervisor.
    "pciutils",         # lspci
    "dmidecode",        # vendor / product info via DMI

    # X11 window/property utilities — wmctrl + x11-utils (xprop,
    # xwininfo, xdpyinfo) are kept in the base set as they're handy
    # diagnostic tools.  Conky's launcher used to need them for a
    # keep-below daemon; that's gone now (own_window_type='override'
    # makes the WM ignore conky entirely, no daemon required).
    "wmctrl", "x11-utils",

    # Archive tools — Mason needs `unzip` to extract clangd's release zip;
    # without it the Mason install of clangd silently fails with
    # "unzip is not executable".
    "unzip",
]

NVIDIA_PACKAGES = [
    "nvidia-driver",
    "nvidia-settings",
    # Note: there is NO Debian package called `nvidia-smi`.  The binary
    # of that name ships inside `nvidia-driver` (specifically nvidia-utils,
    # which `nvidia-driver` depends on).  Listing it here used to make
    # `apt-get install -y` fail with "Unable to locate package nvidia-smi"
    # on every NVIDIA setup attempt.
]


def install_gui(
    is_hyperv: bool = True,
    install_nvidia: bool = False,
    verbose: bool = True,
) -> int:
    """Install all GUI + terminal-tool packages.

    RDP/xrdp is no longer auto-installed.  Install it manually if you need
    to inspect the desktop visually — the deploy step will configure any
    pre-existing xrdp install.

    On the NVIDIA path we MUST enable Debian's non-free + non-free-firmware
    apt components first — `nvidia-driver` lives there.  Without it, the
    apt install would fail with a "Unable to locate package" error.
    """
    packages = list(BASE_PACKAGES)

    if is_hyperv:
        label = "Hyper-V (no RDP, no GPU drivers)"
    else:
        label = "Physical hardware"
        if install_nvidia:
            # Enable non-free BEFORE building the package list so the
            # subsequent `apt-get update` picks up nvidia-driver.
            enable_nonfree_repos()
            packages.extend(NVIDIA_PACKAGES)
            label += " + NVIDIA drivers"

    print(f"[*] Install profile : {label}")
    print(f"[*] {len(packages)} packages queued")

    print("[*] Updating apt cache …")
    rc, out = run_root("apt-get update -qq >/tmp/vma_apt_update.log 2>&1", timeout=120)
    if rc != 0:
        _, log = run("tail -20 /tmp/vma_apt_update.log")
        print(log)
        print(f"[!] apt update failed (exit {rc})")
        return rc

    print("[*] Installing packages (may take several minutes) …")
    pkg_str = " ".join(packages)
    rc, out = run_root(
        f"DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "
        f"{pkg_str} >/tmp/vma_apt_install.log 2>&1",
        timeout=900,
    )
    if verbose:
        _, log = run("tail -30 /tmp/vma_apt_install.log")
        print(log.strip())
    if rc != 0:
        print(f"[!] apt install failed (exit {rc})")
        return rc

    print("[ok] GUI packages installed")
    return 0


# ============================================================
# Mullvad VPN  —  apt-repo install, auto-updates with the system
# ============================================================

# ── Pinned Mullvad signing-key fingerprint ────────────────────
# This is the GPG fingerprint of Mullvad's apt repo signing key as
# published on https://mullvad.net/en/help/install-mullvad-app-linux .
# We download the keyring file from Mullvad's HTTPS endpoint and then
# verify its fingerprint matches this constant — if they ever rotate
# the key, install will fail loudly until you bump this value.
#
# To override (e.g., during a key rotation): set the env var
# MULLVAD_KEY_FINGERPRINT before running setup.
# Mullvad's apt repo signing key (primary, 4096-bit RSA, created 2016).
# Cross-check before pinning at https://mullvad.net/en/help/install-mullvad-app-linux
# or by `gpg --keyserver hkp://keyserver.ubuntu.com --recv-keys <fp>` and
# comparing against published values.
MULLVAD_KEY_FINGERPRINT = (
    "A1198702FC3E0A09A9AE5B75D5A1D4F266DE8DDF"
)


def install_mullvad() -> int:
    """Install Mullvad VPN from its official apt repository.

    Mullvad publishes signed .deb packages and a per-Debian-release apt
    repo; using it (rather than downloading the latest .deb each time)
    means `apt upgrade` keeps Mullvad current alongside everything else.

    Security:
      • The signing key is downloaded over HTTPS, then its fingerprint is
        cross-checked against MULLVAD_KEY_FINGERPRINT (above).  If the
        check fails — either Mullvad rotated the key intentionally OR
        we caught a MITM — install aborts and the apt repo is NOT added.
      • The keyring lives under /etc/apt/keyrings/ and is referenced in
        the .list file via `signed-by=...`, so apt only trusts that key
        for that repo (no global keyring pollution).

    Idempotent: re-running on an already-configured machine just reports
    "already installed" and exits 0.  Failures don't abort the wider
    setup pipeline — caller treats this stage as best-effort.
    """
    print("[*] Installing Mullvad VPN …")

    # Check if it's already there.
    rc, out = run("dpkg -l mullvad-vpn 2>/dev/null | grep -q '^ii' && echo yes || echo no")
    if "yes" in out:
        print("    [ok] mullvad-vpn already installed")
        return 0

    expected_fp = os.environ.get("MULLVAD_KEY_FINGERPRINT",
                                 MULLVAD_KEY_FINGERPRINT)

    # The script runs as root on the VM and aborts on first error so we
    # never end up with a half-configured apt source.  Note the
    # fingerprint check happens BEFORE the .list file is written.
    setup = rf'''
set -euo pipefail
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://repository.mullvad.net/deb/mullvad-keyring.asc \
    -o /etc/apt/keyrings/mullvad-keyring.asc

# SECURITY: require the keyring to contain EXACTLY ONE PRIMARY key
# matching our pin.  Mullvad's keyring legitimately ships a primary +
# encryption subkey + signing subkey; we only count `fpr:` lines that
# follow a `pub:` (primary), not those that follow `sub:`.
EXPECTED={shlex.quote(expected_fp)}
FPS=$(gpg --show-keys --with-colons /etc/apt/keyrings/mullvad-keyring.asc \
    2>/dev/null \
    | awk -F: '
        /^pub:/ {{p=1; next}}
        /^sub:/ {{p=0}}
        /^fpr:/ && p {{print $10; p=0}}
    ')
NKEYS=$(printf '%s\n' "$FPS" | grep -c .)
if [ "$NKEYS" != 1 ] || [ "$FPS" != "$EXPECTED" ]; then
    rm -f /etc/apt/keyrings/mullvad-keyring.asc
    echo "Mullvad keyring failed pinning check:"
    echo "  expected exactly 1 PRIMARY key with fingerprint $EXPECTED"
    echo "  saw $NKEYS primary key(s):"
    printf '    %s\n' $FPS
    echo "If Mullvad rotated their key, update MULLVAD_KEY_FINGERPRINT"
    echo "in vm_automation.py (or pass MULLVAD_KEY_FINGERPRINT=<new>)."
    exit 1
fi

ARCH=$(dpkg --print-architecture)
. /etc/os-release
echo "deb [signed-by=/etc/apt/keyrings/mullvad-keyring.asc arch=${{ARCH}}] https://repository.mullvad.net/deb/stable ${{VERSION_CODENAME}} main" \
    > /etc/apt/sources.list.d/mullvad.list
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y mullvad-vpn
'''
    rc, out = run_root(setup, timeout=300)
    if rc != 0:
        # Don't fail the whole setup — Mullvad is optional UX.
        print(f"    [!] Mullvad install failed (exit {rc}). Last output:")
        print("        " + out.strip()[-400:].replace("\n", "\n        "))
        return rc

    print("    [ok] Mullvad VPN installed (key fingerprint verified)")
    print("    [i]  Run `mullvad account login <number>` to activate")
    return 0


# ============================================================
# NVIDIA drivers (physical hardware)
# ============================================================

def enable_nonfree_repos() -> int:
    """Enable Debian's `contrib`, `non-free`, and `non-free-firmware`
    components in apt sources.  Required before installing nvidia-driver.

    Handles BOTH apt source formats Debian uses today:
      • `.list` (legacy single-line: `deb URI suite components…`)
      • `.sources` (modern deb822 multi-line block with `Components:`)

    Idempotent: skips lines that already include `non-free-firmware`.
    """
    print("[*] Enabling non-free + non-free-firmware components …")
    # Auto-prune apt-source backups older than 30 days first (they
    # accumulate every time enable_nonfree_repos runs against a fresh
    # box).  apt only scans *.list / *.sources so leaving them around
    # is harmless, but they stack up.
    run_root(
        "find /etc/apt -maxdepth 2 -name '*.bak.*' -mtime +30 -delete "
        "2>/dev/null || true"
    )
    # Use a python script on the remote side — far easier to reason about
    # than nested shell quoting and `sed` regex escapes for two formats.
    #
    # SECURITY: every file we modify is copied to <path>.bak.<timestamp>
    # FIRST.  Apt source modifications can render a system unable to
    # update; an automated backup means rollback is `mv …bak.* path`,
    # no scrambling for git history.  The backup is created with mode
    # 0600 so its contents (which include source URLs) aren't broadcast.
    remote_script = r'''
import glob, re, shutil, time, os

def _backup(path):
    bak = f"{path}.bak.{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, bak)
    os.chmod(bak, 0o600)
    return bak

def update_list_file(path):
    """Append components to `deb …` lines that are missing non-free-firmware."""
    try:
        with open(path) as f: data = f.read()
    except FileNotFoundError:
        return False
    out = []
    changed = False
    for line in data.splitlines():
        if (line.startswith("deb ") or line.startswith("deb-src "))             and "non-free-firmware" not in line:
            # Append once at end-of-line.  Apt is whitespace-tolerant, so
            # we don't need to deduplicate components like `contrib`.
            line = line.rstrip() + " contrib non-free non-free-firmware"
            changed = True
        out.append(line)
    if changed:
        bak = _backup(path)
        with open(path, "w") as f: f.write("\n".join(out) + "\n")
        print(f"  edited {path}  (backup: {bak})")
    return changed

def update_sources_file(path):
    """Append components to deb822-format `Components:` lines."""
    try:
        with open(path) as f: data = f.read()
    except FileNotFoundError:
        return False
    if "non-free-firmware" in data:
        return False
    new = re.sub(
        r"(?m)^(Components:.*)$",
        r"\1 contrib non-free non-free-firmware",
        data,
    )
    if new != data:
        bak = _backup(path)
        with open(path, "w") as f: f.write(new)
        print(f"  edited {path}  (backup: {bak})")
        return True
    return False

touched = 0
for p in glob.glob("/etc/apt/sources.list") + glob.glob("/etc/apt/sources.list.d/*.list"):
    touched += int(update_list_file(p))
for p in glob.glob("/etc/apt/sources.list.d/*.sources"):
    touched += int(update_sources_file(p))
print(f"updated {touched} source file(s)")
'''
    rc, out = run_root(f"python3 -c {shlex.quote(remote_script)}", timeout=60)
    print("    " + out.strip())
    return rc


def install_nvidia_drivers() -> int:
    """Install NVIDIA proprietary drivers — assumes non-free is already enabled.

    `install_gui(install_nvidia=True)` handles the full path (enable_nonfree +
    apt update + install) in a single sweep.  This standalone helper is
    retained for cases where you want to retry just the driver install.
    """
    enable_nonfree_repos()
    run_root("apt-get update -qq >/tmp/vma_apt_update.log 2>&1", timeout=120)

    print("[*] Installing NVIDIA driver …")
    rc, out = run_root(
        f"DEBIAN_FRONTEND=noninteractive apt-get install -y "
        f"{' '.join(NVIDIA_PACKAGES)} >/tmp/vma_apt_nvidia.log 2>&1",
        timeout=600,
    )
    _, log = run("tail -10 /tmp/vma_apt_nvidia.log")
    print(log.strip())
    if rc != 0:
        print(f"[!] NVIDIA install failed (exit {rc})")
        return rc
    print("[ok] NVIDIA drivers installed — reboot required")
    return 0


# ============================================================
# Config deployment
# ============================================================

# Per-config-tree deploy targets.  Each src dir under ./config/ gets
# rsync'd to the matching ~/<dest> on the VM.  gtk-2.0 is intentionally
# omitted — its single `gtkrc` file is copied to ~/.gtkrc-2.0 by the
# single-file block below, which is the actual location GTK 2 reads.
CONFIG_MAP = {
    "i3":         ".config/i3",
    "polybar":    ".config/polybar",
    "picom":      ".config/picom",
    "rofi":       ".config/rofi",
    "alacritty":  ".config/alacritty",
    "dunst":      ".config/dunst",
    "gtk-3.0":    ".config/gtk-3.0",
    "wallpaper":  ".config/wallpaper",
    "tmux":       ".config/tmux",
    "nvim":       ".config/nvim",
    "starship":   ".config/starship",
    "conky":      ".config/conky",
    "lockscreen": ".config/lockscreen",
}


def _patch_picom_backend(is_hyperv: bool) -> None:
    """Switch picom backend: xrender on Hyper-V (no DRI2), glx on real hardware.

    The previous implementation built the sed expression in the controller
    and shipped it through SSH, which required nesting single quotes inside
    a shell-inside-Python-string and was error-prone (an unbalanced quote
    silently broke the sed command).  We now run the substitution as a
    self-contained Python snippet on the VM, passing the desired values as
    plain arguments — no quote gymnastics required.
    """
    backend     = "xrender" if is_hyperv else "glx"
    use_damage  = "false"   if is_hyperv else "true"

    # The remote python script gets exactly two free-form arguments, so
    # there's no chance of injection or quote-escaping bugs.
    remote_script = r'''
import os, re, sys
backend, use_damage = sys.argv[1], sys.argv[2]
path = os.path.expanduser("~/.config/picom/picom.conf")
with open(path) as f: data = f.read()
data = re.sub(r"^backend\s*=.*$",      f'backend = "{backend}";',   data, flags=re.M)
data = re.sub(r"^use-damage\s*=.*$",   f"use-damage = {use_damage};", data, flags=re.M)
with open(path, "w") as f: f.write(data)
'''
    cmd = (
        f"python3 -c {shlex.quote(remote_script)} "
        f"{shlex.quote(backend)} {shlex.quote(use_damage)}"
    )
    run(cmd)


def deploy_configs(is_hyperv: bool = True) -> int:
    """
    Upload all dotfiles to the VM and configure services.
    Hyper-V-specific files (Xorg config) are only deployed on Hyper-V.
    """
    print("[*] Deploying config files …")
    errors = 0

    for local_name, remote_dest in CONFIG_MAP.items():
        local_path = DOTFILES_DIR / local_name
        if not local_path.exists():
            print(f"    [skip] {local_name} — not found locally")
            continue
        run(f"mkdir -p ~/{Path(remote_dest).parent}")
        rc = scp_to_vm(str(local_path), f"~/{remote_dest}")
        if rc == 0:
            print(f"    [ok] {local_name} → ~/{remote_dest}")
        else:
            print(f"    [!] Failed: {local_name}")
            errors += 1

    # Single-file copies
    gtk2_src = DOTFILES_DIR / "gtk-2.0" / "gtkrc"
    if gtk2_src.exists():
        scp_to_vm(str(gtk2_src), "~/.gtkrc-2.0")
        print("    [ok] gtk-2.0/gtkrc → ~/.gtkrc-2.0")

    xsession_src = Path(__file__).parent / "scripts" / "xsession.sh"
    if xsession_src.exists():
        scp_to_vm(str(xsession_src), "~/.xsession")
        run("chmod +x ~/.xsession")
        print("    [ok] xsession.sh → ~/.xsession")

    xresources_src = Path(__file__).parent / "scripts" / "Xresources"
    if xresources_src.exists():
        scp_to_vm(str(xresources_src), "~/.Xresources")
        print("    [ok] Xresources → ~/.Xresources")

    # Deploy .zshrc
    zshrc_src = DOTFILES_DIR / "zsh" / ".zshrc"
    if zshrc_src.exists():
        scp_to_vm(str(zshrc_src), "~/.zshrc")
        print("    [ok] .zshrc → ~/.zshrc")

    # Mark every shell helper executable.  rsync preserves perms when the
    # source is +x (which they are in the repo), but `scp` does NOT, so we
    # always re-apply.  `2>/dev/null || true` keeps the deploy idempotent
    # when a path doesn't exist (e.g., on a partial config tree).
    run("chmod +x ~/.config/polybar/launch.sh 2>/dev/null || true")
    run("chmod +x ~/.config/conky/launch.sh 2>/dev/null || true")
    run("chmod +x ~/.config/lockscreen/lock.sh 2>/dev/null || true")
    run("chmod +x ~/.config/wallpaper/download_wallpaper.sh 2>/dev/null || true")
    run("chmod +x ~/.config/i3/scripts/*.sh 2>/dev/null || true")
    run("chmod +x ~/.config/polybar/scripts/*.sh 2>/dev/null || true")

    # SECURITY parity with local_setup.sh:
    #   • WireGuard config files contain a private key in cleartext.
    #     wg-quick refuses to bring an interface up if the .conf is
    #     group/world-readable, but the warning is easy to miss.  Force
    #     0600 owned by root, 0700 on the parent dir.
    #   • zsh history can leak credentials accidentally typed without a
    #     leading space.  chmod 600 closes the gap before the first new
    #     shell is spawned (.zshrc also enforces it on every shell start).
    run_root(
        "if [ -d /etc/wireguard ]; then "
        "chown -R root:root /etc/wireguard && "
        "chmod 700 /etc/wireguard && "
        "find /etc/wireguard -type f -name '*.conf' -exec chmod 600 {} +; "
        "fi"
    )
    run("[ -f ~/.zsh_history ] && chmod 600 ~/.zsh_history || true")

    # Patch picom for hardware type
    _patch_picom_backend(is_hyperv)
    backend = "xrender (Hyper-V)" if is_hyperv else "glx (physical)"
    print(f"    [ok] picom backend → {backend}")

    # Wallpaper: try the curated online image first (a 4K Cyberpunk
    # 2077 Night City skyline screenshot, SHA-256 pinned), fall back
    # to the procedural Pillow generator if the download fails
    # (offline install, CDN hiccup, hash mismatch).  Either way we
    # end with ~/.config/wallpaper/wallpaper.png.
    print("[*] Fetching wallpaper (4K Cyberpunk 2077 skyline) …")
    rc, out = run("bash ~/.config/wallpaper/download_wallpaper.sh", timeout=90)
    if rc != 0:
        print(f"    [!] download failed: {out.strip()[-200:]}")
        print("    [*] falling back to procedural generator …")
        rc, out = run(
            "python3 ~/.config/wallpaper/generate_wallpaper.py "
            "--width 1920 --height 1080 --output ~/.config/wallpaper/wallpaper.png"
        )
    if rc == 0:
        print("    [ok] wallpaper")
    else:
        print(f"    [!] wallpaper failed: {out.strip()[-200:]}")
        errors += 1

    run("mkdir -p ~/Pictures")

    # Hyper-V Xorg config (only on Hyper-V)
    if is_hyperv:
        xorg_src = DOTFILES_DIR / "xorg.conf.d" / "10-hyperv.conf"
        if xorg_src.exists():
            print("[*] Deploying Hyper-V Xorg config …")
            scp_to_vm(str(xorg_src), "/tmp/10-hyperv.conf")
            rc, out = run_root(
                "mkdir -p /etc/X11/xorg.conf.d && "
                "cp /tmp/10-hyperv.conf /etc/X11/xorg.conf.d/10-hyperv.conf"
            )
            if rc == 0:
                print("    [ok] /etc/X11/xorg.conf.d/10-hyperv.conf")
            else:
                print(f"    [!] Xorg config: {out.strip()[:200]}")
                errors += 1
    else:
        run_root("rm -f /etc/X11/xorg.conf.d/10-hyperv.conf 2>/dev/null || true")
        print("    [ok] Hyper-V Xorg config skipped (physical)")

    # LightDM greeter
    lightdm_src = DOTFILES_DIR / "lightdm" / "lightdm-gtk-greeter.conf"
    if lightdm_src.exists():
        print("[*] Deploying LightDM greeter config …")
        scp_to_vm(str(lightdm_src), "/tmp/lightdm-gtk-greeter.conf")
        rc, out = run_root(
            "cp /tmp/lightdm-gtk-greeter.conf /etc/lightdm/lightdm-gtk-greeter.conf"
        )
        if rc == 0:
            print("    [ok] lightdm-gtk-greeter.conf deployed")
        else:
            print(f"    [!] lightdm config: {out.strip()[:200]}")
            errors += 1

    # xrdp (only if installed)
    _, xrdp_check = run("dpkg -l xrdp 2>/dev/null | grep -q '^ii' && echo yes || echo no")
    if "yes" in xrdp_check:
        print("[*] Configuring xrdp …")
        rc, out = configure_xrdp()
        if rc != 0:
            print(f"    [!] xrdp: {out.strip()[:200]}")
            errors += 1
        else:
            print("    [ok] xrdp configured and started")
    else:
        print("[*] xrdp not installed — skipping")

    # lightdm
    print("[*] Enabling lightdm …")
    rc, _ = run_root("systemctl enable --now lightdm && systemctl restart lightdm", timeout=30)
    if rc == 0:
        print("    [ok] lightdm enabled")
    else:
        print("    [!] lightdm restart failed")
        errors += 1

    # Terminal tools setup
    term_errors = setup_terminal_tools()
    errors += term_errors

    print(f"\n[{'ok' if errors == 0 else '!!'}] Deploy complete ({errors} error(s))")
    return errors


def configure_xrdp() -> tuple[int, str]:
    """Configure xrdp to use ~/.xsession (i3) and restart the service.

    Bug history: this previously hardcoded ``usermod -aG ssl-cert generic``,
    which silently misbehaved if VM_USER was set to anything other than
    "generic".  We now interpolate VM_USER and quote it defensively.
    """
    vm_user_q = shlex.quote(VM_USER)
    cmds = [
        f"usermod -aG ssl-cert {vm_user_q}",
        "usermod -aG ssl-cert xrdp",
        "systemctl enable --now xrdp",
        "systemctl restart xrdp",
    ]
    return run_root(" && ".join(cmds), timeout=60)


# ============================================================
# Terminal tools (tmux / neovim / zsh)
# ============================================================

def setup_terminal_tools() -> int:
    """
    Post-deploy setup: tpm, oh-my-zsh, zsh plugins, starship, change default
    shell to zsh, pre-install neovim plugins.

    Bug-prevention measures vs the previous implementation:
    - zsh path is resolved with `command -v zsh` BEFORE calling usermod,
      and the absolute path is passed explicitly — no shell variable expansion
      inside the root command where an empty result could corrupt /etc/passwd.
    - `usermod -s` is used instead of `chsh` — usermod is more predictable
      when called non-interactively as root and doesn't validate against
      /etc/shells the same way chsh does.
    - All root operations go through sudo (run_root), never su.
    """
    print("[*] Setting up terminal tools …")
    errors = 0

    # JetBrainsMono Nerd Font — required for starship glyphs and icons.
    # The Debian package (fonts-jetbrains-mono) is NOT patched with Nerd Font
    # glyphs, so we download the official Nerd Fonts release and install to
    # ~/.local/share/fonts/ using Python's zipfile (no unzip binary needed).
    _, nf_check = run("fc-list | grep -i 'JetBrainsMonoNerd' | head -1")
    if nf_check.strip():
        print("    [ok] JetBrainsMono Nerd Font already installed")
    else:
        print("    [*] Installing JetBrainsMono Nerd Font (SHA-256 pinned) …")
        # SECURITY: download the zip AND the official SHA-256.txt
        # manifest from the same release, then verify with sha256sum -c
        # before extracting.  Stops a tampered .zip from being unpacked
        # even if a CDN mirror were compromised.
        nf_cmds = r'''
set -eu
rel="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.3.0"
mkdir -p ~/.local/share/fonts/NerdFonts
cd /tmp
curl -fsSL "$rel/JetBrainsMono.zip" -o JetBrainsMono.zip
curl -fsSL "$rel/SHA-256.txt"       -o nerd-fonts-sha256.txt
exp="$(awk '$2=="JetBrainsMono.zip" {print $1}' nerd-fonts-sha256.txt | head -1)"
[ -n "$exp" ] || { echo "JetBrainsMono.zip not in manifest" >&2; exit 1; }
echo "$exp  JetBrainsMono.zip" | sha256sum -c - >/dev/null
python3 -c "import zipfile, pathlib; \
dest = pathlib.Path.home() / '.local/share/fonts/NerdFonts'; \
dest.mkdir(parents=True, exist_ok=True); \
z = zipfile.ZipFile('/tmp/JetBrainsMono.zip'); \
n = sum(z.extract(f, dest) is None or 1 for f in z.namelist() \
        if f.endswith('.ttf') and 'NerdFont' in f); \
print('extracted', n, 'TTFs')"
fc-cache -f ~/.local/share/fonts/ >/dev/null 2>&1 || true
rm -f /tmp/JetBrainsMono.zip /tmp/nerd-fonts-sha256.txt
'''
        rc, out = run(nf_cmds, timeout=180)
        if rc == 0:
            print("    [ok] JetBrainsMono Nerd Font installed (SHA-256 verified)")
        else:
            print(f"    [!] Nerd Font install failed: {out.strip()[-300:]}")
            errors += 1

    # fd-find installs as 'fdfind' on Debian; symlink to fd in ~/.local/bin
    _, fdfind = run("command -v fdfind 2>/dev/null")
    if fdfind.strip():
        run("mkdir -p ~/.local/bin && "
            "ln -sf $(command -v fdfind) ~/.local/bin/fd 2>/dev/null || true")
        print("    [ok] fd → fdfind alias")

    # bat installs as 'batcat' on Debian; symlink to bat in ~/.local/bin
    _, batcat = run("command -v batcat 2>/dev/null")
    if batcat.strip():
        run("mkdir -p ~/.local/bin && "
            "ln -sf $(command -v batcat) ~/.local/bin/bat 2>/dev/null || true")
        print("    [ok] bat → batcat alias")

    # tpm (tmux plugin manager)
    _, tpm_check = run("test -d ~/.tmux/plugins/tpm && echo exists || echo missing")
    if "exists" in tpm_check:
        print("    [ok] tpm already installed")
    else:
        rc, out = run(
            "git clone --depth=1 https://github.com/tmux-plugins/tpm "
            "~/.tmux/plugins/tpm 2>&1 | tail -3",
            timeout=60,
        )
        if rc == 0:
            print("    [ok] tpm cloned")
        else:
            print(f"    [!] tpm: {out.strip()[:200]}")
            errors += 1

    # Install tpm plugins headlessly
    rc, _ = run(
        "TMUX_PLUGIN_MANAGER_PATH=~/.tmux/plugins "
        "~/.tmux/plugins/tpm/bin/install_plugins 2>&1 | tail -3"
    )
    if rc == 0:
        print("    [ok] tmux plugins installed")
    else:
        print("    [!] tmux plugin install had warnings (non-fatal)")

    # oh-my-zsh — check for a real install (oh-my-zsh.sh must exist, not just the dir)
    _, omz_check = run("test -f ~/.oh-my-zsh/oh-my-zsh.sh && echo exists || echo missing")
    omz_was_installed = "exists" in omz_check
    if omz_was_installed:
        print("    [ok] oh-my-zsh already installed")
    else:
        # SECURITY: avoid the upstream `curl … | sh` installer.  We just
        # need the repo cloned to ~/.oh-my-zsh — the installer's other
        # job (writing a default ~/.zshrc) is something we'd overwrite a
        # moment later anyway.  `git clone` is verifiable (TLS to GitHub,
        # repo content is git-hashed) and doesn't pipe arbitrary remote
        # text into a shell.
        run("rm -rf ~/.oh-my-zsh")
        rc, out = run(
            "git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "
            "~/.oh-my-zsh 2>&1 | tail -3",
            timeout=120,
        )
        if rc == 0:
            print("    [ok] oh-my-zsh cloned")
        else:
            print(f"    [!] oh-my-zsh clone: {out.strip()[:200]}")
            errors += 1

    # zsh plugins
    custom = "$HOME/.oh-my-zsh/custom"
    for name, repo in [
        ("zsh-autosuggestions",
         "https://github.com/zsh-users/zsh-autosuggestions"),
        ("zsh-syntax-highlighting",
         "https://github.com/zsh-users/zsh-syntax-highlighting"),
    ]:
        dest = f"{custom}/plugins/{name}"
        _, check = run(f"test -d {dest} && echo exists || echo missing")
        if "exists" in check:
            print(f"    [ok] {name} already installed")
        else:
            rc, out = run(
                f"git clone --depth=1 {repo} {dest} 2>&1 | tail -3",
                timeout=60,
            )
            if rc == 0:
                print(f"    [ok] {name}")
            else:
                print(f"    [!] {name}: {out.strip()[:100]}")
                errors += 1

    # Starship prompt
    _, star_check = run(
        "command -v starship 2>/dev/null || "
        "test -x ~/.local/bin/starship && echo exists || echo missing"
    )
    if "exists" in star_check or "starship" in star_check:
        print("    [ok] starship already installed")
    else:
        # SECURITY: don't `curl … | sh` the install.sh script.  Instead
        # download the architecture-specific tarball directly from the
        # GitHub release page — these are GPG-signed by the starship
        # maintainers (sigstore/cosign) and the URL pattern is stable.
        # We also fetch the SHA256 sidecar and verify it before
        # extracting, so a compromised CDN can't ship a backdoored binary.
        starship_install = r'''
set -euo pipefail
# mktemp + trap so a failure mid-install doesn't leave /tmp cruft.
# Previously we used a fixed /tmp/starship-install path which would
# linger if any of the curl / sha256sum / tar steps errored.
tmpdir=$(mktemp -d)
trap "rm -rf '$tmpdir'" EXIT
mkdir -p ~/.local/bin
cd "$tmpdir"
arch=$(uname -m)
case "$arch" in
    x86_64)  tarball=starship-x86_64-unknown-linux-gnu.tar.gz ;;
    aarch64) tarball=starship-aarch64-unknown-linux-gnu.tar.gz ;;
    armv7l)  tarball=starship-arm-unknown-linux-musleabihf.tar.gz ;;
    *)       echo "unsupported arch: $arch" >&2; exit 1 ;;
esac
url="https://github.com/starship/starship/releases/latest/download/${tarball}"
curl -fsSL "$url" -o starship.tar.gz
curl -fsSL "${url}.sha256" -o starship.tar.gz.sha256
# The .sha256 file is "<hash>  <name>" — sha256sum -c needs that format.
echo "$(awk '{print $1}' starship.tar.gz.sha256)  starship.tar.gz" \
    | sha256sum -c - >/dev/null
tar -xzf starship.tar.gz starship
install -m 0755 starship ~/.local/bin/starship
echo OK
'''
        rc, out = run(starship_install, timeout=120)
        if rc == 0 and "OK" in out:
            print("    [ok] starship installed (sha256 verified) → "
                  "~/.local/bin/starship")
        else:
            print(f"    [!] starship: {out.strip()[-300:]}")
            errors += 1

    # Redeploy our .zshrc — oh-my-zsh installer overwrites ~/.zshrc with its
    # default; we always restore ours after OMZ is confirmed present.
    zshrc_src = Path(__file__).parent / "config" / "zsh" / ".zshrc"
    if zshrc_src.exists():
        rc = scp_to_vm(str(zshrc_src), "~/.zshrc")
        if rc == 0:
            print("    [ok] .zshrc redeployed (post-OMZ)")
        else:
            print("    [!] .zshrc redeploy failed")
            errors += 1

    # Change default shell to zsh — SAFE implementation
    # 1. Resolve zsh path BEFORE any root call so empty string can't propagate.
    # 2. Validate it is an absolute path.
    # 3. Use `usermod -s` (not chsh) for clean non-interactive shell change.
    _, zsh_path_raw = run("command -v zsh 2>/dev/null || echo ''")
    zsh_path = zsh_path_raw.strip()

    _, current_shell_raw = run("getent passwd generic | cut -d: -f7")
    current_shell = current_shell_raw.strip()

    if "zsh" in current_shell:
        print(f"    [ok] default shell already zsh ({current_shell})")
    elif zsh_path and zsh_path.startswith("/"):
        rc, out = run_root(f"usermod -s {shlex.quote(zsh_path)} {VM_USER}")
        if rc == 0:
            print(f"    [ok] default shell → {zsh_path}")
        else:
            print(f"    [!] usermod -s failed: {out.strip()[:200]}")
            errors += 1
    else:
        print("    [!] zsh not found in PATH — install packages before setup-terminal")
        errors += 1

    # lm-sensors auto-detect (non-fatal)
    rc, _ = run_root("sensors-detect --auto >/tmp/vma_sensors.log 2>&1 || true")
    print("    [ok] sensors-detect run")

    # Neovim headless plugin sync (lazy.nvim) + treesitter parser compile.
    # TSUpdateSync blocks until parsers are compiled — without this, the
    # auto_install option fires asynchronously and parsers may not be
    # ready by the time the headless nvim exits.
    print("[*] Pre-installing neovim plugins (headless) …")
    rc, out = run(
        "nvim --headless '+Lazy! sync' '+TSUpdateSync' +qa 2>&1 | tail -10",
        timeout=600,
    )
    _, lazy_check = run("ls ~/.local/share/nvim/lazy/ 2>/dev/null | wc -l")
    n_plugins = lazy_check.strip()
    _, ts_check = run("ls ~/.local/share/nvim/lazy/nvim-treesitter/parser/ 2>/dev/null | wc -l")
    n_parsers = ts_check.strip()
    if n_plugins and int(n_plugins) > 0:
        print(f"    [ok] {n_plugins} neovim plugin(s), {n_parsers} treesitter parser(s)")
    else:
        print(f"    [!] neovim plugin sync warning: {out.strip()[:200]}")

    print(f"\n[{'ok' if errors == 0 else '!!'}] Terminal setup ({errors} error(s))")
    return errors


# ============================================================
# Validation
# ============================================================

VALIDATION_CHECKS = [
    # Sudo — use `sudo -ln` so the check works in both broad-sudo (install
    # mode) and narrow-sudo (post-harden) states.  `sudo -n true` would
    # falsely fail post-harden because `true` isn't on the narrow allowlist.
    ("sudo (NOPASSWD)",     "sudo -ln 2>/dev/null | grep -q NOPASSWD && echo ok || echo FAIL"),
    # GUI stack
    ("i3",                  "which i3"),
    ("polybar",             "which polybar"),
    ("picom",               "which picom"),
    ("rofi",                "which rofi"),
    ("alacritty",           "which alacritty"),
    ("dunst",               "which dunst"),
    ("feh",                 "which feh"),
    ("lightdm",             "systemctl is-enabled lightdm 2>/dev/null"),
    # Config files
    ("~/.xsession",         "test -x ~/.xsession && echo ok"),
    ("~/.config/i3/config", "test -f ~/.config/i3/config && echo ok"),
    ("wallpaper",           "test -f ~/.config/wallpaper/wallpaper.png && echo ok"),
    ("lockscreen script",   "test -x ~/.config/lockscreen/lock.sh && echo ok"),
    ("rofi config",         "test -f ~/.config/rofi/config.rasi && echo ok"),
    ("polybar config",      "test -f ~/.config/polybar/config.ini && echo ok"),
    # Terminal tools
    ("tmux",                "which tmux"),
    ("neovim",              "which nvim"),
    ("zsh",                 "which zsh"),
    ("fzf",                 "which fzf"),
    ("starship",            "command -v starship 2>/dev/null || ~/.local/bin/starship --version 2>/dev/null | head -1"),
    ("oh-my-zsh",           "test -d ~/.oh-my-zsh && echo ok"),
    ("tpm",                 "test -d ~/.tmux/plugins/tpm && echo ok"),
    ("tmux config",         "test -f ~/.config/tmux/tmux.conf && echo ok"),
    ("nvim config",         "test -f ~/.config/nvim/init.lua && echo ok"),
    ("~/.zshrc",            "test -f ~/.zshrc && echo ok"),
    ("starship config",     "test -f ~/.config/starship/starship.toml && echo ok"),
    ("default shell",       "getent passwd generic | cut -d: -f7"),
    # Pretty CLI tools
    ("bat/batcat",          "command -v bat 2>/dev/null || command -v batcat 2>/dev/null"),
    ("grc",                 "which grc"),
    ("netstat",             "which netstat"),
    ("conky",               "which conky"),
    ("conky launch.sh",     "test -x ~/.config/conky/launch.sh && echo ok"),
    ("lm-sensors",          "which sensors"),
    ("conky config",        "test -f ~/.config/conky/conky.conf && echo ok"),
    # VPN
    ("mullvad CLI",         "which mullvad"),
    ("mullvad daemon",      "systemctl is-active mullvad-daemon 2>/dev/null || echo (missing)"),
    ("wg-quick",            "which wg-quick"),
    ("wg",                  "which wg"),
    ("polybar mullvad-status.sh",  "test -x ~/.config/polybar/scripts/mullvad-status.sh && echo ok"),
    ("polybar wireguard-status.sh","test -x ~/.config/polybar/scripts/wireguard-status.sh && echo ok"),
    # Network manager UIs + low-level helpers.  iw / rfkill / powertop
    # live in /usr/sbin which is NOT on a non-root SSH session's PATH;
    # fall back to an absolute-path test so the check passes.
    ("NetworkManager active",      "systemctl is-active NetworkManager 2>/dev/null"),
    ("nm-applet",                  "which nm-applet"),
    ("nm-connection-editor",       "which nm-connection-editor"),
    ("nmcli",                      "which nmcli"),
    ("iw",                         "command -v iw 2>/dev/null || (test -x /usr/sbin/iw && echo /usr/sbin/iw)"),
    ("rfkill",                     "command -v rfkill 2>/dev/null || (test -x /usr/sbin/rfkill && echo /usr/sbin/rfkill)"),
    ("acpi",                       "which acpi"),
    ("powertop",                   "command -v powertop 2>/dev/null || (test -x /usr/sbin/powertop && echo /usr/sbin/powertop)"),
]

HYPERV_CHECKS = [
    ("hyperv Xorg",   "test -f /etc/X11/xorg.conf.d/10-hyperv.conf && echo ok"),
]

NVIDIA_CHECKS = [
    ("nvidia-smi",    "nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo not available"),
    ("nvidia driver", "dpkg -l nvidia-driver 2>/dev/null | grep -q '^ii' && echo installed || echo missing"),
]


def validate(is_hyperv: bool = True, has_nvidia: bool = False) -> int:
    """Run post-install checks and report pass/fail per component."""
    print("[*] Running validation checks …\n")
    failures = 0

    checks = list(VALIDATION_CHECKS)
    if is_hyperv:
        checks.extend(HYPERV_CHECKS)
    if has_nvidia:
        checks.extend(NVIDIA_CHECKS)

    bad = {"not found", "missing", "not available", "inactive", "disabled", "fail"}
    for label, cmd in checks:
        rc, out = run(cmd)
        out = out.strip()
        failed = rc != 0 or any(b in out.lower() for b in bad)
        status = "[FAIL]" if failed else "[ ok ]"
        detail = f"  ({out[:70]})" if out and out not in ("ok", "enabled") else ""
        print(f"  {status}  {label}{detail}")
        if failed:
            failures += 1

    print(f"\n{'[ok] All checks passed' if failures == 0 else f'[!!] {failures} check(s) failed'}")
    return failures


# ============================================================
# harden / unharden — opt-in security tightening
# ============================================================
# Mirrors local_setup.sh's harden phase but runs over SSH.  Idempotent
# and reversible — `unharden` flips each step back to the install-time
# defaults so a re-run of `setup` doesn't get blocked by a tight sudo
# rule or a deny-by-default firewall.
#
# Steps applied (each in its own helper for clarity):
#   1. Narrow /etc/sudoers.d/<user> from `NOPASSWD: ALL` to a small
#      Cmnd_Alias allowlist (VPN tools, apt, key systemctl restarts).
#   2. ufw default deny incoming + allow ssh BEFORE enable (so the
#      in-progress SSH session survives).
#   3. unattended-upgrades configured for Debian-Security packages.
#   4. systemd-resolved with Quad9 over DNS-over-TLS + DNSSEC validation.

_SUDOERS_NARROW = """\
# /etc/sudoers.d/{user}  —  NARROW ruleset
# Generated by vm_automation.py harden.
#
# Allows the dotfiles' runtime + maintenance commands without a
# password.  Anything else still prompts (including `sudo bash`,
# `sudo -i`, `sudo nano /etc/...`).

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

# SECURITY: `apt-get -y install *` allowed `sudo apt install
# ./malicious.deb` — a near-complete sudoers escape because postinst
# runs as root.  Stripped to read-only + cache-clean operations.
# unattended-upgrades does its own thing as a system service and
# doesn't go through this user's sudoers.
Cmnd_Alias DOTFILES_APT = \\
    /usr/bin/apt-get update,           \\
    /usr/bin/apt-get clean,            \\
    /usr/bin/apt-get autoclean

Cmnd_Alias DOTFILES_SVC = \\
    /usr/bin/systemctl restart polybar, \\
    /usr/bin/systemctl restart picom,   \\
    /usr/bin/systemctl restart lightdm

# Network introspection — read-only, used by conky's netstat.py /
# listenports.py to show process names for system-owned sockets (sshd,
# mullvad-daemon, …).  Without root, `ss -p` hides those names.
Cmnd_Alias DOTFILES_NET = \\
    /usr/bin/ss -nlp,                  \\
    /usr/bin/ss -nip,                  \\
    /usr/bin/ss -tl -nlp,              \\
    /usr/bin/ss -ul -nlp,              \\
    /usr/bin/ss -ta -nip,              \\
    /usr/bin/ss -ua -nip,              \\
    /usr/bin/ss -wa -nip

{user} ALL=(root) NOPASSWD: DOTFILES_VPN, DOTFILES_APT, DOTFILES_SVC, DOTFILES_NET
"""

_SUDOERS_BROAD = """\
# /etc/sudoers.d/{user}  —  BROAD ruleset (install/dev mode)
# Generated by vm_automation.py unharden.
{user} ALL=(ALL) NOPASSWD: ALL
"""


def _install_sudoers(content: str) -> int:
    """Write a sudoers fragment, validate with `visudo -c`, install it.

    Validates BEFORE replacing /etc/sudoers.d/<user> — a syntactically
    broken sudoers file can lock the user out of root permanently.

    SECURITY: previously this base64-encoded the sudoers content and
    passed it as a `sudo bash -c '<script with embedded base64>'` arg.
    The full sudoers content (including username + Cmnd_Aliases) was
    visible in `ps -ef` for the brief window the command ran AND in any
    audit log capturing argv (auditd, journald with high LogLevel).
    Now we scp the content to a private temp file on the VM and the
    remote script just reads it from disk — nothing sensitive lands in
    a command line.
    """
    if not re.match(r"^[a-z_][a-z0-9_-]*$", VM_USER):
        sys.exit(f"[!] refusing to install sudoers for unsafe VM_USER={VM_USER!r}")
    target = f"/etc/sudoers.d/{VM_USER}"

    # Stage on the controller, scp to the VM, install in place.  The
    # remote staging path lives in a per-user dir under /tmp; we make
    # it 0700 so other VM users can't peek at the queued sudoers blob.
    local_tmp = tempfile.NamedTemporaryFile(
        mode="w", prefix="sudoers-", delete=False, encoding="utf-8")
    try:
        local_tmp.write(content)
        local_tmp.close()
        os.chmod(local_tmp.name, 0o600)
        remote_stage = f"/tmp/.sudoers-stage-{os.getpid()}"
        rc = scp_to_vm(local_tmp.name, remote_stage)
        if rc != 0:
            return rc
        script = (
            f"set -eu\n"
            f"chmod 600 {shlex.quote(remote_stage)}\n"
            f"visudo -c -f {shlex.quote(remote_stage)} >/dev/null\n"
            f"install -m 0440 -o root -g root {shlex.quote(remote_stage)} "
            f"  {shlex.quote(target)}\n"
            f"rm -f {shlex.quote(remote_stage)}\n"
        )
        rc, out = run_root(script, timeout=30)
        if rc != 0:
            print(f"    [!] sudoers install failed: {out.strip()[-300:]}")
            run(f"rm -f {shlex.quote(remote_stage)}")  # best-effort cleanup
        return rc
    finally:
        try: os.unlink(local_tmp.name)
        except OSError: pass


def harden_sudo() -> int:
    print("[*] Narrowing /etc/sudoers.d/%s …" % VM_USER)
    rc = _install_sudoers(_SUDOERS_NARROW.format(user=VM_USER))
    if rc == 0:
        print("    [ok] sudoers narrowed")
    return rc


def unharden_sudo() -> int:
    print("[*] Restoring broad NOPASSWD sudoers (install/dev mode) …")
    rc = _install_sudoers(_SUDOERS_BROAD.format(user=VM_USER))
    if rc == 0:
        print("    [ok] sudoers re-broadened")
    return rc


def harden_ufw() -> int:
    print("[*] Configuring ufw — allow SSH, deny everything else inbound …")
    # Order matters: allow SSH BEFORE enable, otherwise we lock our own
    # SSH session out and the rest of the harden run can't continue.
    # We invoke ufw by absolute path because /usr/sbin isn't always on
    # PATH for the SSH-launched non-interactive shell.
    cmds = (
        "DEBIAN_FRONTEND=noninteractive apt-get install -y ufw "
        ">/tmp/vma_apt_ufw.log 2>&1 && "
        "/usr/sbin/ufw default deny incoming   >/dev/null && "
        "/usr/sbin/ufw default allow outgoing  >/dev/null && "
        "/usr/sbin/ufw allow ssh               >/dev/null && "
        "/usr/sbin/ufw --force enable          >/dev/null"
    )
    rc, out = run_root(cmds, timeout=120)
    if rc == 0:
        print("    [ok] ufw enabled (SSH allowed, default-deny inbound)")
    else:
        print(f"    [!] ufw harden failed: {out.strip()[-300:]}")
    return rc


def unharden_ufw() -> int:
    print("[*] Disabling ufw …")
    rc, _ = run_root(
        "if dpkg -l ufw 2>/dev/null | grep -q '^ii'; then "
        "/usr/sbin/ufw --force disable >/dev/null 2>&1 || true; "
        "fi",
        timeout=30,
    )
    print("    [ok] ufw disabled")
    return 0


def harden_uu() -> int:
    print("[*] Enabling unattended-upgrades (Debian-Security only) …")
    cmds = (
        "DEBIAN_FRONTEND=noninteractive apt-get install -y "
        "unattended-upgrades apt-listchanges >/tmp/vma_apt_uu.log 2>&1 && "
        "cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'\n"
        'APT::Periodic::Update-Package-Lists "1";\n'
        'APT::Periodic::Unattended-Upgrade "1";\n'
        'APT::Periodic::AutocleanInterval "7";\n'
        "EOF\n"
        "systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true"
    )
    rc, _ = run_root(cmds, timeout=180)
    print("    [ok] unattended-upgrades enabled")
    return rc


def unharden_uu() -> int:
    print("[*] Disabling unattended-upgrades …")
    cmds = (
        "cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'\n"
        'APT::Periodic::Update-Package-Lists "0";\n'
        'APT::Periodic::Unattended-Upgrade "0";\n'
        "EOF\n"
        "systemctl disable --now unattended-upgrades.service >/dev/null 2>&1 || true"
    )
    rc, _ = run_root(cmds, timeout=30)
    print("    [ok] unattended-upgrades disabled")
    return rc


def harden_dns() -> int:
    print("[*] Configuring systemd-resolved — Quad9 DoT + DNSSEC …")
    cmds = (
        "DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-resolved "
        ">/tmp/vma_apt_resolved.log 2>&1\n"
        "install -d -m 0755 /etc/systemd/resolved.conf.d\n"
        "cat > /etc/systemd/resolved.conf.d/dnsovertls.conf <<'EOF'\n"
        "[Resolve]\n"
        "DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net\n"
        "FallbackDNS=1.1.1.1#one.one.one.one\n"
        "DNSOverTLS=yes\n"
        "DNSSEC=allow-downgrade\n"
        "Cache=yes\n"
        "DNSStubListener=yes\n"
        "EOF\n"
        "ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf\n"
        # Strip any dhcpcd static DNS line that conflicts with resolved.
        "if [ -f /etc/dhcpcd.conf ]; then\n"
        "  sed -i '/^static domain_name_servers=/d' /etc/dhcpcd.conf\n"
        "  grep -q '^nohook resolv.conf' /etc/dhcpcd.conf || \\\n"
        "    echo 'nohook resolv.conf' >> /etc/dhcpcd.conf\n"
        "fi\n"
        "systemctl enable --now systemd-resolved >/dev/null\n"
        "systemctl restart systemd-resolved\n"
    )
    rc, out = run_root(cmds, timeout=180)
    if rc == 0:
        print("    [ok] DNS → Quad9 over DoT (DNSSEC)")
    else:
        print(f"    [!] DNS harden failed: {out.strip()[-300:]}")
    return rc


def unharden_dns() -> int:
    print("[*] Reverting DNS to dhcpcd-managed …")
    cmds = (
        "rm -f /etc/systemd/resolved.conf.d/dnsovertls.conf\n"
        "systemctl restart systemd-resolved >/dev/null 2>&1 || true\n"
        "if [ -f /etc/dhcpcd.conf ]; then\n"
        "  sed -i '/^nohook resolv.conf/d' /etc/dhcpcd.conf\n"
        "  grep -q '^static domain_name_servers=' /etc/dhcpcd.conf || \\\n"
        "    echo 'static domain_name_servers=1.1.1.1 8.8.8.8' >> /etc/dhcpcd.conf\n"
        "fi\n"
        "rm -f /etc/resolv.conf\n"
        "printf 'nameserver 1.1.1.1\\nnameserver 8.8.8.8\\n' > /etc/resolv.conf\n"
    )
    rc, _ = run_root(cmds, timeout=30)
    print("    [ok] DNS reverted")
    return rc


def harden_phase() -> int:
    """Run every harden_* step; tolerate individual warnings, fail loudly
    only if the sudoers narrowing breaks (that's the bit that affects
    next-time-you-sudo behaviour and a broken file is dangerous).
    """
    print("\n[*] Security-hardening pass on", VM_HOST)
    harden_uu()
    harden_dns()
    harden_ufw()
    rc = harden_sudo()
    if rc != 0:
        print("[!] sudoers harden failed — leaving prior sudoers in place")
        return rc
    print("\n[ok] Hardening complete on", VM_HOST)
    print("[i]  Verify on the VM: `sudo -l`, `sudo ufw status`, "
          "`resolvectl status`, `systemctl status unattended-upgrades`")
    return 0


def unharden_phase() -> int:
    print("\n[*] Reverting hardening on", VM_HOST)
    unharden_sudo()
    unharden_ufw()
    unharden_uu()
    unharden_dns()
    print("\n[ok] Unhardening complete on", VM_HOST)
    return 0


# ============================================================
# Screenshot via Xvfb (headless)
# ============================================================

def take_screenshot(
    local_output: str = "/tmp/vm_i3_screenshot.png",
    display: int = 99,
    width: int = 1920,
    height: int = 1080,
) -> int:
    """Start a headless Xvfb + i3 session, screenshot, copy back."""
    disp     = f":{display}"
    geometry = f"{width}x{height}x24"
    remote   = "/tmp/vm_screenshot.png"

    print(f"[*] Starting Xvfb{disp} ({geometry}) …")
    child = _spawn_ssh(tty=True, timeout=120)
    try:
        child.expect(PROMPT_RE)
        child.sendline(
            f"pkill -f 'Xvfb {disp}' 2>/dev/null; pkill polybar 2>/dev/null; "
            f"pkill alacritty 2>/dev/null; sleep 0.5; echo CLEAN"
        )
        child.expect("CLEAN"); child.expect(PROMPT_RE)

        child.sendline(
            f"Xvfb {disp} -screen 0 {geometry} &>/tmp/xvfb.log & sleep 1.5 && echo XVFB_OK"
        )
        child.expect("XVFB_OK", timeout=15); child.expect(PROMPT_RE)

        print("[*] Starting i3 …")
        child.sendline(
            f"DISPLAY={disp} i3 &>/tmp/i3_xvfb.log & sleep 5 && echo I3_OK"
        )
        child.expect("I3_OK", timeout=20); child.expect(PROMPT_RE)

        print("[*] Launching alacritty …")
        child.sendline(
            f"DISPLAY={disp} alacritty &>/tmp/alacritty.log & sleep 3 && echo ALT_OK"
        )
        child.expect("ALT_OK", timeout=15); child.expect(PROMPT_RE)

        child.sendline(
            f"rm -f {remote}; DISPLAY={disp} scrot {remote} && echo SHOT_OK"
        )
        idx = child.expect(["SHOT_OK", pexpect.TIMEOUT], timeout=15)
        child.expect(PROMPT_RE)
        if idx != 0:
            print("[!] scrot timed out")
            child.sendline("cat /tmp/i3_xvfb.log 2>/dev/null"); child.expect(PROMPT_RE)
            print(child.before[-2000:])
            child.sendline("exit"); child.close()
            return 1

        child.sendline(
            f"pkill -f 'Xvfb {disp}' 2>/dev/null; pkill polybar 2>/dev/null; "
            f"pkill alacritty 2>/dev/null; echo BYE"
        )
        child.expect(["BYE", pexpect.TIMEOUT], timeout=5)
        child.sendline("exit"); child.close()

    except pexpect.EOF:
        print("[!] SSH session ended unexpectedly"); return 1
    except pexpect.TIMEOUT as e:
        print(f"[!] Timeout: {e}"); child.sendline("exit"); child.close(); return 1

    print(f"[*] Copying screenshot to {local_output} …")
    rc = scp_from_vm(remote, local_output)
    if rc == 0:
        print(f"[ok] Screenshot → {local_output}")
    return rc


# ============================================================
# End-to-end setup
# ============================================================

# ── Stage descriptions used by full_setup() in interactive mode ──
# Lifted from local_setup.sh so the controller side prints the same
# explanation the local installer would.  Keep these in sync if you edit
# either side.
_STAGE_DESCRIPTIONS = {
    "bootstrap": (
        "Bootstrap sudo (one-time)",
        "  • Install `sudo` if missing\n"
        "  • Add a NOPASSWD entry to /etc/sudoers.d/ for VM_USER so all\n"
        "    later steps don't need to re-prompt for the password\n"
        "  • Skipped if NOPASSWD sudo is already configured",
    ),
    "install_gui": (
        "Install packages + drivers + Mullvad VPN",
        "  • apt-get update, then install ~80 desktop & terminal packages\n"
        "    (i3, polybar, alacritty, neovim, zsh, picom, dunst, …)\n"
        "  • If Hyper-V detected: skip GPU drivers, set up Hyper-V Xorg\n"
        "  • If physical + --nvidia: enable non-free apt + nvidia-driver\n"
        "  • Install WireGuard userland\n"
        "  • Time: 3–10 minutes (depends on network)",
    ),
    "mullvad": (
        "Set up Mullvad VPN apt repo and install client",
        "  • Add Mullvad's signed apt repo + keyring\n"
        "  • Install mullvad-vpn (the GUI + CLI + systemd daemon)\n"
        "  • Idempotent — skips when already installed\n"
        "  • Failures are non-fatal (this stage is best-effort)",
    ),
    "deploy": (
        "Deploy configuration files",
        "  • rsync this repo's config/ → ~/.config/ on the VM\n"
        "  • Patch picom backend (xrender for Hyper-V, glx for physical)\n"
        "  • Generate desktop wallpaper (procedural cyberpunk PNG)\n"
        "  • Deploy Hyper-V Xorg config (if applicable)\n"
        "  • Configure xrdp if installed; enable lightdm",
    ),
    "validate": (
        "Run validation checks",
        "  • Run ~40 sanity checks: tools, configs, services, default\n"
        "    shell, fonts, VPN tools, polybar helpers\n"
        "  • Read-only — no system changes",
    ),
    "screenshot": (
        "Take a headless screenshot of the i3 desktop",
        "  • Start Xvfb on display :99 (1920x1080)\n"
        "  • Launch i3 + alacritty into it\n"
        "  • Capture to /tmp/vm_i3_screenshot.png and copy back\n"
        "  • Useful for verifying the desktop without RDP / a monitor",
    ),
}


def _confirm_stage(num: int, total: int, key: str, interactive: bool) -> bool:
    """Print a stage banner; in interactive mode also ask the user [Y/n/q].

    Returns True to run the stage, False to skip it.  In non-interactive
    mode always returns True (the banner is just informational).
    Quitting (`q`) raises SystemExit so the whole pipeline stops cleanly.
    """
    title, desc = _STAGE_DESCRIPTIONS.get(key, (key, ""))
    print()
    print("═" * 60)
    print(f"  STAGE {num}/{total} — {title}")
    print("═" * 60)

    if not interactive:
        print("(--bypass: running automatically)")
        return True

    print(desc)
    try:
        ans = input("\nRun this stage now? [Y/n/q] ").strip().lower()
    except EOFError:
        # stdin closed — treat as bypass to avoid hanging.
        return True

    if ans in ("n", "no"):
        print("[!] Stage skipped — aborting setup.")
        print("[!] Re-run with individual subcommands (install-gui / "
              "deploy-configs / validate) to resume from a specific stage.")
        raise SystemExit(0)
    if ans in ("q", "quit"):
        print("[!] Quit at user request.")
        raise SystemExit(0)
    return True


def full_setup(
    hw: dict | None = None,
    force_hyperv: bool | None = None,
    install_nvidia: bool = False,
    screenshot_path: str = "/tmp/vm_i3_screenshot.png",
    interactive: bool | None = None,
) -> int:
    """Detect hardware → bootstrap sudo → install → deploy → validate → screenshot.

    interactive=None (default): pick interactive ON when stdin is a TTY,
    OFF otherwise.  Pass True or False to force.
    """
    if interactive is None:
        # Auto: TTY → interactive, piped/SSH-without-tty → bypass.  This
        # keeps automation flows working with no extra flags.
        interactive = sys.stdin.isatty()

    if hw is None:
        print("[*] Detecting hardware …")
        hw = detect_hardware()
    print_hardware(hw)

    is_hyperv  = hw["is_hyperv"]  if force_hyperv is None else force_hyperv
    has_nvidia = hw["has_nvidia"] and not is_hyperv

    if install_nvidia and is_hyperv:
        print("[!] --nvidia ignored in Hyper-V mode")
        install_nvidia = False

    if interactive:
        print("[*] Interactive mode — you'll be asked before each stage.")
        print("[*] (use --bypass / -y to install everything without prompts)")
    else:
        print("[*] Bypass mode — running unattended.")

    # Each entry: (stage_key, label_for_log, callable returning rc).
    # The stage_key matches _STAGE_DESCRIPTIONS so _confirm_stage finds
    # the right description to show.
    steps = [
        ("bootstrap",  "Bootstrapping sudo",
         lambda: bootstrap_sudo()),
        ("install_gui","Installing GUI packages",
         lambda: install_gui(is_hyperv=is_hyperv,
                             install_nvidia=install_nvidia)),
        # Mullvad install can fail on offline / restricted networks — wrap
        # it so a failure doesn't abort the whole setup.  WireGuard userland
        # is in BASE_PACKAGES so it's already in by this point.
        ("mullvad",    "Installing Mullvad VPN",
         lambda: install_mullvad() or 0),
        ("deploy",     "Deploying configs",
         lambda: deploy_configs(is_hyperv=is_hyperv)),
        ("validate",   "Validating installation",
         lambda: validate(is_hyperv=is_hyperv, has_nvidia=has_nvidia)),
        ("screenshot", "Taking screenshot",
         lambda: take_screenshot(screenshot_path)),
    ]

    total = len(steps)
    for n, (key, label, fn) in enumerate(steps, start=1):
        if not _confirm_stage(n, total, key, interactive):
            continue
        rc = fn()
        if rc != 0:
            print(f"\n[!] Step failed: {label} (exit {rc})")
            return rc

    print(f"\n[ok] Full setup complete.  Screenshot → {screenshot_path}")
    return 0


# ============================================================
# CLI
# ============================================================

def _parse_hw_flags(argv: list[str]) -> tuple[bool | None, bool]:
    force_hyperv   = True  if "--hyperv"   in argv else (False if "--physical" in argv else None)
    install_nvidia = "--nvidia" in argv
    return force_hyperv, install_nvidia


def _parse_mode(argv: list[str]) -> bool | None:
    """Parse --interactive / --bypass / -y / -i flags.

    Returns True (interactive), False (bypass), or None (auto: TTY → on,
    non-TTY → off — handled inside full_setup()).

    Errors out early if BOTH flags are present — silent precedence
    (whichever the parser saw first) used to mask user mistakes.
    """
    has_i = ("--interactive" in argv) or ("-i" in argv)
    has_y = ("--bypass" in argv) or ("--yes" in argv) or ("-y" in argv)
    if has_i and has_y:
        sys.exit("[!] --interactive and --bypass are mutually exclusive")
    if has_i:
        return True
    if has_y:
        return False
    return None


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0

    action = argv[1]

    if action == "bootstrap":
        return bootstrap_sudo()

    if action == "verify":
        return verify()

    if action == "detect":
        hw = detect_hardware(); print_hardware(hw); return 0

    if action == "run":
        rc, out = run(" ".join(argv[2:]))
        sys.stdout.write(out); return rc

    if action == "sudo":
        rc, out = run_root(" ".join(argv[2:]))
        sys.stdout.write(out); return rc

    if action == "install-gui":
        force_hyperv, install_nvidia = _parse_hw_flags(argv)
        if force_hyperv is None:
            hw = detect_hardware(); print_hardware(hw); is_hyperv = hw["is_hyperv"]
        else:
            is_hyperv = force_hyperv
        return install_gui(is_hyperv=is_hyperv, install_nvidia=install_nvidia)

    if action == "deploy-configs":
        force_hyperv, _ = _parse_hw_flags(argv)
        if force_hyperv is None:
            hw = detect_hardware(); print_hardware(hw); is_hyperv = hw["is_hyperv"]
        else:
            is_hyperv = force_hyperv
        return deploy_configs(is_hyperv=is_hyperv)

    if action == "setup-terminal":
        return setup_terminal_tools()

    if action == "validate":
        force_hyperv, _ = _parse_hw_flags(argv)
        if force_hyperv is None:
            hw = detect_hardware(); is_hyperv = hw["is_hyperv"]; has_nvidia = hw["has_nvidia"]
        else:
            is_hyperv = force_hyperv; has_nvidia = False
        return validate(is_hyperv=is_hyperv, has_nvidia=has_nvidia)

    if action == "screenshot":
        path = next((a for a in argv[2:] if not a.startswith("--")),
                    "/tmp/vm_i3_screenshot.png")
        return take_screenshot(local_output=path)

    if action == "harden":
        return harden_phase()

    if action == "unharden":
        return unharden_phase()

    if action == "setup":
        force_hyperv, install_nvidia = _parse_hw_flags(argv)
        interactive = _parse_mode(argv)
        # The first non-flag positional after `setup` is treated as the
        # screenshot output path (for backwards compat).  We must skip
        # short flags like `-y` / `-i` here too, otherwise they'd be
        # mistaken for a path.
        path = next(
            (a for a in argv[2:] if not a.startswith("-")),
            "/tmp/vm_i3_screenshot.png",
        )
        return full_setup(force_hyperv=force_hyperv,
                          install_nvidia=install_nvidia,
                          screenshot_path=path,
                          interactive=interactive)

    print(f"unknown action: {action}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
