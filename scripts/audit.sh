#!/usr/bin/env bash
# scripts/audit.sh
#
# "Did anything change since I last ran this?" — a fast, cron-friendly
# summary that re-derives the *current* state of each
# ~/.config/conky/baseline-*.txt file and diffs it against the stored
# baseline.  This is the CLI counterpart to the drift checks in
# ~/.config/conky/health.py (check_port_drift, check_module_drift,
# check_critical_file_drift, check_suid_drift).
#
# Why a separate script and not just `python3 health.py`?  health.py
# is a conky panel renderer — it returns conky template strings, runs
# 18 different checks (most of which don't relate to drift), and has
# tight latency budgets that exclude expensive scans like the
# full-rootfs SUID find.  This script does the FOUR drift checks
# only, in plain text, suitable for cron + MAILTO=.
#
# We deliberately do NOT import health.py — each baseline name maps to
# a small inline "regenerate current" + diff function in bash so
# audit.sh has no Python dependency and can be debugged with `bash -x`.
#
# Baseline-name → format table:
#   ports          one "host:port" per line              ss -tln
#   modules        "<name> <use_count>" per line         lsmod
#   critical-files "<sha256>  <path>" per line           sha256sum on /etc/passwd, sudoers.d, etc.
#   suid           "<sha256>  <path>" per line           find / -perm -4000/-2000, then sha256sum
#   pins           NOT a baseline file — a live shell-out to
#                  scripts/verify-pins.sh --json that surfaces app
#                  pin freshness + sha/gpg verification status as a
#                  pseudo-baseline row.  See gen_pins() below.
#
# Exit code:
#   0  — every baseline is OK or WARN
#   1  — at least one baseline is BAD  (cron + MAILTO catches this)
#   2  — usage / argument error
#
# Usage:
#   ./scripts/audit.sh
#   ./scripts/audit.sh --json
#   ./scripts/audit.sh --refresh-baseline <name>
#   ./scripts/audit.sh --help

set -euo pipefail

# ── Colour helpers (same palette as scripts/build-bundle.sh) ───────
if [[ -t 1 ]]; then
    C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'
    C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
    C_OK= ; C_WARN= ; C_ERR= ; C_DIM= ; C_RST=
fi
log()  { echo "${C_DIM}[*]${C_RST} $*"; }
ok()   { echo "${C_OK}[ok]${C_RST} $*"; }
warn() { echo "${C_WARN}[!]${C_RST} $*" >&2; }
err()  { echo "${C_ERR}[!!]${C_RST} $*" >&2; }
die()  { err "$*"; exit 2; }

# ── Resolve own location regardless of CWD ─────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# REPO_DIR currently unused but kept for symmetry with build-bundle.sh
# in case future audits want to compare against repo state.
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
: "${REPO_DIR:?}"   # silence shellcheck

BASELINE_DIR="${HOME}/.config/conky"

# Baseline registry.  To add a new baseline:
#   1. Add a row to BASELINES (name).
#   2. Implement gen_<name>() that prints current state to stdout in the
#      same format the baseline file uses.
#   3. (Optional) Implement diff_<name>() if the format needs special
#      handling — otherwise the generic line-set diff is used.
BASELINES=(ports modules critical-files suid pins)

# ── Argument parsing (mirrors build-bundle.sh's pattern) ───────────
OUTPUT_JSON=0
REFRESH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)
            OUTPUT_JSON=1
            ;;
        --refresh-baseline)
            REFRESH="${2:-}"
            [[ -z "$REFRESH" ]] && die "--refresh-baseline requires a name (one of: ${BASELINES[*]})"
            shift
            ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            die "Unknown flag: $1 (try --help)"
            ;;
    esac
    shift
done

# Validate --refresh-baseline target up front so a typo doesn't silently
# regenerate the wrong baseline.
if [[ -n "$REFRESH" ]]; then
    found=0
    for b in "${BASELINES[@]}"; do
        [[ "$b" == "$REFRESH" ]] && found=1
    done
    (( found )) || die "Unknown baseline: $REFRESH (one of: ${BASELINES[*]})"
fi

# ── Generators: print current state in the same format as the baseline ─
# Each gen_*() is responsible for tolerating missing tools / permission
# errors and printing what it can.  Lines must match what health.py
# would have written so the diff is meaningful.

gen_ports() {
    # Mirror check_port_drift in health.py: TCP listening sockets,
    # tagged with bind address so 0.0.0.0:5900 vs 127.0.0.1:5900 show
    # up as different.  We sort the output so the baseline file is
    # deterministic across runs.
    ss -tln 2>/dev/null | awk 'NR>1 {
        local=$4
        # rsplit on last colon: port is after, host is before.
        n=split(local, parts, ":")
        port=parts[n]
        # rebuild host as everything before the last colon
        host=""
        for (i=1; i<n; i++) { host = host (i>1 ? ":" : "") parts[i] }
        if (host=="") host="*"
        if (port ~ /^[0-9]+$/) print host ":" port
    }' | LC_ALL=C sort -u
}

gen_modules() {
    # Mirror check_module_drift: drop header, keep only name + use_count
    # (NOT the size, which can vary across kernel rebuilds).
    lsmod 2>/dev/null | awk 'NR>1 && NF>=3 {print $1, $3}' | LC_ALL=C sort -u
}

gen_critical-files() {
    # Mirror check_critical_file_drift: hash /etc/passwd, /etc/group,
    # /etc/sudoers (+ drop-ins), authorized_keys, every systemd unit
    # we've installed locally, every cron.d job, and /etc/shadow (if
    # sudo -n works — otherwise silently skipped, same as health.py).
    local files=()
    files+=(/etc/passwd /etc/group /etc/sudoers)
    if [[ -d /etc/sudoers.d ]]; then
        while IFS= read -r -d '' f; do files+=("$f"); done \
          < <(find /etc/sudoers.d -maxdepth 1 -type f -print0 2>/dev/null)
    fi
    [[ -f "${HOME}/.ssh/authorized_keys" ]] && files+=("${HOME}/.ssh/authorized_keys")
    if [[ -d /etc/systemd/system ]]; then
        # `find -L` follows symlinks so .target.wants/<unit>.service
        # symlinks resolve to their target and -type f matches.  This
        # matches health.py's Path.rglob + p.is_file() behaviour where
        # Path.is_file() returns True for a symlink whose target is a
        # regular file.  Without -L we'd miss ~all units (Debian wires
        # everything via /etc/systemd/system/*.target.wants/ symlinks).
        while IFS= read -r -d '' f; do files+=("$f"); done \
          < <(find -L /etc/systemd/system -type f -name '*.service' -print0 2>/dev/null)
    fi
    if [[ -d /etc/cron.d ]]; then
        while IFS= read -r -d '' f; do files+=("$f"); done \
          < <(find /etc/cron.d -maxdepth 1 -type f -print0 2>/dev/null)
    fi

    # Hash everything we can read.  /etc/shadow is sudo-only; try
    # non-interactive sudo and tolerate denial silently — health.py
    # behaves the same way, so the diff stays consistent.
    local f sum
    for f in "${files[@]}"; do
        [[ -r "$f" ]] || continue
        if sum="$(sha256sum -- "$f" 2>/dev/null)"; then
            echo "$sum"
        fi
    done
    if sudo -n true 2>/dev/null; then
        if sum="$(sudo -n sha256sum -- /etc/shadow 2>/dev/null)"; then
            echo "$sum"
        fi
    fi
    # The baseline file is written sorted-by-path (second field); match
    # that so the diff is line-aligned.
    # (sha256sum output is "<sum>  <path>" — sort by path = field 2.)
    # Re-emit through sort -k2.
    # Note: we sort the WHOLE output after collecting it, by piping
    # this function's stdout through sort -k2 at the call site below.
}

gen_pins() {
    # `pins` is a PSEUDO-baseline: there's no on-disk baseline-pins.txt
    # to diff against — instead we shell out to scripts/verify-pins.sh
    # --json (Phase 0 supply-chain check) and produce a deterministic
    # text representation here so the existing diff_/audit_one driver
    # is happy.  Emits one line per app:
    #     <status>:<name>:<detail>
    # where <status> ∈ {ok, stale, bad} and the colons partition the
    # row for parse_pins_summary() below.  Returns empty on missing
    # script (Agent C hasn't landed yet) — audit_one() then short-
    # circuits to a DIM row rather than a spurious BAD.
    local vp="${SCRIPT_DIR}/verify-pins.sh"
    if [[ ! -x "$vp" ]]; then
        # Sentinel line — caller (audit_one_pins) recognises it.
        echo "missing:verify-pins.sh:script not found"
        return 0
    fi
    # --json is preferred so we can parse without ANSI/format drift.
    # Tolerate non-zero exit codes (1 = stale, 2 = bad verification)
    # by capturing rc separately and feeding only stdout downstream.
    local out
    if ! out="$("$vp" --json 2>/dev/null)"; then
        : # rc captured by caller via run; output may still be valid JSON
    fi
    if [[ -z "$out" ]]; then
        echo "missing:verify-pins.sh:no output"
        return 0
    fi
    # Parse JSON via python3 — already in the dotfiles dep set (conky
    # health.py, local_setup.sh's font extract, audit_one's caller).
    # We deliberately tolerate malformed JSON (e.g. Agent C ships a
    # newer schema we don't recognise yet) by falling back to a
    # single-line "parse-error" sentinel.  The here-string feeds JSON
    # to python's stdin; the inline script is the python source.
    python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read())
except Exception as e:
    print(f"missing:verify-pins.sh:json parse error ({type(e).__name__})")
    sys.exit(0)
# Agent C ships verify-pins.sh --json emitting a top-level JSON array
# of per-app records.  Accept either that or a {"apps": [...]} wrapper
# so we are resilient if the format gets nested later.
if isinstance(d, list):
    apps = d
else:
    apps = d.get("apps") or d.get("results") or []
for a in apps:
    name   = a.get("name", "?")
    status = a.get("status", "ok")
    detail = a.get("detail") or a.get("reason") or ""
    age    = a.get("days_old")
    if age is None:
        age = a.get("age_days")
    if age is not None and not detail:
        detail = f"age={age}d"
    name   = str(name).replace(":", "_")
    status = str(status).replace(":", "_")
    detail = str(detail).replace(":", " ").replace("\n", " ")
    print(f"{status}:{name}:{detail}")
' <<<"$out"
}

gen_suid() {
    # Mirror check_suid_drift: a full-rootfs find for SUID/SGID files,
    # then sha256sum each.  Slow (30-60s).  -xdev keeps us off network
    # /FUSE mounts.  We surface failure-to-stat as a skip, never an
    # abort.
    local f sum
    while IFS= read -r f; do
        [[ -n "$f" && -r "$f" ]] || continue
        if sum="$(sha256sum -- "$f" 2>/dev/null)"; then
            echo "$sum"
        fi
    done < <(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null)
}

# ── Format the generator output to match the baseline file ─────────
# The on-disk baselines for critical-files and suid are sorted by path
# (the second field of sha256sum's output).  Re-pipe through sort so
# the generators' raw output matches the baseline format.
gen_current() {
    local name="$1"
    case "$name" in
        critical-files|suid)
            "gen_${name}" | LC_ALL=C sort -k2
            ;;
        *)
            "gen_${name}"
            ;;
    esac
}

# ── Diff: returns a (status, summary) pair via globals  ────────────
# DIFF_STATUS = ok | warn | bad | dim
# DIFF_SUMMARY = human-readable one-liner
# Reasoning behind status mapping (consistent with health.py):
#   * Additions are scarier than removals (new listener / new SUID =
#     persistence pattern).  bad.
#   * Removals alone = something legitimately turned off or uninstalled.
#     warn.
#   * For critical-files, ANY change (changed/added/removed) = bad —
#     /etc/sudoers etc. should be inert.
DIFF_STATUS=""
DIFF_SUMMARY=""

diff_generic_set() {
    # Generic line-set diff for ports / modules.  Each line is a unique
    # "key" already (host:port or "module count").  We re-sort both
    # sides before piping to `comm` because the on-disk baseline may
    # have been hand-edited (or appended to by a manual `echo >>`) and
    # `comm` aborts with "input not in sorted order" if either input
    # isn't sorted — silently losing the entire diff.
    local name="$1" baseline="$2" current="$3"
    local sorted_b sorted_c
    sorted_b="$(LC_ALL=C sort -u <<<"$baseline")"
    sorted_c="$(LC_ALL=C sort -u <<<"$current")"
    local added removed
    added="$(LC_ALL=C comm -23 <(echo "$sorted_c") <(echo "$sorted_b"))"
    removed="$(LC_ALL=C comm -13 <(echo "$sorted_c") <(echo "$sorted_b"))"
    local n_add n_rem
    n_add=$([[ -n "$added"   ]] && echo "$added"   | wc -l || echo 0)
    n_rem=$([[ -n "$removed" ]] && echo "$removed" | wc -l || echo 0)
    if (( n_add == 0 && n_rem == 0 )); then
        DIFF_STATUS="ok"
        DIFF_SUMMARY="unchanged ($(echo "$current" | grep -c '.' || true))"
        return
    fi
    local bits=()
    if (( n_add > 0 )); then
        # Show first addition as a sample for the "what changed" hint.
        bits+=("+${n_add} $(echo "$added"   | head -1)")
    fi
    if (( n_rem > 0 )); then
        bits+=("-${n_rem} $(echo "$removed" | head -1)")
    fi
    if (( n_add > 0 )); then
        DIFF_STATUS="bad"
    else
        DIFF_STATUS="warn"
    fi
    DIFF_SUMMARY="${bits[*]}"
}

diff_hashed_files() {
    # critical-files / suid: lines are "<sha>  <path>".  We compare on
    # path-set membership PLUS hash mismatch on overlap.
    local name="$1" baseline="$2" current="$3"
    # Build path→sha maps via temp files (associative arrays would be
    # cleaner but we want bash 4 portability; on Debian 13 we're fine
    # either way, but tempfiles make this easier to reason about).
    local tmp_b tmp_c
    tmp_b="$(mktemp)"; tmp_c="$(mktemp)"
    # `trap … RETURN` would be cleaner but adds bash-version footguns;
    # just clean up at the end of the function.
    echo "$baseline" | awk 'NF>=2 {sha=$1; $1=""; sub(/^ +/,""); print $0 "\t" sha}' \
        | LC_ALL=C sort > "$tmp_b"
    echo "$current"  | awk 'NF>=2 {sha=$1; $1=""; sub(/^ +/,""); print $0 "\t" sha}' \
        | LC_ALL=C sort > "$tmp_c"

    # Added paths: in current, not in baseline.
    local added removed changed
    added="$(LC_ALL=C comm -23 <(cut -f1 "$tmp_c") <(cut -f1 "$tmp_b"))"
    removed="$(LC_ALL=C comm -13 <(cut -f1 "$tmp_c") <(cut -f1 "$tmp_b"))"
    # Changed: paths in both, with differing sha.
    # Join on path (field 1); print path when sha-baseline != sha-current.
    changed="$(LC_ALL=C join -t $'\t' -j 1 "$tmp_b" "$tmp_c" \
                 | awk -F'\t' '$2 != $3 {print $1}')"

    rm -f "$tmp_b" "$tmp_c"

    local n_add n_rem n_chg
    n_add=$([[ -n "$added"   ]] && echo "$added"   | wc -l || echo 0)
    n_rem=$([[ -n "$removed" ]] && echo "$removed" | wc -l || echo 0)
    n_chg=$([[ -n "$changed" ]] && echo "$changed" | wc -l || echo 0)

    if (( n_add == 0 && n_rem == 0 && n_chg == 0 )); then
        DIFF_STATUS="ok"
        DIFF_SUMMARY="unchanged ($(echo "$current" | grep -c '.' || true))"
        return
    fi

    local bits=()
    if (( n_chg > 0 )); then
        bits+=("${n_chg} changed: $(echo "$changed" | head -1)")
    fi
    if (( n_add > 0 )); then
        bits+=("+${n_add} $(echo "$added" | head -1)")
    fi
    if (( n_rem > 0 )); then
        bits+=("-${n_rem} $(echo "$removed" | head -1)")
    fi

    # For these two baselines (critical-files, suid) ANY change to a
    # tracked path is a security-relevant event — file modified, file
    # added, even files removed (uninstalled SUID binary you didn't
    # uninstall = also suspicious).  Map all three to BAD unless the
    # ONLY change is a removal (warn — apt may legitimately drop a
    # setcap'd helper between releases).
    if (( n_chg > 0 || n_add > 0 )); then
        DIFF_STATUS="bad"
    else
        DIFF_STATUS="warn"
    fi
    DIFF_SUMMARY="${bits[*]}"
}

diff_modules() {
    # Modules baseline lines are "<name> <use_count>" — but use_count
    # legitimately fluctuates on i915/nvidia between renders (a graphics
    # client opening/closing bumps it), so a whole-line diff would
    # false-positive constantly.  health.py's check_module_drift compares
    # NAME-ONLY for this reason; mirror that here.  We strip both sides
    # to field 1 before invoking the generic set differ.
    local name="$1" baseline="$2" current="$3"
    local b_names c_names
    b_names="$(awk 'NF{print $1}' <<<"$baseline")"
    c_names="$(awk 'NF{print $1}' <<<"$current")"
    diff_generic_set "$name" "$b_names" "$c_names"
}

# Dispatch table.
run_diff() {
    local name="$1" baseline="$2" current="$3"
    case "$name" in
        critical-files|suid) diff_hashed_files "$name" "$baseline" "$current" ;;
        modules)             diff_modules      "$name" "$baseline" "$current" ;;
        *)                   diff_generic_set  "$name" "$baseline" "$current" ;;
    esac
}

# ── pins: pseudo-baseline driver ───────────────────────────────────
# `pins` doesn't have an on-disk baseline (the legit state is whatever
# verify-pins.sh says right now), so we skip audit_one's read/diff path
# entirely and compute DIFF_STATUS / DIFF_SUMMARY from gen_pins()'s
# tagged output.  Status mapping mirrors verify-pins.sh exit codes:
#   any "bad:…"     row → DIFF_STATUS=bad
#   else any "stale:…" → DIFF_STATUS=warn
#   else missing sentinel → DIFF_STATUS=dim
#   else                → DIFF_STATUS=ok
audit_pins() {
    local out n_total n_ok n_stale n_bad oldest_app oldest_age first_bad
    out="$(gen_pins 2>/dev/null || true)"
    if [[ -z "$out" ]]; then
        DIFF_STATUS="dim"
        DIFF_SUMMARY="gen_pins produced no output"
        return
    fi
    # Sentinel — verify-pins.sh isn't on disk yet (Agent C pending).
    if [[ "$out" =~ ^missing: ]]; then
        DIFF_STATUS="dim"
        DIFF_SUMMARY="$(head -1 <<<"$out" | awk -F: '{print $2": "$3}')"
        return
    fi
    n_total=$(grep -c '.' <<<"$out" || true)
    n_ok=$(   grep -c '^ok:'    <<<"$out" || true)
    n_stale=$(grep -c '^stale:' <<<"$out" || true)
    n_bad=$(  grep -c '^bad:'   <<<"$out" || true)
    [[ -z "$n_total" ]] && n_total=0
    [[ -z "$n_ok"    ]] && n_ok=0
    [[ -z "$n_stale" ]] && n_stale=0
    [[ -z "$n_bad"   ]] && n_bad=0
    if (( n_bad > 0 )); then
        # Sample the first BAD row so the operator sees what failed.
        first_bad="$(grep '^bad:' <<<"$out" | head -1 \
                     | awk -F: '{print $2": "$3}')"
        DIFF_STATUS="bad"
        DIFF_SUMMARY="${n_bad} verification failure(s) (e.g. ${first_bad})"
        return
    fi
    if (( n_stale > 0 )); then
        # Try to surface the oldest stale entry — verify-pins.sh's JSON
        # carries age_days inline.  We just take the first stale row;
        # adapters that want ordering can sort their JSON output.
        oldest_app="$(grep '^stale:' <<<"$out" | head -1 \
                      | awk -F: '{print $2}')"
        oldest_age="$(grep '^stale:' <<<"$out" | head -1 \
                      | awk -F: '{print $3}')"
        DIFF_STATUS="warn"
        DIFF_SUMMARY="${n_stale} stale (oldest: ${oldest_app} ${oldest_age})"
        return
    fi
    DIFF_STATUS="ok"
    DIFF_SUMMARY="${n_total} apps, all fresh + verified"
}

# ── Per-baseline driver ────────────────────────────────────────────
# Returns via DIFF_STATUS / DIFF_SUMMARY globals.  Side effect: writes
# the baseline file on first run (matching health.py's behaviour) so
# the FIRST audit run after a clean install seeds the baselines rather
# than reporting everything as BAD.
audit_one() {
    local name="$1"
    local base_file="${BASELINE_DIR}/baseline-${name}.txt"

    mkdir -p "$BASELINE_DIR"

    local current
    if ! current="$(gen_current "$name" 2>/dev/null)"; then
        DIFF_STATUS="dim"
        DIFF_SUMMARY="generator failed"
        return
    fi
    # Note: an EMPTY $current is a valid result (e.g. a machine with no
    # TCP listeners has empty `ss -tln` output minus the header).  We
    # still treat that as a real state and diff against the baseline.
    # Only generator-process failure (the `if !` branch above) is
    # considered "no data".

    if [[ ! -f "$base_file" ]]; then
        # First run — write the baseline and report dim, matching the
        # behaviour of check_*_drift() in health.py.
        if printf '%s\n' "$current" > "$base_file" 2>/dev/null; then
            DIFF_STATUS="dim"
            DIFF_SUMMARY="baseline set ($(echo "$current" | grep -c '.' || true))"
        else
            DIFF_STATUS="dim"
            DIFF_SUMMARY="baseline write failed: $base_file"
        fi
        return
    fi

    local baseline
    if ! baseline="$(cat "$base_file" 2>/dev/null)"; then
        DIFF_STATUS="dim"
        DIFF_SUMMARY="baseline unreadable: $base_file"
        return
    fi

    run_diff "$name" "$baseline" "$current"
}

# ── --refresh-baseline shortcut ─────────────────────────────────────
# Equivalent to `rm baseline-<name>.txt && audit.sh` but only touches
# the named baseline and exits 0 cleanly so cron-like callers can drive
# it from a wrapper script.
if [[ -n "$REFRESH" ]]; then
    # `pins` has no on-disk baseline — refreshing it is meaningless.
    # The correct knob is scripts/refresh-pins.sh (Agent C).  Bail with
    # a hint rather than write an empty/garbage baseline file.
    if [[ "$REFRESH" == "pins" ]]; then
        die "'pins' has no on-disk baseline; bump pin freshness via scripts/refresh-pins.sh"
    fi
    base_file="${BASELINE_DIR}/baseline-${REFRESH}.txt"
    current="$(gen_current "$REFRESH" 2>/dev/null || true)"
    if [[ -z "$current" ]]; then
        die "Couldn't regenerate current state for '$REFRESH'."
    fi
    mkdir -p "$BASELINE_DIR"
    printf '%s\n' "$current" > "$base_file"
    ok "baseline refreshed: $base_file ($(echo "$current" | grep -c '.' || true) lines)"
    exit 0
fi

# ── Main loop ──────────────────────────────────────────────────────
declare -A RESULT_STATUS RESULT_SUMMARY
WORST="ok"   # ok < warn < bad   (dim treated as ok for exit-code purposes)

severity_rank() {
    case "$1" in
        ok|dim) echo 0 ;;
        warn)   echo 1 ;;
        bad)    echo 2 ;;
        *)      echo 0 ;;
    esac
}

for name in "${BASELINES[@]}"; do
    # `pins` is a live shell-out, not a baseline file — route it through
    # its dedicated driver.  All other baselines use the standard
    # generator/diff path.
    if [[ "$name" == "pins" ]]; then
        audit_pins
    else
        audit_one "$name"
    fi
    RESULT_STATUS[$name]="$DIFF_STATUS"
    RESULT_SUMMARY[$name]="$DIFF_SUMMARY"
    if (( $(severity_rank "$DIFF_STATUS") > $(severity_rank "$WORST") )); then
        WORST="$DIFF_STATUS"
    fi
done

# ── Output ─────────────────────────────────────────────────────────
if (( OUTPUT_JSON )); then
    # Hand-rolled JSON to avoid jq / python dependency.  Values come
    # from gen_*() output which is line-based ASCII, but the summary
    # MAY contain a backslash or quote from a sample filename — we
    # escape both, plus control chars, so the output stays valid JSON.
    json_escape() {
        # Read a string from argv, emit a JSON-escaped string (without
        # surrounding quotes — caller adds those).
        local s="$1"
        s="${s//\\/\\\\}"   # backslash first
        s="${s//\"/\\\"}"   # then doublequote
        s="${s//$'\t'/\\t}"
        s="${s//$'\n'/\\n}"
        s="${s//$'\r'/\\r}"
        printf '%s' "$s"
    }
    printf '{\n'
    printf '  "worst": "%s",\n' "$WORST"
    printf '  "baselines": {\n'
    first=1
    for name in "${BASELINES[@]}"; do
        if (( ! first )); then printf ',\n'; fi
        first=0
        printf '    "%s": {"status": "%s", "summary": "%s"}' \
            "$(json_escape "$name")" \
            "$(json_escape "${RESULT_STATUS[$name]}")" \
            "$(json_escape "${RESULT_SUMMARY[$name]}")"
    done
    printf '\n  }\n'
    printf '}\n'
else
    # Human-readable: one row per baseline, colour-coded.  The marker
    # word ([ok|warn|bad]) is the same vocabulary health.py uses so
    # users develop one mental model across both surfaces.
    for name in "${BASELINES[@]}"; do
        status="${RESULT_STATUS[$name]}"
        summary="${RESULT_SUMMARY[$name]}"
        case "$status" in
            ok)   echo "${C_OK}[ok]${C_RST}     ${name}: ${summary}" ;;
            warn) echo "${C_WARN}[warn]${C_RST}   ${name}: ${summary}" ;;
            bad)  echo "${C_ERR}[bad]${C_RST}    ${name}: ${summary}" ;;
            dim|*) echo "${C_DIM}[dim]${C_RST}    ${name}: ${summary}" ;;
        esac
    done
fi

case "$WORST" in
    bad) exit 1 ;;
    *)   exit 0 ;;
esac
