#!/usr/bin/env bash
# scripts/install-methods/github-release.sh
#
# Phase 0 install-method adapter: download a pinned github-release
# asset, verify (sha256 + optional gpg), install to a target path.
#
# Why this method exists: lots of single-binary CLIs (starship,
# zoxide, lazygit, etc.) ship as github releases.  An adapter that
# pins {version, sha256_<arch>, gpg_fingerprint} per-arch is safer
# than `curl -fsSL .../install.sh | bash` because:
#   1. SHA is pinned in the manifest — bitrot or a Trojan in the
#      upstream artifact is caught.
#   2. GPG fingerprint is pinned — when the upstream maintainer signs
#      releases, we cryptographically anchor the artifact to their key.
#   3. version is pinned — no surprise upgrades.
#
# Invocation contract: see scripts/install-methods/apt.sh.  Manifest
# fields under .install.github_release:
#   repo (org/name), asset_pattern, version, install_to,
#   sha256_x86_64, sha256_aarch64, gpg_fingerprint (opt),
#   extract_path (opt — relative path inside the tar to the binary).
#
# {arch} substitution in asset_pattern mirrors build-bundle.sh:176-181
# (uname -m mapping) so manifest authors use one canonical token.

set -euo pipefail

if [[ -t 2 ]]; then
    C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'
    C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
    C_OK= ; C_WARN= ; C_ERR= ; C_DIM= ; C_RST=
fi
log()  { echo "${C_DIM}[*]${C_RST} $*" >&2; }
ok()   { echo "${C_OK}[ok]${C_RST} $*" >&2; }
warn() { echo "${C_WARN}[!]${C_RST} $*" >&2; }
err()  { echo "${C_ERR}[!!]${C_RST} $*" >&2; }

emit() { printf '%s\n' "$*"; }

manifest_json="${1:-}"
if [[ -z "$manifest_json" || ! -r "$manifest_json" ]]; then
    err "manifest JSON path missing or unreadable: ${manifest_json:-<unset>}"
    emit "installed=false skipped_reason=bad-args"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    err "jq not on PATH — required to parse manifest JSON"
    emit "installed=false skipped_reason=jq-missing"
    exit 1
fi
for tool in curl sha256sum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        err "$tool not on PATH — required for github-release method"
        emit "installed=false skipped_reason=${tool}-missing"
        exit 1
    fi
done

: "${DRY_RUN:=0}"
: "${REPO_DIR:=}"
: "${DOTFILES_MACHINE:=}"

get() { jq -r "$1 // empty" "$manifest_json"; }

repo="$(get '.install.github_release.repo')"
asset_pattern="$(get '.install.github_release.asset_pattern')"
version="$(get '.install.github_release.version')"
install_to="$(get '.install.github_release.install_to')"
gpg_fingerprint="$(get '.install.github_release.gpg_fingerprint')"
extract_path="$(get '.install.github_release.extract_path')"

for f in repo asset_pattern version install_to; do
    if [[ -z "${!f}" ]]; then
        err "manifest missing .install.github_release.$f"
        emit "installed=false skipped_reason=manifest-incomplete"
        exit 1
    fi
done

# ── Architecture resolution ───────────────────────────────────────
# Use dpkg --print-architecture (debian-aware) when available; fall
# back to uname -m for non-debian rescue environments.  Mapping:
#   amd64/x86_64  → x86_64
#   arm64/aarch64 → aarch64
# Manifest may use either form via {arch} — see below.
debian_arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$debian_arch" in
    amd64|x86_64)   arch_canonical=x86_64 ;;
    arm64|aarch64)  arch_canonical=aarch64 ;;
    *)
        err "unsupported architecture: $debian_arch"
        emit "installed=false skipped_reason=unsupported-arch"
        exit 1
        ;;
esac

# Resolve {arch} placeholder in the asset pattern.
resolved_asset="${asset_pattern//\{arch\}/$arch_canonical}"

# Pick the per-arch SHA.  jq path is dynamic so we use --arg.
expected_sha="$(jq -r --arg a "$arch_canonical" \
    '.install.github_release["sha256_" + $a] // empty' "$manifest_json")"
if [[ -z "$expected_sha" ]]; then
    err "manifest missing sha256_$arch_canonical"
    emit "installed=false skipped_reason=sha256-missing"
    exit 1
fi

# ── Already-installed short-circuit ───────────────────────────────
# If the destination file's SHA already matches the pinned arch SHA,
# nothing to do.  This is more reliable than `<binary> --version`
# (which would require knowing the version-flag convention per tool).
if [[ -f "$install_to" ]]; then
    have_sha="$(sha256sum "$install_to" | awk '{print $1}')"
    if [[ "$have_sha" == "$expected_sha" ]]; then
        ok "$install_to already at pinned SHA"
        emit "installed=false skipped_reason=already-installed"
        exit 0
    fi
fi

asset_url="https://github.com/$repo/releases/download/$version/$resolved_asset"

if [[ "$DRY_RUN" == "1" ]]; then
    log "would download: $asset_url"
    log "would verify sha256: $expected_sha"
    [[ -n "$gpg_fingerprint" ]] && log "would gpg-verify against: $gpg_fingerprint"
    log "would install → $install_to"
    emit "installed=false skipped_reason=dry-run"
    exit 0
fi

# All work happens in a private workdir we clean up on exit.  The
# trap covers SHA mismatch / GPG failure / interrupt — without it,
# /tmp would fill with half-downloads on a flaky network.
workdir="$(mktemp -d -t github-release.XXXXXX)"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT INT TERM

asset_file="$workdir/$resolved_asset"
log "downloading $asset_url"
# --proto =https + --tlsv1.2 — refuse any downgrade attempt.
# -f fail on HTTP errors; -L follow github's redirect to S3.
if ! curl --proto '=https' --tlsv1.2 -fsSL "$asset_url" -o "$asset_file"; then
    err "download failed: $asset_url"
    emit "installed=false skipped_reason=download-failed"
    exit 2
fi

# ── SHA-256 verification ──────────────────────────────────────────
log "verifying sha256 …"
if ! echo "$expected_sha  $asset_file" | sha256sum -c - >/dev/null 2>&1; then
    actual_sha="$(sha256sum "$asset_file" | awk '{print $1}')"
    err "sha256 mismatch"
    err "  expected: $expected_sha"
    err "  actual:   $actual_sha"
    emit "installed=false skipped_reason=sha256-mismatch"
    exit 1
fi
ok "sha256 verified"

# ── Optional GPG verification ─────────────────────────────────────
# When the manifest pins a gpg_fingerprint we try `.sig` first then
# `.asc` since upstream conventions vary.  If neither is downloadable
# but a fingerprint was pinned, that's a hard fail — silently skipping
# verification would defeat the purpose of pinning the fingerprint.
if [[ -n "$gpg_fingerprint" ]]; then
    if ! command -v gpg >/dev/null 2>&1; then
        err "gpg_fingerprint pinned but gpg not on PATH"
        emit "installed=false skipped_reason=gpg-missing"
        exit 1
    fi
    sig_file=""
    for ext in sig asc; do
        if curl --proto '=https' --tlsv1.2 -fsSL \
                "${asset_url}.${ext}" -o "$asset_file.$ext" 2>/dev/null; then
            sig_file="$asset_file.$ext"
            break
        fi
    done
    if [[ -z "$sig_file" ]]; then
        err "no .sig or .asc available for $asset_url"
        emit "installed=false skipped_reason=signature-missing"
        exit 1
    fi
    # Use an ephemeral gpg home so we don't pollute the user's keyring
    # and so a stale local key can't accidentally vouch for the artifact.
    gpg_home="$workdir/gpghome"
    mkdir -p "$gpg_home"
    chmod 700 "$gpg_home"
    # Receive the pinned key from a keyserver.  --keyid-format long
    # forces full IDs in any output we'd later parse.
    if ! gpg --homedir "$gpg_home" --batch --keyserver hkps://keys.openpgp.org \
            --recv-keys "$gpg_fingerprint" >/dev/null 2>&1; then
        # Some upstreams only publish on keys.gnupg.net / Ubuntu;
        # try a fallback before giving up.
        if ! gpg --homedir "$gpg_home" --batch --keyserver hkps://keyserver.ubuntu.com \
                --recv-keys "$gpg_fingerprint" >/dev/null 2>&1; then
            err "could not fetch key $gpg_fingerprint from any keyserver"
            emit "installed=false skipped_reason=gpg-key-fetch-failed"
            exit 1
        fi
    fi
    # Verify and capture the fingerprint of the *signing* key from the
    # status-fd output.  Only a VALIDSIG with the pinned fingerprint
    # is accepted — GOODSIG alone is too permissive (it accepts any
    # key in the homedir).
    if ! gpg --homedir "$gpg_home" --status-fd 1 --batch \
            --verify "$sig_file" "$asset_file" 2>/dev/null \
         | grep -q "^\[GNUPG:\] VALIDSIG ${gpg_fingerprint}"; then
        err "gpg verification failed (no VALIDSIG for $gpg_fingerprint)"
        emit "installed=false skipped_reason=gpg-verify-failed"
        exit 1
    fi
    ok "gpg signature verified ($gpg_fingerprint)"
fi

# ── Install ───────────────────────────────────────────────────────
# Detect archive vs bare binary by suffix.  Three tarball flavors
# cover ~all practical github releases; .zip is rare enough that
# we'll add it on demand instead of guessing extraction now.
binary_to_install=""
case "$resolved_asset" in
    *.tar.gz|*.tgz|*.tar.xz)
        log "extracting archive …"
        extract_dir="$workdir/extracted"
        mkdir -p "$extract_dir"
        if ! tar -xf "$asset_file" -C "$extract_dir" 2>&2; then
            err "tar extraction failed"
            emit "installed=false skipped_reason=extract-failed"
            exit 2
        fi
        if [[ -n "$extract_path" ]]; then
            binary_to_install="$extract_dir/$extract_path"
        else
            # Look for a single executable in the extracted root.
            # If multiple match, manifest MUST set extract_path —
            # bail out rather than guess.
            mapfile -t candidates < <(find "$extract_dir" -maxdepth 2 -type f -perm -u+x)
            if [[ "${#candidates[@]}" -eq 0 ]]; then
                # Some tarballs ship non-executable files; try by name.
                mapfile -t candidates < <(find "$extract_dir" -maxdepth 2 -type f \
                    -name "$(basename "$install_to")")
            fi
            if [[ "${#candidates[@]}" -ne 1 ]]; then
                err "could not auto-locate binary in archive (${#candidates[@]} candidates) — set extract_path"
                emit "installed=false skipped_reason=extract-path-ambiguous"
                exit 1
            fi
            binary_to_install="${candidates[0]}"
        fi
        ;;
    *)
        # Bare binary — install directly.
        binary_to_install="$asset_file"
        ;;
esac

if [[ ! -f "$binary_to_install" ]]; then
    err "expected binary not found: $binary_to_install"
    emit "installed=false skipped_reason=binary-missing"
    exit 2
fi

log "installing → $install_to"
if ! sudo install -D -m 0755 "$binary_to_install" "$install_to" 2>&2; then
    err "install -D failed (target: $install_to)"
    emit "installed=false skipped_reason=install-failed"
    exit 2
fi

ok "$install_to installed (version $version)"
emit "installed=true"
exit 0
