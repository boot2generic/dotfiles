#!/usr/bin/env bash
# scripts/install-methods/apt.sh
#
# Install-method adapter: plain "sudo apt install <package>".
#
# Invocation (from dispatcher):
#   DOTFILES_MACHINE=<profiles> DRY_RUN=<0|1> REPO_DIR=<abs-path> \
#       LOCKFILE_PATH=<abs-path-to-lockfile> \
#       scripts/install-methods/apt.sh <parsed-manifest-json>
#
# Reads .install.package (preferred) or .meta.name (fallback) from the
# manifest JSON.  Idempotent — re-running on an already-installed
# package is a no-op that exits 0 with installed=false.
#
# Pin-mode handling: apt ALWAYS tracks latest (the OS package manager
# manages versions).  pin.mode is recorded in the lockfile for audit
# purposes but does not change install behaviour.
#
# Output contract:
#   stdout: ONE line — "installed=true" or
#           "installed=false skipped_reason=<token>"
#   stderr: human-readable progress
# Exit codes: 0 success/skip, 1 pre-flight failure, 2 install error.
#
# Lockfile: written on successful install only.  Records the actually-
# installed version from dpkg-query (not whatever the manifest declares).
# DRY_RUN=1 prints "would write lockfile at $LOCKFILE_PATH" and skips
# the write.
#
# Sudo handling: local_setup.sh:ensure_sudo primes the cache at the
# outer flow, so we just call `sudo` directly without re-prompting.

set -euo pipefail

# ── Colour helpers (copy of build-bundle.sh:59-68; deliberate to keep
# each adapter standalone — see manifest "Adapters MUST be standalone").
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

# Emit the single machine-readable stdout line.  Funnel ALL such writes
# through this helper so the contract is impossible to break by accident.
emit() { printf '%s\n' "$*"; }

manifest_json="${1:-}"
if [[ -z "$manifest_json" || ! -r "$manifest_json" ]]; then
    err "manifest JSON path missing or unreadable: ${manifest_json:-<unset>}"
    emit "installed=false skipped_reason=bad-args"
    exit 1
fi

# Defensive jq check — dispatcher will pre-flight this later but the
# adapter shouldn't core-dump on a fresh box where jq isn't installed.
if ! command -v jq >/dev/null 2>&1; then
    err "jq not on PATH — required to parse manifest JSON"
    emit "installed=false skipped_reason=jq-missing"
    exit 1
fi

: "${DRY_RUN:=0}"
: "${REPO_DIR:=}"
: "${DOTFILES_MACHINE:=}"
: "${LOCKFILE_PATH:=}"

# install.package wins; fall back to meta.name so simple apps don't
# need to duplicate the package field.
package="$(jq -r '.install.package // .meta.name // ""' "$manifest_json")"
if [[ -z "$package" || "$package" == "null" ]]; then
    err "manifest missing both .install.package and .meta.name"
    emit "installed=false skipped_reason=manifest-incomplete"
    exit 1
fi

# Manifest-level name (used as the lockfile NAME).  Falls back to
# the apt package if the dispatcher omitted meta.name.
app_name="$(jq -r '.meta.name // ""' "$manifest_json")"
[[ -z "$app_name" || "$app_name" == "null" ]] && app_name="$package"

# pin.mode is informational for apt (apt manages versions); default to
# track-latest when the manifest omits it.  Recorded verbatim in the
# lockfile so `apps-cli.sh status` can render the manifest's stated mode.
pin_mode="$(jq -r '.pin.mode // "track-latest"' "$manifest_json")"
[[ "$pin_mode" == "null" || -z "$pin_mode" ]] && pin_mode="track-latest"

# Already-installed short-circuit — `dpkg -s` is faster than apt and
# doesn't need network.  The exact "Status: install ok installed" line
# is the canonical marker; "deinstall ok config-files" etc. don't count.
if dpkg -s "$package" 2>/dev/null | grep -q '^Status: install ok installed'; then
    ok "$package already installed"
    emit "installed=false skipped_reason=already-installed"
    exit 0
fi

if [[ "$DRY_RUN" == "1" ]]; then
    log "would install: apt install $package"
    [[ -n "$LOCKFILE_PATH" ]] && log "[apt] would write lockfile at $LOCKFILE_PATH"
    emit "installed=false skipped_reason=dry-run"
    exit 0
fi

log "apt-get install $package …"
# --no-install-recommends keeps the system lean — declared deps only.
# DEBIAN_FRONTEND=noninteractive avoids any debconf prompts that would
# wedge an automated install.
if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends "$package" >&2; then
    err "apt-get install $package failed"
    emit "installed=false skipped_reason=apt-error"
    exit 2
fi
ok "$package installed via apt"

# ── Lockfile write ────────────────────────────────────────────────
# dpkg-query reports the actually-installed Version field; this is the
# source of truth (NOT the manifest, which carries no version for apt).
# If the query fails — should never happen right after a successful
# install but defensive — fall back to empty string so the lockfile
# still records "we installed this on date X" even without version.
if [[ -n "$LOCKFILE_PATH" ]]; then
    installed_version="$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)"
    # shellcheck source=../lib/lockfile.sh
    if ! source "${REPO_DIR}/scripts/lib/lockfile.sh"; then
        warn "could not source lockfile.sh — install succeeded but lockfile NOT written"
    elif ! lockfile_write \
            --path         "$LOCKFILE_PATH" \
            --name         "$app_name" \
            --method       "apt" \
            --version      "$installed_version" \
            --sha256       "" \
            --install-path "" \
            --verified-by  "apt-archive" \
            --pin-mode     "$pin_mode"; then
        warn "lockfile_write failed — install succeeded but lockfile NOT written"
    fi
fi

emit "installed=true"
exit 0
