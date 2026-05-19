#!/usr/bin/env bash
# scripts/build-bundle.sh
#
# Run on an INTERNET-CONNECTED Debian/Ubuntu box to pack everything
# `install-shell.sh --offline` will need into <repo>/bundle/.
#
# After this completes, copy the WHOLE dotfiles directory (repo +
# bundle/) onto the offline target — USB stick, scp from a bridge box,
# whatever your sneakernet path is.  On the offline target, run:
#     ./scripts/install-shell.sh --offline
# and the entire shell-only setup completes without any outbound
# network access.
#
# Bundle contents (~150–250 MB depending on apt cache state):
#   bundle/
#     manifest.txt              — generated metadata; `install-shell.sh
#                                 --offline` reads this to verify the
#                                 bundle matches the offline target.
#     debs/                     — every .deb needed by apt's resolver,
#                                 including transitive dependencies of
#                                 the shell package set.
#     git/oh-my-zsh/            — clone (depth=1) of ohmyzsh.
#     git/zsh-autosuggestions/
#     git/zsh-syntax-highlighting/
#     git/tpm/
#     starship/starship.tar.gz  — release binary + its .sha256 sidecar.
#
# Caveats / hidden costs:
#   1. Distro/version/arch must match.  A bundle built on Debian 13
#      x86_64 won't install cleanly on Ubuntu 22.04 ARM.  The manifest
#      records source distro+version+arch and `install-shell.sh
#      --offline` checks them.
#   2. The `apt-get install --download-only --reinstall` step
#      downloads .debs to bundle/debs/ — including transitive deps of
#      packages that are already installed on the build machine.  If
#      the OFFLINE target's base install differs significantly from
#      the build machine's, `dpkg -i` may surface missing deps.
#      Mitigation: build the bundle on a machine with the same Debian
#      base image as the target.
#   3. The bundle is *.gitignore'd.  Don't commit it — sizes are
#      large, and Debian package URLs in the deb files contain the
#      build machine's apt mirror config.
#
# Optional tamper-evidence beyond sha256 — opt-in GPG signing:
#   BUNDLE_SIGNING_KEY=<keyid> ./scripts/build-bundle.sh
# When set, a detached armored signature over manifest.sha256 is
# written to bundle/manifest.sha256.asc.  install-shell.sh --offline
# auto-verifies it if present (gpg must be installed; if absent the
# step is silently skipped).  Without BUNDLE_SIGNING_KEY the bundle is
# unsigned — sha256 alone catches bitrot but not a deliberate swap.
#
# Usage:
#   ./scripts/build-bundle.sh                   # full bundle
#   ./scripts/build-bundle.sh --refresh-debs    # re-download debs only
#   ./scripts/build-bundle.sh --refresh-git     # re-clone git repos only

set -euo pipefail

if [[ -t 1 ]]; then
    C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'
    C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
    C_OK= ; C_WARN= ; C_ERR= ; C_DIM= ; C_RST=
fi
log()  { echo "${C_DIM}[*]${C_RST} $*"; }
ok()   { echo "${C_OK}[ok]${C_RST} $*"; }
warn() { echo "${C_WARN}[!]${C_RST} $*" >&2; }
die()  { echo "${C_ERR}[!!]${C_RST} $*" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_DIR="${REPO_DIR}/bundle"

REFRESH_ALL=1
REFRESH_DEBS=0
REFRESH_GIT=0
REFRESH_STARSHIP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --refresh-debs)     REFRESH_ALL=0; REFRESH_DEBS=1 ;;
        --refresh-git)      REFRESH_ALL=0; REFRESH_GIT=1 ;;
        --refresh-starship) REFRESH_ALL=0; REFRESH_STARSHIP=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown flag: $1" ;;
    esac
    shift
done
if (( REFRESH_ALL == 1 )); then
    REFRESH_DEBS=1; REFRESH_GIT=1; REFRESH_STARSHIP=1
fi

# ── Preflight ──────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] && die "Run as a regular user; sudo is invoked where needed."
command -v apt-get >/dev/null 2>&1 || die "apt-get not found — Debian/Ubuntu only"
command -v git     >/dev/null 2>&1 || die "git not installed"
command -v curl    >/dev/null 2>&1 || die "curl not installed"

# Source /etc/os-release for the manifest.
# shellcheck disable=SC1091
. /etc/os-release
SRC_ID="${ID:-unknown}"
SRC_VER="${VERSION_ID:-unknown}"
SRC_CODENAME="${VERSION_CODENAME:-unknown}"
SRC_ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"

log "Build bundle: ${SRC_ID} ${SRC_VER} (${SRC_CODENAME}) / ${SRC_ARCH}"
mkdir -p "$BUNDLE_DIR"/{debs,git,starship}

# ── Apt packages ───────────────────────────────────────────────────
# Same package set as scripts/provision-server.sh (the apt branch).
# Keep these two lists in sync if you change one.
PKGS=(
    zsh tmux neovim fzf ripgrep fd-find bat
    git curl wget rsync htop unzip
    build-essential nodejs npm python3
    grc fastfetch direnv
)

if (( REFRESH_DEBS )); then
    log "Downloading ${#PKGS[@]} packages + transitive deps to bundle/debs/ …"
    # `--reinstall` forces re-download even when packages are already
    # installed on this build box, so transitive deps are guaranteed
    # present in the bundle for the offline target.
    # `Dir::Cache::archives` redirects apt's download dir; otherwise
    # the .debs would land in /var/cache/apt/archives and we'd have to
    # cp them out.  An absolute path is required.
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends --download-only \
        --reinstall \
        -o Dir::Cache::archives="$BUNDLE_DIR/debs" \
        "${PKGS[@]}" \
        || die "apt download failed — see /var/log/apt/term.log"
    # Apt creates a lock-tracking partial/ subdir; remove it so it's
    # not in the bundle and dpkg doesn't trip on it offline.
    sudo rm -rf "$BUNDLE_DIR/debs/partial" 2>/dev/null || true
    sudo chown -R "$USER":"$USER" "$BUNDLE_DIR/debs"
    n="$(find "$BUNDLE_DIR/debs" -name '*.deb' | wc -l)"
    ok "downloaded $n .deb files (size: $(du -sh "$BUNDLE_DIR/debs" | cut -f1))"
fi

# ── Git clones ─────────────────────────────────────────────────────
if (( REFRESH_GIT )); then
    log "Mirroring github repos for offline use …"
    # Tuples of "github-org/repo:local-name".  --depth=1 is fine for
    # offline use — none of these are time-machine'd at install time.
    repos=(
        "ohmyzsh/ohmyzsh:oh-my-zsh"
        "zsh-users/zsh-autosuggestions:zsh-autosuggestions"
        "zsh-users/zsh-syntax-highlighting:zsh-syntax-highlighting"
        "tmux-plugins/tpm:tpm"
    )
    for entry in "${repos[@]}"; do
        org_repo="${entry%:*}"
        local_name="${entry##*:}"
        dest="$BUNDLE_DIR/git/$local_name"
        if [[ -d "$dest/.git" ]]; then
            log "  refreshing $local_name …"
            git -C "$dest" pull --ff-only --depth=1 >/dev/null 2>&1 \
                || warn "  pull failed; clone may be stale"
        else
            log "  cloning $local_name …"
            rm -rf "$dest"
            git clone --depth=1 "https://github.com/${org_repo}.git" "$dest" \
                >/dev/null 2>&1 \
                || die "git clone $org_repo failed"
        fi
        # Strip git's .git/hooks dir so re-running the offline install
        # doesn't accidentally fire any prepush hook etc.
        rm -rf "$dest/.git/hooks" 2>/dev/null || true
    done
    ok "git repos mirrored to bundle/git/ ($(du -sh "$BUNDLE_DIR/git" | cut -f1))"
fi

# ── Starship binary ────────────────────────────────────────────────
if (( REFRESH_STARSHIP )); then
    log "Downloading starship release binary …"
    case "$(uname -m)" in
        x86_64)  tarball=starship-x86_64-unknown-linux-gnu.tar.gz ;;
        aarch64) tarball=starship-aarch64-unknown-linux-gnu.tar.gz ;;
        armv7l)  tarball=starship-arm-unknown-linux-musleabihf.tar.gz ;;
        *) die "Unsupported arch for starship bundle: $(uname -m)" ;;
    esac
    url="https://github.com/starship/starship/releases/latest/download/${tarball}"
    curl --proto '=https' --tlsv1.2 -fsSL "$url" \
        -o "$BUNDLE_DIR/starship/starship.tar.gz" \
        || die "starship download failed"
    curl --proto '=https' --tlsv1.2 -fsSL "${url}.sha256" \
        -o "$BUNDLE_DIR/starship/starship.tar.gz.sha256" \
        || die "starship sha256 download failed"
    # Verify in place so the bundle ships only known-good content.
    ( cd "$BUNDLE_DIR/starship" \
      && echo "$(awk '{print $1}' starship.tar.gz.sha256)  starship.tar.gz" \
         | sha256sum -c - >/dev/null ) \
      || die "starship SHA256 mismatch — refusing to bundle"
    ok "starship $(du -h "$BUNDLE_DIR/starship/starship.tar.gz" | cut -f1) verified"
fi

# ── Manifest ───────────────────────────────────────────────────────
cat > "$BUNDLE_DIR/manifest.txt" <<EOF
# install-shell.sh offline-bundle manifest
# DO NOT EDIT — read by install-shell.sh --offline to verify
# the bundle is compatible with the offline target.
generated_at=$(date -Iseconds)
source_distro_id=${SRC_ID}
source_distro_version=${SRC_VER}
source_distro_codename=${SRC_CODENAME}
source_arch=${SRC_ARCH}
package_count=$(find "$BUNDLE_DIR/debs" -name '*.deb' 2>/dev/null | wc -l)
git_repos=$(find "$BUNDLE_DIR/git" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
has_starship=$([[ -f "$BUNDLE_DIR/starship/starship.tar.gz" ]] && echo 1 || echo 0)
total_size=$(du -sh "$BUNDLE_DIR" 2>/dev/null | cut -f1)
EOF

# ── SHA-256 manifest covering every file in bundle/ ────────────────
# Threat model: USB sneakernet.  The bundle leaves this trusted build
# box, crosses a (possibly untrusted) intermediate medium, and lands on
# the offline install target.  manifest.txt only records counts and
# metadata — it would NOT detect a swapped .deb, a Trojan'd
# oh-my-zsh, or a tampered starship binary.  This per-file SHA-256
# manifest plus `sha256sum -c` in install-shell.sh closes that gap.
#
# Exclude manifest.sha256 itself (chicken/egg) and any nested .git/
# packfile (deterministic from clone metadata anyway).  The output is
# sha256sum-compatible so `sha256sum -c manifest.sha256` Just Works on
# the target.  Sort the find output so the manifest is reproducible
# across builds on the same source.
log "Generating per-file SHA-256 manifest …"
# Write the manifest via a TMPDIR-resident temp file rather than
# bundle/manifest.sha256.tmp — if the staging file lives under bundle/,
# `find` enumerates it (and ./manifest.sha256.tmp ends up listed in its
# own output), so the post-`mv` manifest references a path that no
# longer exists and `sha256sum --check --strict` fails on every fresh
# bundle.
_manifest_tmp="$(mktemp -t bundle-manifest.XXXXXX)" \
    || die "mktemp for manifest staging failed"
(
    cd "$BUNDLE_DIR"
    # Also exclude manifest.sha256.asc — a stale signature from a
    # previous build would otherwise be hashed into the new manifest
    # but then overwritten by the fresh signature step below, leaving
    # the manifest referencing a now-invalid .asc hash.
    find . -type f \
        ! -name manifest.sha256 \
        ! -name manifest.sha256.asc \
        ! -path './*/.git/objects/pack/*' \
        -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 sha256sum
) > "$_manifest_tmp" \
  && mv "$_manifest_tmp" "$BUNDLE_DIR/manifest.sha256" \
  || { rm -f "$_manifest_tmp"; die "manifest.sha256 generation failed"; }
unset _manifest_tmp
n_files=$(wc -l < "$BUNDLE_DIR/manifest.sha256")
ok "manifest.sha256: $n_files files covered"

# ── Optional GPG signature over manifest.sha256 ────────────────────
# Opt-in via BUNDLE_SIGNING_KEY=<keyid>.  sha256 alone is sufficient
# for bitrot and naive USB swaps; a GPG signature additionally proves
# the manifest came from the holder of <keyid>'s private key, which
# defeats a "swap the .deb AND regenerate manifest.sha256" attacker.
# We sign manifest.sha256 (not each file individually) because the
# manifest itself authenticates every bundled file by hash.
if [[ -n "${BUNDLE_SIGNING_KEY:-}" ]]; then
    if ! command -v gpg >/dev/null 2>&1; then
        die "BUNDLE_SIGNING_KEY set but gpg is not installed (apt install gnupg)"
    fi
    log "Signing manifest.sha256 with key ${BUNDLE_SIGNING_KEY} …"
    # --batch + --yes: don't open an interactive pinentry prompt mid-build
    # if the key is passphrase-less (CI/agent-driven case); when a
    # passphrase IS required the agent will surface it.  Overwrite any
    # stale .asc from a prior build with -o.
    rm -f "$BUNDLE_DIR/manifest.sha256.asc"
    if gpg --batch --yes --detach-sign --armor \
           -u "$BUNDLE_SIGNING_KEY" \
           -o "$BUNDLE_DIR/manifest.sha256.asc" \
           "$BUNDLE_DIR/manifest.sha256"; then
        ok "manifest.sha256.asc written (detached signature, ASCII-armored)"
    else
        rm -f "$BUNDLE_DIR/manifest.sha256.asc"
        die "gpg --detach-sign failed (key id wrong, or agent unavailable?)"
    fi
else
    log "BUNDLE_SIGNING_KEY not set — bundle is unsigned (sha256 still covers"
    log "  bitrot; set BUNDLE_SIGNING_KEY=<keyid> for full tamper-evidence)."
fi

ok "Bundle ready: $BUNDLE_DIR ($(du -sh "$BUNDLE_DIR" | cut -f1))"
log "Next steps:"
log "  1. Copy the dotfiles dir (incl. bundle/) to the offline target."
log "  2. On the target: ./scripts/install-shell.sh --offline"
log "     (offline preflight verifies bundle/manifest.sha256 before installing)"
log "  3. Reconnect / open a fresh shell."
