#!/usr/bin/env bash
# scripts/install-apps.sh
#
# Dispatcher for the dotfiles application-install system (schema_version 2).
# Reads every config/apps/*.toml file that contains a top-level
# [[apps]] array — skipping schema*.toml, _*.toml, and dotfiles —
# flattens the entries to an in-memory list, filters by the current
# machine profile, then shells out to scripts/install-methods/<method>.sh
# for the actual work.
#
# Files that parse cleanly but contain NO [[apps]] array are silently
# skipped (so future tier-split files such as core.toml / desktop.toml
# can be added without dispatcher changes).
#
# Usage:
#     scripts/install-apps.sh [--all]                  # default
#     scripts/install-apps.sh --app NAME
#     scripts/install-apps.sh --list
#     scripts/install-apps.sh --dry-run [--app NAME]
#     scripts/install-apps.sh --profile PROFILE [...]  # override auto-detect
#     scripts/install-apps.sh --tier T[,T,...]         # filter by tier 1..5
#     scripts/install-apps.sh --no-validate            # UNSAFE — skip pre-flight
#     scripts/install-apps.sh --help
#
# Machine profiles (resolve_profile):
#     "common"  — always included
#     "t14"     — DMI chassis_type in {8,9,10,14}  (mirror of is_laptop_chassis)
#     "desktop" — Nvidia GPU detected (PCI vendor 10de, or /proc/driver/nvidia)
# The dispatcher installs an app iff its machines list intersects the
# resolved profile set.
#
# Validator gate:
#     Before any per-entry work (including --list / --dry-run),
#     scripts/apps-validate.py runs as a hard pre-flight.  Exit 1
#     (errors) aborts the dispatcher; exit 2 (warnings only) is logged
#     and we continue.  --no-validate skips the gate entirely; use only
#     for debugging a known-bad manifest, never for production runs.
#
# Install-method adapter contract (adapters consume a flattened
# per-app JSON shape this dispatcher builds on the fly from each
# schema-v2 entry; pin.mode is passed through so adapters branch on
# track-latest vs frozen):
#     DOTFILES_MACHINE=<profile> DRY_RUN=<0|1> REPO_DIR=<...> \
#         LOCKFILE_PATH=<abs-path-to-lockfile> \
#         scripts/install-methods/<method>.sh <path-to-manifest-json>
#
#     stdout : ONE line — `installed=true` or `installed=false [ skipped_reason=<str>]`
#     stderr : human progress
#     exit 0 = success or intentional skip
#     exit 1 = pre-flight failure
#     exit 2 = installation error
#
# The JSON file handed to each adapter has this legacy shape:
#     {
#       "meta":   { "name": ..., "machines": [...], "description": ..., ... },
#       "install":{ "method": ..., "<method-subtable>": {...} },
#       "pin":    { "mode": ..., "last_refreshed": ..., "refresh_after_days": ... },
#       "configs":{...},
#       "hooks":  { "pre_install": [...], "post_install": [...] }
#     }
# pin.mode passes through to the adapter unchanged so each adapter can
# branch on track-latest vs frozen.
#
# Pin verification (verify-pins.sh):
#     If verify-pins.sh exits 2 (signature mismatch) or 3 (no manifest
#     matched --app NAME), the app is REFUSED.  Any other non-zero exit
#     is advisory — we log and proceed.  If verify-pins.sh is missing
#     entirely we skip the check.

set -euo pipefail

# ============================================================
# Bootstrap — locate the repo and define logging helpers
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APPS_DIR="${REPO_DIR}/config/apps"
METHODS_DIR="${SCRIPT_DIR}/install-methods"
VALIDATOR="${SCRIPT_DIR}/apps-validate.py"

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

  # Desktop-environment detection (i3 vs plasma).  Three signals in
  # priority order:
  #   1. ~/.config/dotfiles-state/desktop file written by local_setup.sh
  #      when --desktop=X was passed.  Most authoritative.
  #   2. $XDG_CURRENT_DESKTOP env var (set by the running session).
  #   3. Process-name check (pgrep) — works during install when the
  #      user is already in their desktop session.
  # No detection signals = no DE profile added (apps targeting "i3" or
  # "plasma" only just won't install in that case).
  local desktop=""
  local state_file="${HOME}/.config/dotfiles-state/desktop"
  if [[ -r "$state_file" ]]; then
    desktop="$(tr -d '[:space:]' < "$state_file" 2>/dev/null)"
  fi
  if [[ -z "$desktop" && -n "${XDG_CURRENT_DESKTOP:-}" ]]; then
    case "${XDG_CURRENT_DESKTOP,,}" in
      *kde*|*plasma*) desktop="plasma" ;;
      *i3*)           desktop="i3" ;;
    esac
  fi
  if [[ -z "$desktop" ]] && command -v pgrep >/dev/null 2>&1; then
    if pgrep -x plasmashell >/dev/null 2>&1; then
      desktop="plasma"
    elif pgrep -x i3 >/dev/null 2>&1; then
      desktop="i3"
    fi
  fi
  case "$desktop" in
    i3|plasma) profiles+=("$desktop") ;;
  esac

  printf '%s\n' "${profiles[*]}"
}

# ============================================================
# Pre-flight validator gate
# ============================================================
# Shared with verify-pins.sh + refresh-pins.sh so all three entry points
# enforce identical schema-validation policy.  See the library file for
# the full contract; the short version is:
#   0 — clean / warnings-only.  Proceed.
#   1 — errors (or --no-validate without the env co-signature).  Abort.
# shellcheck source=lib/validator-gate.sh
source "${SCRIPT_DIR}/lib/validator-gate.sh"
run_validator() {
  run_apps_validator "$VALIDATOR" "$REPO_DIR" "$NO_VALIDATE"
}

# ============================================================
# Manifest discovery (schema-v2)
# ============================================================
# Find every config/apps/*.toml that ISN'T schema*.toml, _*.toml, or a
# dotfile.  Caller filters further by presence of a top-level [[apps]]
# array (handled in load_entries()).
list_candidate_files() {
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

# Load every [[apps]] entry across the candidate files and emit a flat
# table.  Output format (TSV, one entry per line):
#     <file_path>\t<entry_index>\t<entry_json>
# entry_index is 0-based within its source file.  entry_json is the
# RAW schema-v2 entry dict, NOT yet flattened to the legacy adapter
# shape — install_one() does that shim conversion right before invoking
# the adapter.
#
# Files that parse cleanly but lack a top-level [[apps]] array are
# silently skipped (this is how the three legacy per-file manifests
# coexist during the transition).  Files that fail to parse emit a
# warning but do not abort discovery — the validator gate already
# caught real schema problems; here we just want to not crash on a
# weird sibling file.
load_entries() {
  local files
  files="$(list_candidate_files)"
  [[ -n "$files" ]] || return 0
  # Pass the file list via env var rather than stdin: combining heredoc
  # (<<'PY') with here-string (<<<"$files") on the same stream causes
  # the heredoc to be silently lost — the Python code never runs and
  # the path strings get parsed as Python (SyntaxError).
  APPS_FILES="$files" python3 - "$REPO_DIR" <<'PY'
import json
import os
import sys
import tomllib
from pathlib import Path

repo_dir = Path(sys.argv[1])
paths = [Path(line) for line in os.environ.get("APPS_FILES", "").splitlines() if line.strip()]
for p in paths:
    try:
        with open(p, "rb") as fh:
            data = tomllib.load(fh)
    except (tomllib.TOMLDecodeError, OSError, UnicodeDecodeError) as exc:
        # Mirror the dispatcher's "skip unparseable, don't crash" rule.
        # The validator gate (run earlier in the dispatch) would have
        # rejected an apps.toml-shaped file with this problem; if we
        # arrive here it's either --no-validate or a non-apps file
        # we should never have tried to parse anyway.
        print(f"# WARN unparseable {p}: {exc}", file=sys.stderr)
        continue
    apps = data.get("apps")
    # Silent-skip files without [[apps]] — that's where the legacy
    # per-file manifests live.
    if not isinstance(apps, list):
        continue
    for idx, entry in enumerate(apps):
        if not isinstance(entry, dict):
            continue
        # TSV: <path>\t<idx>\t<json>
        sys.stdout.write(
            f"{p}\t{idx}\t{json.dumps(entry, separators=(',', ':'))}\n"
        )
PY
}

# ============================================================
# JSON helpers (Python 3.11+, stdlib only)
# ============================================================
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

# Convert a schema-v2 [[apps]] entry into the legacy per-file shape the
# adapters consume.  Output: JSON object on stdout.
#
# Mapping:
#   entry.{name,display_name,machines,description,docs_url,enabled}
#     → meta.{name,display_name,machines,description,docs_url,enabled}
#   entry.install     → install      (unchanged shape)
#   entry.pin         → pin          (pass-through, INCLUDING pin.mode
#                                     so adapters branch on track-latest
#                                     vs frozen)
#   entry.configs     → configs      (unchanged)
#   entry.hooks       → hooks        (unchanged)
#   entry.browser_extensions → DROPPED for adapters
#                              (consumed by browser-policies-gen.py
#                              earlier via pre_install hook, not by the
#                              method adapter).
entry_to_legacy_json() {
  local entry_json="$1"
  python3 -c '
import json, sys
entry = json.loads(sys.argv[1])
meta_keys = ("name", "display_name", "machines", "description", "docs_url", "enabled")
meta = {}
for k in meta_keys:
    if k in entry:
        meta[k] = entry[k]
out = {"meta": meta}
if isinstance(entry.get("install"), dict):
    out["install"] = entry["install"]
if isinstance(entry.get("pin"), dict):
    # Pass pin through verbatim — including pin.mode, which adapters
    # branch on (github-release frozen vs track-latest, etc.).
    pin = dict(entry["pin"])
    out["pin"] = pin
if isinstance(entry.get("configs"), dict):
    out["configs"] = entry["configs"]
if isinstance(entry.get("hooks"), dict):
    out["hooks"] = entry["hooks"]
json.dump(out, sys.stdout, separators=(",", ":"))
' "$entry_json"
}

# ============================================================
# --list — print every loaded entry as a table, then exit 0
# ============================================================
# Honours --tier when set: entries filtered out of the install set are
# also hidden from the table (so the user doesn't see 17 apps when they
# asked --tier 1, which would install ~5).
do_list() {
  printf '%-24s %-20s %-30s %s\n' "NAME" "METHOD" "MACHINES" "DESCRIPTION"
  printf '%-24s %-20s %-30s %s\n' "----" "------" "--------" "-----------"
  local entries
  entries="$(load_entries)" || return 0
  [[ -n "$entries" ]] || return 0
  local _path _idx entry_json name method machines description
  # Read TSV: path<TAB>idx<TAB>entry_json
  while IFS=$'\t' read -r _path _idx entry_json; do
    [[ -n "$entry_json" ]] || continue
    if ! entry_passes_tier_filter "$entry_json" "$TIER_FILTER"; then
      continue
    fi
    name="$(json_get "$entry_json" 'name')"
    method="$(json_get "$entry_json" 'install.method')"
    machines="$(json_get "$entry_json" 'machines')"
    description="$(json_get "$entry_json" 'description')"
    printf '%-24s %-20s %-30s %s\n' \
      "${name:-?}" "${method:-?}" "${machines:-?}" "${description:-}"
  done <<<"$entries"
}

# ============================================================
# Tier filtering — normalise + match the optional [[apps]].tier field
# ============================================================
# Args: <raw --tier value, e.g. "1,4" or "tier1,tier4">
# Stdout: normalised space-separated set of integers (e.g. "1 4").
# Exits 2 with a clean error if anything is outside the {1,2,3,4,5} set.
#
# Accepts both bare integers and the ergonomic `tierN` alias so users
# can type `--tier tier1` interchangeably with `--tier 1`.
parse_tier_set() {
  local raw="$1"
  [[ -n "$raw" ]] || { err "--tier requires a value"; exit 2; }
  local token tiers=() t
  IFS=',' read -ra tiers <<<"$raw"
  for token in "${tiers[@]}"; do
    # Trim whitespace and strip a leading "tier" prefix (case-insensitive
    # on the prefix only — the digit part stays raw for the regex check).
    t="${token## }"; t="${t%% }"
    t="${t#[Tt][Ii][Ee][Rr]}"
    if [[ ! "$t" =~ ^[1-5]$ ]]; then
      err "--tier value '${token}' is not in {1,2,3,4,5}"
      exit 2
    fi
    printf '%s ' "$t"
  done
  printf '\n'
}

# Args: <entry-json> <space-separated tier set>
# Returns 0 if the entry should be installed under the current tier
# filter, 1 if it should be skipped.  Entries with no `tier` field always
# pass — the rationale is that small universal tools shouldn't be
# accidentally filtered out by a per-tier install run.
entry_passes_tier_filter() {
  local json="$1" tier_set="$2"
  [[ -z "$tier_set" ]] && return 0   # no filter → always pass
  local entry_tier
  entry_tier="$(json_get "$json" 'tier')"
  [[ -z "$entry_tier" ]] && return 0  # no tier field → always pass
  local t
  for t in $tier_set; do
    [[ "$t" == "$entry_tier" ]] && return 0
  done
  return 1
}

# ============================================================
# Profile-filter — does this entry target the current machine?
# ============================================================
# Args: <entry json blob> <space-separated profile list>
# Returns 0 (install) if intersection is non-empty, 1 otherwise.
# entry.machines lives at the top of the [[apps]] entry, NOT under
# meta — that's the schema-v2 layout.
entry_targets_profile() {
  local json="$1" active_profiles="$2"
  local machines wanted active
  machines="$(json_get "$json" 'machines')"
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
# Exit code 2 means "signature mismatch — REFUSE install" per the
# contract.  Exit 3 means "name not found" — treat as a hard refusal so
# we don't silently install something verify-pins couldn't anchor.  Any
# other failure (1, 127, …) is treated as advisory — we log and move
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
    3)  err "verify-pins.sh: no manifest matches $name (typo? name != [[apps]].name?)"
        return 3 ;;
    *)  warn "verify-pins.sh exited $rc for $name (non-fatal)"
        return 0 ;;
  esac
}

# ============================================================
# Hook runner
# ============================================================
# Iterates over hooks.<phase> from the legacy-shape JSON (which is what
# we just built in install_one()), runs each command with the
# {app_dir} and {name} placeholders substituted.  Returns the exit code
# of the first failing command, or 0 if all succeed (or no hooks exist).
#
# TRUST BOUNDARY:
#   Every hook command is fed verbatim to `bash -c` after a naive
#   string substitution for {app_dir} and {name} — there is NO escaping,
#   quoting, or shell-metacharacter sanitisation.  By design: hooks are
#   arbitrary shell.  But that makes apps.toml fully trusted input —
#   anyone who can edit it can execute arbitrary code as the install user.
#
#   The hard pre-flight gate at run_validator() is what makes this safe:
#   it enforces a strict regex on `name` (kebab-case, ≤64 chars, NUL- and
#   length-bounded `command`) so corrupted-but-syntactically-valid TOML
#   cannot smuggle metacharacters into the substitution.
#
#   Never call run_hooks() from a code path that bypasses the validator
#   gate.  --no-validate exists only for one-off debugging of a known-bad
#   manifest and is co-signature-gated by DOTFILES_ALLOW_UNVALIDATED=1.
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
# Install one entry
# ============================================================
# Args: <source file path> <entry index in file> <schema-v2 entry json>
#       <active profile list>
# Sets ${INSTALL_RESULT} (installed | skipped | failed) so the caller's
# summary counters stay accurate without parsing log output.
install_one() {
  local source_file="$1"
  local entry_index="$2"
  local entry_json="$3"
  local active_profiles="$4"
  INSTALL_RESULT="failed"

  local name method
  name="$(json_get "$entry_json" 'name')"
  method="$(json_get "$entry_json" 'install.method')"
  if [[ -z "$name" || -z "$method" ]]; then
    err "entry #${entry_index} in $(basename "$source_file") missing name or install.method"
    return 1
  fi

  # `enabled = false` opts an entry out without deleting it.  Used by
  # entries that ship in the manifest but are NOT installed by default —
  # currently the `code` (Microsoft VSCode) opt-in.  Also honored by
  # per-machine overrides under ~/.config/dotfiles-local/apps.toml that
  # set `enabled = false` for an app on a specific host.
  #
  # Missing `enabled` field → defaults to true (the common case).  Only
  # the literal string "false" disables.
  local enabled
  enabled="$(json_get "$entry_json" 'enabled')"
  if [[ "$enabled" == "false" ]]; then
    log "skip ${name}: enabled = false"
    INSTALL_RESULT="skipped"
    return 0
  fi

  if ! entry_targets_profile "$entry_json" "$active_profiles"; then
    log "skip ${name}: machines $(json_get "$entry_json" 'machines') ∉ active [$active_profiles]"
    INSTALL_RESULT="skipped"
    return 0
  fi

  # Tier filter — applied AFTER profile filtering so the more-specific
  # diagnostic ("wrong machine") fires first when both miss.  Entries with
  # no `tier` field always pass (see entry_passes_tier_filter for the
  # rationale).  Skip line is only printed for tier-bearing entries —
  # ordinary (no-tier) entries are noiseless because they always run.
  if ! entry_passes_tier_filter "$entry_json" "$TIER_FILTER"; then
    local entry_tier
    entry_tier="$(json_get "$entry_json" 'tier')"
    log "skip ${name}: tier ${entry_tier} not in requested {${TIER_FILTER// /,}}"
    INSTALL_RESULT="skipped"
    return 0
  fi

  # Pre-flight pin verification.  Refuse on exit 2 (signature mismatch).
  # Exit 3 ("not found") shouldn't actually happen here — we already
  # have the entry in hand — but if [[apps]] entries on disk drift from
  # verify-pins.sh's discovery rules, the dispatcher would still proceed.
  # Treat 3 as a hard refusal too so we don't silently install something
  # verify-pins couldn't anchor.
  local rc=0
  run_verify_pins "$name" || rc=$?
  if (( rc == 2 || rc == 3 )); then
    INSTALL_RESULT="failed"
    return 1
  fi

  # Build the legacy-shape JSON the adapters expect — meta/install/pin/
  # configs/hooks at the top level, with name/machines/etc. nested under
  # meta.  This shim keeps the 4 install-methods/*.sh adapters working
  # unchanged during the schema-v2 transition.
  local legacy_json
  if ! legacy_json="$(entry_to_legacy_json "$entry_json" 2>/dev/null)"; then
    err "could not transform ${name} to legacy adapter shape"
    return 1
  fi

  # Per-app dir under config/apps/<name>/  is where [configs] sources
  # are resolved relative to, and where the hook {app_dir} placeholder
  # expands.  Doesn't need to exist for the dispatcher itself.
  local app_dir="${APPS_DIR}/${name}"

  # Pre-install hooks — bail on failure.
  if ! run_hooks "$legacy_json" "pre_install" "$name" "$app_dir"; then
    err "${name}: pre_install hook failed"
    return 1
  fi

  # Materialise the JSON to a temp file so the adapter receives it as
  # a path (per the contract) instead of via a pipe.  mktemp keeps it
  # in /tmp; trap cleans up on any exit path.
  local json_file
  json_file="$(mktemp -t "install-apps-${name}.XXXXXX.json")"
  printf '%s' "$legacy_json" >"$json_file"
  # shellcheck disable=SC2064
  trap "rm -f '$json_file'" RETURN

  local adapter="${METHODS_DIR}/${method}.sh"
  if [[ ! -x "$adapter" ]]; then
    if (( DRY_RUN )); then
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

  # Lockfile contract: dispatcher computes the path, adapter writes
  # the file.  One file per app under config/apps/.locks/<name>.lock.
  # In DRY_RUN the env var is still set (so adapters can echo "would
  # write to ...") but adapters MUST NOT actually touch the file.
  local lockfile_path="${REPO_DIR}/config/apps/.locks/${name}.lock"

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
                   LOCKFILE_PATH="$lockfile_path" \
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
  if ! run_hooks "$legacy_json" "post_install" "$name" "$app_dir"; then
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
NO_VALIDATE=0
MODE="all"
TARGET_APP=""
PROFILE_OVERRIDE=""
TIER_FILTER_RAW=""   # raw user input (pre-normalisation)
TIER_FILTER=""       # normalised space-separated set; empty = no filter
TIER_FILTER_SEEN=0   # was --tier passed at all?  (separates "no flag" from
                     # "flag with empty value" — the latter is an error.)

while (( $# )); do
  case "$1" in
    --all)         MODE="all";       shift ;;
    --app)         MODE="one"; TARGET_APP="${2:-}"; shift 2 ;;
    --dry-run)     DRY_RUN=1;        shift ;;
    --profile)     PROFILE_OVERRIDE="${2:-}"; shift 2 ;;
    --tier)        TIER_FILTER_SEEN=1; TIER_FILTER_RAW="${2:-}"; shift 2 ;;
    --list)        MODE="list";      shift ;;
    --no-validate) NO_VALIDATE=1;    shift ;;
    -h|--help)     print_help; exit 0 ;;
    *) err "unknown argument: $1"; print_help; exit 64 ;;
  esac
done

if [[ "$MODE" == "one" && -z "$TARGET_APP" ]]; then
  err "--app requires a NAME argument"
  exit 64
fi

# ============================================================
# Pre-flight: validator gate (applies to --list / --dry-run too)
# ============================================================
# Validate the manifests first so a broken apps.toml is the surfaced
# failure, not a tier-filter side effect.  The tier filter is a
# downstream selector — its own validity is checked next.
if ! run_validator; then
  exit 1
fi

# Normalise --tier AFTER the validator gate so the manifest is known good
# before we attempt to apply the filter.  parse_tier_set exits 2 itself
# on bad input; trimming trailing whitespace keeps the set tidy.  If
# --tier was passed with an empty value, that's an error — the user
# clearly intended to filter but provided nothing actionable.
if (( TIER_FILTER_SEEN )); then
  if [[ -z "$TIER_FILTER_RAW" ]]; then
    err "--tier requires a value (e.g. --tier 1 or --tier tier1,tier4)"
    exit 2
  fi
  TIER_FILTER="$(parse_tier_set "$TIER_FILTER_RAW")"
  TIER_FILTER="${TIER_FILTER%% }"
  TIER_FILTER="${TIER_FILTER%$'\n'}"
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

ENTRIES="$(load_entries)"
if [[ -z "$ENTRIES" ]]; then
  log "no apps to install (no apps.toml-shaped manifests under config/apps/)"
  exit 0
fi

declare -i COUNT_INSTALLED=0 COUNT_SKIPPED=0 COUNT_FAILED=0

# Read TSV stream: <source_file>\t<entry_index>\t<schema-v2 entry json>
while IFS=$'\t' read -r src_file entry_idx entry_json; do
  [[ -n "$entry_json" ]] || continue

  if [[ "$MODE" == "one" ]]; then
    # Filter by the schema-v2 `name` field — that's the canonical key.
    probe_name="$(json_get "$entry_json" 'name')"
    [[ "$probe_name" == "$TARGET_APP" ]] || continue
  fi

  INSTALL_RESULT="failed"
  # Note: prefix-increment `((++x))` returns the NEW value (so it's
  # non-zero when x was 0), unlike postfix `((x++))` which returns the
  # old value and would trip `set -e` on the very first increment.
  if install_one "$src_file" "$entry_idx" "$entry_json" "$ACTIVE_PROFILES"; then
    case "$INSTALL_RESULT" in
      installed) ((++COUNT_INSTALLED)) ;;
      skipped)   ((++COUNT_SKIPPED))   ;;
      *)         ((++COUNT_SKIPPED))   ;;
    esac
  else
    ((++COUNT_FAILED))
  fi
done <<<"$ENTRIES"

# ============================================================
# Summary
# ============================================================
log "summary: ${COUNT_INSTALLED} installed, ${COUNT_SKIPPED} skipped, ${COUNT_FAILED} failed"
if (( COUNT_FAILED > 0 )); then
  exit 1
fi
exit 0
