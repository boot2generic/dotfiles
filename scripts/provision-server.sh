#!/usr/bin/env bash
# scripts/provision-server.sh                ── Install Path C ──
#
# Provision a remote server (Debian/Ubuntu/RHEL-family) with the
# SHELL-ONLY subset of these dotfiles — zsh + oh-my-zsh + starship +
# tmux + nvim + the small CLI utilities that show up in an SSH session.
# No X11, no display manager, no audio, no fonts, no GUI tools.
#
# Use case: dev VMs / servers you only ever SSH into.  Gives you the
# same prompt, history, completions, tmux bindings, and nvim setup as
# your laptop, without any of the desktop bloat.
#
# Compared to:
#   • Path A (local_setup.sh):       full GUI, on THIS machine
#   • Path B (vm_automation.py):     full GUI on a remote VM
#   • Path D (install-shell.sh):     same shell-only set, but LOCAL
#                                    (this script ssh's in; D doesn't)
# Paths C and D share install logic via scripts/lib/install-common.sh.
# This script streams the lib + a small driver heredoc into ssh's
# stdin, so the install logic isn't duplicated.
#
# See README.md "Feature-parity matrix" for the full capability table
# across all four install paths.
#
# Usage:
#   ./scripts/provision-server.sh user@host                    # full setup
#   ./scripts/provision-server.sh user@host --no-nvim          # skip nvim (older distros where neovim < 0.9)
#   ./scripts/provision-server.sh user@host --no-omz           # skip oh-my-zsh (slim zsh only)
#   ./scripts/provision-server.sh user@host --dry-run          # show what would happen, do nothing
#
# Requirements on YOUR machine:
#   • ssh, rsync (apt: openssh-client rsync — already in BASE_PACKAGES)
#   • SSH key auth set up against the remote (we refuse password auth
#     to avoid leaking it through ps).  If you don't have key auth yet:
#         ssh-copy-id user@host
#
# Requirements on the REMOTE:
#   • passwordless sudo for the user (or a sudo session that's
#     primed before this script runs — sudo prompts hang the SSH
#     stream).  Quick test:  ssh user@host 'sudo -n true'  → exit 0.
#   • Distro: Debian 11+, Ubuntu 22.04+, Rocky/Alma/RHEL 9+, Fedora 38+.
#     (CentOS 7 / Debian 10 are EOL and unsupported.)
#
# What gets installed:
#   apt distros:  zsh tmux neovim fzf ripgrep fd-find bat git curl
#                 wget rsync htop fastfetch grc unzip build-essential
#                 nodejs npm python3 direnv
#   dnf distros:  zsh tmux neovim fzf ripgrep fd-find bat git curl
#                 wget rsync htop grc unzip @development-tools nodejs
#                 python3 direnv
#                 (fastfetch via copr if available)
#
# What gets deployed (subset of the repo's config/):
#   ~/.zshrc                   from config/zsh/.zshrc
#   ~/.config/starship/        from config/starship/
#   ~/.config/tmux/            from config/tmux/
#   ~/.config/nvim/            from config/nvim/   (skip with --no-nvim)
#
# Idempotent — safe to re-run.  Each step detects its own
# already-installed state.

set -euo pipefail

# ── Colours / helpers ──────────────────────────────────────────────
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

# ── Args ───────────────────────────────────────────────────────────
TARGET=""
WANT_NVIM=1
WANT_OMZ=1
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-nvim)  WANT_NVIM=0 ;;
        --no-omz)   WANT_OMZ=0 ;;
        --dry-run)  DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*) die "Unknown flag: $1" ;;
        *)  [[ -n "$TARGET" ]] && die "Multiple targets given; only one allowed."
            TARGET="$1" ;;
    esac
    shift
done
[[ -z "$TARGET" ]] && die "Usage: $(basename "$0") user@host [--no-nvim] [--no-omz] [--dry-run]"
[[ "$TARGET" =~ ^[A-Za-z_][A-Za-z0-9_-]*@[A-Za-z0-9.\-]+$ ]] \
    || die "Target must be in form user@host (got: $TARGET)"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── SSH preflight ──────────────────────────────────────────────────
log "Preflight: SSH key auth to $TARGET …"
# StrictHostKeyChecking policy is opt-in:
#   default            = accept-new  (TOFU — auto-pin first time, then strict)
#   STRICT_HOST_KEY=1  = yes         (require the key to be in known_hosts)
# accept-new is convenient for first-time provisioning of a known box on a
# trusted network; it does NOT defend against a MITM at first contact.  Set
# STRICT_HOST_KEY=1 (or =yes) when provisioning a long-lived server you've
# already SSH'd to from this workstation — that turns first-contact failure
# from "silently pin attacker's key" into "abort with host-key error".
case "${STRICT_HOST_KEY:-}" in
    1|y|yes|true|on) _hk_policy=yes ;;
    *)               _hk_policy=accept-new ;;
esac
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o "StrictHostKeyChecking=${_hk_policy}")
if ! ssh "${SSH_OPTS[@]}" "$TARGET" true 2>/dev/null; then
    if [[ "$_hk_policy" == "yes" ]]; then
        die "SSH to $TARGET failed under STRICT_HOST_KEY=yes.  Either:
  • The host key isn't in ~/.ssh/known_hosts yet (run \`ssh $TARGET\` once
    interactively first, verify the fingerprint, then re-run this script),
  • Or the host key changed unexpectedly (potential MITM — investigate)."
    fi
    die "SSH key auth to $TARGET failed.  Run \`ssh-copy-id $TARGET\` first."
fi
ok "SSH key auth OK (host-key policy: $_hk_policy)"

log "Preflight: passwordless sudo on $TARGET …"
if ! ssh "${SSH_OPTS[@]}" "$TARGET" 'sudo -n true' 2>/dev/null; then
    die "passwordless sudo not available on $TARGET.  Either configure
NOPASSWD for your user, or prime sudo by running \`sudo -v\` in another
SSH session and re-running this script within the timestamp window."
fi
ok "passwordless sudo OK"

# ── Detect remote distro ───────────────────────────────────────────
REMOTE_OS_RELEASE="$(ssh "${SSH_OPTS[@]}" "$TARGET" 'cat /etc/os-release 2>/dev/null')"
REMOTE_ID="$(echo "$REMOTE_OS_RELEASE" | awk -F= '$1=="ID"{gsub(/"/,"",$2); print $2}')"
REMOTE_VER="$(echo "$REMOTE_OS_RELEASE" | awk -F= '$1=="VERSION_ID"{gsub(/"/,"",$2); print $2}')"
REMOTE_LIKE="$(echo "$REMOTE_OS_RELEASE" | awk -F= '$1=="ID_LIKE"{gsub(/"/,"",$2); print $2}')"
log "Remote: ID=${REMOTE_ID} VERSION_ID=${REMOTE_VER} ID_LIKE=${REMOTE_LIKE}"

case "${REMOTE_ID:-}" in
    debian|ubuntu|raspbian)               PM=apt ;;
    fedora|rhel|centos|rocky|almalinux)   PM=dnf ;;
    *)
        case " ${REMOTE_LIKE:-} " in
            *' debian '*|*' ubuntu '*) PM=apt ;;
            *' rhel '*|*' fedora '*)   PM=dnf ;;
            *) die "Unrecognised distro (ID=${REMOTE_ID}, ID_LIKE=${REMOTE_LIKE}).
Supported: debian/ubuntu/raspbian (apt) and rhel/centos/rocky/alma/fedora (dnf)." ;;
        esac
        ;;
esac
ok "Package manager: $PM"

# ── Compose the remote-side install driver ───────────────────────
# Approach: cat the shared library (scripts/lib/install-common.sh)
# AND a small driver heredoc into ssh's stdin.  Bash on the remote
# sources the lib (it's just function definitions + arrays) and runs
# the driver (which calls those functions).  No round-trips, no
# remote file cleanup, and the install logic lives in ONE place
# instead of being duplicated between install-shell.sh's body and a
# 130-line heredoc here.
LIB_PATH="$REPO_DIR/scripts/lib/install-common.sh"
[[ -f "$LIB_PATH" ]] || die "Missing $LIB_PATH (corrupt clone?)"

remote_install_driver() {
cat <<'REMOTE_EOF'

# ── Driver — runs after the lib has been sourced ────────────────
set -euo pipefail
PM="${1:-apt}"

case "$PM" in
    apt)
        log "apt update + install ${#PKGS_SHELL_APT[@]} packages …"
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
            --no-install-recommends "${PKGS_SHELL_APT[@]}" >/dev/null
        ok "apt install done"
        ;;
    dnf)
        log "dnf install ${#PKGS_SHELL_DNF[@]} packages + @development-tools …"
        # epel-release only matters on RHEL/Rocky/Alma; harmless on Fedora.
        sudo dnf install -y --setopt=install_weak_deps=False \
            epel-release 2>/dev/null || true
        sudo dnf install -y --setopt=install_weak_deps=False \
            "${PKGS_SHELL_DNF[@]}" >/dev/null
        sudo dnf groupinstall -y "Development Tools" >/dev/null 2>&1 || true
        ok "dnf install done"
        # fastfetch isn't in default dnf repos; try copr (community
        # build).  Best-effort — skip silently if not available.
        if ! command -v fastfetch >/dev/null 2>&1; then
            log "trying fastfetch from copr (zyrouge) …"
            sudo dnf copr enable -y zyrouge/fastfetch 2>/dev/null \
                && sudo dnf install -y fastfetch >/dev/null 2>&1 \
                && ok "fastfetch installed (copr)" \
                || warn "fastfetch unavailable on this dnf — skipping"
        fi
        ;;
esac

common_hash_refresh
common_link_debian_aliases
common_install_starship
[[ "${WANT_OMZ:-1}" == 1 ]] && {
    common_install_omz
    common_install_zsh_plugins
}
common_install_tpm
[[ "${WANT_NVIM:-1}" == 1 ]] && common_nvim_plugin_sync online
common_set_default_shell_zsh
common_tighten_zsh_history
echo
echo "  ── done ──"
REMOTE_EOF
}

# ── Push minimal config tree to remote ────────────────────────────
RSYNC_OPTS=(-az --delete --exclude='__pycache__' --exclude='*.pyc'
            --exclude='.git' --exclude='.DS_Store')
declare -a SYNC_DIRS=(zsh starship tmux)
(( WANT_NVIM == 1 )) && SYNC_DIRS+=(nvim)

if (( DRY_RUN == 1 )); then
    log "DRY RUN — would do:"
    log "  • install packages on $TARGET via $PM (see remote script for list)"
    log "  • rsync these config/ subdirs to $TARGET:~/.config/:"
    for d in "${SYNC_DIRS[@]}"; do log "      $d"; done
    log "  • install ~/.zshrc on $TARGET from config/zsh/.zshrc"
    log "  • install oh-my-zsh, starship, tpm, nvim plugins on $TARGET"
    log "  • set zsh as default shell on $TARGET"
    exit 0
fi

log "Syncing configs to $TARGET:~/.config/ …"
ssh "${SSH_OPTS[@]}" "$TARGET" 'mkdir -p ~/.config'
for d in "${SYNC_DIRS[@]}"; do
    src="$REPO_DIR/config/$d"
    if [[ "$d" == "zsh" ]]; then
        # zsh's deploy target is ~/.zshrc, not ~/.config/zsh/.zshrc —
        # send the file directly.
        if [[ -f "$src/.zshrc" ]]; then
            rsync "${RSYNC_OPTS[@]}" "$src/.zshrc" "$TARGET:~/.zshrc"
            ok "  $d → ~/.zshrc"
        fi
        continue
    fi
    if [[ -d "$src" ]]; then
        rsync "${RSYNC_OPTS[@]}" "$src/" "$TARGET:~/.config/$d/"
        ok "  $d → ~/.config/$d/"
    else
        warn "  $src missing — skipping"
    fi
done

# ── Run the remote-side install ───────────────────────────────────
# Stream the shared library + driver to ssh's stdin.  Bash reads them
# as one concatenated script: the lib's `common_*` functions become
# available, then the driver invokes them in order.
log "Running remote install on $TARGET …"
{ cat "$LIB_PATH"; remote_install_driver; } \
    | ssh "${SSH_OPTS[@]}" "$TARGET" \
        "WANT_NVIM=$WANT_NVIM WANT_OMZ=$WANT_OMZ bash -s -- $PM"

ok "Server provisioned: $TARGET"
log "Connect with:  ssh $TARGET"
log "First login starts a fresh zsh session with the new config + tmux"
log "auto-restoring any prior pane layout (tmux-resurrect, if you used"
log "it on another box and synced ~/.tmux/resurrect/ over)."
