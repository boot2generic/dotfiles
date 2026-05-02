#!/usr/bin/env python3
"""
Conky new processes helper.
Compares current /proc PIDs to the previous poll's state file.
New PIDs are shown for LINGER seconds after first appearance.
State: /tmp/.conky_newprocs (JSON)
"""
import json, os, sys, time

# SECURITY: same per-user state-dir treatment as netstat.py.  The state
# file leaks process names + PIDs of recently-launched programs, which
# is metadata another local user shouldn't be able to harvest.
def _state_path() -> str:
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime:
        base = os.path.join(runtime, "conky")            # /run/user/$UID/conky
    else:
        base = os.path.join(os.path.expanduser("~/.cache"), "conky")
    os.makedirs(base, mode=0o700, exist_ok=True)
    return os.path.join(base, "newprocs")


STATE  = _state_path()
LINGER = 60   # seconds to keep a new proc visible
MAX_OUT = 8

now = time.time()

def get_procs():
    procs = {}
    for entry in os.scandir("/proc"):
        if not entry.name.isdigit():
            continue
        try:
            with open(f"/proc/{entry.name}/comm") as f:
                procs[entry.name] = f.read().strip()
        except OSError:
            pass
    return procs

current = get_procs()

first_run = not os.path.exists(STATE)
state = {}
if not first_run:
    try:
        with open(STATE) as f:
            state = json.load(f)
    except Exception:
        first_run = True

if first_run:
    # Seed state with current processes — nothing to show yet
    new_state = {pid: [name, now] for pid, name in current.items()}
    try:
        fd = os.open(STATE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(new_state, f)
    except Exception:
        pass
    print("  watching...")
    sys.exit(0)

prev_pids = set(state.keys())
curr_pids = set(current.keys())

# Record newly seen PIDs
new_pids = curr_pids - prev_pids
for pid in new_pids:
    state[pid] = [current[pid], now]

# Prune: gone processes past the linger window
for pid in list(state.keys()):
    if pid not in curr_pids and now - state[pid][1] > LINGER:
        del state[pid]

try:
    with open(STATE, "w") as f:
        json.dump(state, f)
except Exception:
    pass

# Entries to display: only newly seen PIDs within linger window
entries = []
for pid in new_pids:
    if pid in state:
        name, first_seen = state[pid]
        age = now - first_seen
        if age <= LINGER:
            entries.append((name, pid, age))

entries.sort(key=lambda x: x[2])  # youngest first

if not entries:
    print("  no new processes")
else:
    for name, pid, age in entries[:MAX_OUT]:
        print(f"  {name:<20} pid {pid:<6}  +{age:.0f}s")
