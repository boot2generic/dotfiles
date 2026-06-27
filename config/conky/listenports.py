#!/usr/bin/env python3
"""
Conky listening ports — TCP, UDP, and raw/ICMP bound sockets.
Deduplicates IPv4/IPv6 duplicates; merges TCP+UDP on the same port.

Process resolution requires CAP_NET_ADMIN, so we run `ss` via `sudo -n`
when possible.  If sudo isn't allowed (no NOPASSWD entry for ss), fall
back to plain `ss` — process names will then only appear for sockets
this user owns, and system services will show "-".  See readme/security.md
for the sudoers entry that gives full visibility.

New-port alerting (rendered in yellow with a ★ marker for ~10 min):
  • The set of (port, proc) pairs seen on the very first run becomes
    the baseline.  Subsequent runs flag any pair NOT in the baseline.
  • A 60s warmup grace period after the baseline is FIRST written
    suppresses noise from services that come up just-after the panel
    starts (Plasma + autostart cascade — kded, dbus-daemons, nm-applet,
    pipewire-pulse, …).  Inside the warmup we keep adding to the
    baseline silently.
  • The "alert window" for each new port is NEW_HIGHLIGHT_SECONDS;
    after that the port silently joins the baseline, so a port that
    came up two days ago doesn't permanently glow yellow.
  • To force re-baselining (e.g., you intentionally added a new
    service), delete ~/.cache/conky/listenports-baseline.json (or its
    XDG_RUNTIME_DIR equivalent).  The next run rebuilds the baseline.

State schema (XDG_RUNTIME_DIR/conky/listenports-baseline.json):
  {
    "baseline_set_at": <epoch>,
    "ports":           { "<proto>:<port>:<proc>": <first_seen_epoch> }
  }
"""
import subprocess, re, sys, json, os, time

# Tuning knobs — match netstat.py's semantics where relevant.
NEW_HIGHLIGHT_SECONDS = 10 * 60   # how long a new port stays starred
WARMUP_SECONDS        = 60        # post-baseline grace where new ports
                                  # auto-join the baseline silently


def _state_path() -> str:
    """Per-user, mode-0700 state dir.  Mirrors netstat.py's pattern."""
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime:
        base = os.path.join(runtime, "conky")
    else:
        base = os.path.join(os.path.expanduser("~/.cache"), "conky")
    os.makedirs(base, mode=0o700, exist_ok=True)
    return os.path.join(base, "listenports-baseline.json")


def _try(cmd):
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL,
                                       text=True, timeout=3)
    except Exception:
        return None


def run_ss(flags):
    """Run `ss <flags> -nlp`, preferring sudo for full process visibility."""
    base = flags + ["-nlp"]
    # First try with sudo -n (no prompt).  /usr/bin/ss is on the broad
    # NOPASSWD ALL list (install mode) and the narrow allowlist (post-
    # harden mode), so this should succeed on any properly-set-up box.
    out = _try(["sudo", "-n", "/usr/bin/ss", *base])
    if out is not None:
        return out
    # Fall back to plain ss — graceful degradation when sudo is denied.
    out = _try(["ss", *base])
    return out or ""

_STATES = {"LISTEN", "UNCONN"}

# Exe-path allowlist for system locations.  Mirrors health.py's
# SYSTEM_PREFIXES + ALLOW_SUBSTRS pattern: substring match (lowercase),
# tolerant of the kernel's `<NUL>(deleted)` suffix.  A listener whose
# exe ISN'T under one of these prefixes is the strongest single-row
# signal this panel can produce — a server binary placed in /tmp/ or
# /home/ even with a legit-looking comm (sshd, nginx) is almost always
# malicious.  Keep this list TIGHT — the whole point is to flag the
# weird stuff, so don't paper over /opt/ or /home/ unless one of those
# is actually a system install root on your box.
_SYSTEM_PATH_SUBSTRS = (
    "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/usr/lib/",
    "/bin/", "/sbin/", "/lib/",
    "/snap/", "/var/lib/flatpak/",
)


def _resolve_exe(pid: str) -> str:
    """Read /proc/<pid>/exe — '?' on failure (dead PID or no perm).

    Returns the kernel-provided string verbatim, INCLUDING any trailing
    `(deleted)` suffix.  The caller uses that suffix as the "binary was
    unlinked" signal — a daemon still listening AFTER its on-disk exe
    vanished is the same in-memory-payload pattern health.py flags, but
    much more alarming for a LISTENER than a generic process.
    """
    try:
        return os.readlink(f"/proc/{pid}/exe")
    except (OSError, PermissionError):
        return "?"


def _is_system_path(exe: str) -> bool:
    """True if the exe lives in a trusted system location.

    Lowercase substring match (mirrors health.py); a `(deleted)` suffix
    does NOT count as system — that's the unlink-after-start signal.
    """
    if not exe or exe == "?":
        return False
    if exe.endswith("(deleted)"):
        return False
    low = exe.lower()
    return any(s in low for s in _SYSTEM_PATH_SUBSTRS)


def parse_listen(raw, proto):
    """Return dict of port -> (proc, proto, exe).

    Exe path comes from /proc/<pid>/exe via the `pid=N` embedded in
    ss -p's `users:(...)` tuple.  When a port has multiple listening
    PIDs (e.g. socket-activated services), we keep the first one — ss
    output is process-then-port-ordered so this is deterministic enough.
    """
    ports = {}
    lines = raw.splitlines()
    i = 1
    while i < len(lines):
        line = lines[i]
        if not line or line[0].isspace():
            i += 1
            continue
        parts = line.split()
        local = parts[3] if parts[0] in _STATES else parts[2]
        port = local.rsplit(":", 1)[-1]
        # The `users:(("name", ...))` field lives at the END of the
        # connection line itself (the Process column when -p is used),
        # NOT on the indented info line that -i adds.  Earlier versions
        # of this script searched i+1 — wrong, the proc column always
        # came back "-".
        proc = "-"
        exe  = "?"
        m = re.search(r'users:\(\("([^"]+)",pid=(\d+)', line)
        if m:
            # Linux process names from /proc/<pid>/comm are at most 15
            # chars (TASK_COMM_LEN-1).  Truncate at 24 to give headroom
            # for any name that survives unscathed without forcing the
            # column to be wider than the panel can hold.
            proc = m.group(1)[:24]
            exe  = _resolve_exe(m.group(2))
        # If -i added an indented stats line, skip it so we don't try
        # to parse it as the next connection.
        if i + 1 < len(lines) and lines[i + 1][:1].isspace():
            i += 1
        if port.isdigit():
            if port not in ports:
                ports[port] = (proc, proto, exe)
        i += 1
    return ports

tcp = parse_listen(run_ss(["-tl"]), "TCP")
udp = parse_listen(run_ss(["-ul"]), "UDP")

# Merge; label as T+U when the same port listens on both
merged = {}
for port, (proc, proto, exe) in {**udp, **tcp}.items():
    merged[port] = [proc, proto, exe]

for port, (proc, proto, exe) in udp.items():
    if port in tcp:
        merged[port][1] = "T+U"

if not merged:
    print("  none")
    sys.exit(0)

# ── First-seen / new-port detection ────────────────────────────────
now = time.time()
state_file = _state_path()

# Load (or initialise) the baseline.  We key on (proto, port, proc) so
# that a different process taking over the same port DOES alert — a
# legit handover (e.g., `systemd-resolved` → `unbound` on :53) is a
# real change worth surfacing.
try:
    with open(state_file) as f:
        state = json.load(f)
    baseline_set_at = float(state.get("baseline_set_at", now))
    seen = dict(state.get("ports", {}))   # key → first_seen_epoch
except Exception:
    baseline_set_at = now
    seen = {}

# Build the current key set; record first-seen timestamps for anything
# we don't already know about.
current_keys = {}
for port, (proc, proto, _exe) in merged.items():
    key = f"{proto}:{port}:{proc}"
    current_keys[key] = (proto, port, proc)
    if key not in seen:
        seen[key] = now

# Drop entries that no longer appear (port closed) — keeps the state
# file bounded.  Closed ports re-opening = new ★, which is the desired
# behaviour: a service flapping is itself worth noticing.
seen = {k: v for k, v in seen.items() if k in current_keys}

# Persist the (possibly updated) state.  Mode-0600 atomic-ish write.
try:
    fd = os.open(state_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"baseline_set_at": baseline_set_at, "ports": seen}, f)
except OSError:
    pass

# Decide which ports get the ★ / yellow treatment.  During warmup we
# treat every port as "in the baseline" regardless of first_seen, so a
# Plasma session start doesn't paint half the listenports panel yellow.
warmup_active = (now - baseline_set_at) < WARMUP_SECONDS

# Path-rendering budget.  The legacy row was ~35 chars wide; the new
# column adds the exe path on the right.  Truncate paths from the LEFT
# (keep the filename + parent dir) so the suspicious tail is what gets
# preserved — `…/tmp/x` tells the user more than `/tmp/dropp…` ever
# could.  Mirrors health.py:_shorten_path's reasoning.
_EXE_MAX = 32


def _shorten_exe(p: str) -> str:
    if len(p) <= _EXE_MAX:
        return p
    return "…" + p[-(_EXE_MAX - 1):]


# Suspect listeners (bound by a non-system / deleted binary) collected
# during the render pass, logged once to the security event log below.
_suspect_listeners: list[dict] = []

# Render — sorted numerically by port so the column reads cleanly.
for port, (proc, proto, exe) in sorted(merged.items(), key=lambda x: int(x[0])):
    key = f"{proto}:{port}:{proc}"
    age = now - seen.get(key, now)
    is_new = (not warmup_active) and (age < NEW_HIGHLIGHT_SECONDS) \
             and (seen.get(key, baseline_set_at) > baseline_set_at)

    # Exe-path classification.  Two failure modes both deserve red:
    #   • path NOT under a system-prefix — dropper in /tmp/, /home/, etc.
    #   • path ending in `(deleted)` — binary unlinked after process
    #     started.  For a LISTENER this is much more alarming than the
    #     generic post-upgrade restart-needed case health.py covers, so
    #     we always flag it regardless of original prefix.
    # `?` (readlink failed: no perm or PID died) is NOT flagged — on a
    # box where sudo isn't allowed for ss, half the ports would render
    # red and the signal would drown in noise.  The user already has
    # health.py's broader process audit for that case.
    exe_deleted = exe.endswith("(deleted)")
    exe_suspect = exe != "?" and (exe_deleted or not _is_system_path(exe))
    if exe_suspect:
        _suspect_listeners.append({"proto": proto, "port": port,
                                   "proc": proc, "exe": exe,
                                   "deleted": exe_deleted})
    exe_short   = _shorten_exe(exe)
    # A rogue listener (non-packaged or unlinked binary) is a strong
    # post-exploit signal, so colour the WHOLE row red with a ⚠ marker —
    # a short path like /tmp/x in red was too easy to miss when only the
    # path was tinted.  ★ if it's also newly-appeared.  Otherwise: yellow
    # ★ for new ports, section-default green for steady-state.
    # (Conky's ${color} resets to the section default — no nested-colour
    # stack — so each row carries exactly one leading colour bracket.)
    if exe_suspect:
        marker = "★" if is_new else "⚠"
        print(f"${{color5}} {marker} {proto:<3}  :{port:<5}  {proc:<16}  {exe_short}${{color}}")
    elif is_new:
        # ★ + colour3 (yellow) override the section's default (green).
        print(f"${{color3}} ★ {proto:<3}  :{port:<5}  {proc:<16}${{color}} {exe_short}")
    else:
        print(f"   {proto:<3}  :{port:<5}  {proc:<16} {exe_short}")

# ── Security event log: record listeners bound by a non-packaged or
# unlinked ("(deleted)") binary — a classic dropped-implant signature.
# Best-effort; a logging hiccup must never break the panel.
try:
    import seclog
    if _suspect_listeners:
        n = len(_suspect_listeners)
        seclog.note("rogue_listener", "bad",
                    f"{n} listener(s) bound by non-system/deleted binary",
                    {"listeners": _suspect_listeners[:20]})
    else:
        seclog.note("rogue_listener", "ok", "all listeners system-packaged")
except Exception:
    pass
