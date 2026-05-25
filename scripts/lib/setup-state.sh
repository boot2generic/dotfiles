# scripts/lib/setup-state.sh
#
# Sourced bash library — do NOT execute directly.  Tracks setup-phase
# progress in a small TOML file under /var/lib/dotfiles/ so that
# `local_setup.sh --resume` can skip phases that already succeeded.
#
# Backing file:
#     /var/lib/dotfiles/setup-state.toml      (root-owned, mode 0644)
#
# Schema:
#     [state]
#     last_run_started  = "<ISO 8601>"
#     last_run_finished = "<ISO 8601>"   # empty until a clean run
#     completed_phases  = ["detect", "install", "deploy", ...]
#
# Functions (all prefixed `setup_state_`):
#     setup_state_init
#     setup_state_mark_completed PHASE
#     setup_state_is_completed   PHASE
#     setup_state_completed_phases
#     setup_state_mark_finished
#     setup_state_reset
#
# Degraded mode: if the user runs without sudo, init emits a clear
# warning and the rest of the calls become no-ops — setup still works,
# just without resume capability.

# ── Module-private constants ───────────────────────────────────────
SETUP_STATE_DIR="/var/lib/dotfiles"
SETUP_STATE_FILE="${SETUP_STATE_DIR}/setup-state.toml"

# Set to 1 by setup_state_init when the backing store is unavailable
# (no sudo, or write failed).  Every other function checks this flag
# and short-circuits so callers don't have to.
SETUP_STATE_DEGRADED=0

# ── Tiny logger — write to stderr, prefixed for grep ───────────────
# Kept local to this file so the lib stays self-contained when sourced
# from contexts that haven't defined the canonical log/warn helpers.
_setup_state_log()  { printf '[setup-state] %s\n' "$*" >&2; }
_setup_state_warn() { printf '[setup-state] WARN: %s\n' "$*" >&2; }
_setup_state_err()  { printf '[setup-state] ERROR: %s\n' "$*" >&2; }

# Current time in UTC ISO 8601 ("Z" suffix).  Centralised so all
# timestamps in the file share the same format.
_setup_state_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Sudo-capable detector ──────────────────────────────────────────
# Returns 0 if we can sudo without prompting (NOPASSWD path) OR if a
# previous `sudo -v` has already cached creds in this session.
# Returns 1 otherwise.  We refuse to prompt from a library function —
# callers (local_setup.sh) own the interactive sudo priming.
_setup_state_can_sudo() {
  if [[ $EUID -eq 0 ]]; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || return 1
  sudo -n true 2>/dev/null
}

# Run a command as root.  Uses sudo when we're not already root.
_setup_state_as_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

# ── Atomic write helper ────────────────────────────────────────────
# Stage content in a same-filesystem tempfile under
# $SETUP_STATE_DIR, then `mv -f` it over the destination.  rename(2)
# is the real atomic primitive — `install` falls back to copy-then-
# chmod when the source is on a different filesystem (e.g. tmpfs at
# /tmp vs the rootfs holding /var/lib/dotfiles), which is NOT atomic.
# Returns 1 on any error.  Tempfile is created as root so the rename
# works regardless of caller uid.
_setup_state_write_atomic() {
  local content="$1"
  local tmp
  # Stage on the SAME filesystem as the destination — guarantees the
  # subsequent mv -f is a rename(2) and therefore atomic.
  tmp="$(_setup_state_as_root mktemp -p "$SETUP_STATE_DIR" .setup-state.XXXXXX.tmp)" \
    || return 1
  # shellcheck disable=SC2064  # intentional early-binding of $tmp
  trap "_setup_state_as_root rm -f '$tmp'" RETURN
  printf '%s' "$content" | _setup_state_as_root tee "$tmp" >/dev/null \
    || return 1
  _setup_state_as_root chmod 0644 "$tmp" || return 1
  _setup_state_as_root mv -f "$tmp" "$SETUP_STATE_FILE" || return 1
}

# ── Python reader/writer ───────────────────────────────────────────
# Reads the current TOML, applies a small in-memory mutation described
# by $1 (one of: add-phase, finished, reset, started), and prints the
# new file contents on stdout.  Manual TOML emit — single [state]
# table, three keys — so we don't pull in tomlkit just for this.
#
# Args:  <op> [<arg>]
#   started               — touch last_run_started
#   add-phase   PHASE     — append PHASE if not already in list
#   finished              — set last_run_finished to now
#   reset                 — clear completed_phases, refresh started
#   raw                   — just emit the parsed-then-serialised form
#
# Reads $SETUP_STATE_FILE if it exists; otherwise starts from a
# freshly initialised state.  Always returns valid TOML on stdout.
_setup_state_python() {
  local op="$1"
  local arg="${2:-}"
  local now
  now="$(_setup_state_now)"

  SETUP_STATE_FILE="$SETUP_STATE_FILE" \
  SETUP_STATE_OP="$op" \
  SETUP_STATE_ARG="$arg" \
  SETUP_STATE_NOW="$now" \
  python3 - <<'PY'
import os, sys, tomllib

path  = os.environ["SETUP_STATE_FILE"]
op    = os.environ["SETUP_STATE_OP"]
arg   = os.environ["SETUP_STATE_ARG"]
now   = os.environ["SETUP_STATE_NOW"]

# Defaults — used when the file is absent or corrupt.  The schema is
# small enough that we re-seed instead of bailing.
state = {
    "last_run_started":  now,
    "last_run_finished": "",
    "completed_phases":  [],
}

try:
    with open(path, "rb") as f:
        data = tomllib.loads(f.read().decode("utf-8"))
    s = data.get("state", {})
    if isinstance(s.get("last_run_started"), str):
        state["last_run_started"] = s["last_run_started"]
    if isinstance(s.get("last_run_finished"), str):
        state["last_run_finished"] = s["last_run_finished"]
    if isinstance(s.get("completed_phases"), list):
        state["completed_phases"] = [str(p) for p in s["completed_phases"]]
except FileNotFoundError:
    pass
except Exception as e:
    # Corrupt file — log to stderr but continue with defaults so the
    # next write replaces it cleanly.
    print(f"[setup-state] WARN: could not parse {path}: {e}", file=sys.stderr)

if op == "started":
    state["last_run_started"] = now
elif op == "add-phase":
    if arg and arg not in state["completed_phases"]:
        state["completed_phases"].append(arg)
elif op == "finished":
    state["last_run_finished"] = now
elif op == "reset":
    state["completed_phases"] = []
    state["last_run_started"] = now
    state["last_run_finished"] = ""
elif op == "raw":
    pass
else:
    print(f"[setup-state] ERROR: unknown op {op!r}", file=sys.stderr)
    sys.exit(2)

# Manual TOML emit — three fields, fixed order, no exotic types.
def emit_str(v):
    # Backslash + double-quote escaping is sufficient for ISO 8601
    # timestamps and kebab-case phase names; no embedded controls.
    return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'

def emit_list(items):
    return "[" + ", ".join(emit_str(i) for i in items) + "]"

out = []
out.append("[state]")
out.append(f"last_run_started  = {emit_str(state['last_run_started'])}")
out.append(f"last_run_finished = {emit_str(state['last_run_finished'])}")
out.append(f"completed_phases  = {emit_list(state['completed_phases'])}")
out.append("")
sys.stdout.write("\n".join(out))
PY
}

# ============================================================
# Public API
# ============================================================

# Create /var/lib/dotfiles/ + setup-state.toml if missing; refresh
# last_run_started.  Sets SETUP_STATE_DEGRADED=1 (no-op mode) if we
# can't acquire sudo.
setup_state_init() {
  SETUP_STATE_DEGRADED=0

  if ! _setup_state_can_sudo; then
    _setup_state_warn "needs sudo for /var/lib/dotfiles writes — resume capability disabled"
    SETUP_STATE_DEGRADED=1
    return 0
  fi

  if [[ ! -d "$SETUP_STATE_DIR" ]]; then
    if ! _setup_state_as_root install -d -m 0755 "$SETUP_STATE_DIR"; then
      _setup_state_warn "could not create $SETUP_STATE_DIR — resume capability disabled"
      SETUP_STATE_DEGRADED=1
      return 0
    fi
  fi

  local new_content
  if ! new_content="$(_setup_state_python started)"; then
    _setup_state_warn "could not compute new state file content — resume capability disabled"
    SETUP_STATE_DEGRADED=1
    return 0
  fi

  if ! _setup_state_write_atomic "$new_content"; then
    _setup_state_warn "could not write $SETUP_STATE_FILE — resume capability disabled"
    SETUP_STATE_DEGRADED=1
    return 0
  fi

  _setup_state_log "state file ready: $SETUP_STATE_FILE"
}

# Append PHASE to completed_phases if not already present.  No-op when
# degraded or when the file doesn't exist.
setup_state_mark_completed() {
  local phase="${1:-}"
  if [[ -z "$phase" ]]; then
    _setup_state_err "setup_state_mark_completed: PHASE argument required"
    return 1
  fi
  if (( SETUP_STATE_DEGRADED )); then
    return 0
  fi
  if [[ ! -f "$SETUP_STATE_FILE" ]]; then
    # init wasn't called or failed silently — degrade rather than abort
    SETUP_STATE_DEGRADED=1
    return 0
  fi
  local new_content
  if ! new_content="$(_setup_state_python add-phase "$phase")"; then
    _setup_state_warn "could not add phase $phase"
    return 0
  fi
  _setup_state_write_atomic "$new_content" || _setup_state_warn "could not persist phase $phase"
}

# Exit 0 if PHASE in completed_phases, 1 otherwise.  Degraded mode
# always returns 1 so callers re-run every phase (safe default).
setup_state_is_completed() {
  local phase="${1:-}"
  [[ -n "$phase" ]] || return 1
  if (( SETUP_STATE_DEGRADED )); then
    return 1
  fi
  [[ -f "$SETUP_STATE_FILE" ]] || return 1

  SETUP_STATE_FILE="$SETUP_STATE_FILE" \
  SETUP_STATE_ARG="$phase" \
  python3 - <<'PY'
import os, sys, tomllib
try:
    with open(os.environ["SETUP_STATE_FILE"], "rb") as f:
        data = tomllib.loads(f.read().decode("utf-8"))
except Exception:
    sys.exit(1)
phases = data.get("state", {}).get("completed_phases", [])
sys.exit(0 if os.environ["SETUP_STATE_ARG"] in phases else 1)
PY
}

# Print all completed phases space-separated.  Empty output in
# degraded mode or when the file is absent.
setup_state_completed_phases() {
  if (( SETUP_STATE_DEGRADED )); then
    return 0
  fi
  [[ -f "$SETUP_STATE_FILE" ]] || return 0

  SETUP_STATE_FILE="$SETUP_STATE_FILE" \
  python3 - <<'PY'
import os, sys, tomllib
try:
    with open(os.environ["SETUP_STATE_FILE"], "rb") as f:
        data = tomllib.loads(f.read().decode("utf-8"))
except Exception:
    sys.exit(0)
phases = data.get("state", {}).get("completed_phases", [])
print(" ".join(str(p) for p in phases))
PY
}

# Set last_run_finished to now.  No-op when degraded.
setup_state_mark_finished() {
  if (( SETUP_STATE_DEGRADED )); then
    return 0
  fi
  [[ -f "$SETUP_STATE_FILE" ]] || return 0
  local new_content
  if ! new_content="$(_setup_state_python finished)"; then
    _setup_state_warn "could not mark run finished"
    return 0
  fi
  _setup_state_write_atomic "$new_content" || _setup_state_warn "could not persist finished marker"
}

# Clear completed_phases (used by setup --resume to start fresh).
# No-op when degraded.
setup_state_reset() {
  if (( SETUP_STATE_DEGRADED )); then
    return 0
  fi
  if [[ ! -f "$SETUP_STATE_FILE" ]]; then
    # Nothing to reset — but we still need init to create the file.
    setup_state_init
    return 0
  fi
  local new_content
  if ! new_content="$(_setup_state_python reset)"; then
    _setup_state_warn "could not reset state"
    return 0
  fi
  _setup_state_write_atomic "$new_content" || _setup_state_warn "could not persist reset"
}
