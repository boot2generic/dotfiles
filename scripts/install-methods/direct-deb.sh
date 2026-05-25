#!/usr/bin/env bash
# scripts/install-methods/direct-deb.sh
#
# Install-method adapter: fetch a pinned .deb URL, verify SHA-256,
# dpkg-install, fix-broken if dpkg leaves unsatisfied deps.
#
# Why a separate method from apt-pinned-repo: some upstreams (e.g.
# 1Password CLI, Slack, certain VPN clients) publish a .deb directly
# rather than running an apt repo.  Trading the repo's automatic
# upgrade story for a single pinned URL is acceptable when the
# version cadence is slow and the SHA is pinned by us.
#
# Pin-mode handling: direct-deb is FROZEN-ONLY by contract (the schema
# validator enforces this — track-latest would have no upstream to
# query without a release feed).  The lockfile records pin_mode =
# "frozen" unconditionally.
#
# Invocation contract: see scripts/install-methods/apt.sh.  LOCKFILE_PATH
# is honored same as the other adapters; the lockfile records the
# manifest version + sha256, plus verified_by = "sha256".
#
# Manifest fields under .install.direct_deb:
#   url, sha256, version.
# Optional: .install.package (else fall back to .meta.name) — used
# only for the already-installed dpkg check.
#
# Idempotency:
#   * `dpkg -s <pkg>` exposes both Status and Version; we compare the
#     installed Version against the manifest's `version` field.  If
#     it's >= we skip.  This matters because re-installing the same
#     .deb runs maintainer scripts again (which can break Slack /
#     1Password's keyring integration).

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
for tool in curl sha256sum dpkg; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        err "$tool not on PATH — required for direct-deb method"
        emit "installed=false skipped_reason=${tool}-missing"
        exit 1
    fi
done

: "${DRY_RUN:=0}"
: "${REPO_DIR:=}"
: "${DOTFILES_MACHINE:=}"
: "${LOCKFILE_PATH:=}"

get() { jq -r "$1 // empty" "$manifest_json"; }

url="$(get '.install.direct_deb.url')"
expected_sha="$(get '.install.direct_deb.sha256')"
version="$(get '.install.direct_deb.version')"
package="$(get '.install.package')"
[[ -z "$package" ]] && package="$(get '.meta.name')"

# Lockfile NAME tracks the manifest's meta.name so apps-cli.sh can find
# the .lock by app key (which may differ from the .deb's Package field).
app_name="$(get '.meta.name')"
[[ -z "$app_name" ]] && app_name="$package"

for f in url expected_sha version package; do
    if [[ -z "${!f}" ]]; then
        err "manifest missing direct_deb field: $f"
        emit "installed=false skipped_reason=manifest-incomplete"
        exit 1
    fi
done

# ── Already-installed short-circuit ───────────────────────────────
# `dpkg --compare-versions A ge B` returns 0 when A>=B; this is the
# canonical dpkg-aware way to compare debian version strings (handles
# epochs, ~rc suffixes, etc. correctly — string comparison would not).
if installed_version="$(dpkg -s "$package" 2>/dev/null \
        | awk '/^Status: install ok installed/{ok=1} /^Version:/{v=$2} END{if(ok)print v}')"; then
    if [[ -n "$installed_version" ]] \
        && dpkg --compare-versions "$installed_version" ge "$version"; then
        ok "$package $installed_version already installed (>= $version)"
        emit "installed=false skipped_reason=already-installed"
        exit 0
    fi
fi

if [[ "$DRY_RUN" == "1" ]]; then
    log "would download: $url"
    log "would verify sha256: $expected_sha"
    log "would: sudo dpkg -i <downloaded.deb>"
    log "would: sudo apt-get install -y --fix-broken (if dpkg reports deps)"
    [[ -n "$LOCKFILE_PATH" ]] && log "[direct-deb] would write lockfile at $LOCKFILE_PATH"
    emit "installed=false skipped_reason=dry-run"
    exit 0
fi

workdir="$(mktemp -d -t direct-deb.XXXXXX)"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT INT TERM

# Use the URL's basename for a tidy filename; fall back to package.deb
# if the URL has query strings or trailing slashes.
deb_basename="$(basename "${url%%\?*}")"
[[ "$deb_basename" == *.deb ]] || deb_basename="${package}.deb"
deb_file="$workdir/$deb_basename"

log "downloading $url"
if ! curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$deb_file"; then
    err "download failed: $url"
    emit "installed=false skipped_reason=download-failed"
    exit 2
fi

log "verifying sha256 …"
if ! echo "$expected_sha  $deb_file" | sha256sum -c - >/dev/null 2>&1; then
    actual_sha="$(sha256sum "$deb_file" | awk '{print $1}')"
    err "sha256 mismatch"
    err "  expected: $expected_sha"
    err "  actual:   $actual_sha"
    emit "installed=false skipped_reason=sha256-mismatch"
    exit 1
fi
ok "sha256 verified"

# ── Install ───────────────────────────────────────────────────────
# Two-step pattern: dpkg -i first (so we know whether dependency
# breakage actually happened — apt install ./file.deb would mask it).
# On dep failure, apt-get install --fix-broken pulls deps from the
# regular apt sources.  This works because dpkg -i has already left
# the package in "iU" (unpacked, deps unmet) state, which fix-broken
# recognises.
log "dpkg -i $deb_file"
installed_ok=0
if sudo dpkg -i "$deb_file" >&2; then
    ok "$package installed via dpkg"
    installed_ok=1
else
    # dpkg -i failed — most likely dependency problem.  Try fix-broken
    # exactly once (not in a loop — repeated failure indicates something
    # else and we'd rather surface that than spin).
    warn "dpkg reported issues — running apt-get install --fix-broken"
    if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-broken >&2; then
        # Re-check: did fix-broken leave the package configured?
        if dpkg -s "$package" 2>/dev/null | grep -q '^Status: install ok installed'; then
            ok "$package installed (after fix-broken)"
            installed_ok=1
        fi
    fi
fi

if (( ! installed_ok )); then
    err "dpkg + fix-broken both failed for $package"
    emit "installed=false skipped_reason=dpkg-error"
    exit 2
fi

# ── Lockfile write ────────────────────────────────────────────────
# direct-deb is frozen-by-contract; record the manifest version + sha
# verbatim (these were just verified pre-install).  install_path is
# empty: a .deb installs to system locations dpkg controls, not a
# single repo-tracked path.
if [[ -n "$LOCKFILE_PATH" ]]; then
    # shellcheck source=../lib/lockfile.sh
    if ! source "${REPO_DIR}/scripts/lib/lockfile.sh"; then
        warn "could not source lockfile.sh — install succeeded but lockfile NOT written"
    elif ! lockfile_write \
            --path         "$LOCKFILE_PATH" \
            --name         "$app_name" \
            --method       "direct-deb" \
            --version      "$version" \
            --sha256       "$expected_sha" \
            --install-path "" \
            --verified-by  "sha256" \
            --pin-mode     "frozen"; then
        warn "lockfile_write failed — install succeeded but lockfile NOT written"
    fi
fi

emit "installed=true"
exit 0
