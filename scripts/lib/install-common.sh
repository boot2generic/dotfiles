# scripts/lib/install-common.sh
#
# Shared shell library for the four install paths.  This file is
# *sourced*, not executed — never invoke it directly.  Defines:
#   • Color/log helpers              (log, ok, warn, err, die, toast)
#   • Package lists                  (PKGS_SHELL_APT, PKGS_SHELL_DNF)
#   • Distro detection               (common_detect_pm)
#   • Bash hash refresh              (common_hash_refresh)
#   • fd/bat canonical symlinks      (common_link_debian_aliases)
#   • starship installer             (common_install_starship)
#   • oh-my-zsh + plugins            (common_install_omz, common_install_zsh_plugins)
#   • tpm + tmux plugin sync         (common_install_tpm)
#   • neovim plugin sync             (common_nvim_plugin_sync)
#   • Default shell switch           (common_set_default_shell_zsh)
#   • zsh history file perms         (common_tighten_zsh_history)
#
# Used by:
#   scripts/install-shell.sh         — sources this file directly
#   scripts/provision-server.sh      — scp's this file to the remote
#                                      and ssh-source's it there
#
# NOT used by:
#   local_setup.sh                   — its own logic is GUI-aware and
#                                      the package-list overlap is
#                                      small.  Kept independent.
#   vm_automation.py                 — pexpect-driven SSH automation,
#                                      not bash sourceable.  Calls the
#                                      same upstream sources directly.
#
# All function names are prefixed `common_` so callers can wrap or
# override individual steps without losing the rest.
# All variables not exported are scoped to the sourcing shell — caller
# can re-define them between sourcing the lib and calling the
# functions if needed.

# ── Logging helpers ────────────────────────────────────────────────
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

# ── Package lists ──────────────────────────────────────────────────
# Shell-only set.  Same intent on both PMs but names differ slightly.
# Keep these two lists in sync — adding a tool means editing both.
PKGS_SHELL_APT=(
    zsh tmux neovim fzf ripgrep fd-find bat
    git curl wget rsync htop unzip
    build-essential nodejs npm python3
    grc fastfetch direnv btop
)
PKGS_SHELL_DNF=(
    zsh tmux neovim fzf ripgrep fd-find bat
    git curl wget rsync htop unzip
    nodejs python3 grc direnv btop
)

# ── Distro / package-manager detection ─────────────────────────────
# Reads /etc/os-release once; sets COMMON_PM to apt|dnf and exports
# COMMON_DISTRO_ID for diagnostic messages.  Caller decides what to
# do with `unsupported`.  Idempotent — safe to call multiple times.
common_detect_pm() {
    if [[ -z "${COMMON_PM:-}" ]]; then
        if [[ ! -r /etc/os-release ]]; then
            die "/etc/os-release missing — cannot identify distro"
        fi
        # shellcheck disable=SC1091
        . /etc/os-release
        COMMON_DISTRO_ID="${ID:-unknown}"
        COMMON_DISTRO_VERSION="${VERSION_ID:-unknown}"
        COMMON_DISTRO_CODENAME="${VERSION_CODENAME:-}"
        case "${ID:-}" in
            debian|ubuntu|raspbian)               COMMON_PM=apt ;;
            fedora|rhel|centos|rocky|almalinux)   COMMON_PM=dnf ;;
            *)
                case " ${ID_LIKE:-} " in
                    *' debian '*|*' ubuntu '*) COMMON_PM=apt ;;
                    *' rhel '*|*' fedora '*)   COMMON_PM=dnf ;;
                    *) die "Unsupported distro: ID=${ID:-?} ID_LIKE=${ID_LIKE:-?}" ;;
                esac
                ;;
        esac
    fi
}

# ── Refresh shell command-cache after package install ─────────────
# After `apt install`, bash's hash table may still report newly-
# installed binaries as "not found" if their absence was cached.
# Always call this once between install and the first `command -v`.
common_hash_refresh() {
    hash -r 2>/dev/null || true
}

# ── fd/bat canonical-name symlinks ─────────────────────────────────
# Debian renames fd→fdfind and bat→batcat.  Restore the upstream
# names so muscle memory and tooling that hardcodes `fd`/`bat` work.
common_link_debian_aliases() {
    mkdir -p "$HOME/.local/bin"
    if command -v fdfind >/dev/null 2>&1 && [[ ! -e "$HOME/.local/bin/fd" ]]; then
        ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
        ok "fd → fdfind symlink"
    fi
    if command -v batcat >/dev/null 2>&1 && [[ ! -e "$HOME/.local/bin/bat" ]]; then
        ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
        ok "bat → batcat symlink"
    fi
}

# ── starship — apt/dnf if available, upstream curl|sh otherwise ───
# Idempotent: skips if already on PATH or in ~/.local/bin/.
# Mitigates curl|sh by enforcing TLS-only and refusing downgrades.
common_install_starship() {
    if command -v starship >/dev/null 2>&1 \
       || [[ -x "$HOME/.local/bin/starship" ]]; then
        ok "starship already installed ($(starship --version 2>/dev/null | head -1))"
        return 0
    fi
    common_detect_pm
    case "$COMMON_PM" in
        apt)
            if apt-cache show starship >/dev/null 2>&1; then
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
                    starship >/dev/null 2>&1 \
                    && { ok "starship via apt"; return 0; }
            fi
            ;;
        dnf)
            if dnf info starship >/dev/null 2>&1; then
                sudo dnf install -y starship >/dev/null 2>&1 \
                    && { ok "starship via dnf"; return 0; }
            fi
            ;;
    esac
    log "starship not in distro repos — using upstream installer"
    if curl --proto '=https' --tlsv1.2 -sSfL https://starship.rs/install.sh \
       | sh -s -- --yes >/dev/null 2>&1; then
        ok "starship via upstream installer"
    else
        warn "starship install failed — prompt won't render correctly"
        return 1
    fi
}

# ── oh-my-zsh — git clone (or copy from $1 if present) ────────────
# $1 (optional): a path to an existing oh-my-zsh checkout to copy
# from instead of git-cloning.  Used by install-shell.sh's --offline
# mode (passes bundle/git/oh-my-zsh).
common_install_omz() {
    local source_dir="${1:-}"
    if [[ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]]; then
        ok "oh-my-zsh already installed"
        return 0
    fi
    rm -rf "$HOME/.oh-my-zsh"
    if [[ -n "$source_dir" && -d "$source_dir" ]]; then
        cp -a "$source_dir" "$HOME/.oh-my-zsh"
        ok "oh-my-zsh copied from $source_dir"
    else
        if git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git \
            "$HOME/.oh-my-zsh" >/dev/null 2>&1; then
            ok "oh-my-zsh cloned"
        else
            warn "oh-my-zsh clone failed"
            return 1
        fi
    fi
}

# ── zsh-autosuggestions + zsh-syntax-highlighting plugins ─────────
# $1 (optional): path to a directory containing both plugins as
# subdirectories (offline-bundle layout).  When unset, git-clones
# from upstream.
common_install_zsh_plugins() {
    local source_dir="${1:-}"
    local custom="$HOME/.oh-my-zsh/custom"
    [[ -d "$custom" ]] || return 0   # OMZ not installed; nothing to plug into
    local plugin repo dest
    for plugin in zsh-autosuggestions zsh-syntax-highlighting; do
        dest="$custom/plugins/$plugin"
        if [[ -d "$dest" ]]; then
            ok "$plugin already present"
            continue
        fi
        if [[ -n "$source_dir" && -d "$source_dir/$plugin" ]]; then
            cp -a "$source_dir/$plugin" "$dest"
            ok "$plugin copied from bundle"
            continue
        fi
        case "$plugin" in
            zsh-autosuggestions)
                repo=https://github.com/zsh-users/zsh-autosuggestions ;;
            zsh-syntax-highlighting)
                repo=https://github.com/zsh-users/zsh-syntax-highlighting ;;
        esac
        if git clone --depth=1 "$repo" "$dest" >/dev/null 2>&1; then
            ok "$plugin cloned"
        else
            warn "$plugin clone failed"
        fi
    done
}

# ── tmux plugin manager (tpm) ─────────────────────────────────────
# $1 (optional): existing tpm checkout to copy from.
# Always runs `tpm/bin/install_plugins` afterwards so users don't sit
# at first attach watching plugins install.
common_install_tpm() {
    local source_dir="${1:-}"
    if [[ ! -d "$HOME/.tmux/plugins/tpm" ]]; then
        mkdir -p "$HOME/.tmux/plugins"
        if [[ -n "$source_dir" && -d "$source_dir" ]]; then
            cp -a "$source_dir" "$HOME/.tmux/plugins/tpm"
            ok "tpm copied from $source_dir"
        else
            if git clone --depth=1 https://github.com/tmux-plugins/tpm \
                "$HOME/.tmux/plugins/tpm" >/dev/null 2>&1; then
                ok "tpm cloned"
            else
                warn "tpm clone failed — tmux plugins won't auto-install"
                return 1
            fi
        fi
    else
        ok "tpm already present"
    fi
    TMUX_PLUGIN_MANAGER_PATH="$HOME/.tmux/plugins" \
        "$HOME/.tmux/plugins/tpm/bin/install_plugins" >/dev/null 2>&1 \
        && ok "tmux plugins synced" \
        || warn "tmux plugin install warnings (non-fatal)"
}

# ── neovim plugin pre-sync ─────────────────────────────────────────
# Runs `nvim --headless +Lazy! sync +TSUpdateSync +qa` — pre-builds
# all plugins + treesitter parsers so the first interactive nvim
# start is fast.  Only runs when `nvim` is on PATH.  Skipped (with a
# warning) under offline because lazy.nvim reaches GitHub.
# $1: "online" or "offline" — controls behavior.
common_nvim_plugin_sync() {
    local mode="${1:-online}"
    if ! command -v nvim >/dev/null 2>&1; then
        return 0
    fi
    if [[ "$mode" == "offline" ]]; then
        warn "nvim plugin sync skipped under offline mode (lazy.nvim needs github.com)"
        warn "Bundle pre-built plugins separately, or use --no-nvim to silence."
        return 0
    fi
    log "pre-installing neovim plugins (headless) …"
    nvim --headless '+Lazy! sync' '+TSUpdateSync' +qa >/dev/null 2>&1 || true
    local n
    n="$(ls "$HOME/.local/share/nvim/lazy/" 2>/dev/null | wc -l)"
    if [[ "$n" -gt 0 ]]; then
        ok "$n nvim plugin(s) installed"
    else
        warn "nvim plugin sync produced no plugins"
    fi
}

# ── Default shell ──────────────────────────────────────────────────
common_set_default_shell_zsh() {
    local zsh_path current
    zsh_path="$(command -v zsh 2>/dev/null || true)"
    current="$(getent passwd "$USER" | cut -d: -f7)"
    if [[ "$current" == *zsh* ]]; then
        ok "zsh is already the default shell"
        return 0
    fi
    if [[ -z "$zsh_path" ]]; then
        warn "zsh not on PATH — can't change default shell"
        return 1
    fi
    sudo usermod -s "$zsh_path" "$USER" \
        && ok "default shell → zsh (relog to apply)" \
        || warn "usermod -s failed"
}

# ── zsh history file perms ─────────────────────────────────────────
# Matches local_setup.sh's deploy_phase tightening — closes the
# group/world-readable-credential-leak gap before the first new
# shell starts up.
common_tighten_zsh_history() {
    [[ -f "$HOME/.zsh_history" ]] && chmod 600 "$HOME/.zsh_history" \
        2>/dev/null || true
}
