#!/usr/bin/env bash
# scripts/install-apps.sh
#
# Phase 0 dispatcher for the dotfiles application-install system.
# Reads every manifest under config/apps/*.toml (skipping schema*.toml,
# _*.toml, and dotfiles), filters by the current machine profile, then
# shells out to scripts/install-methods/<method>.sh for the actual work.
#
# Usage:
#     scripts/install-apps.sh [--all]                  # default
#     scripts/install-apps.sh --app NAME
#     scripts/install-apps.sh --list
#     scripts/install-apps.sh --dry-run [--app NAME]
#     scripts/install-apps.sh --profile PROFILE [...]  # override auto-detect
#     scripts/install-apps.sh --help
#
# Machine profiles (resolve_profile):
#     "common"  — always included
#     "t14"     — DMI chassis_type in {8,9,10,14}  (mirror of is_laptop_chassis)
#     "desktop" — Nvidia GPU detected (PCI vendor 10de, or /proc/driver/nvidia)
# The dispatcher installs an app iff its meta.machines list intersects the
# resolved profile set.
#
# Install-method adapter contract (Agent B implements):
#     DOTFILES_MACHINE=<profile> DRY_RUN=<0|1> REPO_DIR=<...> \
#         scripts/install-methods/<method>.sh <path-to-manifest-json>
#
#     stdout : ONE line — `installed=true` or `installed=false [ skipped_reason=<str>]`
#     stderr : human progress
#     exit 0 = success or intentional skip
#     exit 1 = pre-flight failure
#     exit 2 = installation error
#
# Pin verification (Agent C deliverable):
#     If scripts/verify-pins.sh exists and exits 2 (signature mismatch)
#     or 3 (no manifest matched --app NAME), the app is REFUSED.  Any
#     other non-zero exit is advisory — we log and proceed.  If
#     verify-pins.sh is missing entirely we skip the check.
#     The manifest filename basename MUST equal meta.name — both the
#     dispatcher and verify-pins.sh look up by basename.
#
# Phase 0 is additive-only: this file lives next to local_setup.sh but is
# NOT yet wired into it.  Run it by hand for now; Phase 1 will integrate.

set -euo pipefail

# ============================================================
# Bootstrap — locate the repo and define logging helpers
# ============================================================
# Resolve REPO_DIR from this script's own location so the dispatcher
# works whether invoked by absolute path, via $PATH, or from inside
# another script.  Mirrors the convention in build-bundle.sh / audit.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APPS_DIR="${REPO_DIR}/config/apps"
METHODS_DIR="${SCRIPT_DIR}/install-methods"

# Colourless logging — keeps output greppable in CI / journal.  Using
# stderr for progress so stdout stays usable for `--list` table.
log()  { printf '[install-apps] %s\n' "$*" >&2; }
warn() { printf '[install-apps] WARN: %s\n' "$*" >&2; }
err()  { printf '[install-apps] ERROR: %s\n' "$*" >&2; }

# ============================================================
# Help — mirrors build-bundle.sh's docstring-extraction pattern
# ============================================================
print_help() {
  # Pull the leading block of '# …' comments after the shebang.  The
  # `sed -n '2,/^$/p'` recipe matches build-bundle.sh exactly, so the
  # two tools render help consistently.
  sed -n '2,/^$/p' "$0"
}

# ============================================================
# Machine-profile detection
# ============================================================
# Always includes "common".  Adds "t14" for laptop chassis (DMI codes
# 8/9/10/14 per SMBIOS §7.4.1 — same predicate as is_laptop_chassis in
# local_setup.sh).  Adds "desktop" if an Nvidia GPU is present (PCI
# vendor 10de) — proxy for the user's 3080Ti tower since that's the
# only non-laptop they own.  Emits a space-separated list.
resolve_profile() {
  local profiles=("common")

  # Laptop check — file-not-found is fine, the regex just won't match.
  local chassis
  chassis="$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || echo)"
  if [[ "$chassis" =~ ^(8|9|10|14)$ ]]; then
    profiles+=("t14")
  fi

  # Nvidia detection — two independent signals because lspci can be
  # missing on minimal installs and /proc/driver/nvidia only exists
  # when the kernel module is loaded.  Either one is sufficient.
  if [[ -e /proc/driver/nvidia/version ]] \
     || (command -v lspci >/dev/null 2>&1 \
         && lspci 2>/dev/null | grep -qi 'vga.*nvidia'); then
    profiles+=("desktop")
  fi

  printf '%s\n' "${profiles[*]}"
}

# ============================================================
# Manifest discovery
# ============================================================
# Find every config/apps/*.toml that ISN'T schema*.toml, _*.toml, or a
# dotfile.  Returns absolute paths, one per line, sorted lexically.
# Empty output is valid — Phase 0 ships zero manifests.
list_manifests() {
  [[ -d "$APPS_DIR" ]] || return 0
  local f base
  for f in "$APPS_DIR"/*.toml; do
    # The glob may not match; the literal pattern is returned in that case.
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    case "$base" in
      schema*.toml) continue ;;
      _*.toml)      continue ;;
      .*)           continue ;;
    esac
    printf '%s\n' "$f"
  done | sort
}

# ============================================================
# TOML → JSON via stdlib tomllib (Python 3.11+, present on Debian 13)
# ============================================================
# Returns JSON on stdout, exits non-zero on parse error.  Kept as a
# function so the same call site is reused by the list / dispatch
# paths — and so we have ONE place to swap parsers later if needed.
toml_to_json() {
  local path="$1"
  python3 -c 'import tomllib, json, sys
with open(sys.argv[1], "rb") as f:
    data = tomllib.loads(f.read().decode("utf-8"))
json.dump(data, sys.stdout)
' "$path"
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

# ============================================================
# --list — print manifests as a table, then exit 0
# ============================================================
do_list() {
  local manifests
  manifests="$(list_manifests)"
  printf '%-24s %-20s %-30s %s\n' "NAME" "METHOD" "MACHINES" "DESCRIPTION"
  printf '%-24s %-20s %-30s %s\n' "----" "------" "--------" "-----------"
  if [[ -z "$manifests" ]]; then
    return 0
  fi
  local m json name method machines description
  while IFS= read -r m; do
    if ! json="$(toml_to_json "$m" 2>/dev/null)"; then
      warn "skipping unparseable manifest: $m"
      continue
    fi
    name="$(json_get "$json" 'meta.name')"
    method="$(json_get "$json" 'install.method')"
    machines="$(json_get "$json" 'meta.machines')"
    description="$(json_get "$json" 'meta.description')"
    printf '%-24s %-20s %-30s %s\n' \
      "${name:-?}" "${method:-?}" "${machines:-?}" "${description:-}"
  done <<<"$manifests"
}

# ============================================================
# Profile-filter — does this app target the current machine?
# ============================================================
# Args: <json blob> <space-separated profile list>
# Returns 0 (install) if intersection is non-empty, 1 otherwise.
manifest_targets_profile() {
  local json="$1" active_profiles="$2"
  local machines wanted active
  machines="$(json_get "$json" 'meta.machines')"
  [[ -n "$machines" ]] || return 1
  for wanted in $machines; do
    for active in $active_profiles; do
      if [[ "$wanted" == "$active" ]]; then
        return 0
      fi
    done
  done
  return 1
}

# ============================================================
# Pin verification — best-effort delegation to verify-pins.sh
# ============================================================
# Phase 0 ships before Agent C, so the script may not exist yet.  Exit
# code 2 means "signature mismatch — REFUSE install" per the contract.
# Any other failure (1, 127, …) is treated as advisory — we log and move
# on.  When the script is absent entirely, the check is skipped silently.
run_verify_pins() {
  local name="$1"
  local script="${SCRIPT_DIR}/verify-pins.sh"
  [[ -x "$script" ]] || return 0
  local rc=0
  "$script" --app "$name" || rc=$?
  case "$rc" in
    0)  return 0 ;;
    2)  err "verify-pins.sh reported signature mismatch for $name — refusing install"
        return 2 ;;
    3)  # "Not found" — caller already failed to find the manifest by
        # filename basename; verify-pins also couldn't find it by name.
        # That's a name-mismatch / typo, not a security event.  Surface
        # the distinction so the dispatcher doesn't tally it as a verify
        # failure.
        err "verify-pins.sh: no manifest matches $name (typo? filename != meta.name?)"
        return 3 ;;
    *)  warn "verify-pins.sh exited $rc for $name (non-fatal)"
        return 0 ;;
  esac
}

# ============================================================
# Hook runner
# ============================================================
# Iterates over hooks.<phase> from JSON, runs each command with the
# {app_dir} and {name} placeholders substituted.  Returns the exit code
# of the first failing command, or 0 if all succeed (or no hooks exist).
run_hooks() {
  local json="$1" phase="$2" name="$3" app_dir="$4"
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
hooks = data.get("hooks", {}).get(sys.argv[2], [])
for h in hooks:
    desc = h.get("description", "")
    cmd  = h.get("command", "")
    print(f"{desc}\t{cmd}")
' "$json" "$phase" | while IFS=$'\t' read -r desc cmd; do
    [[ -n "$cmd" ]] || continue
    local rendered="${cmd//\{app_dir\}/$app_dir}"
    rendered="${rendered//\{name\}/$name}"
    log "hook [$phase]: ${desc:-(no description)}"
    if (( DRY_RUN )); then
      log "  would run: $rendered"
      continue
    fi
    if ! bash -c "$rendered"; then
      err "hook [$phase] failed: $rendered"
      return 2
    fi
  done
}

# ============================================================
# Install one manifest
# ============================================================
# Sets ${INSTALL_RESULT} (installed | skipped | failed) so the caller's
# summary counters stay accurate without parsing log output.
install_one() {
  local manifest="$1"
  local active_profiles="$2"
  INSTALL_RESULT="failed"

  local json
  if ! json="$(toml_to_json "$manifest" 2>/dev/null)"; then
    err "could not parse manifest: $manifest"
    return 1
  fi

  local name method
  name="$(json_get "$json" 'meta.name')"
  method="$(json_get "$json" 'install.method')"
  if [[ -z "$name" || -z "$method" ]]; then
    err "manifest missing meta.name or install.method: $manifest"
    return 1
  fi

  if ! manifest_targets_profile "$json" "$active_profiles"; then
    log "skip ${name}: machines $(json_get "$json" 'meta.machines') ∉ active [$active_profiles]"
    INSTALL_RESULT="skipped"
    return 0
  fi

  # Pre-flight pin verification.  Refuse on exit 2 (signature mismatch).
  # Exit 3 ("not found") shouldn't actually happen here — we already
  # parsed the manifest by filename — but if filename ≠ meta.name, the
  # dispatcher would still proceed.  Treat 3 as a hard refusal too so
  # we don't silently install something verify-pins couldn't anchor.
  local rc=0
  run_verify_pins "$name" || rc=$?
  if (( rc == 2 || rc == 3 )); then
    INSTALL_RESULT="failed"
    return 1
  fi

  # Per-app dir under config/apps/<name>/  is where [configs] sources
  # are resolved relative to, and where the hook {app_dir} placeholder
  # expands.  Doesn't need to exist for the dispatcher itself.
  local app_dir="${APPS_DIR}/${name}"

  # Pre-install hooks — bail on failure.
  if ! run_hooks "$json" "pre_install" "$name" "$app_dir"; then
    err "${name}: pre_install hook failed"
    return 1
  fi

  # Materialise the JSON to a temp file so the adapter receives it as
  # a path (per the contract) instead of via a pipe.  mktemp keeps it
  # in /tmp; trap cleans up on any exit path.
  local json_file
  json_file="$(mktemp -t "install-apps-${name}.XXXXXX.json")"
  printf '%s' "$json" >"$json_file"
  # shellcheck disable=SC2064
  trap "rm -f '$json_file'" RETURN

  local adapter="${METHODS_DIR}/${method}.sh"
  if [[ ! -x "$adapter" ]]; then
    if (( DRY_RUN )); then
      # The adapters are Agent B's deliverable — they likely don't exist
      # yet during Phase 0 validation.  Don't fail dry runs on that.
      log "dry-run: would invoke $adapter (adapter not yet present)"
      echo "installed=false skipped_reason=dry-run"
      INSTALL_RESULT="skipped"
      return 0
    fi
    err "no adapter for method=$method (looked at $adapter)"
    return 1
  fi

  local first_profile
  first_profile="${active_profiles%% *}"

  local adapter_rc=0
  local adapter_out
  if (( DRY_RUN )); then
    log "dry-run ${name}: would invoke ${adapter}"
    adapter_out="installed=false skipped_reason=dry-run"
    echo "$adapter_out"
  else
    # Capture stdout so the dispatcher can parse `installed=…`; stderr
    # passes through unchanged for human progress.
    set +e
    adapter_out="$(DOTFILES_MACHINE="$first_profile" DRY_RUN="$DRY_RUN" REPO_DIR="$REPO_DIR" \
                   "$adapter" "$json_file")"
    adapter_rc=$?
    set -e
    printf '%s\n' "$adapter_out"
  fi

  if (( adapter_rc != 0 )); then
    err "${name}: adapter ${adapter} exited $adapter_rc"
    return 1
  fi

  # Post-install hooks — even on dry-run we still print what would run.
  if ! run_hooks "$json" "post_install" "$name" "$app_dir"; then
    err "${name}: post_install hook failed"
    return 1
  fi

  case "$adapter_out" in
    *installed=true*)  INSTALL_RESULT="installed" ;;
    *)                 INSTALL_RESULT="skipped" ;;
  esac
  return 0
}

# ============================================================
# Argument parsing
# ============================================================
DRY_RUN=0
MODE="all"
TARGET_APP=""
PROFILE_OVERRIDE=""

while (( $# )); do
  case "$1" in
    --all)       MODE="all";       shift ;;
    --app)       MODE="one"; TARGET_APP="${2:-}"; shift 2 ;;
    --dry-run)   DRY_RUN=1;        shift ;;
    --profile)   PROFILE_OVERRIDE="${2:-}"; shift 2 ;;
    --list)      MODE="list";      shift ;;
    -h|--help)   print_help; exit 0 ;;
    *) err "unknown argument: $1"; print_help; exit 64 ;;
  esac
done

if [[ "$MODE" == "one" && -z "$TARGET_APP" ]]; then
  err "--app requires a NAME argument"
  exit 64
fi

# ============================================================
# Dispatch
# ============================================================
if [[ "$MODE" == "list" ]]; then
  do_list
  exit 0
fi

ACTIVE_PROFILES="${PROFILE_OVERRIDE:-$(resolve_profile)}"
log "active machine profiles: $ACTIVE_PROFILES"
(( DRY_RUN )) && log "DRY_RUN=1 — no install adapters will be executed"

MANIFESTS="$(list_manifests)"
if [[ -z "$MANIFESTS" ]]; then
  log "no apps to install (config/apps/ has no manifests yet)"
  exit 0
fi

declare -i COUNT_INSTALLED=0 COUNT_SKIPPED=0 COUNT_FAILED=0

while IFS= read -r manifest; do
  [[ -n "$manifest" ]] || continue
  if [[ "$MODE" == "one" ]]; then
    # Cheap pre-filter so we don't parse every manifest when targeting one.
    base="$(basename "$manifest" .toml)"
    if [[ "$base" != "$TARGET_APP" ]]; then
      # Fall through to a full parse only when basename mismatches but
      # meta.name might still match (defensive — keeps the contract that
      # NAME = meta.name, not filename).
      if ! json_probe="$(toml_to_json "$manifest" 2>/dev/null)"; then
        continue
      fi
      probe_name="$(json_get "$json_probe" 'meta.name')"
      [[ "$probe_name" == "$TARGET_APP" ]] || continue
    fi
  fi

  INSTALL_RESULT="failed"
  # Note: prefix-increment `((++x))` returns the NEW value (so it's
  # non-zero when x was 0), unlike postfix `((x++))` which returns the
  # old value and would trip `set -e` on the very first increment.
  if install_one "$manifest" "$ACTIVE_PROFILES"; then
    case "$INSTALL_RESULT" in
      installed) ((++COUNT_INSTALLED)) ;;
      skipped)   ((++COUNT_SKIPPED))   ;;
      *)         ((++COUNT_SKIPPED))   ;;
    esac
  else
    ((++COUNT_FAILED))
  fi
done <<<"$MANIFESTS"

# ============================================================
# Summary
# ============================================================
log "summary: ${COUNT_INSTALLED} installed, ${COUNT_SKIPPED} skipped, ${COUNT_FAILED} failed"
if (( COUNT_FAILED > 0 )); then
  exit 1
fi
exit 0
