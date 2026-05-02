#!/usr/bin/env python3
"""
Conky listening ports — TCP, UDP, and raw/ICMP bound sockets.
Deduplicates IPv4/IPv6 duplicates; merges TCP+UDP on the same port.

Process resolution requires CAP_NET_ADMIN, so we run `ss` via `sudo -n`
when possible.  If sudo isn't allowed (no NOPASSWD entry for ss), fall
back to plain `ss` — process names will then only appear for sockets
this user owns, and system services will show "-".  See readme/security.md
for the sudoers entry that gives full visibility.
"""
import subprocess, re, sys


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

def parse_listen(raw, proto):
    """Return dict of port -> proc."""
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
        m = re.search(r'users:\(\("([^"]+)"', line)
        if m:
            # Linux process names from /proc/<pid>/comm are at most 15
            # chars (TASK_COMM_LEN-1).  Truncate at 24 to give headroom
            # for any name that survives unscathed without forcing the
            # column to be wider than the panel can hold.
            proc = m.group(1)[:24]
        # If -i added an indented stats line, skip it so we don't try
        # to parse it as the next connection.
        if i + 1 < len(lines) and lines[i + 1][:1].isspace():
            i += 1
        if port.isdigit():
            if port not in ports:
                ports[port] = (proc, proto)
        i += 1
    return ports

tcp = parse_listen(run_ss(["-tl"]), "TCP")
udp = parse_listen(run_ss(["-ul"]), "UDP")

# Merge; label as T+U when the same port listens on both
merged = {}
for port, (proc, proto) in {**udp, **tcp}.items():
    merged[port] = [proc, proto]

for port, (proc, proto) in udp.items():
    if port in tcp:
        merged[port][1] = "T+U"

if not merged:
    print("  none")
    sys.exit(0)

for port, (proc, proto) in sorted(merged.items(), key=lambda x: int(x[0])):
    print(f"  {proto:<3}  :{port:<5}  {proc}")
