#!/usr/bin/env bash
# scripts/install-methods/github-release.sh
#
# Install-method adapter: download a github-release asset, verify
# (sha256 + optional gpg), install to a target path.
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
# Pin-mode handling (Phase B):
#   pin.mode = "frozen" (or unset): use the manifest's version +
#       sha256_<arch>.  This is the original Phase 0 behavior.
#   pin.mode = "track-latest": query the GitHub Releases API for
#       /repos/<repo>/releases/latest, substitute the resolved tag
#       into {version} in asset_pattern, download, compute SHA-256 at
#       runtime, and (if gpg_fingerprint is non-empty) verify a .sig /
#       .asc detached signature against the pinned fingerprint.
#
#       Rate-limit note: the unauthenticated GitHub API allows 60
#       requests per hour per source IP.  We rely on that being plenty
#       for an interactive install on one machine; bulk-install paths
#       that loop over many entries are NOT optimised for this.
#       Adapters that need auth would pull GITHUB_TOKEN from env;
#       Phase B explicitly does NOT (the user wanted minimal deps).
#
# Invocation contract: see scripts/install-methods/apt.sh.  Manifest
# fields under .install.github_release:
#   repo (org/name), asset_pattern, version, install_to,
#   sha256_x86_64, sha256_aarch64, gpg_fingerprint (opt),
#   extract_path (opt — relative path inside the tar to the binary).
#
# {arch} substitution in asset_pattern mirrors build-bundle.sh:176-181
# (uname -m mapping) so manifest authors use one canonical token.
# {version} substitution lets a track-latest entry build asset URLs
# from the GitHub-resolved tag without hard-coding the version into
# the pattern.

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
: "${LOCKFILE_PATH:=}"

get() { jq -r "$1 // empty" "$manifest_json"; }

repo="$(get '.install.github_release.repo')"
asset_pattern="$(get '.install.github_release.asset_pattern')"
version="$(get '.install.github_release.version')"
install_to="$(get '.install.github_release.install_to')"
gpg_fingerprint="$(get '.install.github_release.gpg_fingerprint')"
extract_path="$(get '.install.github_release.extract_path')"
app_name="$(get '.meta.name')"

# Pin mode controls whether we trust manifest version+sha (frozen) or
# resolve them at runtime from the GitHub Releases API (track-latest).
# Default to "frozen" — preserves Phase 0 behaviour when the field is
# absent or empty.
pin_mode="$(get '.pin.mode')"
[[ -z "$pin_mode" ]] && pin_mode="frozen"

# Required fields differ by pin mode.  In frozen mode the manifest must
# carry repo + asset_pattern + version + install_to.  In track-latest
# mode the manifest must carry repo + asset_pattern + install_to (the
# resolved version comes from GitHub).
case "$pin_mode" in
    frozen)
        for f in repo asset_pattern version install_to; do
            if [[ -z "${!f}" ]]; then
                err "manifest missing .install.github_release.$f (pin.mode=frozen)"
                emit "installed=false skipped_reason=manifest-incomplete"
                exit 1
            fi
        done
        ;;
    track-latest)
        for f in repo asset_pattern install_to; do
            if [[ -z "${!f}" ]]; then
                err "manifest missing .install.github_release.$f (pin.mode=track-latest)"
                emit "installed=false skipped_reason=manifest-incomplete"
                exit 1
            fi
        done
        ;;
    *)
        err "unsupported pin.mode for github-release: $pin_mode"
        emit "installed=false skipped_reason=bad-pin-mode"
        exit 1
        ;;
esac

[[ -z "$app_name" ]] && app_name="$(basename "$install_to")"

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

# ── Pin-mode-specific version + SHA resolution ────────────────────
# resolved_version  — the tag the asset URL targets (manifest in
#                     frozen mode, GitHub API in track-latest).
# expected_sha      — empty in track-latest (we compute at runtime);
#                     pinned manifest sha in frozen mode.
resolved_version=""
expected_sha=""

if [[ "$pin_mode" == "frozen" ]]; then
    resolved_version="$version"
    # Pick the per-arch SHA.  jq path is dynamic so we use --arg.
    expected_sha="$(jq -r --arg a "$arch_canonical" \
        '.install.github_release["sha256_" + $a] // empty' "$manifest_json")"
    if [[ -z "$expected_sha" ]]; then
        err "manifest missing sha256_$arch_canonical (pin.mode=frozen)"
        emit "installed=false skipped_reason=sha256-missing"
        exit 1
    fi
else
    # track-latest: query the unauthenticated GitHub Releases API for
    # /repos/<repo>/releases/latest and read tag_name.  Rate limit is
    # 60 req/hr per source IP; one interactive install hits this once.
    # We deliberately do NOT use jq for the response parse — python3
    # is already a hard dependency upstream and a single jq query
    # would still need defensive handling for missing fields.
    api_url="https://api.github.com/repos/${repo}/releases/latest"
    log "querying GitHub API for latest release: $api_url"
    api_response=""
    if ! api_response="$(curl --proto '=https' --tlsv1.2 -fsSL \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            "$api_url" 2>/dev/null)"; then
        err "GitHub API request failed for $repo (rate-limited? offline?)"
        emit "installed=false skipped_reason=api-fetch-failed"
        exit 2
    fi
    resolved_version="$(python3 -c '
import json, sys
try:
    data = json.loads(sys.argv[1])
except json.JSONDecodeError:
    sys.exit(0)
tag = data.get("tag_name")
if isinstance(tag, str):
    print(tag)
' "$api_response")"
    if [[ -z "$resolved_version" ]]; then
        err "could not parse tag_name from GitHub API response for $repo"
        emit "installed=false skipped_reason=api-parse-failed"
        exit 2
    fi
    # tag_name is attacker-controllable (anyone with push access to the
    # upstream repo can create arbitrary refs).  Constrain to the
    # characters GitHub permits in tags in practice; reject "..",
    # slashes, control chars, and shell metas defensively.  If this
    # ever rejects a real tag the maintainer can pin frozen and submit
    # an issue.  Limit to 128 chars so a pathological tag doesn't blow
    # up downstream argv length.
    if [[ ! "$resolved_version" =~ ^[A-Za-z0-9._+-]{1,128}$ ]]; then
        err "GitHub tag_name failed sanity check: $resolved_version"
        err "  expected: ^[A-Za-z0-9._+-]{1,128}$"
        emit "installed=false skipped_reason=bad-tag-name"
        exit 2
    fi
    log "resolved latest tag: $resolved_version"
fi

# Resolve placeholders in the asset pattern:
#   {arch}           → resolved CPU arch (x86_64 / aarch64)
#   {version}        → resolved tag verbatim (e.g. "v1.12.7")
#   {version_no_v}   → resolved tag with a leading 'v' stripped
#                      (e.g. "1.12.7").  Needed for projects whose tag
#                      is `vX.Y.Z` but whose asset filename uses just
#                      `X.Y.Z` (Joplin, Obsidian, many Go releases).
# Frozen entries that don't use any of these placeholders just pass
# through unchanged.
resolved_version_no_v="${resolved_version#v}"
resolved_asset="${asset_pattern//\{arch\}/$arch_canonical}"
resolved_asset="${resolved_asset//\{version\}/$resolved_version}"
resolved_asset="${resolved_asset//\{version_no_v\}/$resolved_version_no_v}"

asset_url="https://github.com/$repo/releases/download/$resolved_version/$resolved_asset"

# ── Already-installed short-circuit (frozen only) ─────────────────
# If the destination file's SHA already matches the pinned arch SHA,
# nothing to do.  In track-latest mode we have no manifest sha to
# compare against, so we'd have to download to know — at which point
# we may as well install.  Skipping the short-circuit in that mode is
# the simplest honest answer.
if [[ "$pin_mode" == "frozen" && -f "$install_to" ]]; then
    have_sha="$(sha256sum "$install_to" | awk '{print $1}')"
    if [[ "$have_sha" == "$expected_sha" ]]; then
        ok "$install_to already at pinned SHA"
        emit "installed=false skipped_reason=already-installed"
        exit 0
    fi
fi

if [[ "$DRY_RUN" == "1" ]]; then
    log "would download: $asset_url"
    if [[ -n "$expected_sha" ]]; then
        log "would verify sha256: $expected_sha"
    else
        log "would compute sha256 at runtime (pin.mode=track-latest)"
    fi
    if [[ -n "$gpg_fingerprint" ]]; then
        log "would gpg-verify against: $gpg_fingerprint"
    elif [[ "$pin_mode" == "track-latest" ]]; then
        log "no gpg_fingerprint pinned — HTTPS is the only integrity check"
    fi
    log "would install → $install_to"
    [[ -n "$LOCKFILE_PATH" ]] && log "[github-release] would write lockfile at $LOCKFILE_PATH"
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

# ── SHA-256 handling ──────────────────────────────────────────────
# Frozen mode: verify the manifest's pinned sha.  Mismatch = hard fail.
# Track-latest mode: compute the runtime sha (gets recorded in the
#   lockfile).  We have no manifest value to compare against; integrity
#   for this mode comes from HTTPS + optional GPG verification below.
if [[ "$pin_mode" == "frozen" ]]; then
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
    runtime_sha="$expected_sha"
else
    runtime_sha="$(sha256sum "$asset_file" | awk '{print $1}')"
    log "computed sha256: $runtime_sha (pin.mode=track-latest, no manifest pin to compare)"
fi

# ── Optional GPG verification ─────────────────────────────────────
# When the manifest pins a gpg_fingerprint we try `.sig` first then
# `.asc` since upstream conventions vary.  Missing sig + pinned
# fingerprint = hard fail (silently skipping would defeat the pin).
#
# We use gpg_verify_pinned from scripts/lib/gpg-helpers.sh — the same
# helper verify-pins.sh uses for its audit pass, so the install path
# and the audit path apply identical trust criteria.
#
# track-latest with NO gpg_fingerprint: log a warning that HTTPS is
# the only integrity check (matches the existing-behavior contract for
# unsigned releases like starship).
verified_by="sha256"
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
    # Source gpg-helpers.sh from the absolute REPO_DIR path so the
    # adapter works regardless of CWD or how it was invoked.  The
    # helper is sourced lazily here (post-download) so the static-only
    # pre-flight checks don't trigger a source error on misconfigured
    # boxes lacking the lib file.
    # shellcheck source=../lib/gpg-helpers.sh
    if ! source "${REPO_DIR}/scripts/lib/gpg-helpers.sh"; then
        err "could not source scripts/lib/gpg-helpers.sh"
        emit "installed=false skipped_reason=gpg-helpers-missing"
        exit 1
    fi
    sig_status=""
    sig_rc=0
    sig_status="$(gpg_verify_pinned "$sig_file" "$asset_file" "$gpg_fingerprint")" || sig_rc=$?
    if (( sig_rc != 0 )); then
        err "gpg verification failed: $sig_status"
        emit "installed=false skipped_reason=gpg-verify-failed"
        exit 1
    fi
    ok "gpg signature verified ($gpg_fingerprint)"
    verified_by="gpg-sig:${gpg_fingerprint}"
elif [[ "$pin_mode" == "track-latest" ]]; then
    warn "no gpg_fingerprint pinned for $repo — HTTPS is the only integrity check"
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
        # Defensive tar flags:
        #   --no-same-owner / --no-same-permissions
        #     don't restore archive's uid/gid/mode (would let a hostile
        #     tarball drop setuid bits in $workdir)
        #   --no-overwrite-dir
        #     refuse to clobber an existing directory's metadata
        #   --no-acls / --no-xattrs
        #     don't restore extended attributes (selinux contexts etc.)
        #   --restrict
        #     refuse to follow symlinks during extraction (newer tar);
        #     fall back gracefully on older tar via `|| true` is wrong
        #     since we'd then run with the unsafe defaults — instead we
        #     just omit --restrict and rely on the other flags.
        if ! tar --no-same-owner --no-same-permissions --no-overwrite-dir \
                 --no-acls --no-xattrs \
                 -xf "$asset_file" -C "$extract_dir" 2>&2; then
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

ok "$install_to installed (version $resolved_version)"

# ── Lockfile write ────────────────────────────────────────────────
# version  = resolved tag (manifest in frozen, GitHub API in track-latest)
# sha256   = runtime_sha (= expected_sha in frozen mode, computed sha in
#            track-latest mode)
# verified_by — "sha256" when no signature, "gpg-sig:FPR" when verified.
if [[ -n "$LOCKFILE_PATH" ]]; then
    # shellcheck source=../lib/lockfile.sh
    if ! source "${REPO_DIR}/scripts/lib/lockfile.sh"; then
        warn "could not source lockfile.sh — install succeeded but lockfile NOT written"
    elif ! lockfile_write \
            --path         "$LOCKFILE_PATH" \
            --name         "$app_name" \
            --method       "github-release" \
            --version      "$resolved_version" \
            --sha256       "$runtime_sha" \
            --install-path "$install_to" \
            --verified-by  "$verified_by" \
            --pin-mode     "$pin_mode"; then
        warn "lockfile_write failed — install succeeded but lockfile NOT written"
    fi
fi

emit "installed=true"
exit 0
