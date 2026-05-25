#!/usr/bin/env bash
# scripts/refresh-pins.sh
#
# Pull upstream metadata for every [[apps]] pin under config/apps/,
# verify what we can, and rewrite each pin's `last_refreshed` (and
# SHA/version for github-release frozen mode) back into the TOML in
# place.  NEVER commits.  NEVER auto-prompts.  Designed to be
# cron-driven; --quiet exists so a successful run produces zero output.
#
# Discovery is identical to install-apps.sh / verify-pins.sh: walk
# every .toml under config/apps/ that contains a top-level [[apps]]
# array (skipping schema*.toml, _*.toml, .*.toml).  Files without
# [[apps]] are silently skipped (room for future tier-split files
# such as core.toml / desktop.toml).
#
# Per-method semantics:
#   apt              skipped — no pin to refresh.
#   apt-pinned-repo  run `apt-get update` scoped to ONLY this app's
#                    sources file + keyring.  If apt accepts the
#                    signed Release file, the pinned key is still
#                    trusted upstream → bump last_refreshed only.
#                    If apt rejects it, the upstream key likely
#                    rotated; we log a CRITICAL warning and DO NOT
#                    bump the date (the next run will keep flagging
#                    until refresh-keys.sh is run by a human).
#   github-release   GET https://api.github.com/repos/<repo>/releases/latest
#                    pin.mode behaviour:
#                      track-latest → always bump last_refreshed.
#                      frozen + tag == version → bump last_refreshed only.
#                      frozen + tag != version → REFUSE to auto-rewrite.
#                          Print a clear message saying the equivalent
#                          track-latest mode would auto-bump but frozen
#                          requires manual review (with the new tag).
#   direct-deb       HEAD the pinned URL.  If 2xx, bump last_refreshed
#                    (the URL is alive).  Non-2xx is an error — don't
#                    bump.  We can't re-derive sha/version without
#                    re-downloading; manual editing required for that.
#
# Why we no longer auto-rewrite SHAs on a frozen tag bump:
#   Refreshing a SHA after a real upstream version bump should be
#   reviewed by a human (release notes, breaking-changes scan).  This
#   script intentionally stops at the date-bump step so the user sees
#   a clean `git diff` before committing.  track-latest mode signals
#   "I want this to follow upstream"; frozen mode signals "I've
#   audited this exact version".  We honour both.
#
# pin.mode behaviour summary:
#   "track-latest"   bump last_refreshed unconditionally (after the
#                    upstream-liveness probe succeeds).
#   "frozen"         bump last_refreshed if upstream still matches the
#                    pinned version; refuse to mutate the pinned
#                    version/sha automatically.
#
# Writing back to apps.toml requires comment/format preservation —
# the file ships hand-curated section headers and per-entry comments.
# We use python3-tomlkit for round-tripping.  If tomlkit is not
# importable we abort with a clear install hint rather than fall back
# to a naive str-replace that would corrupt the file.
#
# Usage:
#   ./scripts/refresh-pins.sh                       # all apps
#   ./scripts/refresh-pins.sh --app NAME
#   ./scripts/refresh-pins.sh --method github-release
#   ./scripts/refresh-pins.sh --dry-run
#   ./scripts/refresh-pins.sh --quiet               # cron
#   ./scripts/refresh-pins.sh --help

set -euo pipefail

if [[ -t 1 ]]; then
    C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'
    C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
    C_OK= ; C_WARN= ; C_ERR= ; C_DIM= ; C_RST=
fi

QUIET=0
log()  { [[ $QUIET -eq 1 ]] || echo "${C_DIM}[*]${C_RST} $*" >&2; }
ok()   { [[ $QUIET -eq 1 ]] || echo "${C_OK}[ok]${C_RST} $*" >&2; }
warn() { echo "${C_WARN}[!]${C_RST} $*" >&2; }
err()  { echo "${C_ERR}[!!]${C_RST} $*" >&2; }
die()  { err "$*"; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APPS_DIR="${REPO_DIR}/config/apps"
KEYRINGS_DIR="${REPO_DIR}/config/system/etc/apt/keyrings"
SOURCES_DIR="${REPO_DIR}/config/system/etc/apt/sources.list.d"

VALIDATOR="${SCRIPT_DIR}/apps-validate.py"

DRY_RUN=0
ONLY_APP=""
ONLY_METHOD=""
NO_VALIDATE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)         ;;
        --app)         ONLY_APP="${2:-}";    [[ -z "$ONLY_APP" ]]    && die "--app requires a name"; shift ;;
        --method)      ONLY_METHOD="${2:-}"; [[ -z "$ONLY_METHOD" ]] && die "--method requires a value"; shift ;;
        --dry-run)     DRY_RUN=1 ;;
        --quiet)       QUIET=1 ;;
        --no-validate) NO_VALIDATE=1 ;;
        -h|--help)     sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             die "Unknown flag: $1 (try --help)" ;;
    esac
    shift
done

command -v python3 >/dev/null 2>&1 || die "python3 missing"
command -v curl    >/dev/null 2>&1 || warn "curl missing — github-release / direct-deb refresh will fail"
command -v gpg     >/dev/null 2>&1 || warn "gpg missing — apt-pinned-repo fingerprint checks will fail"

# ── Pre-flight validator gate ──────────────────────────────────────
# Mirrors install-apps.sh / verify-pins.sh; refuse to refresh a
# manifest the schema validator rejects.  See scripts/lib/validator-gate.sh.
# shellcheck source=lib/validator-gate.sh
source "${SCRIPT_DIR}/lib/validator-gate.sh"
if ! run_apps_validator "$VALIDATOR" "$REPO_DIR" "$NO_VALIDATE"; then
    exit 1
fi

# ── Shared GPG helpers ─────────────────────────────────────────────
# fingerprint_of() is identical to verify-pins.sh's; sourcing the lib
# keeps the trust model consistent — if the two ever drift, an attacker
# who edits the repo could land a "passes-refresh, fails-verify" state.
# shellcheck source=lib/gpg-helpers.sh
source "${SCRIPT_DIR}/lib/gpg-helpers.sh"

# ── tomlkit gate
#
# Rewriting apps.toml in place requires comment/whitespace preservation
# (the file ships hand-curated section headers and per-entry rationales
# that a naive str-replace heuristic would silently destroy when it
# can't anchor a key inside the array-of-tables shape).  We rely on
# python3-tomlkit; if it's not installed, bail with a clean error
# rather than fall back to a destructive strategy.
#
# Skipping the gate in --dry-run is intentional: --dry-run prints the
# planned changes without touching disk, so tomlkit is not strictly
# required.  We still warn so the user knows a real run would fail.
if ! python3 -c 'import tomlkit' >/dev/null 2>&1; then
    if [[ $DRY_RUN -eq 1 ]]; then
        warn "python3-tomlkit not installed — a real (non-dry-run) refresh will fail"
        warn "  install with: sudo apt install python3-tomlkit"
    else
        err "python3-tomlkit not installed; cannot rewrite apps.toml without destroying comments."
        err "  install with: sudo apt install python3-tomlkit"
        err "  (then re-run setup, or 'apt update && apt install python3-tomlkit')"
        exit 1
    fi
fi

TODAY=$(date +%Y-%m-%d)
TMPROOT=""
cleanup() { [[ -n "$TMPROOT" && -d "$TMPROOT" ]] && rm -rf "$TMPROOT"; }
trap cleanup EXIT
TMPROOT=$(mktemp -d -t refresh-pins.XXXXXX)

# ── Schema-v2 manifest discovery
#
# Mirrors install-apps.sh::load_entries() / verify-pins.sh::load_entries().
# Emits TSV: <source_file>\t<entry_index>\t<entry_json>.  Files without
# a top-level [[apps]] array are silently skipped.
load_entries() {
    [[ -d "$APPS_DIR" ]] || return 0
    local f base
    local files=""
    for f in "$APPS_DIR"/*.toml; do
        [[ -e "$f" ]] || continue
        base="$(basename "$f")"
        case "$base" in
            schema*.toml) continue ;;
            _*.toml)      continue ;;
            .*)           continue ;;
        esac
        files+="$f"$'\n'
    done
    [[ -n "$files" ]] || return 0
    APPS_FILES="$files" python3 - <<'PY'
import json
import os
import sys
import tomllib
from pathlib import Path

paths = [Path(line) for line in os.environ.get("APPS_FILES", "").splitlines() if line.strip()]
for p in paths:
    try:
        with open(p, "rb") as fh:
            data = tomllib.load(fh)
    except (tomllib.TOMLDecodeError, OSError, UnicodeDecodeError) as exc:
        print(f"# WARN unparseable {p}: {exc}", file=sys.stderr)
        continue
    apps = data.get("apps")
    if not isinstance(apps, list):
        continue
    for idx, entry in enumerate(apps):
        if not isinstance(entry, dict):
            continue
        sys.stdout.write(
            f"{p}\t{idx}\t{json.dumps(entry, separators=(',', ':'))}\n"
        )
PY
}

# Extract a JSON value via Python — keeps the script jq-free.
# Usage: json_get '<json>' '<dotted.path>'  → prints value or empty.
json_get() {
    local json="$1" path="$2"
    python3 -c '
import json, sys
data = json.loads(sys.argv[1])
for key in sys.argv[2].split("."):
    if isinstance(data, dict) and key in data:
        data = data[key]
    else:
        sys.exit(0)
if isinstance(data, (list, tuple)):
    print(" ".join(str(x) for x in data))
elif isinstance(data, bool):
    print("true" if data else "false")
else:
    print(data if data is not None else "")
' "$json" "$path"
}

# ── TOML write via tomlkit — comment/whitespace-preserving in-place
# rewrite of one field inside one [[apps]] entry.
#
# Args:
#   $1 path   — absolute path to the apps.toml-shaped file to mutate
#   $2 idx    — 0-based entry index within that file's `apps` list
#   $3 dotted — dotted path inside the entry, e.g.:
#                   "pin.last_refreshed"
#                   "install.github_release.version"
#                   "install.github_release.sha256_x86_64"
#   $4 value  — new STRING value (quoting handled inside the writer)
#
# Notes on tomlkit semantics:
#   • Reading and writing must go through the same Document so trivia
#     (comments, whitespace) is preserved.  We re-parse on every call —
#     fine for refresh-pins because it touches at most a handful of
#     fields per apps.toml file.
#   • tomlkit's __setitem__ replaces the value-node in-place, keeping
#     surrounding trivia (the inline `#` comment to the right of the
#     value).
toml_set() {
    local path="$1" idx="$2" dotted="$3" newval="$4"
    if [[ $DRY_RUN -eq 1 ]]; then
        log "  would set apps[${idx}].${dotted} = \"${newval}\" in $(basename "$path")"
        return 0
    fi
    python3 - "$path" "$idx" "$dotted" "$newval" <<'PY'
import sys
import pathlib

try:
    import tomlkit
except ImportError:
    # The bash-side gate should have caught this; re-print here as a
    # belt-and-braces guard so a corrupted environment fails loudly.
    sys.stderr.write("toml_set: python3-tomlkit not importable\n")
    sys.exit(2)

path = pathlib.Path(sys.argv[1])
idx = int(sys.argv[2])
dotted = sys.argv[3]
newval = sys.argv[4]

doc = tomlkit.parse(path.read_text())

apps = doc.get("apps")
if apps is None or not isinstance(apps, list) or idx >= len(apps):
    sys.stderr.write(f"toml_set: apps[{idx}] missing in {path}\n")
    sys.exit(3)
entry = apps[idx]

# Walk the dotted path, creating intermediate tables only if they
# already exist (we never invent a new sub-table — the schema gates
# that).  Last segment is the leaf we rewrite.
parts = dotted.split(".")
node = entry
for p in parts[:-1]:
    if p not in node:
        sys.stderr.write(f"toml_set: intermediate '{p}' missing under apps[{idx}] in {path}\n")
        sys.exit(4)
    node = node[p]
leaf = parts[-1]
if leaf not in node:
    sys.stderr.write(f"toml_set: leaf '{leaf}' missing under apps[{idx}].{'.'.join(parts[:-1])} in {path}\n")
    sys.exit(5)

# Assign as a tomlkit string so the existing inline comment (if any)
# stays attached to the key-value line.
node[leaf] = newval

path.write_text(tomlkit.dumps(doc))
PY
}

# ── Per-method refresh handlers.
#
# Each sets REFRESH_OUTCOME to one of:
#   bumped         last_refreshed date was advanced; no version change.
#   skipped        nothing to do (apt method, frozen-pin upstream drift, etc.)
#   failed         upstream rejected / network / sha mismatch.
# and REFRESH_NOTE to a human-readable one-liner.
#
# No "updated" outcome by design — we never auto-rewrite version/sha
# on a frozen tag bump.  The user reviews the drift and edits the
# manifest by hand (or flips pin.mode to track-latest).

refresh_apt() {
    REFRESH_OUTCOME="skipped"
    REFRESH_NOTE="no pin to refresh (apt method)"
}

refresh_apt_pinned_repo() {
    local name="$1" path="$2" idx="$3"
    local kf="${KEYRINGS_DIR}/${APR_KEYRING_FILE}"
    local sf="${SOURCES_DIR}/${APR_SOURCES_FILE}"

    if [[ ! -r "$kf" || ! -r "$sf" ]]; then
        REFRESH_OUTCOME="failed"
        REFRESH_NOTE="missing keyring or sources file"
        return
    fi

    # ── Manifest-pin re-anchor BEFORE we trust the on-disk keyring.
    # verify-pins.sh does the same check; without it here, a refresh
    # would happily apt-get update against a keyring whose fingerprint
    # has drifted from the manifest pin (an attacker who can rewrite
    # the on-disk keyring file but not apps.toml could otherwise
    # silently bump last_refreshed against an unpinned key).  Refuse
    # outright on mismatch — the user must reconcile via the
    # refresh-keys workflow before this method's refresh runs again.
    if [[ -z "$APR_KEY_FINGERPRINT" ]]; then
        REFRESH_OUTCOME="failed"
        REFRESH_NOTE="install.apt_pinned_repo.key_fingerprint unset (validator should have caught this)"
        return
    fi
    local on_disk_fpr
    on_disk_fpr="$(fingerprint_of "$kf" || true)"
    if [[ -z "$on_disk_fpr" ]]; then
        REFRESH_OUTCOME="failed"
        REFRESH_NOTE="could not read fingerprint from on-disk keyring ${APR_KEYRING_FILE}"
        return
    fi
    if [[ "${on_disk_fpr^^}" != "${APR_KEY_FINGERPRINT^^}" ]]; then
        err "${name}: on-disk keyring fingerprint does not match manifest pin"
        err "  on-disk:  ${on_disk_fpr}"
        err "  manifest: ${APR_KEY_FINGERPRINT}"
        err "  refusing to refresh until reconciled (run refresh-keys.sh --app ${name})"
        REFRESH_OUTCOME="failed"
        REFRESH_NOTE="on-disk keyring fingerprint != manifest pin"
        return
    fi

    # Build an isolated apt environment so we can validate THIS repo's
    # signed Release file without polluting the system apt state or
    # depending on what's already in /etc/apt.  The flags Dir::Etc::*
    # point apt at our repo's files; lists go into a tmp dir so we
    # don't write to /var.  --no-allow-insecure-repositories is the
    # default but we set it explicitly so a future apt version that
    # weakens that default still rejects an unsigned Release.
    local tmpd; tmpd="$(mktemp -d -p "$TMPROOT" apt.XXXX)"
    mkdir -p "$tmpd/lists/partial" "$tmpd/cache" "$tmpd/sources.list.d" "$tmpd/keyrings"
    cp -- "$sf" "$tmpd/sources.list.d/"
    cp -- "$kf" "$tmpd/keyrings/"

    if [[ $DRY_RUN -eq 1 ]]; then
        REFRESH_OUTCOME="skipped"
        REFRESH_NOTE="dry-run: would apt-get update against ${APR_SOURCES_FILE}"
        return
    fi

    # We can't talk to sudo from a cron job without NOPASSWD; apt-get
    # update without root can run with these Dir overrides as long as
    # the lists/ dir is writable.  No-cache flag avoids stale results.
    if apt-get update -qq \
            -o "Dir::Etc::SourceParts=${tmpd}/sources.list.d" \
            -o "Dir::Etc::SourceList=/dev/null" \
            -o "Dir::Etc::TrustedParts=${tmpd}/keyrings" \
            -o "Dir::Etc::Trusted=/dev/null" \
            -o "Dir::State::Lists=${tmpd}/lists" \
            -o "Dir::Cache=${tmpd}/cache" \
            -o "APT::Get::List-Cleanup=0" \
            -o "Acquire::AllowInsecureRepositories=false" \
            -o "Acquire::AllowDowngradeToInsecureRepositories=false" \
            >/dev/null 2>"${tmpd}/err"; then
        toml_set "$path" "$idx" "pin.last_refreshed" "$TODAY"
        REFRESH_OUTCOME="bumped"
        REFRESH_NOTE="apt-get update verified the pinned key"
    else
        REFRESH_OUTCOME="failed"
        REFRESH_NOTE="apt-get update FAILED — upstream key may have rotated (run refresh-keys.sh --app ${name})"
        # Echo the apt error so the cron mail shows it.
        [[ $QUIET -eq 1 ]] || sed 's/^/      | /' "${tmpd}/err" >&2 || true
    fi
}

refresh_github_release() {
    local name="$1" path="$2" idx="$3"
    if [[ -z "$GH_REPO" ]]; then
        REFRESH_OUTCOME="failed"; REFRESH_NOTE="install.github_release.repo unset"
        return
    fi
    local api="https://api.github.com/repos/${GH_REPO}/releases/latest"
    local body; body="$(curl -fsSL --max-time 30 -H "Accept: application/vnd.github+json" "$api" 2>/dev/null || true)"
    if [[ -z "$body" ]]; then
        REFRESH_OUTCOME="failed"
        REFRESH_NOTE="github API unreachable for ${GH_REPO} (rate-limit or network)"
        return
    fi
    local new_tag
    new_tag=$(printf '%s' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tag_name",""))' 2>/dev/null || true)
    if [[ -z "$new_tag" ]]; then
        REFRESH_OUTCOME="failed"; REFRESH_NOTE="could not parse tag_name from GitHub response"
        return
    fi

    if [[ "$PIN_MODE" == "track-latest" ]]; then
        # track-latest by design has no pinned version to compare
        # against — the manifest defers to upstream.  Just bump the
        # "we last looked at this" date.
        if [[ $DRY_RUN -eq 1 ]]; then
            REFRESH_OUTCOME="skipped"
            REFRESH_NOTE="dry-run: ${GH_REPO} latest=${new_tag} (track-latest); would bump date only"
        else
            toml_set "$path" "$idx" "pin.last_refreshed" "$TODAY"
            REFRESH_OUTCOME="bumped"
            REFRESH_NOTE="${GH_REPO} latest=${new_tag} (track-latest); bumped date"
        fi
        return
    fi

    # frozen mode (or unspecified — treat as frozen for safety).
    if [[ "$new_tag" == "$GH_VERSION" ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            REFRESH_OUTCOME="skipped"
            REFRESH_NOTE="dry-run: ${GH_REPO} still at ${new_tag} (frozen); would bump date only"
        else
            toml_set "$path" "$idx" "pin.last_refreshed" "$TODAY"
            REFRESH_OUTCOME="bumped"
            REFRESH_NOTE="${GH_REPO} still at ${new_tag} (frozen)"
        fi
        return
    fi

    # Frozen + tag drift — REFUSE to auto-rewrite.  Policy: a human
    # reviews release notes before we move a frozen pin.
    REFRESH_OUTCOME="skipped"
    REFRESH_NOTE="${GH_REPO}: track-latest mode would auto-bump to ${new_tag}; frozen requires manual review (pinned=${GH_VERSION})"
}

refresh_direct_deb() {
    local name="$1" path="$2" idx="$3"
    if [[ -z "$DD_URL" ]]; then
        REFRESH_OUTCOME="failed"; REFRESH_NOTE="install.direct_deb.url unset"
        return
    fi
    # HEAD instead of GET — we're only checking liveness here, not
    # rehashing.  --fail makes curl return non-zero on 4xx/5xx.
    if curl -fsSL --max-time 20 -I "$DD_URL" >/dev/null 2>&1; then
        if [[ $DRY_RUN -eq 1 ]]; then
            REFRESH_OUTCOME="skipped"
            REFRESH_NOTE="dry-run: ${DD_URL} reachable; would bump date only"
        else
            toml_set "$path" "$idx" "pin.last_refreshed" "$TODAY"
            REFRESH_OUTCOME="bumped"
            REFRESH_NOTE="HEAD ${DD_URL} → 2xx (URL alive; version field NOT re-derived)"
        fi
    else
        REFRESH_OUTCOME="failed"
        REFRESH_NOTE="HEAD ${DD_URL} failed — vendor moved the download?"
    fi
}

# ── Driver ─────────────────────────────────────────────────────────
if [[ ! -d "$APPS_DIR" ]]; then
    log "no apps configured"
    [[ $QUIET -eq 1 ]] || printf '\nsummary: 0 bumped, 0 failed, 0 skipped\n'
    exit 0
fi

ENTRIES="$(load_entries)"
if [[ -z "$ENTRIES" ]]; then
    if [[ -n "$ONLY_APP" ]]; then
        die "no [[apps]] entry matched --app ${ONLY_APP}"
    fi
    log "no apps configured"
    [[ $QUIET -eq 1 ]] || printf '\nsummary: 0 bumped, 0 failed, 0 skipped\n'
    exit 0
fi

# If --app was passed, filter BEFORE per-entry work so a missing name
# surfaces as a die() rather than a silent 0-entry pass.
if [[ -n "$ONLY_APP" ]]; then
    FILTERED=""
    while IFS=$'\t' read -r _src _idx entry_json; do
        [[ -n "$entry_json" ]] || continue
        probe_name="$(json_get "$entry_json" 'name')"
        if [[ "$probe_name" == "$ONLY_APP" ]]; then
            FILTERED+="${_src}"$'\t'"${_idx}"$'\t'"${entry_json}"$'\n'
        fi
    done <<<"$ENTRIES"
    if [[ -z "$FILTERED" ]]; then
        die "no [[apps]] entry matched --app ${ONLY_APP}"
    fi
    ENTRIES="$FILTERED"
fi

bumped=0; failed=0; skipped=0
declare -a BUMPED_LINES=()
declare -a FAILED_LINES=()

while IFS=$'\t' read -r src_file entry_idx entry_json; do
    [[ -n "$entry_json" ]] || continue

    # Pull every field per-iteration into locals — keeping them prefixed
    # mirrors the previous toml_extract layout so the per-method
    # handlers can be read without context-switching.
    name="$(json_get "$entry_json" 'name')"
    INSTALL_METHOD="$(json_get "$entry_json" 'install.method')"
    PIN_MODE="$(json_get "$entry_json" 'pin.mode')"
    PIN_LAST_REFRESHED="$(json_get "$entry_json" 'pin.last_refreshed')"

    APR_KEYRING_FILE="$(json_get "$entry_json" 'install.apt_pinned_repo.keyring_file')"
    APR_SOURCES_FILE="$(json_get "$entry_json" 'install.apt_pinned_repo.sources_file')"
    APR_KEY_FINGERPRINT="$(json_get "$entry_json" 'install.apt_pinned_repo.key_fingerprint')"

    GH_REPO="$(    json_get "$entry_json" 'install.github_release.repo')"
    GH_VERSION="$( json_get "$entry_json" 'install.github_release.version')"

    DD_URL="$(    json_get "$entry_json" 'install.direct_deb.url')"
    DD_VERSION="$(json_get "$entry_json" 'install.direct_deb.version')"

    if [[ -n "$ONLY_METHOD" && "$INSTALL_METHOD" != "$ONLY_METHOD" ]]; then
        continue
    fi

    REFRESH_OUTCOME=""
    REFRESH_NOTE=""

    case "$INSTALL_METHOD" in
        apt)              refresh_apt ;;
        apt-pinned-repo)  refresh_apt_pinned_repo "$name" "$src_file" "$entry_idx" ;;
        github-release)   refresh_github_release  "$name" "$src_file" "$entry_idx" ;;
        direct-deb)       refresh_direct_deb      "$name" "$src_file" "$entry_idx" ;;
        "")               REFRESH_OUTCOME="failed"; REFRESH_NOTE="install.method unset" ;;
        *)                REFRESH_OUTCOME="failed"; REFRESH_NOTE="unknown install.method: ${INSTALL_METHOD}" ;;
    esac

    case "$REFRESH_OUTCOME" in
        bumped)
            bumped=$((bumped+1))
            ok  "$name: $REFRESH_NOTE"
            BUMPED_LINES+=("$name")
            ;;
        skipped)
            skipped=$((skipped+1))
            log "$name: $REFRESH_NOTE"
            ;;
        failed)
            failed=$((failed+1))
            warn "$name: $REFRESH_NOTE"
            FAILED_LINES+=("$name: $REFRESH_NOTE")
            ;;
    esac
done <<<"$ENTRIES"

# Summary at end — printed unconditionally in non-quiet mode; under
# --quiet only failures escape to stderr (warn() above already did that).
if [[ $QUIET -eq 0 ]]; then
    printf '\nsummary: %d bumped, %d failed, %d skipped\n' \
        "$bumped" "$failed" "$skipped"
    if [[ $bumped -gt 0 ]]; then
        printf '\nnext steps:\n'
        printf '    $ git diff config/apps/\n'
        printf '    $ git add config/apps/\n'
        printf '    $ git commit -m "refresh: bump pin dates"\n'
    fi
fi

# Failed > 0 is a non-zero exit so cron + MAILTO surfaces it.  Bumped /
# skipped are normal outcomes.
[[ $failed -eq 0 ]] || exit 1
exit 0
