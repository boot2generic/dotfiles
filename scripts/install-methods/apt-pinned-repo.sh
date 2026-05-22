#!/usr/bin/env bash
# scripts/install-methods/apt-pinned-repo.sh
#
# Phase 0 install-method adapter: install a package from a pinned
# third-party apt repo (e.g. Docker, Tailscale, signal-desktop).
#
# Why this exists separate from apt.sh: third-party repos require a
# pinned signing key AND a sources.list entry, and the right answer
# for security is to ship both as repo-tracked files (under
# config/system/etc/apt/) instead of curl|sh'ing them at install time.
# The manifest names the files; this adapter:
#   1. Verifies the keyring fingerprint matches what the manifest pins.
#   2. Installs keyring + sources file to /etc/apt/.
#   3. Refreshes ONLY that source (-o Dir::Etc::sourcelist=...) so a
#      bad key error doesn't poison the whole apt cache.
#   4. apt-get install -y --no-install-recommends <package>.
#
# Invocation contract — see scripts/install-methods/apt.sh for the
# shared adapter spec; only the .install.apt_pinned_repo.* fields
# differ.
#
# Files read from the repo:
#   $REPO_DIR/config/system/etc/apt/keyrings/<keyring_file>
#   $REPO_DIR/config/system/etc/apt/sources.list.d/<sources_file>
# Both are agent A's territory; we read them but never write them.

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

: "${DRY_RUN:=0}"
: "${REPO_DIR:?REPO_DIR env var must be set to the dotfiles repo root}"
: "${DOTFILES_MACHINE:=}"

# Resolve a single jq path with a friendly error message on missing key.
get() {
    local q="$1" v
    v="$(jq -r "$q // empty" "$manifest_json")"
    printf '%s' "$v"
}

package="$(get '.install.apt_pinned_repo.package')"
key_fingerprint="$(get '.install.apt_pinned_repo.key_fingerprint')"
keyring_file="$(get '.install.apt_pinned_repo.keyring_file')"
sources_file="$(get '.install.apt_pinned_repo.sources_file')"

# All four are required.  suite_url/suite/components/key_url are
# *documented* in the manifest for human auditors but only the
# fingerprint + filenames matter at install time — the actual repo
# definition lives in the deployed sources.list file.
for f in package key_fingerprint keyring_file sources_file; do
    if [[ -z "${!f}" ]]; then
        err "manifest missing .install.apt_pinned_repo.$f"
        emit "installed=false skipped_reason=manifest-incomplete"
        exit 1
    fi
done

keyring_src="$REPO_DIR/config/system/etc/apt/keyrings/$keyring_file"
sources_src="$REPO_DIR/config/system/etc/apt/sources.list.d/$sources_file"

if [[ ! -f "$keyring_src" ]]; then
    err "keyring source missing: $keyring_src"
    emit "installed=false skipped_reason=keyring-missing"
    exit 1
fi
if [[ ! -f "$sources_src" ]]; then
    err "sources source missing: $sources_src"
    emit "installed=false skipped_reason=sources-missing"
    exit 1
fi

# ── Fingerprint verification ──────────────────────────────────────
# gpg --import-options show-only --import never writes to the user's
# keyring — it just parses the file and emits colon-delimited records.
# We look at the "fpr:" record for the primary key.  Normalise both
# sides by stripping whitespace + uppercasing so "  ab cd" vs "ABCD"
# don't trip us up.  A mismatch is a hard fail — refusing to install
# protects against a rogue commit that replaces keyrings/<file>.asc
# with an attacker-controlled key.
if ! command -v gpg >/dev/null 2>&1; then
    err "gpg not on PATH — cannot verify keyring fingerprint"
    emit "installed=false skipped_reason=gpg-missing"
    exit 1
fi

# gpg exits non-zero on a malformed/empty keyring; combined with
# `set -o pipefail` the assignment would abort the script before we
# could emit a friendly error.  Use `|| true` on the gpg side so the
# pipeline always reports awk's status, then check for empty output.
actual_fpr="$( { gpg --with-colons --import-options show-only --import \
                     < "$keyring_src" 2>/dev/null || true; } \
              | awk -F: '$1=="fpr"{print $10; exit}')"
expected_fpr="$(printf '%s' "$key_fingerprint" | tr -d ' \t\n' | tr 'a-f' 'A-F')"
actual_fpr_norm="$(printf '%s' "$actual_fpr" | tr -d ' \t\n' | tr 'a-f' 'A-F')"

if [[ -z "$actual_fpr_norm" ]]; then
    err "could not parse fingerprint from $keyring_src"
    emit "installed=false skipped_reason=fingerprint-unparseable"
    exit 1
fi
if [[ "$actual_fpr_norm" != "$expected_fpr" ]]; then
    err "keyring fingerprint mismatch"
    err "  expected: $expected_fpr"
    err "  actual:   $actual_fpr_norm"
    emit "installed=false skipped_reason=fingerprint-mismatch"
    exit 1
fi
ok "keyring fingerprint verified: $actual_fpr_norm"

# Already-installed short-circuit happens AFTER fingerprint check so
# we catch a rotated upstream key on every run, not just first install.
if dpkg -s "$package" 2>/dev/null | grep -q '^Status: install ok installed'; then
    ok "$package already installed"
    emit "installed=false skipped_reason=already-installed"
    exit 0
fi

if [[ "$DRY_RUN" == "1" ]]; then
    log "would install keyring → /etc/apt/keyrings/$keyring_file"
    log "would install sources → /etc/apt/sources.list.d/$sources_file"
    log "would: sudo apt-get update (this source only)"
    log "would: sudo apt-get install -y --no-install-recommends $package"
    emit "installed=false skipped_reason=dry-run"
    exit 0
fi

# Deploy the pinned files.  Mode 0644 — both files must be readable by
# the _apt user when apt fetches indexes.
log "deploying keyring → /etc/apt/keyrings/$keyring_file"
sudo install -D -m 0644 "$keyring_src" "/etc/apt/keyrings/$keyring_file"

log "deploying sources → /etc/apt/sources.list.d/$sources_file"
sudo install -D -m 0644 "$sources_src" "/etc/apt/sources.list.d/$sources_file"

# Template substitution: sources files often reference the running
# release with a `$(distro_codename)` placeholder so the same file
# works on bookworm, trixie, jammy, noble, etc.  Replace AFTER the
# install so the repo-tracked file stays portable.
if grep -q '\$(distro_codename)' "/etc/apt/sources.list.d/$sources_file"; then
    # shellcheck disable=SC1091
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    if [[ -z "$codename" ]]; then
        err "sources file references \$(distro_codename) but /etc/os-release has no VERSION_CODENAME"
        emit "installed=false skipped_reason=codename-missing"
        exit 1
    fi
    sudo sed -i "s/\$(distro_codename)/${codename}/g" \
        "/etc/apt/sources.list.d/$sources_file"
    ok "substituted \$(distro_codename) → $codename"
fi

# Refresh ONLY this repo to surface key errors before we trust the
# rest of apt.  Dir::Etc::sourceparts="-" disables the dir-scan;
# Dir::Etc::sourcelist points at the single file.  APT::Get::List-
# Cleanup=0 keeps OTHER repos' cached indexes intact.
log "apt-get update (this source only) …"
if ! sudo apt-get update -qq \
        -o Dir::Etc::sourceparts="-" \
        -o APT::Get::List-Cleanup="0" \
        -o Dir::Etc::sourcelist="sources.list.d/$sources_file" >&2; then
    err "apt-get update failed for $sources_file — key/repo problem"
    emit "installed=false skipped_reason=apt-update-failed"
    exit 1
fi
ok "repo index refreshed"

log "apt-get install $package …"
if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends "$package" >&2; then
    ok "$package installed from pinned repo"
    emit "installed=true"
    exit 0
else
    err "apt-get install $package failed (after successful repo refresh)"
    emit "installed=false skipped_reason=apt-error"
    exit 2
fi
