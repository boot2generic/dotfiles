#!/usr/bin/env python3
"""
Conky active connections — TCP established, connected UDP, ICMP/raw.

Shows live per-connection bandwidth + age + first-seen / long-running
flags by diffing ss byte counters between polls and persisting the
first-seen timestamp of every (proto, raddr, lport, proc) tuple.

State file layout (XDG_RUNTIME_DIR/conky/netstat_bw, mode 0600):
    {
      "time":    <last-poll-epoch>,
      "conns":   { "<key>": [sent_bytes, recv_bytes, first_seen_epoch] },
      "history": { "<ip>|<port>|<proc>": [epoch1, epoch2, ...] }
    }
Keys not seen in the current poll are dropped on the next write, so the
"conns" file size tracks active-connection count, not history.  The
"history" map is RETAINED across polls (capped at 10 timestamps per
triple, TTL 1h) — that's how we detect periodic-reconnect beacons even
when individual connections are short-lived.

Row-prefix markers (one char before each line) signal anomalies at a
glance without widening the panel:
   ★  first-seen this session (<10 min) — coloured ${color3} (yellow)
   ⚠  long-running (>1 h) to a NON-RFC1918 destination — ${color5} (red)
   ∞  long-running (>1 h) to RFC1918 — ${color3} (yellow, informational)
   ⏱  periodic-reconnect beacon (regular intervals) — ${color3} (yellow)
   (space)  normal — default ${color2} (green)

A header summary line is emitted before the rows:
   Σ <total>   <public_count>→public   <long_count> long-lived
so the panel still gives a one-glance "is anything weird happening?".

Listening/bound-only sockets are excluded — they're shown by the
LISTENING PORTS section (listenports.py) of the same conky panel.
"""
import subprocess, re, sys, json, os, time, ipaddress, statistics

# Bumped from 12 to 28 after the conky NEW PROCESSES + TOP PROCESSES
# blocks were retired — CONNECTIONS now fills the bottom of the panel.
# 28 fits comfortably in conky's default panel height at JetBrainsMono
# size 8.  If the panel ever wraps off-screen, drop this number.
MAX_SHOW = 28

# Anomaly thresholds.  Tunable here; not exposed as env vars yet.
NEW_HIGHLIGHT_SECONDS = 10 * 60   # ★ marker fades after this long
LONG_LIVED_SECONDS    = 60 * 60   # ⚠ / ∞ marker after this long

# Beacon-detection knobs.  A "beacon" is a (remote_ip, dest_port, proc)
# triple that has opened ≥BEACON_MIN_EVENTS short-lived connections at
# REGULAR intervals — exactly the pattern most C2 implants emit when
# they can't hold a persistent socket.  We measure regularity as
# coefficient-of-variation (stdev / mean) of the inter-event intervals;
# anything under BEACON_CV is considered "too regular to be human".
BEACON_HISTORY_TTL    = 60 * 60   # drop triples idle this long
BEACON_HISTORY_MAX    = 10        # last-N timestamps per triple
BEACON_MIN_EVENTS     = 4         # need this many to compute stdev meaningfully
BEACON_CV_THRESHOLD   = 0.15      # stdev/mean below this = "regular"
BEACON_MIN_MEAN_SECS  = 30        # ignore sub-30s mean intervals — DNS/NTP noise
BEACON_HISTORY_CAP    = 200       # hard cap on triples in state file (~50KB)

# Processes whose normal connections are folded into a single summary row.
# Any connection that is anomalous (long-lived or beaconing) still gets an
# individual row so bad actors are not hidden behind the collapse.
COLLAPSE_PROCS: set[str] = {
    # Firefox family
    "firefox", "librewolf", "waterfox", "floorp",
    # Mullvad Browser (Firefox-based; "mullvad-browser" is exactly 15 chars,
    # fitting TASK_COMM_LEN precisely — no truncation occurs)
    "mullvad-browser",
    # Chromium family (binary names vary by distro/install method)
    "chromium", "chromium-browser", "chromium-brows",
    "chrome", "google-chrome",
    "brave", "brave-browser",
    "vivaldi", "vivaldi-stable", "vivaldi-bin",
    "opera", "opera-browser",
    "msedge", "microsoft-edge",
    # Other GTK/Qt browsers
    "epiphany", "falkon", "qutebrowser", "midori", "luakit",
}

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


def fmt_age(seconds: float) -> str:
    """Compact age string: "30s", "12m", "3h", "2d"."""
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h"
    return f"{seconds // 86400}d"


# RFC1918 / loopback / link-local / CGNAT / IPv6 ULA + link-local — anything
# in these blocks is "local-ish" and a long-running conn there is usually
# benign (LAN sync, router admin, local containers, mDNS, …).  Anything
# OUTSIDE these blocks is a "public" destination — the one we'd want to
# flag for long-running C2 / persistent-shell patterns.
_PRIVATE_NETS_V4 = [
    ipaddress.ip_network(n) for n in (
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
        "127.0.0.0/8", "169.254.0.0/16", "100.64.0.0/10",
    )
]
_PRIVATE_NETS_V6 = [
    ipaddress.ip_network(n) for n in (
        "::1/128", "fc00::/7", "fe80::/10",
    )
]


def is_private(addr: str) -> bool:
    """True for RFC1918 / loopback / link-local / CGNAT / IPv6 ULA.

    Parses defensively — if the address comes back malformed (rare but
    possible with weird kernels or short_addr's `...` truncation when
    inspected upstream), we conservatively call it PUBLIC so the user
    is alerted rather than silently misclassified.
    """
    bare = re.sub(r"^::ffff:", "", addr).strip("[]")
    bare = bare.split("%", 1)[0]      # strip zone-id (e.g. fe80::…%eth0)
    try:
        ip = ipaddress.ip_address(bare)
    except ValueError:
        return False
    nets = _PRIVATE_NETS_V6 if ip.version == 6 else _PRIVATE_NETS_V4
    return any(ip in n for n in nets)

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

        # Extract the bare REMOTE ip BEFORE we hand it to short_addr() —
        # short_addr() truncates anything >16 chars to "1.2.3.4..." which
        # makes ip_address() raise ValueError, and short_addr() also
        # leaves the trailing `:<port>` on, which also breaks
        # ip_address().  We need the un-truncated, port-less form to
        # classify is_public correctly.  Same .rsplit(":", 1) trick used
        # for the local side above.
        rip = remote.rsplit(":", 1)[0].strip("[]")
        # rport is the SERVICE we're talking to — same parsing trick as
        # rip, just take the right side.  Beacon detection groups by
        # (rip, rport, proc), so we need this in the conn dict.
        rport = remote.rsplit(":", 1)[-1] if ":" in remote else ""

        try:
            direction = "← IN " if int(lport) <= 1024 else "→ OUT"
        except ValueError:
            direction = "→ OUT"

        key = f"{proto}:{local}-{remote}"
        conns.append({"proto": proto, "dir": direction, "lport": lport,
                      "raddr": short_addr(remote), "rip": rip,
                      "rport": rport, "proc": proc,
                      "sent": sent, "recv": recv, "key": key})
        i += 1
    return conns

now   = time.time()
conns = parse_ss(["-ta"], "TCP", keep_states={"ESTAB"})
conns += parse_ss(["-ua"], "UDP", keep_states={"UNCONN", "ESTAB"})
conns += parse_ss(["-wa"], "ICM", keep_states={"UNCONN", "ESTAB"})

# Load previous snapshot.  Schema:
#   {"time": <epoch>,
#    "conns":   {key: [sent, recv, first_seen]},
#    "history": {triple_key: [epoch, epoch, ...]}}
# Older snapshots (pre-first-seen) have 2-element conn lists, and even
# older ones lack "history" entirely — we tolerate both so an upgrade
# doesn't lose byte-rate continuity OR force a beacon-state rebuild.
prev = {}
prev_history: dict[str, list[float]] = {}
try:
    with open(STATE) as f:
        data = json.load(f)
        prev         = data.get("conns", {})
        prev_history = data.get("history", {}) or {}
        prev_time    = data.get("time", now)
except Exception:
    prev_time = now

dt = max(now - prev_time, 0.1)

# Build the new snapshot.  For each currently-active conn, carry the
# old `first_seen` forward if we've seen this key before; otherwise
# stamp it as new.  Connections that aren't in `conns` this poll are
# simply dropped — no history of closed connections is retained.
#
# A conn is "newly-appeared" (worth logging an event for beacon
# detection) when it wasn't in the previous poll's conns map.  That's
# exactly the case where we'd stamp first_seen = now, so we hook in
# there.  The triple key is (remote_ip, dest_port, proc) — coarser than
# the full conn key so periodic-reconnect patterns collapse to one row.
new_conns_state = {}
new_history: dict[str, list[float]] = {key: list(ts) for key, ts in prev_history.items()}
# Track which triples already got an event THIS poll — a process that
# fans out N parallel sockets in one wave is still ONE callback for
# beacon-cadence purposes.  Without this, 8 simultaneous conns smear
# 8 timestamps onto `now` and destroy the regularity signal.
triples_logged_this_poll: set[str] = set()
for c in conns:
    old = prev.get(c["key"])
    if old and len(old) >= 3:
        first_seen = old[2]
        is_newly_appeared = False
    else:
        first_seen = now
        is_newly_appeared = True
    new_conns_state[c["key"]] = [c["sent"], c["recv"], first_seen]
    c["age"]        = now - first_seen
    c["is_new"]     = c["age"] < NEW_HIGHLIGHT_SECONDS
    c["is_long"]    = c["age"] >= LONG_LIVED_SECONDS
    # Use the bare remote IP (no port, untruncated) — see parse_ss for
    # why c["raddr"] is unsafe here.
    c["is_public"]  = not is_private(c["rip"])

    # Dest port stays constant across a beacon's repeated callbacks,
    # but the local source port is randomized on each new socket — so
    # we MUST key on rport+rip+proc and not on c["key"].
    triple = f"{c['rip']}|{c['rport']}|{c['proc']}"
    c["triple"] = triple
    if is_newly_appeared and triple not in triples_logged_this_poll:
        triples_logged_this_poll.add(triple)
        hist = new_history.setdefault(triple, [])
        hist.append(now)
        # Cap per-triple history — only the recent cadence matters; older
        # events get crowded out by the same regularity test we'd run anyway.
        if len(hist) > BEACON_HISTORY_MAX:
            del hist[:-BEACON_HISTORY_MAX]

# TTL-prune triples whose newest event is older than BEACON_HISTORY_TTL.
# Without this the file grows monotonically for any host you ever talked
# to, and the noise floor for "regularity" rises until nothing alerts.
new_history = {
    k: ts for k, ts in new_history.items()
    if ts and (now - ts[-1]) < BEACON_HISTORY_TTL
}

# Hard-cap by count too — if some pathological case (e.g. tor exit
# rotation) blows past TTL pruning we still want the file under ~50KB.
# Keep the most-recently-active triples since those are the only ones
# beacon detection could still fire on.
if len(new_history) > BEACON_HISTORY_CAP:
    ordered = sorted(new_history.items(), key=lambda kv: kv[1][-1], reverse=True)
    new_history = dict(ordered[:BEACON_HISTORY_CAP])

# Compute the set of currently-beaconing triples.  Coefficient of
# variation (stdev/mean) under BEACON_CV_THRESHOLD = "too regular for a
# human-driven workload".  We also skip very-frequent triples since
# DNS/NTP/metrics scrapes naturally look periodic but aren't C2.
beaconing: set[str] = set()
for triple, ts in new_history.items():
    if len(ts) < BEACON_MIN_EVENTS:
        continue
    intervals = [ts[i] - ts[i - 1] for i in range(1, len(ts))]
    if not intervals:
        continue
    mean_iv = statistics.fmean(intervals)
    if mean_iv < BEACON_MIN_MEAN_SECS:
        continue
    try:
        cv = statistics.stdev(intervals) / mean_iv
    except statistics.StatisticsError:
        continue
    if cv < BEACON_CV_THRESHOLD:
        beaconing.add(triple)

for c in conns:
    c["is_beacon"] = c["triple"] in beaconing

snap = {"time": now, "conns": new_conns_state, "history": new_history}
try:
    fd = os.open(STATE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(snap, f)
except Exception:
    pass

if not conns:
    print("  no active connections")
    sys.exit(0)

# ── Summary header: total / public / long-lived counts ─────────────
# Useful even when MAX_SHOW would truncate the row list — the counts
# always reflect ALL connections, not just the rendered subset.
total    = len(conns)
n_public = sum(1 for c in conns if c["is_public"])
n_long   = sum(1 for c in conns if c["is_long"])
n_new    = sum(1 for c in conns if c["is_new"])
n_beacon = sum(1 for c in conns if c["is_beacon"])
# Colour the public + long counts when they're non-zero, since those
# are the "look at this" buckets.  ${color3}=yellow, ${color5}=red.
pub_str  = f"${{color3}}{n_public}${{color}}→public" if n_public else f"{n_public}→public"
# A long-lived connection to a PUBLIC IP is the scariest case — paint
# the long count red specifically when there's also public traffic.
long_col = "${color5}" if (n_long and n_public) else "${color3}" if n_long else ""
long_str = f"{long_col}{n_long}${{color}} long" if n_long else f"{n_long} long"
new_col  = "${color3}" if n_new else ""
new_str  = f"{new_col}{n_new}${{color}} new" if n_new else f"{n_new} new"
# Beaconing count only renders when non-zero — empty space is the
# expected steady-state and we don't want to teach the eye to ignore it.
header = f"  Σ {total}   {pub_str}   {long_str}   {new_str}"
if n_beacon:
    header += f"   ${{color3}}{n_beacon}${{color}} beaconing"
print(header)

# Sort: long-lived public connections first (most interesting), then
# new ones, then everything else by recency.  Keeps the alerting rows
# at the TOP where the user actually looks; mundane housekeeping conns
# (NM dispatcher → 127.0.0.1, dbus, …) sink to the bottom and get
# truncated by MAX_SHOW if needed — losing those is the right tradeoff.
#
# Beacon rows slot in BETWEEN their severity peers: a public beacon
# sits just under a public long-lived row but above private long-lived,
# because periodic callbacks to a public IP is closer in severity to
# "⚠ long-lived public" than to "∞ long-lived private".
def _sort_key(c):
    if   c["is_long"]   and c["is_public"]:  bucket = 0
    elif c["is_beacon"] and c["is_public"]:  bucket = 1
    elif c["is_long"]:                       bucket = 2
    elif c["is_beacon"]:                     bucket = 3
    elif c["is_new"]:                        bucket = 4
    else:                                     bucket = 5
    return (bucket, -c["age"])
conns.sort(key=_sort_key)

# Split: anomalous connections always get individual rows; normal connections
# from COLLAPSE_PROCS are folded into a single summary row per process so
# they don't consume all available display budget.
individual: list[dict] = []
collapsed:  dict[str, list[dict]] = {}
for c in conns:
    proc_base = c["proc"].split()[0] if c["proc"] else c["proc"]
    if proc_base in COLLAPSE_PROCS and not (c["is_long"] or c["is_beacon"]):
        collapsed.setdefault(proc_base, []).append(c)
    else:
        individual.append(c)

for c in individual[:MAX_SHOW]:
    old = prev.get(c["key"])
    if old:
        up_rate   = max(0, c["sent"] - old[0]) / dt
        down_rate = max(0, c["recv"] - old[1]) / dt
    else:
        up_rate = down_rate = 0

    # Row-prefix marker — single glyph, no extra column width.
    # ⚠ long-lived to PUBLIC is the strongest signal — surface in red.
    # ⏱ beacons sit below long-lived rows but above ★ new — they're a
    # weaker signal than a long-running session but stronger than a
    # one-off connection (a regular callback IS a session, just chunked).
    if c["is_long"] and c["is_public"]:
        marker, row_color = "⚠", "${color5}"
    elif c["is_long"]:
        marker, row_color = "∞", "${color3}"
    elif c["is_beacon"]:
        marker, row_color = "⏱", "${color3}"
    elif c["is_new"]:
        marker, row_color = "★", "${color3}"
    else:
        marker, row_color = " ", ""    # inherit default (green) from caller

    # Layout: marker + protocol + direction + local port + remote addr
    # + ↑/↓ rates + age + process.  Process is last so a long name
    # only clips itself, not the bandwidth/age columns.  Age is short
    # (max 3 chars) so it slips in without widening the row.
    age_s = fmt_age(c["age"])
    line = (f" {marker}{c['proto']:<3} {c['dir']} :{c['lport']:<5}  "
            f"{c['raddr']:<16}  "
            f"↑{fmt_rate(up_rate):<8} ↓{fmt_rate(down_rate):<8} "
            f"{age_s:<3} {c['proc']}")
    if row_color:
        print(f"{row_color}{line}${{color}}")
    else:
        print(line)

# One summary row per collapsed process.  Shows connection count, public
# count (security signal), new count, and aggregate bandwidth.
budget_used = min(len(individual), MAX_SHOW)
for proc_base, clist in collapsed.items():
    if budget_used >= MAX_SHOW:
        break
    n     = len(clist)
    n_pub = sum(1 for c in clist if c["is_public"])
    n_new = sum(1 for c in clist if c["is_new"])
    up_tot = dn_tot = 0.0
    for c in clist:
        old = prev.get(c["key"])
        if old:
            up_tot += max(0, c["sent"] - old[0]) / dt
            dn_tot += max(0, c["recv"] - old[1]) / dt
    pub_str = (f"  ${{color3}}{n_pub}→pub${{color}}" if n_pub else "  0→pub")
    new_str = f"  {n_new} new" if n_new else ""
    line = (f"  [{proc_base} ×{n}{pub_str}{new_str}"
            f"  ↑{fmt_rate(up_tot)} ↓{fmt_rate(dn_tot)}]")
    print(line)
    budget_used += 1
