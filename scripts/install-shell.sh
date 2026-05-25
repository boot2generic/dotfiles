#!/usr/bin/env bash
# scripts/install-shell.sh                  ── Install Path D ──
#
# LOCAL shell-only install (zsh + oh-my-zsh + starship + tmux + nvim
# + CLI utilities), distro-aware.
#
# Use case (from the README's decision tree):
#   • You're on the target machine (console / KVM / SSH'd in)
#   • You want the SHELL stack only (no i3 / polybar / X11)
#
# Compared to:
#   • Path A (local_setup.sh):       full GUI, this is shell-only
#   • Path B (vm_automation.py):     remote-via-SSH, this is local
#   • Path C (provision-server.sh):  remote-via-SSH, this is local
# Paths C and D share install logic via scripts/lib/install-common.sh.
#
# Usage:
#   ./scripts/install-shell.sh                 # full online install
#   ./scripts/install-shell.sh --offline       # use bundle/, no network
#   ./scripts/install-shell.sh --no-nvim       # skip neovim setup
#   ./scripts/install-shell.sh --no-omz        # slim zsh, no oh-my-zsh
#   ./scripts/install-shell.sh --dry-run       # show what would happen
#
# `--offline` requires a bundle/ directory at the repo root, built on
# a connected box via `./scripts/build-bundle.sh`.  See that script
# for caveats (distro/version/arch must match).
#
# See README.md "Feature-parity matrix" for the full capability table
# across all four install paths.

set -euo pipefail

# Source shared install logic (log helpers, package lists, distro
# detection, oh-my-zsh + tpm + starship installers, fd/bat symlinks,
# default-shell switch).  See scripts/lib/install-common.sh for the
# function inventory and rationale.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/install-common.sh
. "${REPO_DIR}/scripts/lib/install-common.sh"

BUNDLE_DIR="${REPO_DIR}/bundle"

OFFLINE=0
WANT_NVIM=1
WANT_OMZ=1
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --offline)  OFFLINE=1 ;;
        --no-nvim)  WANT_NVIM=0 ;;
        --no-omz)   WANT_OMZ=0 ;;
        --dry-run)  DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "Unknown flag: $1" ;;
    esac
    shift
done

# ── Preflight ──────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] && die "Run as a regular user; sudo invoked where needed"
command -v sudo >/dev/null 2>&1 || die "sudo not installed"

# Distro / package-manager detection — sets COMMON_PM, COMMON_DISTRO_ID,
# COMMON_DISTRO_VERSION, COMMON_DISTRO_CODENAME for the rest of this
# script.  Aliased to PM for backward compatibility with the offline-
# preflight + install branches below.
common_detect_pm
PM="$COMMON_PM"

# ── Offline preflight: verify bundle ───────────────────────────────
if (( OFFLINE )); then
    [[ "$PM" == "apt" ]] \
        || die "--offline only supported on apt-based distros (yours: $PM)"
    [[ -f "$BUNDLE_DIR/manifest.txt" ]] \
        || die "$BUNDLE_DIR/manifest.txt missing.  Run scripts/build-bundle.sh
on a connected box first, then copy the whole dotfiles dir over."

    # Pull bundle metadata.
    src_id=$(awk -F= '$1=="source_distro_id"{print $2}' "$BUNDLE_DIR/manifest.txt")
    src_codename=$(awk -F= '$1=="source_distro_codename"{print $2}' "$BUNDLE_DIR/manifest.txt")
    src_arch=$(awk -F= '$1=="source_arch"{print $2}' "$BUNDLE_DIR/manifest.txt")
    cur_arch="$(dpkg --print-architecture 2>/dev/null || echo unknown)"

    log "Bundle source : ${src_id} ${src_codename} / ${src_arch}"
    log "This machine  : ${ID} ${VERSION_CODENAME:-?} / ${cur_arch}"

    # Compare archs lowercased — `dpkg --print-architecture` is
    # normally lowercase (`amd64`, `arm64`) but cross-compiler chroots
    # have been seen returning mixed case.  Without normalising we'd
    # block an otherwise-fine install over a single-byte case
    # difference.
    if [[ "${src_arch,,}" != "${cur_arch,,}" ]]; then
        die "Architecture mismatch: bundle=${src_arch} target=${cur_arch}.
Rebuild bundle on a machine matching the target architecture."
    fi
    if [[ "$src_codename" != "${VERSION_CODENAME:-}" && -n "$src_codename" ]]; then
        warn "Bundle was built on ${src_codename}; you're on ${VERSION_CODENAME:-?}."
        warn "dpkg may complain about missing transitive deps.  Continuing."
    fi

    n_debs="$(find "$BUNDLE_DIR/debs" -name '*.deb' 2>/dev/null | wc -l)"
    [[ "$n_debs" -gt 0 ]] || die "$BUNDLE_DIR/debs/ has zero .deb files"
    log "Bundle has $n_debs .deb files, $(du -sh "$BUNDLE_DIR" | cut -f1) total"

    # ── SHA-256 integrity verification ─────────────────────────────
    # build-bundle.sh writes bundle/manifest.sha256 covering every
    # file.  Verifying here catches tampering on the sneakernet path
    # (USB stick swap, MITM during scp from a bridge box, etc.) and
    # bitrot.  --strict makes sha256sum fail on missing/extra files,
    # not just mismatched content.  Skippable via INSTALL_SKIP_BUNDLE_CHECK=1
    # for the rare case of a partial bundle the user knows is OK
    # (e.g. they swapped out the starship tarball deliberately).
    if [[ "${INSTALL_SKIP_BUNDLE_CHECK:-}" == "1" ]]; then
        warn "INSTALL_SKIP_BUNDLE_CHECK=1 set — skipping manifest.sha256 verification"
    elif [[ -f "$BUNDLE_DIR/manifest.sha256" ]]; then
        log "Verifying bundle integrity (sha256sum -c manifest.sha256) …"
        # mktemp -t for the integrity-check log so a local attacker can't
        # pre-create the predictable /tmp path as a symlink to a root-
        # owned file and race the fs.protected_regular check.
        _bundle_check_log="$(mktemp -t install-shell-bundle-check.XXXXXX.log)"
        if ( cd "$BUNDLE_DIR" \
             && sha256sum --check --strict --quiet manifest.sha256 ) 2>"$_bundle_check_log"; then
            ok "bundle integrity verified ($n_debs debs, $(wc -l < "$BUNDLE_DIR/manifest.sha256") files total)"
        else
            err "bundle integrity check FAILED.  This is a security alarm,"
            err "not a transient error — files have changed since the bundle"
            err "was built.  Investigate before continuing:"
            err "  sudo cat $_bundle_check_log"
            err ""
            err "If you're INTENTIONALLY running with a hand-modified bundle"
            err "(e.g. swapped starship tarball), re-run with"
            err "INSTALL_SKIP_BUNDLE_CHECK=1 to bypass this check."
            die "refusing to install from a tampered or incomplete bundle"
        fi
    else
        warn "$BUNDLE_DIR/manifest.sha256 not found — bundle was built with"
        warn "an older build-bundle.sh (pre-integrity-manifest).  Continuing"
        warn "without integrity check; rebuild on a connected box to get"
        warn "tamper detection."
    fi

    # ── Optional GPG signature verification ────────────────────────
    # build-bundle.sh writes bundle/manifest.sha256.asc when the user
    # exported BUNDLE_SIGNING_KEY.  If that .asc is present here, we
    # MUST verify it — its presence advertises a stronger trust claim
    # than sha256 alone, and silently ignoring a bad signature would
    # defeat the whole point.  If gpg is missing, fail loud so the
    # user knows the claim wasn't checked.  Same INSTALL_SKIP_BUNDLE_CHECK
    # escape hatch as the sha256 step above (single env knob = less
    # cognitive load for the legitimate-mismatch case).
    if [[ "${INSTALL_SKIP_BUNDLE_CHECK:-}" == "1" ]]; then
        :  # already warned above
    elif [[ -f "$BUNDLE_DIR/manifest.sha256.asc" ]]; then
        if ! command -v gpg >/dev/null 2>&1; then
            die "$BUNDLE_DIR/manifest.sha256.asc present but gpg not installed.
Either install gnupg, remove the .asc to drop the signature claim,
or set INSTALL_SKIP_BUNDLE_CHECK=1 if you trust the bundle source."
        fi
        log "Verifying GPG signature on manifest.sha256 …"
        # Capture gpg output so we can a) decide on success/failure
        # from its exit code and b) surface the "not certified" warning
        # to the user.  --status-fd 1 would be more rigorous (machine-
        # readable) but parsing the human text suffices for the one
        # warning we care about here.
        # mktemp -t per finding #5 of the project-wide security review.
        _gpg_log="$(mktemp -t install-shell-gpg-verify.XXXXXX.log)"
        if gpg --verify "$BUNDLE_DIR/manifest.sha256.asc" \
                        "$BUNDLE_DIR/manifest.sha256" \
                        >"$_gpg_log" 2>&1; then
            if grep -q "WARNING: This key is not certified with a trusted signature" "$_gpg_log"; then
                warn "GPG signature is VALID but the signing key is not certified"
                warn "in your local trust DB.  Proceeding — verify the key fingerprint"
                warn "out-of-band if this is a first-time install from this signer:"
                grep -E "(Good signature|using .* key|Primary key fingerprint)" "$_gpg_log" >&2 || true
            else
                ok "GPG signature verified (trusted key)"
            fi
        else
            err "GPG signature verification FAILED on manifest.sha256.asc."
            err "This is a security alarm: the bundle is signed but the signature"
            err "does NOT match the manifest.  Do not install from it."
            err "  cat $_gpg_log"
            err ""
            err "If you knowingly modified the bundle after signing, either"
            err "re-sign it (BUNDLE_SIGNING_KEY=<keyid> ./scripts/build-bundle.sh"
            err "--refresh-debs to re-emit just the manifest+sig) or remove the"
            err ".asc and re-run with INSTALL_SKIP_BUNDLE_CHECK=1."
            die "refusing to install from a bundle with a bad signature"
        fi
        unset _gpg_log
    fi
fi

(( DRY_RUN )) && {
    log "DRY RUN — would do:"
    if (( OFFLINE )); then
        log "  • dpkg -i $BUNDLE_DIR/debs/*.deb (offline)"
        log "  • copy $BUNDLE_DIR/git/oh-my-zsh → ~/.oh-my-zsh"
        log "  • copy $BUNDLE_DIR/git/{zsh-autosuggestions,zsh-syntax-highlighting} → ~/.oh-my-zsh/custom/plugins/"
        log "  • copy $BUNDLE_DIR/git/tpm → ~/.tmux/plugins/tpm"
        log "  • extract $BUNDLE_DIR/starship/starship.tar.gz → ~/.local/bin/"
    else
        log "  • $PM install <17 packages> + transitive deps"
        log "  • git clone oh-my-zsh + 2 plugins + tpm"
        log "  • install starship via $PM (or upstream installer)"
    fi
    log "  • deploy ~/.zshrc, ~/.config/{starship,tmux,nvim}/ from repo"
    log "  • set zsh as default shell"
    log "  • sync nvim plugins ($([[ "$WANT_NVIM" == 1 ]] && echo 'YES' || echo 'NO'))"
    exit 0
}

# Prime sudo so subsequent calls don't prompt.
sudo -v || die "sudo authentication failed"

# ── Step 1: install packages ──────────────────────────────────────
# Package lists (PKGS_SHELL_APT, PKGS_SHELL_DNF) are defined in the
# shared lib so install-shell.sh and provision-server.sh stay in sync.

if (( OFFLINE )); then
    log "Installing packages from $BUNDLE_DIR/debs/ (offline) …"
    # `apt-get install ./*.deb` is preferred over plain `dpkg -i`
    # because apt resolves dep order automatically.  Glob-expand inside
    # the command so the shell builds the argv (apt's own `*.deb`
    # globbing differs across versions).  ARG_MAX risk is real only
    # with thousands of debs — a typical shell-only bundle has <500.
    if sudo apt-get install -y --no-install-recommends \
           "$BUNDLE_DIR"/debs/*.deb >/dev/null 2>&1; then
        ok "apt installed $(find "$BUNDLE_DIR"/debs -name '*.deb' | wc -l) packages from bundle"
    else
        # Fallback: dpkg -i bypasses apt's dep solver and just unpacks +
        # configures.  If transitive deps are missing, dpkg leaves
        # half-configured packages and exits non-zero — we then try
        # `apt-get install -f -y` to fix things.
        #
        # The catch: `apt-get install -f` reaches REPOS to fetch any
        # missing deps.  In offline mode there are no repos.  So if
        # dpkg ALSO failed (broken deps), -f can't save us.  All we
        # can do is print a clear error pointing the user at the
        # actual failure (the `dpkg -i` output, run interactively).
        warn "apt-get install ./*.deb failed under --offline."
        warn "Falling back to dpkg -i (which doesn't need apt cache) …"
        # mktemp -t per finding #5 of the project-wide security review.
        _dpkg_log="$(mktemp -t install-shell-dpkg.XXXXXX.log)"
        if sudo dpkg -i "$BUNDLE_DIR"/debs/*.deb >"$_dpkg_log" 2>&1; then
            ok "dpkg -i succeeded — packages installed from bundle"
        else
            err "dpkg -i could not install all bundled packages — likely missing"
            err "transitive dependencies that exist on the BUILD box but not on"
            err "this OFFLINE TARGET.  apt-get install -f is unreachable here"
            err "(would need internet to fetch missing deps)."
            err ""
            err "Diagnose:"
            err "  • sudo tail -50 $_dpkg_log"
            err "  • sudo dpkg --audit            # half-configured packages"
            err "  • dpkg -l | grep -E '^iU|^iF'  # broken/wedged installs"
            err ""
            err "Resolution paths:"
            err "  1. Rebuild the bundle on a build box whose base install"
            err "     matches this target's, then re-copy and re-run."
            err "  2. Manually copy missing .deb files from a connected box"
            err "     into bundle/debs/ and re-run."
            err "  3. Get the target online briefly: \`apt-get install -f -y\`"
            err "     will then auto-resolve."
            die "offline install incomplete"
        fi
    fi
else
    case "$PM" in
        apt)
            log "apt update + install ${#PKGS_SHELL_APT[@]} packages …"
            sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
                --no-install-recommends "${PKGS_SHELL_APT[@]}" >/dev/null
            ok "apt install done"
            ;;
        dnf)
            log "dnf install ${#PKGS_SHELL_DNF[@]} packages …"
            sudo dnf install -y --setopt=install_weak_deps=False \
                epel-release 2>/dev/null || true
            sudo dnf install -y --setopt=install_weak_deps=False \
                "${PKGS_SHELL_DNF[@]}" >/dev/null
            sudo dnf groupinstall -y "Development Tools" >/dev/null 2>&1 || true
            ok "dnf install done"
            ;;
    esac
fi

common_hash_refresh
common_link_debian_aliases

# ── Step 2: starship ──────────────────────────────────────────────
install_starship_from_bundle() {
    [[ -f "$BUNDLE_DIR/starship/starship.tar.gz" ]] \
        || die "starship missing from bundle"
    local tmp; tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN
    # Re-verify SHA256 from the bundled sidecar before extracting.
    if [[ -f "$BUNDLE_DIR/starship/starship.tar.gz.sha256" ]]; then
        ( cd "$BUNDLE_DIR/starship" \
          && echo "$(awk '{print $1}' starship.tar.gz.sha256)  starship.tar.gz" \
             | sha256sum -c - >/dev/null ) \
          || die "starship.tar.gz SHA256 mismatch in bundle"
    fi
    tar -C "$tmp" -xzf "$BUNDLE_DIR/starship/starship.tar.gz" starship
    install -m 0755 "$tmp/starship" "$HOME/.local/bin/starship"
    ok "starship installed from bundle"
}

if command -v starship >/dev/null 2>&1; then
    ok "starship already installed ($(starship --version | head -1))"
elif (( OFFLINE )); then
    install_starship_from_bundle
else
    common_install_starship
fi

# ── Step 3: oh-my-zsh + plugins ───────────────────────────────────
# common_install_omz / common_install_zsh_plugins take an optional
# source-dir argument.  When set, they `cp -a` from there instead of
# `git clone` — which is exactly what offline mode wants.
if (( WANT_OMZ )); then
    if (( OFFLINE )); then
        [[ -d "$BUNDLE_DIR/git/oh-my-zsh" ]] \
            || die "bundle/git/oh-my-zsh/ missing"
        common_install_omz         "$BUNDLE_DIR/git/oh-my-zsh"
        common_install_zsh_plugins "$BUNDLE_DIR/git"
    else
        common_install_omz
        common_install_zsh_plugins
    fi
fi

# ── Step 4: tpm ────────────────────────────────────────────────────
if (( OFFLINE )); then
    [[ -d "$BUNDLE_DIR/git/tpm" ]] || die "bundle/git/tpm missing"
    common_install_tpm "$BUNDLE_DIR/git/tpm"
else
    common_install_tpm
fi

# ── Step 5: deploy configs from repo ───────────────────────────────
log "Deploying shell configs …"
mkdir -p "$HOME/.config"
[[ -f "$REPO_DIR/config/zsh/.zshrc" ]] \
    && cp "$REPO_DIR/config/zsh/.zshrc" "$HOME/.zshrc" \
    && ok "  ~/.zshrc"
for d in starship tmux $( ((WANT_NVIM)) && echo nvim ); do
    src="$REPO_DIR/config/$d"
    if [[ -d "$src" ]]; then
        rsync -a --delete \
            --exclude='__pycache__' --exclude='*.pyc' \
            --exclude='.git' --exclude='.DS_Store' \
            "$src/" "$HOME/.config/$d/"
        ok "  ~/.config/$d/"
    fi
done

# ── Step 6: nvim plugin sync (skipped offline by default) ─────────
if (( WANT_NVIM )); then
    if (( OFFLINE )); then
        common_nvim_plugin_sync offline
    else
        common_nvim_plugin_sync online
    fi
fi

# ── Step 7: default shell + history perms ─────────────────────────
common_set_default_shell_zsh
common_tighten_zsh_history

echo
ok "Shell install complete."
log "Open a new shell (or \`exec zsh\`) to pick up the new prompt."
(( OFFLINE )) && log "(Offline install used $BUNDLE_DIR — keep it around for"
(( OFFLINE )) && log "future re-runs, or delete to free disk.)"
