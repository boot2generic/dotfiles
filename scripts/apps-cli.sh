#!/usr/bin/env bash
# scripts/apps-cli.sh
#
# Top-level dispatcher for the apps lifecycle (validate, install, freeze,
# unfreeze, refresh, verify, remove, list, status).
#
# Every subcommand is wired to real behaviour.  Mutating subcommands
# (install / freeze / unfreeze / remove) re-run the pre-flight validator
# gate before touching anything; read-only subcommands (list / status /
# verify / refresh) skip that gate because the underlying scripts they
# wrap already run it.
#
# Usage:
#     scripts/apps-cli.sh validate [--app NAME]
#     scripts/apps-cli.sh list [--tier TIER]
#     scripts/apps-cli.sh install [--tier TIER] [--app NAME] [--dry-run]
#     scripts/apps-cli.sh status --app NAME
#     scripts/apps-cli.sh freeze --app NAME
#     scripts/apps-cli.sh unfreeze --app NAME
#     scripts/apps-cli.sh refresh [--app NAME] [...]
#     scripts/apps-cli.sh verify  [--app NAME] [...]
#     scripts/apps-cli.sh remove  --app NAME [--dry-run] [--yes]
#     scripts/apps-cli.sh --help
#
# Exit codes (consistent across subcommands):
#     0  success
#     1  user error / refused / failed precondition
#     2  internal error
# Some subcommands forward to other scripts (install, refresh, verify) —
# in those cases the wrapped script's exit code is propagated verbatim.

set -euo pipefail

# ============================================================
# Bootstrap — locate the repo and define logging helpers
# ============================================================
# Resolve REPO_DIR from this script's own location so the dispatcher
# works whether invoked by absolute path, via $PATH, or from inside
# another script.  Mirrors the convention in install-apps.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APPS_DIR="${REPO_DIR}/config/apps"
MANIFEST="${APPS_DIR}/apps.toml"

# Colourless logging — keeps output greppable in CI / journal.  All
# progress goes to stderr so stdout is reserved for machine-parseable
# output where applicable (matches install-apps.sh).
log()  { printf '[apps-cli] %s\n' "$*" >&2; }
warn() { printf '[apps-cli] WARN: %s\n' "$*" >&2; }
err()  { printf '[apps-cli] ERROR: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# Source the lockfile library — provides lockfile_path / lockfile_exists
# / lockfile_read / lockfile_delete.  The library is sourced lazily by
# any subcommand that needs it; we source here so every code path has
# access without re-importing.
# shellcheck source=lib/lockfile.sh
source "${SCRIPT_DIR}/lib/lockfile.sh"

# ============================================================
# Help — mirrors install-apps.sh's docstring-extraction pattern
# ============================================================
print_help() {
  # Pull the leading block of '# …' comments after the shebang.  The
  # `sed -n '2,/^$/p'` recipe matches install-apps.sh exactly so help
  # output stays consistent across the tool family.
  sed -n '2,/^$/p' "$0"
}

usage_hint() {
  printf '[apps-cli] usage: %s <subcommand> [args...]\n' "$(basename "$0")" >&2
  printf '[apps-cli]   subcommands: validate, list, install, status,\n' >&2
  printf '[apps-cli]                freeze, unfreeze, refresh, verify, remove\n' >&2
  printf '[apps-cli]   run with --help for the full docstring\n' >&2
}

# ============================================================
# Pre-flight validator gate (called by mutating subcommands)
# ============================================================
# Calls apps-validate.py directly so the gate's behaviour is identical
# to what install-apps.sh / verify-pins.sh / refresh-pins.sh see.  Refuses
# to proceed on validator exit 1; warnings-only (exit 2) logs and
# continues.  Any unexpected exit is treated as fatal.
preflight_validate() {
  local validator="${SCRIPT_DIR}/apps-validate.py"
  if [[ ! -r "$validator" ]]; then
    err "validator script not found: $validator"
    return 2
  fi
  local rc=0
  python3 "$validator" --root "$REPO_DIR" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    2) log "validator returned warnings — continuing"; return 0 ;;
    1) err "validator reported errors — refusing to proceed"
       err "  run: $(basename "$0") validate"
       return 1 ;;
    *) err "validator exited with unexpected code $rc"; return 2 ;;
  esac
}

# ============================================================
# Subcommand: validate (forwards to apps-validate.py)
# ============================================================
cmd_validate() {
  local validator="${SCRIPT_DIR}/apps-validate.py"
  if [[ ! -e "$validator" ]]; then
    err "validator script not found: $validator"
    return 1
  fi
  # Forward any remaining args verbatim so callers can pass --app NAME
  # or --help and have it reach the Python side.  Exit with the
  # validator's own exit code so callers can branch on 0/1/2.
  local rc=0
  python3 "$validator" "$@" || rc=$?
  return "$rc"
}

# ============================================================
# Helper: read manifest into a JSON blob keyed by name
# ============================================================
# Emits one JSON object per [[apps]] entry, indexed by name, on stdout.
# Format: TSV "<name>\t<entry_json>" — keeps shell loops simple and is
# the same pattern install-apps.sh::load_entries uses.  Skips entries
# without a `name` field (validator would have caught that).
manifest_entries_tsv() {
  if [[ ! -r "$MANIFEST" ]]; then
    err "manifest not found: $MANIFEST"
    return 2
  fi
  MANIFEST_PATH="$MANIFEST" python3 - <<'PY'
import json
import os
import sys
import tomllib
from pathlib import Path

path = Path(os.environ["MANIFEST_PATH"])
try:
    with open(path, "rb") as fh:
        data = tomllib.load(fh)
except (tomllib.TOMLDecodeError, OSError, UnicodeDecodeError) as exc:
    print(f"[apps-cli] ERROR: could not parse {path}: {exc}", file=sys.stderr)
    sys.exit(2)
apps = data.get("apps")
if not isinstance(apps, list):
    sys.exit(0)
for entry in apps:
    if not isinstance(entry, dict):
        continue
    name = entry.get("name")
    if not name:
        continue
    sys.stdout.write(f"{name}\t{json.dumps(entry, separators=(',', ':'))}\n")
PY
}

# Extract a JSON dotted-path value (matches install-apps.sh::json_get).
# Lists are space-joined; booleans render true/false; missing/null → empty.
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

# Extract the date portion of an ISO 8601 UTC timestamp (YYYY-MM-DDThh…).
# Used by `list` to render the "yes (2026-05-23)" cell without depending
# on an external date parser.
iso_date_part() {
  local ts="$1"
  printf '%s' "${ts%%T*}"
}

# ============================================================
# Subcommand: list
# ============================================================
# Table: NAME / METHOD / TIER / PIN-MODE / VERSION / INSTALLED.
# Reads manifest via Python+tomllib (no shell-only TOML parsing) and
# decorates each row with lockfile presence + drift signal.  Supports
# `--tier` filter (same vocabulary as install-apps.sh).
cmd_list() {
  local tier_filter=""
  while (( $# )); do
    case "$1" in
      --tier) tier_filter="${2:-}"; shift 2 ;;
      -h|--help)
        printf 'usage: apps-cli.sh list [--tier TIER]\n' >&2
        return 0 ;;
      *) err "list: unknown argument: $1"; return 1 ;;
    esac
  done

  if [[ ! -r "$MANIFEST" ]]; then
    err "manifest not found: $MANIFEST"
    return 2
  fi

  # Normalise --tier into a Python set the heredoc below can consume.
  # Accept both "1" and "tier1" (matches install-apps.sh ergonomics).
  local normalised_tiers=""
  if [[ -n "$tier_filter" ]]; then
    local raw token t
    raw="$tier_filter"
    IFS=',' read -ra _tok_list <<<"$raw"
    for token in "${_tok_list[@]}"; do
      t="${token## }"; t="${t%% }"
      t="${t#[Tt][Ii][Ee][Rr]}"
      if [[ ! "$t" =~ ^[1-5]$ ]]; then
        err "list: --tier value '${token}' not in {1,2,3,4,5}"
        return 1
      fi
      normalised_tiers+="$t "
    done
  fi

  # Heredoc does the heavy lifting — printing the table while reading
  # lockfiles for each entry to compute INSTALLED + drift.
  MANIFEST_PATH="$MANIFEST" \
  REPO_DIR_PATH="$REPO_DIR" \
  TIER_FILTER="$normalised_tiers" \
  python3 - <<'PY'
import os
import sys
import tomllib
from pathlib import Path

manifest = Path(os.environ["MANIFEST_PATH"])
repo_dir = Path(os.environ["REPO_DIR_PATH"])
tier_filter = set(os.environ.get("TIER_FILTER", "").split())

try:
    with open(manifest, "rb") as fh:
        data = tomllib.load(fh)
except Exception as exc:
    print(f"[apps-cli] ERROR: could not parse {manifest}: {exc}", file=sys.stderr)
    sys.exit(2)

apps = data.get("apps")
if not isinstance(apps, list):
    print("(no [[apps]] entries in manifest)", file=sys.stderr)
    sys.exit(0)

# --- helpers ----------------------------------------------------
def read_lockfile(name: str):
    """Return (installed_at, installed_version) or (None, None)."""
    lf = repo_dir / "config" / "apps" / ".locks" / f"{name}.lock"
    if not lf.is_file():
        return (None, None)
    try:
        with open(lf, "rb") as fh:
            ld = tomllib.load(fh)
    except Exception:
        return (None, None)
    lock = ld.get("lock") or {}
    return (lock.get("installed_at", ""), lock.get("installed_version", ""))


def version_field(entry: dict) -> str:
    """Render the VERSION cell for the table."""
    pin = entry.get("pin") or {}
    pin_mode = pin.get("mode", "")
    install = entry.get("install") or {}
    method = install.get("method", "")

    if pin_mode == "track-latest":
        return "latest"

    # frozen / unspecified
    if method == "github-release":
        gh = install.get("github_release") or {}
        return gh.get("version", "") or "(unset)"
    if method == "direct-deb":
        dd = install.get("direct_deb") or {}
        return dd.get("version", "") or "(unset)"
    if method in ("apt", "apt-pinned-repo"):
        return "(apt-managed)"
    return "(unknown)"


# --- header -----------------------------------------------------
fmt = "%-19s %-15s %-4s %-13s %-20s %s"
print(fmt % ("NAME", "METHOD", "TIER", "PIN-MODE", "VERSION", "INSTALLED"))
print(fmt % ("----", "------", "----", "--------", "-------", "---------"))

for entry in apps:
    if not isinstance(entry, dict):
        continue
    name = entry.get("name", "")
    if not name:
        continue

    # tier filter — entries without a tier always pass (mirrors
    # install-apps.sh::entry_passes_tier_filter).
    entry_tier = entry.get("tier", "")
    if tier_filter:
        if entry_tier == "":
            pass  # no tier set → always pass
        else:
            if str(entry_tier) not in tier_filter:
                continue

    install = entry.get("install") or {}
    method = install.get("method", "") or "?"
    pin = entry.get("pin") or {}
    pin_mode = pin.get("mode", "") or "-"

    version = version_field(entry)
    tier_cell = str(entry_tier) if entry_tier != "" else "-"

    installed_at, installed_ver = read_lockfile(name)
    if installed_at is None:
        installed_cell = "no"
    else:
        date_part = installed_at.split("T", 1)[0]
        drift = ""
        # Drift detection — frozen + version present + lockfile version
        # disagrees → asterisk.  track-latest never drifts (no pinned
        # version to compare).  apt methods never drift here either
        # (they have no manifest version to anchor against).
        if pin_mode == "frozen":
            manifest_version = version_field(entry)
            if (
                manifest_version
                and manifest_version not in ("(apt-managed)", "(unset)", "(unknown)")
                and installed_ver
                and installed_ver != manifest_version
            ):
                drift = "*"
        installed_cell = f"yes ({date_part}){drift}"

    print(fmt % (name, method, tier_cell, pin_mode, version, installed_cell))
PY
}

# ============================================================
# Subcommand: status --app NAME
# ============================================================
# Three blocks: manifest, lockfile, live state.  All output goes to
# stdout (this subcommand is a human inspector, not a pipeline producer).
cmd_status() {
  local app=""
  while (( $# )); do
    case "$1" in
      --app) app="${2:-}"; shift 2 ;;
      -h|--help)
        printf 'usage: apps-cli.sh status --app NAME\n' >&2
        return 0 ;;
      *) err "status: unknown argument: $1"; return 1 ;;
    esac
  done
  if [[ -z "$app" ]]; then
    err "status: --app NAME required"
    return 1
  fi

  # Find the entry and pull every field we need.  manifest_entries_tsv
  # already returns one entry per line keyed by name.
  local entries
  entries="$(manifest_entries_tsv)" || return 2
  local found_json=""
  local _name _json
  while IFS=$'\t' read -r _name _json; do
    [[ -n "$_name" ]] || continue
    if [[ "$_name" == "$app" ]]; then
      found_json="$_json"
      break
    fi
  done <<<"$entries"

  if [[ -z "$found_json" ]]; then
    err "no manifest entry for app: $app"
    return 1
  fi

  # ── 1. Manifest entry block ────────────────────────────────────
  printf '== manifest entry ==\n'
  ENTRY_JSON="$found_json" python3 - <<'PY'
import json, os, sys
entry = json.loads(os.environ["ENTRY_JSON"])

def show(label, value, indent=0):
    prefix = "  " * indent
    if isinstance(value, list):
        value = ", ".join(str(x) for x in value)
    elif isinstance(value, bool):
        value = "true" if value else "false"
    elif value is None:
        value = ""
    print(f"{prefix}{label:18} {value}")

show("name",         entry.get("name", ""))
show("display_name", entry.get("display_name", ""))
show("tier",         entry.get("tier", ""))
show("machines",     entry.get("machines", []))
show("description",  entry.get("description", ""))
show("docs_url",     entry.get("docs_url", ""))

install = entry.get("install") or {}
method = install.get("method", "")
show("install.method", method)
sub = None
if method == "apt":
    sub = install.get("apt") or {}
elif method == "apt-pinned-repo":
    sub = install.get("apt_pinned_repo") or {}
elif method == "github-release":
    sub = install.get("github_release") or {}
elif method == "direct-deb":
    sub = install.get("direct_deb") or {}
if isinstance(sub, dict):
    for k, v in sub.items():
        show(k, v, indent=1)

pin = entry.get("pin") or {}
print(f"  pin.mode           {pin.get('mode', '')}")
print(f"  pin.last_refreshed {pin.get('last_refreshed', '')}")
print(f"  pin.refresh_after  {pin.get('refresh_after_days', '')}")
PY

  # ── 2. Lockfile block ──────────────────────────────────────────
  printf '\n== lockfile ==\n'
  local lf_path
  lf_path="$(lockfile_path "$REPO_DIR" "$app")"
  if [[ ! -f "$lf_path" ]]; then
    printf '  no lockfile found at %s\n' "$lf_path"
  else
    # Use the library's reader to get KEY=VAL pairs, then render them.
    local kv
    kv="$(lockfile_read "$lf_path")" || {
      err "could not read lockfile: $lf_path"
      return 2
    }
    printf '  path: %s\n' "$lf_path"
    # KV is shell-eval-safe (the library single-quotes values).  Eval
    # in a subshell so we don't pollute our environment with the keys.
    (
      eval "$kv"
      printf '  schema_version    %s\n' "${SCHEMA_VERSION:-}"
      printf '  name              %s\n' "${NAME:-}"
      printf '  install_method    %s\n' "${INSTALL_METHOD:-}"
      printf '  installed_at      %s\n' "${INSTALLED_AT:-}"
      printf '  installed_version %s\n' "${INSTALLED_VERSION:-}"
      printf '  installed_sha256  %s\n' "${INSTALLED_SHA256:-}"
      printf '  install_path      %s\n' "${INSTALL_PATH:-}"
      printf '  verified_by       %s\n' "${VERIFIED_BY:-}"
      printf '  manifest_pin_mode %s\n' "${MANIFEST_PIN_MODE:-}"
    )
  fi

  # ── 3. Live-state block ────────────────────────────────────────
  printf '\n== live state ==\n'
  local method
  method="$(json_get "$found_json" 'install.method')"
  case "$method" in
    apt)
      local pkg
      pkg="$(json_get "$found_json" 'install.apt.package')"
      [[ -z "$pkg" ]] && pkg="$app"
      if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -W -f='  Status:  ${Status}\n  Version: ${Version}\n' "$pkg" 2>/dev/null \
          || printf '  (not installed: %s)\n' "$pkg"
      else
        printf '  dpkg-query not available — cannot probe installed state\n'
      fi
      ;;
    apt-pinned-repo)
      local pkg
      pkg="$(json_get "$found_json" 'install.apt_pinned_repo.package')"
      [[ -z "$pkg" ]] && pkg="$app"
      if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -W -f='  Status:  ${Status}\n  Version: ${Version}\n' "$pkg" 2>/dev/null \
          || printf '  (not installed: %s)\n' "$pkg"
      else
        printf '  dpkg-query not available — cannot probe installed state\n'
      fi
      ;;
    github-release)
      local install_to
      install_to="$(json_get "$found_json" 'install.github_release.install_to')"
      if [[ -z "$install_to" ]]; then
        printf '  install.github_release.install_to not set in manifest\n'
      elif [[ ! -e "$install_to" ]]; then
        printf '  not present: %s\n' "$install_to"
      else
        local size sha
        if [[ -f "$install_to" ]]; then
          size="$(stat -c '%s' "$install_to" 2>/dev/null || echo unknown)"
          sha="$(sha256sum "$install_to" 2>/dev/null | awk '{print $1}')"
          printf '  path:    %s\n' "$install_to"
          printf '  size:    %s bytes\n' "$size"
          printf '  sha256:  %s\n' "${sha:-unknown}"
        else
          # Directory install (e.g. fonts) — show entry count.
          local entries
          entries="$(find "$install_to" -mindepth 1 -maxdepth 1 -printf . 2>/dev/null | wc -c)"
          printf '  path:    %s (directory)\n' "$install_to"
          printf '  entries: %s\n' "${entries:-0}"
        fi
      fi
      ;;
    direct-deb)
      # Try to derive the package name from the manifest; fall back to
      # the app name if not set.
      local pkg
      pkg="$(json_get "$found_json" 'install.direct_deb.package')"
      [[ -z "$pkg" ]] && pkg="$app"
      if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -W -f='  Status:  ${Status}\n  Version: ${Version}\n' "$pkg" 2>/dev/null \
          || printf '  (not installed: %s)\n' "$pkg"
      else
        printf '  dpkg-query not available — cannot probe installed state\n'
      fi
      ;;
    *)
      printf '  unknown method "%s" — no live-state probe defined\n' "$method"
      ;;
  esac

  return 0
}

# ============================================================
# Subcommand: install (forwards to install-apps.sh)
# ============================================================
# Translates apps-cli args into install-apps.sh args.  Passes through
# --tier, --app, --dry-run verbatim.  Exit code propagated.
cmd_install() {
  local dispatcher="${SCRIPT_DIR}/install-apps.sh"
  if [[ ! -x "$dispatcher" ]]; then
    err "install dispatcher missing or not executable: $dispatcher"
    return 2
  fi

  # jq is required by all four install-method adapters to parse the
  # manifest JSON the dispatcher hands them.  When the user runs apps-cli
  # directly (NOT via `./local_setup.sh setup` which puts jq in
  # BASE_PACKAGES), jq may not be on PATH.  Install it once, here,
  # before the adapters ever fire — better than each of the 4 adapters
  # exiting with a confusing "jq-missing" skipped_reason.
  _ensure_jq || return 2

  local -a forward=()
  while (( $# )); do
    case "$1" in
      --tier)    forward+=(--tier "${2:-}");    shift 2 ;;
      --app)     forward+=(--app  "${2:-}");    shift 2 ;;
      --dry-run) forward+=(--dry-run);          shift ;;
      -h|--help)
        printf 'usage: apps-cli.sh install [--tier TIER] [--app NAME] [--dry-run]\n' >&2
        return 0 ;;
      *) err "install: unknown argument: $1"; return 1 ;;
    esac
  done

  # install-apps.sh runs its own validator gate — we don't need to.
  local rc=0
  "$dispatcher" "${forward[@]}" || rc=$?
  return "$rc"
}

# Ensure jq is available before the install dispatch runs.  Apt-installs
# it via sudo if missing.  Returns 0 if jq is on PATH at exit, non-zero
# otherwise.  Caller must abort if non-zero.
_ensure_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    err "jq missing and apt-get unavailable — install jq manually and retry"
    return 1
  fi
  warn "jq missing — installing now (required by install-method adapters)"
  if ! sudo -n true 2>/dev/null && ! sudo -v; then
    err "sudo unavailable for jq install — run \`sudo apt install -y jq\` and retry"
    return 1
  fi
  if ! sudo apt-get install -y jq >/dev/null; then
    err "apt-get install jq failed — install manually and retry"
    return 1
  fi
  ok "jq installed"
  return 0
}

# ============================================================
# Subcommand: refresh (forwards to refresh-pins.sh)
# ============================================================
cmd_refresh() {
  local refresher="${SCRIPT_DIR}/refresh-pins.sh"
  if [[ ! -x "$refresher" ]]; then
    err "refresh-pins.sh missing or not executable: $refresher"
    return 2
  fi
  # Forward every arg verbatim — refresh-pins.sh has its own help /
  # arg-parsing.  Exit code propagated.
  local rc=0
  "$refresher" "$@" || rc=$?
  return "$rc"
}

# ============================================================
# Subcommand: verify (forwards to verify-pins.sh)
# ============================================================
cmd_verify() {
  local verifier="${SCRIPT_DIR}/verify-pins.sh"
  if [[ ! -x "$verifier" ]]; then
    err "verify-pins.sh missing or not executable: $verifier"
    return 2
  fi
  local rc=0
  "$verifier" "$@" || rc=$?
  return "$rc"
}

# ============================================================
# tomlkit gate — required for freeze / unfreeze
# ============================================================
# Both subcommands mutate apps.toml in place; we MUST use a
# format-preserving writer because the manifest ships hand-curated
# comments + section headers.  Naive sed/awk would destroy them.
require_tomlkit() {
  if ! python3 -c 'import tomlkit' >/dev/null 2>&1; then
    err "python3-tomlkit not installed; cannot rewrite apps.toml without destroying comments."
    err "  install with: sudo apt install python3-tomlkit"
    return 1
  fi
}

# ============================================================
# Subcommand: freeze --app NAME
# ============================================================
# Reads the lockfile (errors out if absent), then uses tomlkit to set
# pin.mode = "frozen" and (for github-release) write installed_version
# + installed_sha256 into the manifest's pin block.
cmd_freeze() {
  local app=""
  while (( $# )); do
    case "$1" in
      --app) app="${2:-}"; shift 2 ;;
      -h|--help)
        printf 'usage: apps-cli.sh freeze --app NAME\n' >&2
        return 0 ;;
      *) err "freeze: unknown argument: $1"; return 1 ;;
    esac
  done
  if [[ -z "$app" ]]; then
    err "freeze: --app NAME required"
    return 1
  fi

  preflight_validate || return $?
  require_tomlkit || return 1

  local lf_path
  lf_path="$(lockfile_path "$REPO_DIR" "$app")"
  if [[ ! -f "$lf_path" ]]; then
    err "freeze: no lockfile at $lf_path"
    err "  install '$app' first (apps-cli.sh install --app $app)"
    return 1
  fi

  # Read the lockfile via the library; eval into local vars.
  local kv
  kv="$(lockfile_read "$lf_path")" || {
    err "freeze: could not read lockfile $lf_path"
    return 2
  }
  local NAME INSTALL_METHOD INSTALLED_VERSION INSTALLED_SHA256
  local INSTALLED_AT INSTALL_PATH VERIFIED_BY MANIFEST_PIN_MODE SCHEMA_VERSION
  eval "$kv"

  # Today (UTC) — pin.last_refreshed format is YYYY-MM-DD throughout.
  local today
  today="$(date -u +%Y-%m-%d)"

  # Hand off to tomlkit for the actual rewrite.  Pass everything via env
  # vars (clean separation from shell quoting issues).  Capture rc
  # explicitly because the `|| { ... }` fallback pattern with a heredoc
  # confuses bash's parser (the brace-group's closing `}` collides with
  # the heredoc body).
  local _rc=0
  APP_NAME="$app" \
  MANIFEST_PATH="$MANIFEST" \
  LF_METHOD="$INSTALL_METHOD" \
  LF_VERSION="$INSTALLED_VERSION" \
  LF_SHA256="$INSTALLED_SHA256" \
  TODAY_DATE="$today" \
  python3 - <<'PY' || _rc=$?
import os, sys
try:
    import tomlkit
except ImportError:
    sys.stderr.write("[apps-cli] ERROR: python3-tomlkit not importable\n")
    sys.exit(2)

manifest = os.environ["MANIFEST_PATH"]
app_name = os.environ["APP_NAME"]
method   = os.environ["LF_METHOD"]
version  = os.environ["LF_VERSION"]
sha256   = os.environ["LF_SHA256"]
today    = os.environ["TODAY_DATE"]

with open(manifest, "r", encoding="utf-8") as fh:
    doc = tomlkit.parse(fh.read())

apps = doc.get("apps")
if apps is None or not isinstance(apps, list):
    sys.stderr.write(f"[apps-cli] ERROR: no [[apps]] array in {manifest}\n")
    sys.exit(3)

target = None
for entry in apps:
    if entry.get("name") == app_name:
        target = entry
        break
if target is None:
    sys.stderr.write(f"[apps-cli] ERROR: no manifest entry for '{app_name}'\n")
    sys.exit(3)

# Ensure pin table exists; tomlkit lets us assign by key.
if "pin" not in target:
    sys.stderr.write(f"[apps-cli] ERROR: '{app_name}' has no [apps.pin] block\n")
    sys.exit(4)
pin = target["pin"]
pin["mode"] = "frozen"

# Defense-in-depth: re-validate the lockfile-supplied values before they
# land in apps.toml.  lockfile_read uses tomllib which only checks that
# the file IS valid TOML — it does not enforce sha256 format or version
# character set.  If a malicious local process pre-positioned a crafted
# lockfile under config/apps/.locks/ (the directory is owner-only via
# the lockfile-dir hardening, but defense in depth costs us nothing),
# freeze would otherwise copy whatever string it found into the
# manifest.  The next `apps validate` run would catch the bad shape,
# but the git diff would already look plausible to a quick-glance reviewer.
import re
_HEX64 = re.compile(r"^[0-9a-f]{64}$")
_VERSION_RE = re.compile(r"^[A-Za-z0-9._+-]{1,128}$")

if method == "github-release":
    install = target.get("install") or {}
    gh = install.get("github_release")
    if gh is None:
        sys.stderr.write(f"[apps-cli] ERROR: github-release method but no [apps.install.github_release]\n")
        sys.exit(4)
    if not version:
        sys.stderr.write("[apps-cli] ERROR: lockfile installed_version is empty — refusing to freeze with empty version\n")
        sys.exit(1)
    if not _VERSION_RE.match(version):
        sys.stderr.write(f"[apps-cli] ERROR: lockfile installed_version '{version}' contains disallowed chars; refusing freeze\n")
        sys.exit(1)
    if not _HEX64.match(sha256 or ""):
        sys.stderr.write("[apps-cli] ERROR: lockfile installed_sha256 is not 64 lowercase hex chars; refusing freeze\n")
        sys.exit(1)
    gh["version"] = version
    if "sha256_x86_64" in gh:
        gh["sha256_x86_64"] = sha256
    else:
        # Manifests are expected to declare sha256_x86_64; the validator
        # enforces it.  If it's truly absent we'd be inventing a new field,
        # which we refuse to do.
        sys.stderr.write("[apps-cli] ERROR: sha256_x86_64 field absent — refusing to invent it\n")
        sys.exit(4)
    pin["last_refreshed"] = today
elif method == "direct-deb":
    # direct-deb is frozen-only by contract — informational only.
    sys.stderr.write("[apps-cli] note: direct-deb is frozen-only by contract; pin.mode set to 'frozen'\n")
    pin["last_refreshed"] = today
elif method in ("apt", "apt-pinned-repo"):
    # apt methods track upstream within the apt archive — `frozen` here
    # is informational.  Do NOT bump `last_refreshed`: that field is
    # owned by `apps refresh` (which actually re-checks the upstream
    # signature/key).  If we bumped it here, a user running freeze six
    # months after install would silence the staleness alarm without
    # ever re-validating the key.
    sys.stderr.write("[apps-cli] note: apt methods track upstream versions; 'frozen' is informational\n")
    sys.stderr.write("[apps-cli] note: pin.last_refreshed unchanged — use `apps refresh` to bump it\n")
else:
    sys.stderr.write(f"[apps-cli] ERROR: unknown install method '{method}' in lockfile\n")
    sys.exit(4)

with open(manifest, "w", encoding="utf-8") as fh:
    fh.write(tomlkit.dumps(doc))

print(f"[apps-cli] froze {app_name}: pin.mode=frozen, last_refreshed={today}", file=sys.stderr)
if method == "github-release":
    print(f"[apps-cli]   version={version} sha256={sha256[:16] if sha256 else '(empty)'}…", file=sys.stderr)
PY
  if (( _rc != 0 )); then
    err "freeze: tomlkit rewrite failed (exit $_rc)"
    return 2
  fi

  return 0
}

# ============================================================
# Subcommand: unfreeze --app NAME
# ============================================================
# Flips pin.mode → "track-latest".  For github-release: clears version
# + sha256_x86_64 + sha256_aarch64 (sets them to "").  For direct-deb:
# REFUSES (frozen-only by contract).  For apt methods: just flips mode.
cmd_unfreeze() {
  local app=""
  while (( $# )); do
    case "$1" in
      --app) app="${2:-}"; shift 2 ;;
      -h|--help)
        printf 'usage: apps-cli.sh unfreeze --app NAME\n' >&2
        return 0 ;;
      *) err "unfreeze: unknown argument: $1"; return 1 ;;
    esac
  done
  if [[ -z "$app" ]]; then
    err "unfreeze: --app NAME required"
    return 1
  fi

  preflight_validate || return $?
  require_tomlkit || return 1

  local today
  today="$(date -u +%Y-%m-%d)"

  local _rc=0
  APP_NAME="$app" \
  MANIFEST_PATH="$MANIFEST" \
  TODAY_DATE="$today" \
  python3 - <<'PY' || _rc=$?
import os, sys
try:
    import tomlkit
except ImportError:
    sys.stderr.write("[apps-cli] ERROR: python3-tomlkit not importable\n")
    sys.exit(2)

manifest = os.environ["MANIFEST_PATH"]
app_name = os.environ["APP_NAME"]
today    = os.environ["TODAY_DATE"]

with open(manifest, "r", encoding="utf-8") as fh:
    doc = tomlkit.parse(fh.read())

apps = doc.get("apps")
if apps is None or not isinstance(apps, list):
    sys.stderr.write(f"[apps-cli] ERROR: no [[apps]] array in {manifest}\n")
    sys.exit(3)

target = None
for entry in apps:
    if entry.get("name") == app_name:
        target = entry
        break
if target is None:
    sys.stderr.write(f"[apps-cli] ERROR: no manifest entry for '{app_name}'\n")
    sys.exit(3)

install = target.get("install") or {}
method = install.get("method", "")

if method == "direct-deb":
    sys.stderr.write("[apps-cli] ERROR: direct-deb is frozen-only by contract; refusing to unfreeze\n")
    sys.exit(1)

if "pin" not in target:
    sys.stderr.write(f"[apps-cli] ERROR: '{app_name}' has no [apps.pin] block\n")
    sys.exit(4)
pin = target["pin"]
pin["mode"] = "track-latest"
pin["last_refreshed"] = today

if method == "github-release":
    gh = install.get("github_release")
    if gh is None:
        sys.stderr.write("[apps-cli] ERROR: github-release method but no [apps.install.github_release]\n")
        sys.exit(4)
    # Clear all per-version fields — track-latest resolves them at install time.
    for k in ("version", "sha256_x86_64", "sha256_aarch64"):
        if k in gh:
            gh[k] = ""
elif method in ("apt", "apt-pinned-repo"):
    sys.stderr.write("[apps-cli] note: apt method — pin.mode flipped to 'track-latest'\n")
else:
    sys.stderr.write(f"[apps-cli] ERROR: unknown install method '{method}'\n")
    sys.exit(4)

with open(manifest, "w", encoding="utf-8") as fh:
    fh.write(tomlkit.dumps(doc))

print(f"[apps-cli] unfroze {app_name}: pin.mode=track-latest, last_refreshed={today}", file=sys.stderr)
PY
  if (( _rc != 0 )); then
    err "unfreeze: tomlkit rewrite failed (exit $_rc)"
    return 2
  fi

  return 0
}

# ============================================================
# Subcommand: remove --app NAME [--dry-run] [--yes]
# ============================================================
# Method-aware uninstaller.  Confirms interactively when stdin is a TTY
# and --yes was not passed.  github-release path-safety check refuses to
# delete anything outside /usr/local/, /opt/, or /usr/local/share/.
# Deletes the lockfile after a successful removal.  Does NOT modify
# apps.toml — the entry stays for the user to delete by hand.
cmd_remove() {
  local app=""
  local dry_run=0
  local assume_yes=0
  while (( $# )); do
    case "$1" in
      --app)     app="${2:-}"; shift 2 ;;
      --dry-run) dry_run=1;    shift ;;
      --yes|-y)  assume_yes=1; shift ;;
      -h|--help)
        printf 'usage: apps-cli.sh remove --app NAME [--dry-run] [--yes]\n' >&2
        return 0 ;;
      *) err "remove: unknown argument: $1"; return 1 ;;
    esac
  done
  if [[ -z "$app" ]]; then
    err "remove: --app NAME required"
    return 1
  fi

  preflight_validate || return $?

  # Find the manifest entry — required so we know the install method.
  local entries
  entries="$(manifest_entries_tsv)" || return 2
  local found_json=""
  local _name _json
  while IFS=$'\t' read -r _name _json; do
    [[ -n "$_name" ]] || continue
    if [[ "$_name" == "$app" ]]; then
      found_json="$_json"
      break
    fi
  done <<<"$entries"

  if [[ -z "$found_json" ]]; then
    err "remove: no manifest entry for '$app'"
    return 1
  fi

  local method
  method="$(json_get "$found_json" 'install.method')"

  # Compute what we're going to do, but DON'T do it yet — we want to
  # show the user the plan before the confirmation prompt.
  local plan_desc=""
  local plan_cmd=""
  local plan_path=""
  case "$method" in
    apt)
      local pkg
      pkg="$(json_get "$found_json" 'install.apt.package')"
      [[ -z "$pkg" ]] && pkg="$app"
      plan_desc="apt remove ${pkg}"
      plan_cmd="sudo apt-get remove -y $(printf '%q' "$pkg")"
      ;;
    apt-pinned-repo)
      local pkg
      pkg="$(json_get "$found_json" 'install.apt_pinned_repo.package')"
      [[ -z "$pkg" ]] && pkg="$app"
      plan_desc="apt remove ${pkg} (from pinned repo)"
      plan_cmd="sudo apt-get remove -y $(printf '%q' "$pkg")"
      ;;
    github-release)
      local install_to
      install_to="$(json_get "$found_json" 'install.github_release.install_to')"
      if [[ -z "$install_to" ]]; then
        err "remove: install.github_release.install_to not set for '$app' — nothing to delete"
        return 1
      fi
      # SAFETY CHECK — refuse to rm anything outside the allowed prefixes.
      # Defense in depth: the raw string can't contain '..' AND the
      # canonicalised path must be a strict descendant of an allowed
      # prefix.  The raw-string check stops the case-glob from matching
      # something like /usr/local/../etc/cron.d/foo (which would otherwise
      # pass the glob).  The realpath check catches symlink shenanigans —
      # if install_to is a symlink that points outside the allowed roots,
      # we refuse before rm follows the link.
      if [[ "$install_to" == *"/.."* || "$install_to" == *"/.." || "$install_to" == "../"* ]]; then
        err "remove refuses to delete install_to containing '..' components"
        err "  install_to = $install_to"
        return 1
      fi
      case "$install_to" in
        /usr/local/*|/opt/*|/usr/local/share/*)
          # OK — explicit allowlist match.
          ;;
        *)
          err "remove refuses to delete files outside /usr/local/, /opt/, or /usr/local/share/"
          err "  install_to = $install_to"
          return 1
          ;;
      esac
      # Canonicalise (resolve symlinks where they exist; -m = "be lenient
      # if target doesn't exist yet so dry-runs work").  Then re-check the
      # canonical form is still inside the allowlist.
      local install_to_canonical
      install_to_canonical="$(realpath -m -- "$install_to")"
      case "$install_to_canonical" in
        /usr/local/*|/opt/*|/usr/local/share/*)
          # OK — canonical form is still within the allowlist.
          ;;
        *)
          err "remove refuses: canonical path of '$install_to' is outside the allowlist"
          err "  raw:        $install_to"
          err "  canonical:  $install_to_canonical"
          return 1
          ;;
      esac
      plan_path="$install_to"
      # For files use rm -f; for directories use rm -rf so font bundles
      # etc. are cleaned out.  Manifest's install_to is the authoritative
      # location.
      if [[ -d "$install_to" ]]; then
        plan_desc="rm -rf ${install_to} (directory)"
        plan_cmd="rm -rf -- $(printf '%q' "$install_to")"
      else
        plan_desc="rm -f ${install_to}"
        plan_cmd="rm -f -- $(printf '%q' "$install_to")"
      fi
      ;;
    direct-deb)
      local pkg
      pkg="$(json_get "$found_json" 'install.direct_deb.package')"
      [[ -z "$pkg" ]] && pkg="$app"
      plan_desc="apt remove ${pkg} (from direct .deb install)"
      plan_cmd="sudo apt-get remove -y $(printf '%q' "$pkg")"
      ;;
    *)
      err "remove: unknown install method '$method' for '$app'"
      return 1
      ;;
  esac

  # Confirmation prompt — only when stdin is a TTY AND --yes was not
  # passed.  Non-interactive callers (cron, scripts) skip the prompt
  # implicitly because stdin won't be a TTY.
  if (( ! assume_yes )) && [[ -t 0 ]]; then
    printf 'About to remove '\''%s'\'' (%s, %s).\n' "$app" "$method" "${plan_path:-$plan_desc}"
    printf 'Confirm? [y/N] '
    local reply=""
    read -r reply || reply=""
    case "$reply" in
      y|Y|yes|YES) ;;
      *) log "remove: user declined"; return 1 ;;
    esac
  fi

  # DRY_RUN — print what would happen and bail.  Don't touch the lockfile.
  if (( dry_run )); then
    log "dry-run: would run: $plan_cmd"
    log "dry-run: would delete lockfile (if present)"
    return 0
  fi

  # Execute.  set -e is on; we capture rc explicitly so we can branch.
  local rc=0
  log "executing: $plan_cmd"
  bash -c "$plan_cmd" || rc=$?
  if (( rc != 0 )); then
    err "remove: command failed with exit $rc"
    return 1
  fi

  # Delete the lockfile (no-op if absent — lockfile_delete logs that itself).
  local lf_path
  lf_path="$(lockfile_path "$REPO_DIR" "$app")"
  lockfile_delete "$lf_path" || warn "remove: could not delete lockfile $lf_path"

  log "removed '$app' (manifest entry retained — edit config/apps/apps.toml to delete it)"
  return 0
}

# ============================================================
# Dispatch
# ============================================================
# A bare `--help` (no subcommand) must still print the docstring, so
# treat it before falling into the empty-args branch.
if (( $# == 0 )); then
  err "no subcommand given"
  usage_hint
  exit 2
fi

case "$1" in
  -h|--help)
    print_help
    exit 0
    ;;
  validate)
    shift
    cmd_validate "$@"
    exit $?
    ;;
  list)
    shift
    cmd_list "$@"
    exit $?
    ;;
  install)
    shift
    cmd_install "$@"
    exit $?
    ;;
  status)
    shift
    cmd_status "$@"
    exit $?
    ;;
  freeze)
    shift
    cmd_freeze "$@"
    exit $?
    ;;
  unfreeze)
    shift
    cmd_unfreeze "$@"
    exit $?
    ;;
  refresh)
    shift
    cmd_refresh "$@"
    exit $?
    ;;
  verify)
    shift
    cmd_verify "$@"
    exit $?
    ;;
  remove)
    shift
    cmd_remove "$@"
    exit $?
    ;;
  *)
    err "unknown subcommand: $1"
    usage_hint
    exit 2
    ;;
esac
