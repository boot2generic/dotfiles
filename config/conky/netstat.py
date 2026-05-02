#!/usr/bin/env python3
"""
Conky active connections — TCP established, connected UDP, ICMP/raw.
Shows live per-connection bandwidth by diffing ss byte counters between polls.
State: /tmp/.conky_netstat_bw (JSON)
Listening/bound-only sockets are excluded — they're shown by the
LISTENING PORTS section (listenports.py) of the same conky panel.
"""
import subprocess, re, sys, json, os, time

MAX_SHOW = 12

# SECURITY: store the byte-counter state in a per-user, mode-700
# directory rather than a predictable /tmp path.  The state file leaks
# every active connection's destination + transferred bytes — on a
# multi-user box that's a metadata side-channel another user
# could read.  XDG_RUNTIME_DIR is exactly /run/user/$UID (created by
# logind, mode 0700, wiped at logout).  Falls back to ~/.cache/conky
# on systems without logind.
def _state_path() -> str:
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime:
        base = os.path.join(runtime, "conky")            # /run/user/$UID/conky
    else:
        base = os.path.join(os.path.expanduser("~/.cache"), "conky")
    os.makedirs(base, mode=0o700, exist_ok=True)
    return os.path.join(base, "netstat_bw")


STATE = _state_path()

def fmt_rate(bps):
    if bps <= 0:
        return "0B/s"
    for unit, thr in (("G", 1 << 30), ("M", 1 << 20), ("K", 1 << 10)):
        if bps >= thr:
            return f"{bps / thr:.1f}{unit}/s"
    return f"{int(bps)}B/s"

def short_addr(addr):
    addr = re.sub(r"^::ffff:", "", addr)
    if len(addr) > 16:
        addr = addr[:13] + "..."
    return addr

_STATES   = {"ESTAB", "LISTEN", "UNCONN", "CLOSE-WAIT", "TIME-WAIT",
             "SYN-SENT", "SYN-RECV", "FIN-WAIT-1", "FIN-WAIT-2",
             "CLOSING", "LAST-ACK", "CLOSE"}
_WILDCARD = {"*:*", "0.0.0.0:*", "[::]:*", ":::*"}

def _ss_output(flags):
    """Get `ss <flags> -nip` output, preferring sudo for full proc info.

    Without root, `ss -p` only shows process names for sockets this user
    owns — system-service connections (sshd, mullvad-daemon, …) come
    back with empty user info.  Try `sudo -n` first; fall back to plain
    `ss` if sudo isn't allowed.  /usr/bin/ss is on the install-mode
    NOPASSWD list AND the post-harden narrow allowlist.
    """
    base = flags + ["-nip"]
    for cmd in (["sudo", "-n", "/usr/bin/ss", *base], ["ss", *base]):
        try:
            return subprocess.check_output(cmd, stderr=subprocess.DEVNULL,
                                           text=True, timeout=3)
        except Exception:
            continue
    return ""


def parse_ss(flags, proto, keep_states):
    raw = _ss_output(flags)
    if not raw:
        return []

    conns = []
    lines = raw.splitlines()
    i = 1
    while i < len(lines):
        line = lines[i]
        if not line or line[0].isspace():
            i += 1
            continue

        parts = line.split()
        if parts[0] in _STATES:
            state, local, remote = parts[0], parts[3], parts[4] if len(parts) > 4 else ""
        else:
            state, local, remote = "ESTAB", parts[2], parts[3] if len(parts) > 3 else ""

        if state not in keep_states or remote in _WILDCARD or not remote:
            i += 1
            continue

        sent = recv = 0
        proc = "-"
        # `users:(...)` lives on the SAME line as the connection in
        # modern `ss` output (the trailing `Process` column when -p is
        # used).  bytes_sent/bytes_received still live on the indented
        # follow-up line that -i adds.  The previous code searched both
        # on i+1, which is why the proc column was always "-".
        m = re.search(r'users:\(\("([^"]+)"', line)
        if m:
            # Match listenports.py: 24 chars covers all real-world Linux
            # comm names without prematurely cutting things like
            # `systemd-resolve` or `NetworkManager`.
            proc = m.group(1)[:24]
        if i + 1 < len(lines) and lines[i + 1][:1].isspace():
            stat = lines[i + 1]
            m = re.search(r"bytes_sent:(\d+)", stat)
            if m: sent = int(m.group(1))
            m = re.search(r"bytes_received:(\d+)", stat)
            if m: recv = int(m.group(1))
            i += 1

        lport = local.rsplit(":", 1)[-1]
        lip   = local.rsplit(":", 1)[0].strip("[]")
        if lip in ("127.0.0.1", "::1"):
            i += 1
            continue

        try:
            direction = "← IN " if int(lport) <= 1024 else "→ OUT"
        except ValueError:
            direction = "→ OUT"

        key = f"{proto}:{local}-{remote}"
        conns.append({"proto": proto, "dir": direction, "lport": lport,
                      "raddr": short_addr(remote), "proc": proc,
                      "sent": sent, "recv": recv, "key": key})
        i += 1
    return conns

now   = time.time()
conns = parse_ss(["-ta"], "TCP", keep_states={"ESTAB"})
conns += parse_ss(["-ua"], "UDP", keep_states={"UNCONN", "ESTAB"})
conns += parse_ss(["-wa"], "ICM", keep_states={"UNCONN", "ESTAB"})

# Load previous byte snapshot
prev = {}
try:
    with open(STATE) as f:
        data = json.load(f)
        prev      = data.get("conns", {})
        prev_time = data.get("time", now)
except Exception:
    prev_time = now

dt = max(now - prev_time, 0.1)

# Save current snapshot.  os.open with explicit 0600 so a previously
# umask-022 state file gets re-tightened on next write.
snap = {"time": now, "conns": {c["key"]: [c["sent"], c["recv"]] for c in conns}}
try:
    fd = os.open(STATE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(snap, f)
except Exception:
    pass

if not conns:
    print("  no active connections")
    sys.exit(0)

for c in conns[:MAX_SHOW]:
    old = prev.get(c["key"], [c["sent"], c["recv"]])
    up_rate   = max(0, c["sent"] - old[0]) / dt
    down_rate = max(0, c["recv"] - old[1]) / dt
    # Layout: protocol, direction, local port, remote address, ↑/↓
    # rates, process.  Process moved to LAST so when a name happens
    # to be longer than 24 chars it can't bump the bandwidth columns
    # out of alignment — the only thing that risks getting clipped at
    # the panel edge is the trailing portion of the process name.
    print(f"  {c['proto']:<3} {c['dir']} :{c['lport']:<5}  "
          f"{c['raddr']:<16}  "
          f"↑{fmt_rate(up_rate):<8} ↓{fmt_rate(down_rate):<8}  "
          f"{c['proc']}")
