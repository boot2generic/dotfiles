#!/usr/bin/env python3
"""
Conky health / anomaly indicators.

Prints one line per check, colour-coded via conky's ${color5} (red /
problem) and ${color2} (green / nominal).  Lines are conky template
strings — conky parses them at exec time.

Design philosophy: this panel should be **mostly green** on a healthy
system.  Anything red means "look at this".  Don't add metrics here
that are interesting-but-fine in normal operation; they belong in the
regular SYSTEM/CPU/etc. blocks.  This panel is for things you'd want
to know about even when you weren't looking.

Each check is its own function so a single bad check can't break the
others (broad try/except wraps each).  Output is fixed-width-ish so
the conky panel doesn't reflow when one line goes red.

Checks (ordered by severity / how-much-you-want-to-know-immediately):
  1. systemd failed units              — services that crashed
  2. SMART pre-fail                    — disk telling you it's dying
  3. Filesystem usage > 85%            — about to fill up
  4. Memory pressure (PSI)             — system under memory stress
  5. Recent OOM kills                  — kernel had to kill processes
  6. Kernel taint flags                — proprietary/unsigned modules,
                                         crashes, hardware errors
  7. Failed sudo attempts (24h)        — possible attempted compromise
  8. Successful sudo (24h)             — surprise privileged invocations
  9. Critical-file drift               — /etc/{passwd,group,shadow,sudoers},
                                         authorized_keys, systemd units
 10. SUID/SGID binary drift            — new/modified setuid binaries
 11. Daemon→shell parent anomaly       — post-exploit reverse-shell pattern
 12. Pending firmware updates (LVFS)   — Lenovo/Dell/Gigabyte firmware
 13. NTP drift > 1 s                   — clock issues affect TLS, logs
 14. DoT (DNS-over-TLS) state          — encrypted DNS engaged / fallback
 15. Pending reboot for kernel update  — `linux-image-*` upgraded but
                                         still running the old kernel
"""
from __future__ import annotations
import os, re, subprocess, time
from pathlib import Path

# ── Colour helpers (conky template strings) ─────────────────
OK    = "${color2}"   # green
WARN  = "${color3}"   # yellow
BAD   = "${color5}"   # red
DIM   = "${color4}"   # dim grey label
RESET = "${color}"

LINE_WIDTH = 36   # fits within conky panel maximum_width=460


def line(label: str, status: str, detail: str = "") -> str:
    """Render one health row.  `status` colours the marker + the value."""
    marker = f"{status}●{RESET}"
    label_pad = f"{DIM}{label:<18}{RESET}"
    detail_str = f"{status}{detail}{RESET}" if detail else ""
    return f"{marker} {label_pad}{detail_str}"


def _run(cmd: list[str], timeout: int = 3) -> str:
    """Best-effort subprocess wrapper — never raises, always returns str."""
    try:
        return subprocess.check_output(
            cmd, stderr=subprocess.DEVNULL, text=True, timeout=timeout
        )
    except Exception:
        return ""


# ── 1. systemd failed units ──────────────────────────────────
def check_failed_services() -> str:
    out = _run(["systemctl", "--failed", "--no-legend", "--plain"])
    n = sum(1 for ln in out.splitlines() if ln.strip())
    if n == 0:
        return line("services", OK, "all running")
    # Show the first failed unit name; full list is one `systemctl --failed` away.
    first = out.splitlines()[0].split()[0] if out.splitlines() else "?"
    return line("services", BAD, f"{n} failed ({first[:18]}…)" if n > 1
                                  else f"failed: {first[:22]}")


# ── 3. Filesystem usage ──────────────────────────────────────
def check_fs() -> str:
    """Any local filesystem >85% triggers a warning."""
    out = _run(["df", "--output=pcent,target,fstype", "-x", "tmpfs",
                "-x", "devtmpfs", "-x", "squashfs", "-x", "overlay",
                "--local"])
    full = []
    for ln in out.splitlines()[1:]:
        m = re.match(r"\s*(\d+)%\s+(\S+)\s+(\S+)", ln)
        if not m:
            continue
        pct, mount, _fs = m.group(1, 2, 3)
        if int(pct) >= 85:
            full.append(f"{mount}={pct}%")
    if not full:
        return line("disk space", OK, "all <85%")
    return line("disk space", BAD if any(int(f.split('=')[1][:-1]) >= 95
                                         for f in full) else WARN,
                ", ".join(full[:2]))


# ── 4. Memory pressure (PSI) ─────────────────────────────────
def check_psi_memory() -> str:
    """Linux pressure-stall info: /proc/pressure/memory has lines like
       some avg10=0.00 avg60=0.00 avg300=0.00 total=0
       full avg10=0.00 ...
    avg10 > 5 means processes spent 5%+ of the last 10s waiting on
    memory — meaningful pressure.
    """
    p = Path("/proc/pressure/memory")
    if not p.exists():
        return line("mem pressure", DIM, "no PSI")
    try:
        text = p.read_text()
    except OSError:
        return line("mem pressure", DIM, "unreadable")
    m = re.search(r"some\s+avg10=([\d.]+)", text)
    if not m:
        return line("mem pressure", DIM, "no avg10")
    avg10 = float(m.group(1))
    if avg10 >= 10:
        return line("mem pressure", BAD, f"avg10={avg10:.1f}%")
    if avg10 >= 5:
        return line("mem pressure", WARN, f"avg10={avg10:.1f}%")
    return line("mem pressure", OK, f"avg10={avg10:.1f}%")


# ── 5. OOM kills (recent) ────────────────────────────────────
def check_oom() -> str:
    """`journalctl -b` since boot for OOM-killer events."""
    out = _run(["journalctl", "-b", "-k", "--no-pager", "-q",
                "--grep=Out of memory|Killed process"])
    n = sum(1 for ln in out.splitlines() if "out of memory" in ln.lower()
                                          or "killed process" in ln.lower())
    if n == 0:
        return line("OOM kills", OK, "none this boot")
    return line("OOM kills", BAD, f"{n} this boot")


# ── 6. Kernel taint ──────────────────────────────────────────
def check_kernel_taint() -> str:
    """/proc/sys/kernel/tainted is 0 on a clean kernel.  Non-zero is a
    bitmask: P=proprietary module, M=hw error, S=SMP unsafe, etc.
    See `man kernel.taint` (or the kernel source documentation).
    A non-zero value usually just means nvidia-driver is loaded
    (proprietary/closed-source on the legacy path).  We treat that
    case (taint == 4096 + 16384, the proprietary+OOT bits) as benign
    and only WARN/BAD on other flags.
    """
    p = Path("/proc/sys/kernel/tainted")
    if not p.exists():
        return line("kernel taint", DIM, "n/a")
    try:
        v = int(p.read_text().strip())
    except (OSError, ValueError):
        return line("kernel taint", DIM, "unreadable")
    if v == 0:
        return line("kernel taint", OK, "clean")
    PROPRIETARY = 1 << 0      # P
    OOT_MODULE  = 1 << 12     # O
    UNSIGNED    = 1 << 13     # E
    benign_mask = PROPRIETARY | OOT_MODULE | UNSIGNED
    if v & ~benign_mask == 0:
        return line("kernel taint", WARN, f"={v} (driver-only)")
    return line("kernel taint", BAD, f"={v} hw/oops/etc")


# ── 7. Failed sudo attempts (24h) ────────────────────────────
def check_failed_sudo() -> str:
    out = _run(["journalctl", "--since=24 hours ago", "-q", "--no-pager",
                "_COMM=sudo", "--grep=authentication failure|incorrect password"],
               timeout=4)
    n = sum(1 for _ in out.splitlines())
    if n == 0:
        return line("failed sudo 24h", OK, "0")
    sev = BAD if n >= 5 else WARN
    return line("failed sudo 24h", sev, str(n))


# ── 8. Pending firmware updates (LVFS) ───────────────────────
def check_fwupd() -> str:
    """Slow-ish (~1-2s) — only run every Nth invocation via cache.

    Conky's update_interval is 5s but health.py's execpi runs at the
    cycle conky chooses for it.  fwupdmgr makes a network call; we
    cache the answer for 1 hour to keep conky responsive.
    """
    cache = Path("/run/user") / str(os.getuid()) / "conky" / "fwupd"
    cache.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if cache.exists() and time.time() - cache.stat().st_mtime < 3600:
        try:
            n = int(cache.read_text().strip())
        except (OSError, ValueError):
            n = -1
    else:
        out = _run(["fwupdmgr", "get-updates", "--json"], timeout=10)
        # Cheap parse: count "Releases" entries.  Failures (no LVFS
        # remote, no devices) print "no updatable devices found"
        # → we treat as 0 but cache the answer.
        n = out.count('"AppstreamId"') if out else 0
        try:
            cache.write_text(str(n))
        except OSError:
            pass
    if n < 0:
        return line("firmware (LVFS)", DIM, "unknown")
    if n == 0:
        return line("firmware (LVFS)", OK, "up to date")
    return line("firmware (LVFS)", WARN, f"{n} pending")


# ── 9. NTP drift ────────────────────────────────────────────
def check_ntp() -> str:
    """timedatectl shows 'System clock synchronized: yes' and the
    active service.  We surface the sync state + drift if available.
    """
    out = _run(["timedatectl", "show", "-p", "NTPSynchronized",
                "-p", "NTP", "--value"])
    parts = out.split()
    if len(parts) < 2:
        return line("NTP sync", DIM, "n/a")
    ntp_enabled = parts[0] == "yes"
    ntp_synced  = parts[1] == "yes"
    if not ntp_enabled:
        return line("NTP sync", WARN, "service off")
    if not ntp_synced:
        return line("NTP sync", BAD, "not synced")
    return line("NTP sync", OK, "synced")


# ── 9b. DNS-over-TLS (DoT) state ────────────────────────────
def check_dot() -> str:
    """Report whether systemd-resolved has DoT engaged on the link
    carrying the default route.

    Parsing strategy: `resolvectl status` prints a per-link
    `Protocols:` line where each protocol gets a `+` (active) or `-`
    (inactive) prefix, e.g.
        Protocols: +DefaultRoute +LLMNR +mDNS +DNSOverTLS DNSSEC=...
    The link we care about is the one carrying the default route --
    on a roaming laptop that may be wifi today, ethernet tomorrow.
    We pick it from `ip route show default`.

    Three states the user actually wants surfaced:
      OK   "active on <iface>"     -- +DNSOverTLS on the live link
      WARN "fallback (plain DNS)"  -- resolved is running but the link
                                      shows -DNSOverTLS (upstream blocks
                                      TCP/853, captive portal, etc.)
      DIM  "not configured"        -- resolved isn't installed / not
                                      active; user hasn't run --harden
    """
    # Cheap gate first: if resolved isn't running, no point shelling out
    # to resolvectl.  is-active returns 0 for "active", non-zero for
    # everything else; _run() returns "" on non-zero exit which is fine.
    state = _run(["systemctl", "is-active", "systemd-resolved"]).strip()
    if state != "active":
        return line("DoT", DIM, "not configured")

    # Find the link carrying the default route -- that's the one whose
    # DoT state actually matters for the user's outbound traffic.
    route = _run(["ip", "-o", "route", "show", "default"])
    # Format: "default via <gw> dev <iface> ..."  Be defensive about
    # whitespace and missing fields rather than indexing blindly.
    iface = ""
    toks = route.split()
    if "dev" in toks:
        i = toks.index("dev")
        if i + 1 < len(toks):
            iface = toks[i + 1]
    if not iface:
        return line("DoT", DIM, "no default route")

    out = _run(["resolvectl", "status", iface])
    if not out:
        # iface not known to resolved -- e.g. a VPN tun NM hasn't
        # registered yet.  Surface as WARN so the user notices.
        return line("DoT", WARN, f"no resolved data for {iface[:10]}")

    # Look for the Protocols: line.  Match `+DNSOverTLS` (active) vs
    # `-DNSOverTLS` (inactive / fallback).  Some resolved versions
    # emit "DNSOverTLS=opportunistic" on the global block too -- we
    # specifically want the per-link `+`/`-` token.
    proto_line = ""
    for ln in out.splitlines():
        s = ln.strip()
        if s.startswith("Protocols:"):
            proto_line = s
            break
    if not proto_line:
        return line("DoT", DIM, "no Protocols line")

    if "+DNSOverTLS" in proto_line:
        return line("DoT", OK, f"active on {iface[:10]}")
    if "-DNSOverTLS" in proto_line:
        # Configured but upstream-disabled (plain-DNS fallback).  This
        # is the threat-model-relevant warning state.
        return line("DoT", WARN, "fallback (plain)")
    # Protocols line exists but no DNSOverTLS token at all -- very old
    # resolved, or build without DoT support.
    return line("DoT", DIM, "n/a (old resolved)")


# ── 10. Pending reboot for kernel update ─────────────────────
def check_reboot_required() -> str:
    """Compare the running kernel to the latest installed.  If there's
    a newer linux-image-* package than what `uname -r` says, a reboot
    is pending."""
    running = _run(["uname", "-r"]).strip()
    if not running:
        return line("kernel reboot", DIM, "n/a")
    out = _run(["bash", "-c",
                "ls -1 /boot/vmlinuz-* 2>/dev/null | "
                "sed 's|.*/vmlinuz-||' | sort -V | tail -1"])
    latest = out.strip()
    if not latest:
        return line("kernel reboot", DIM, "no /boot")
    if latest == running:
        return line("kernel reboot", OK, f"running latest ({running[:14]})")
    return line("kernel reboot", WARN, f"reboot for {latest[:14]}")


# ── 11. Listening-port drift ─────────────────────────────────
def check_port_drift() -> str:
    """Compare current TCP listeners against a baseline file.

    On first run, capture the current set as the baseline and report
    "baseline set".  On subsequent runs, alert on any diff (added or
    removed ports).  This catches:
      • Backdoors that open a new listener (added port).
      • Services you forgot to stop after a research session
        (Jupyter on :8888, dev server on :3000 still up next morning).
      • Services that died unexpectedly (removed port).
    Baseline lives at ~/.config/conky/baseline-ports.txt — to ack a
    legitimate change, just delete it.  The next run rebuilds it
    silently.
    """
    base = Path.home() / ".config" / "conky" / "baseline-ports.txt"
    base.parent.mkdir(parents=True, exist_ok=True, mode=0o755)

    # Fast path: collect TCP listening ports + binding address.
    # `ss -tln` (no -p, no sudo) is plenty for the diff — we only
    # need port numbers, not process names.
    out = _run(["ss", "-tln"])
    current: set[str] = set()
    for ln in out.splitlines()[1:]:
        parts = ln.split()
        if len(parts) < 4:
            continue
        local = parts[3]
        port = local.rsplit(":", 1)[-1]
        if port.isdigit():
            # Tag with bind address so 127.0.0.1:5900 vs 0.0.0.0:5900
            # show up as different — going from loopback to all-ifaces
            # is a real anomaly even on the same port.
            host = local.rsplit(":", 1)[0] or "*"
            current.add(f"{host}:{port}")

    if not base.exists():
        try:
            base.write_text("\n".join(sorted(current)) + "\n")
        except OSError:
            return line("port drift", DIM, "baseline write fail")
        return line("port drift", DIM, f"baseline set ({len(current)})")

    try:
        baseline = set(base.read_text().splitlines()) - {""}
    except OSError:
        return line("port drift", DIM, "baseline unreadable")

    added   = current - baseline
    removed = baseline - current
    if not added and not removed:
        return line("port drift", OK, f"matches baseline ({len(current)})")

    bits = []
    if added:
        bits.append(f"+{len(added)} {sorted(added)[0][-12:]}")
    if removed:
        bits.append(f"-{len(removed)} {sorted(removed)[0][-12:]}")
    sev = BAD if added else WARN     # adds are scarier than removes
    return line("port drift", sev, " ".join(bits))


# ── 12. Mullvad VPN expected-but-down ────────────────────────
def check_mullvad() -> str:
    """Only checked when ~/.config/conky/mullvad-expected exists.

    Make this an opt-in check rather than always-on, because not every
    session wants the VPN up (e.g., debugging local network issues, on
    a captive portal, etc.).  Toggle with:
        touch ~/.config/conky/mullvad-expected     # enable
        rm    ~/.config/conky/mullvad-expected     # disable
    """
    flag = Path.home() / ".config" / "conky" / "mullvad-expected"
    if not flag.exists():
        return line("mullvad VPN", DIM, "not monitored")
    if not _run(["which", "mullvad"]).strip():
        return line("mullvad VPN", DIM, "not installed")

    # `mullvad status` first line:
    #   "Connected to <relay>"           → good
    #   "Disconnected"                   → bad (we're expecting up)
    #   "Connecting..." / "Disconnecting"→ transient, treat as warn
    #   "Blocked"                        → kill-switch active, treat as warn
    out = _run(["mullvad", "status"], timeout=4).strip().lower()
    if not out:
        return line("mullvad VPN", BAD, "no response")
    first = out.splitlines()[0]
    if first.startswith("connected"):
        # Surface the relay short-name so the user can tell which exit
        # they're on at a glance.
        relay = ""
        m = re.search(r"connected to ([^\s,]+)", first)
        if m:
            relay = m.group(1)[:18]
        return line("mullvad VPN", OK, f"connected {relay}")
    if first.startswith("disconnected"):
        return line("mullvad VPN", BAD, "disconnected")
    return line("mullvad VPN", WARN, first[:24])


# ── 13. High-CPU process spike ───────────────────────────────
def check_high_cpu() -> str:
    """Snapshot of current top CPU consumer; flags processes >90%.

    Note: this is a single `ps` snapshot (instantaneous), not a
    sustained-spike detector.  ps reports CPU time / wall time since
    process start, so a 90%+ value means the process really is using
    that much CPU on average since it started.  For sustained-spike
    detection we'd need to sample across multiple invocations of
    health.py, which adds state-on-disk complexity not worth it for
    a panel.

    Runs `ps -eo %cpu,comm,pid --sort=-%cpu --no-headers | head -3`.
    Counts CPU% as a fraction of one core (so 200% = 2 cores fully
    used on a 32-core box; 95% of one core counts as a spike).
    """
    out = _run(["ps", "-eo", "%cpu,comm,pid", "--sort=-%cpu",
                "--no-headers"])
    if not out:
        return line("CPU hog", DIM, "ps failed")
    top: list[tuple[float, str, str]] = []
    for ln in out.splitlines()[:5]:
        parts = ln.split(None, 2)
        if len(parts) < 3:
            continue
        try:
            pct = float(parts[0])
        except ValueError:
            continue
        comm = parts[1][:14]
        pid  = parts[2].strip()
        top.append((pct, comm, pid))
    if not top:
        return line("CPU hog", DIM, "no procs")
    pct, comm, pid = top[0]
    if pct >= 90:
        return line("CPU hog", BAD, f"{comm} {pct:.0f}% pid={pid}")
    if pct >= 50:
        return line("CPU hog", WARN, f"{comm} {pct:.0f}%")
    return line("CPU hog", OK, f"top {comm} {pct:.0f}%")


# ── 14. Suspicious-path processes ────────────────────────────
def check_suspicious_paths() -> str:
    """Flag processes whose executable lives somewhere malware likes.

    Common post-exploit / dropper indicators:
      • exe under /tmp, /var/tmp, /dev/shm  — writable by anyone, often
        used to drop payloads from a constrained exploit primitive.
      • /proc/<pid>/exe symlink ends in `(deleted)` — the binary on
        disk was unlinked after the process started, a textbook
        in-memory-only payload pattern (defeats simple `find / -name`
        searches).
      • Processes not under any cgroup unit — most legit user/system
        processes are accounted to a slice/scope.  A rogue process
        spawned via direct fork() from cron or an exploited daemon
        may end up in the root cgroup.

    Allowlist for known false positives:
      • Snap / Flatpak / AppImage / Firefox content procs whose paths
        legitimately include /tmp or /var/tmp (FUSE mounts, app
        containers).
      • Browsers explicitly cleaning up after themselves often appear
        with `(deleted)` exe for a brief window during update.

    We list at most one offender — `cat /proc/<pid>/{exe,comm}` is the
    next step a human would take.  Iterates /proc once; ~50 ms even on
    boxes with thousands of PIDs.
    """
    # Allowlist of path prefixes whose `(deleted)` / /tmp matches are
    # not interesting.  Match by substring so we tolerate the
    # `<NUL>(deleted)` suffix kernels add to the readlink output.
    ALLOW_SUBSTRS = (
        "/snap/", "/var/lib/flatpak/", "/run/firefox/", "/tmp/.mount_",
        "/tmp/runtime-",  # XDG_RUNTIME_DIR fallbacks
        "/usr/lib/firefox", "/usr/lib/chromium",
    )
    SUSPECT_PREFIXES = ("/tmp/", "/var/tmp/", "/dev/shm/")
    # "(deleted)" exe paths from a SYSTEM_PREFIXES location, where the
    # file is still present on disk RIGHT NOW, are almost always a
    # benign post-upgrade artefact: apt unlinked the old binary, the
    # new one was put in place, the process kept running on the old
    # inode.  Solve by restarting the process (systemctl restart …,
    # `exec zsh`, log out and back in, etc.).  Genuine malware that
    # self-deletes from /usr/bin to evade `find / -name` would also
    # land here, but it would simultaneously REMOVE the file — so
    # `Path(exe).exists()` is the discriminator.
    SYSTEM_PREFIXES = ("/usr/bin/", "/usr/sbin/", "/usr/libexec/",
                       "/usr/lib/", "/bin/", "/sbin/", "/lib/")

    def _shorten_path(p: str, max_len: int) -> str:
        """Truncate a path from the LEFT (keep the tail = filename +
        parent dir), prefixed with `…` to make the truncation obvious.
        Filenames carry the most diagnostic value — `/very/deep/.../X`
        tells the user more than `/very/deep/long/...` ever could."""
        if len(p) <= max_len:
            return p
        return "…" + p[-(max_len - 1):]

    # Each hit is a (severity, detail) tuple.  We track WARN vs BAD
    # so a 3-deep "post-upgrade restart-needed" backlog doesn't paint
    # the panel red while a single in-/tmp/-malware exe does.
    hits: list[tuple[str, str]] = []
    try:
        proc_root = Path("/proc")
        for pid_dir in proc_root.iterdir():
            if not pid_dir.name.isdigit():
                continue
            try:
                exe = os.readlink(pid_dir / "exe")
            except (OSError, PermissionError):
                continue   # kernel thread, vanished, or no perm
            if any(s in exe for s in ALLOW_SUBSTRS):
                continue
            if exe.endswith(" (deleted)"):
                # Strip the " (deleted)" suffix so we can render the
                # actual path; signal "deleted" with a "(del)" trailer.
                # The path is the diagnostic gold — without it the user
                # has to `readlink /proc/<pid>/exe` to know what was
                # nuked.  Trade off the comm (often redundant once you
                # see the basename) for the path's worth.
                exe_path = exe[:-len(" (deleted)")]
                pid = pid_dir.name
                # Classify: system-location + file-still-on-disk = the
                # benign "package upgraded, restart me" case (WARN).
                # Anywhere else, OR file genuinely gone = BAD.
                from_system = any(exe_path.startswith(p) for p in SYSTEM_PREFIXES)
                still_on_disk = False
                try:
                    still_on_disk = Path(exe_path).exists()
                except OSError:
                    pass
                sev = WARN if (from_system and still_on_disk) else BAD
                # Budget: ~28 chars for the path after the [pid] (del) prefix.
                hits.append((sev, f"[{pid}] (del) {_shorten_path(exe_path, 28)}"))
                if len(hits) >= 8:   # cap iteration cost; we only render one
                    break
                continue
            if any(exe.startswith(p) for p in SUSPECT_PREFIXES):
                pid = pid_dir.name
                # Live process running from a writable /tmp-ish location
                # is always BAD — there's no benign explanation that we'd
                # want to soften the alert for.
                hits.append((BAD, f"[{pid}] {_shorten_path(exe, 32)}"))
                if len(hits) >= 8:
                    break
    except OSError:
        return line("suspicious exe", DIM, "/proc unreadable")
    if not hits:
        return line("suspicious exe", OK, "none")
    # Surface the worst hit first; ties broken by iteration order (stable).
    hits.sort(key=lambda h: 0 if h[0] is BAD else 1)
    worst_sev = hits[0][0]
    n = len(hits)
    # Cap at ~42 chars per row so the panel never wraps (panel max_width
    # 460 / JBM size 8 ≈ 65 chars total, minus the 20-char marker+label
    # prefix = ~45 chars of detail headroom).
    DETAIL_CAP = 42

    if n == 1:
        return line("suspicious exe", worst_sev, hits[0][1][:DETAIL_CAP])

    # Multiple findings — emit one HEADER line that carries the marker
    # + label + total count, followed by one CONTINUATION line per
    # hit.  Continuation lines align under the detail column (20 col
    # indent: 1 marker + 1 space + 18-char label pad) and carry their
    # own severity colour so the BAD ones visibly stand out from
    # WARN ones in a mixed list.
    out: list[str] = [
        line("suspicious exe", worst_sev, f"{n} found:")
    ]
    # Hard cap continuation rows at 5 so a runaway "everything is
    # deleted-exe" scenario can't swallow the rest of the panel.
    MAX_ROWS = 5
    indent = " " * 20
    for sev, detail in hits[:MAX_ROWS]:
        out.append(f"{indent}{sev}{detail[:DETAIL_CAP]}{RESET}")
    if n > MAX_ROWS:
        out.append(f"{indent}{DIM}…and {n - MAX_ROWS} more{RESET}")
    return "\n".join(out)


# ── 15. Hidden PIDs (rootkit indicator) ──────────────────────
def check_hidden_pids() -> str:
    """PIDs present in /proc but NOT in `ps -e` output.

    Classic userspace process-hider rootkits (libprocesshider, Reptile's
    user-mode component, etc.) intercept libc's readdir() so /bin/ps
    skips listed PIDs while /proc itself still has them.  Comparing
    sets catches that.

    Race-condition handling (three-snapshot pattern):
        proc_a → ps → proc_b → ps wasn't enough.  Earlier we saw
        false positives where a transient PID (e.g., a quick
        `subprocess.Popen` from another tool) was present in BOTH
        /proc reads but died before `ps` ran — flagged as hidden
        when it was just an unlucky moment of mortality.  Solution:
        require the PID to appear in /proc BEFORE ps AND in /proc
        AFTER ps.  Anything that dies during ps's ~10ms execution
        won't be in the "after" snapshot, so it's excluded.
        True rootkit-hidden PIDs are persistent — they survive both
        snapshots trivially.
    """
    def read_proc_pids() -> set[str]:
        try:
            return {p.name for p in Path("/proc").iterdir()
                    if p.name.isdigit()}
        except OSError:
            return set()

    proc_before = read_proc_pids()
    if not proc_before:
        return line("hidden PIDs", DIM, "/proc unreadable")
    # Tiny gap so a short-lived helper that spawns RIGHT before ps
    # also has a chance to be observed in proc_before — without this
    # sleep, a Python subprocess that fork+execs and exits in <1ms
    # could miss the snapshot.
    time.sleep(0.02)

    out = _run(["ps", "-eo", "pid="])
    if not out:
        return line("hidden PIDs", DIM, "ps failed")
    ps_pids = {ln.strip() for ln in out.splitlines() if ln.strip()}

    # Re-read /proc AFTER ps — any PID that died between proc_before and
    # ps will be missing here too, so the intersection only retains
    # PIDs that were genuinely alive across the entire ps run.
    proc_after = read_proc_pids()
    persistently_alive = proc_before & proc_after

    hidden = persistently_alive - ps_pids
    n = len(hidden)
    if n == 0:
        return line("hidden PIDs", OK, "none")
    # Sample one hidden PID; the user can `ls /proc/<pid>/{exe,comm,cmdline}`
    sample = sorted(hidden, key=int)[0]
    return line("hidden PIDs", BAD, f"{n} (e.g. {sample})")


# ── 16. Critical-file drift ──────────────────────────────────
def check_critical_file_drift() -> str:
    """SHA-256 inventory of files that should almost never change.

    Auth/authz crown jewels: /etc/passwd, /etc/group, /etc/shadow,
    /etc/sudoers (+ drop-ins), authorized_keys, every systemd unit
    you've installed locally, and every cron.d job.  Any change here
    without user knowledge is a textbook persistence indicator —
    fresh sudoers entry, ssh key added, hostile systemd unit dropped
    into /etc/systemd/system/, etc.

    Baseline at ~/.config/conky/baseline-critical-files.txt; delete
    to re-baseline after a legit change (apt upgrade, ssh-copy-id).
    `/etc/shadow` needs sudo -n; we tolerate sudo denial silently
    (the line just gets dropped from the snapshot, so its presence
    in the diff stays consistent across runs).
    """
    base = Path.home() / ".config" / "conky" / "baseline-critical-files.txt"
    base.parent.mkdir(parents=True, exist_ok=True, mode=0o755)

    # Build the candidate file list.  Globs are expanded HERE not in
    # the shell so a malicious filename can't smuggle metachars in.
    paths: list[str] = ["/etc/passwd", "/etc/group", "/etc/sudoers"]
    try:
        for p in Path("/etc/sudoers.d").iterdir():
            if p.is_file():
                paths.append(str(p))
    except OSError:
        pass
    ak = Path.home() / ".ssh" / "authorized_keys"
    if ak.exists():
        paths.append(str(ak))
    try:
        for p in Path("/etc/systemd/system").rglob("*.service"):
            if p.is_file():
                paths.append(str(p))
    except OSError:
        pass
    try:
        for p in Path("/etc/cron.d").iterdir():
            if p.is_file():
                paths.append(str(p))
    except OSError:
        pass
    # shadow is sudo-only; try non-interactive sudo and tolerate denial.
    paths.append("/etc/shadow")

    current: dict[str, str] = {}
    for path in paths:
        if path == "/etc/shadow":
            out = _run(["sudo", "-n", "sha256sum", path], timeout=2)
        else:
            out = _run(["sha256sum", path], timeout=2)
        if not out:
            continue
        sha = out.split()[0]
        current[path] = sha

    if not current:
        return line("critfile drift", DIM, "no files hashed")

    if not base.exists():
        try:
            base.write_text(
                "\n".join(f"{sha}  {p}" for p, sha in sorted(current.items())) + "\n"
            )
        except OSError:
            return line("critfile drift", DIM, "baseline write fail")
        return line("critfile drift", DIM, f"baseline set ({len(current)})")

    try:
        baseline: dict[str, str] = {}
        for ln in base.read_text().splitlines():
            parts = ln.split(None, 1)
            if len(parts) == 2:
                baseline[parts[1].strip()] = parts[0].strip()
    except OSError:
        return line("critfile drift", DIM, "baseline unreadable")

    added   = set(current) - set(baseline)
    removed = set(baseline) - set(current)
    changed = {p for p in set(current) & set(baseline)
               if current[p] != baseline[p]}

    if not added and not removed and not changed:
        return line("critfile drift", OK, f"matches baseline ({len(current)})")

    # Any change in these files is BAD — they almost never change
    # without explicit user action (apt-postinst on /etc/passwd is rare
    # and worth seeing too).
    bits = []
    if changed:
        sample = sorted(changed)[0]
        bits.append(f"{len(changed)} changed: {sample[-22:]}")
    if added:
        sample = sorted(added)[0]
        bits.append(f"+{len(added)} {sample[-18:]}")
    if removed:
        sample = sorted(removed)[0]
        bits.append(f"-{len(removed)} {sample[-18:]}")
    return line("critfile drift", BAD, " ".join(bits))


# ── 17. Recent successful sudo invocations ───────────────────
def check_recent_sudo_invocations() -> str:
    """Count successful sudo runs in last 24h + show most recent.

    Complements check_failed_sudo: spike in SUCCESSFUL sudo (especially
    from a non-interactive session) may indicate something automating
    sudo with cached creds or a compromised shell history replay.
    Most-recent-command + relative timestamp answers "did I just do
    this or is it a surprise?".
    """
    out = _run(["journalctl", "_COMM=sudo", "--since=24 hours ago",
                "-q", "--no-pager", "--grep=COMMAND="],
               timeout=4)
    if not out:
        return line("sudo ok 24h", OK, "0 in 24h")

    # journalctl default line: "May 18 09:00:01 host sudo[1234]: user : TTY=... ; PWD=... ; USER=root ; COMMAND=/usr/bin/apt update"
    lines = [ln for ln in out.splitlines() if "COMMAND=" in ln]
    n = len(lines)
    if n == 0:
        return line("sudo ok 24h", OK, "0 in 24h")

    last = lines[-1]
    # Pull COMMAND= tail.  Bound at 28 chars so the row doesn't wrap.
    cmd = last.split("COMMAND=", 1)[1].strip()
    cmd_short = cmd[:28] + ("…" if len(cmd) > 28 else "")

    # Best-effort "X ago" from the leading syslog timestamp.  journalctl
    # honours system locale; we parse the year-less "May 18 09:00:01"
    # form by re-attaching the current year and asking time.mktime.
    rel = ""
    try:
        # First 15 chars: "May 18 09:00:01"
        ts_str = last[:15]
        now = time.time()
        ts = time.mktime(time.strptime(
            f"{time.strftime('%Y')} {ts_str}", "%Y %b %d %H:%M:%S"))
        delta = max(0, int(now - ts))
        if delta < 60:
            rel = f"{delta}s ago"
        elif delta < 3600:
            rel = f"{delta // 60}m ago"
        elif delta < 86400:
            rel = f"{delta // 3600}h ago"
        else:
            rel = f"{delta // 86400}d ago"
    except (ValueError, OverflowError):
        rel = "recent"

    sev = OK if n <= 10 else (WARN if n <= 50 else BAD)
    return line("sudo ok 24h", sev, f"{n}, last {rel}: {cmd_short}")


# ── 18. SUID / SGID binary drift ─────────────────────────────
def check_suid_drift() -> str:
    """Inventory of every SUID/SGID binary, hashed and compared daily.

    Find scan of the whole rootfs is slow (~30-60s) — way too expensive
    to do every 30s.  Strategy: if the baseline file exists and is less
    than 23h old, return OK immediately referencing the baseline age.
    Only when the baseline is older do we accept the cost of a fresh
    `find` scan + diff.  This makes the check effectively once-a-day.

    A 30-day silent reset prevents the file going stale indefinitely
    if the user never deletes it manually.

    Any add or change = BAD (new SUID root binary is the canonical
    privilege-escalation persistence trick).  Remove = WARN (likely
    apt removing setcap'd helpers).
    """
    base = Path.home() / ".config" / "conky" / "baseline-suid.txt"
    base.parent.mkdir(parents=True, exist_ok=True, mode=0o755)

    now = time.time()
    if base.exists():
        age = now - base.stat().st_mtime
        STALE_RESET = 30 * 86400
        if age < 23 * 3600:
            hours = int(age // 3600)
            return line("suid drift", OK, f"baseline ({hours}h old)")
        if age > STALE_RESET:
            # Silent reset: re-baseline next pass below by removing the
            # file so the "no baseline" branch fires.
            try:
                base.unlink()
            except OSError:
                pass

    # Fresh find scan — slow (30-60s).  -xdev keeps us off network/FUSE
    # mounts; the panel cycle will block here for the duration but only
    # once a day.
    find_out = _run(
        ["find", "/", "-xdev",
         "(", "-perm", "-4000", "-o", "-perm", "-2000", ")",
         "-type", "f"],
        timeout=90)
    if not find_out:
        return line("suid drift", DIM, "find failed")

    current: dict[str, str] = {}
    for path in find_out.splitlines():
        path = path.strip()
        if not path:
            continue
        sha_out = _run(["sha256sum", path], timeout=2)
        if not sha_out:
            continue
        current[path] = sha_out.split()[0]

    if not current:
        return line("suid drift", DIM, "no suid found")

    if not base.exists():
        try:
            base.write_text(
                "\n".join(f"{sha}  {p}" for p, sha in sorted(current.items())) + "\n"
            )
        except OSError:
            return line("suid drift", DIM, "baseline write fail")
        return line("suid drift", DIM, f"baseline set ({len(current)})")

    try:
        baseline: dict[str, str] = {}
        for ln in base.read_text().splitlines():
            parts = ln.split(None, 1)
            if len(parts) == 2:
                baseline[parts[1].strip()] = parts[0].strip()
    except OSError:
        return line("suid drift", DIM, "baseline unreadable")

    added   = set(current) - set(baseline)
    removed = set(baseline) - set(current)
    changed = {p for p in set(current) & set(baseline)
               if current[p] != baseline[p]}

    if not added and not removed and not changed:
        return line("suid drift", OK, f"matches baseline ({len(current)})")

    bits = []
    if added:
        bits.append(f"+{len(added)} {sorted(added)[0][-14:]}")
    if changed:
        bits.append(f"~{len(changed)} {sorted(changed)[0][-14:]}")
    if removed:
        bits.append(f"-{len(removed)} {sorted(removed)[0][-14:]}")
    sev = BAD if (added or changed) else WARN
    return line("suid drift", sev, " ".join(bits))


# ── 19. Anomalous daemon→shell parent chains ─────────────────
def check_parent_anomaly() -> str:
    """Daemons spawning interactive-shell-ish children = exploitation.

    Legit sshd login chains have an intermediate `sshd: user@pts/N`
    privsep process before bash — so the user-bash's PARENT comm is
    that sshd-session, not bare `sshd`.  A direct nginx→bash or
    postfix→sh means the daemon was used as the spawn point, classic
    post-exploit reverse-shell pattern (think: webshell calling
    /bin/sh, or Log4Shell-style RCE).

    Iterates /proc/*/stat once (cheap; field 2 is comm, field 4 is
    ppid).  No subprocess.  Per-PID errors swallowed (vanished /
    permission).
    """
    DAEMONS = {"sshd", "nginx", "apache2", "httpd", "cron", "atd",
               "dovecot", "postfix", "mysqld", "postgres", "exim4"}
    SHELLS  = {"bash", "sh", "zsh", "dash", "ash", "csh", "ksh", "fish",
               "python", "python3", "perl", "ruby", "nc", "ncat",
               "socat", "busybox"}

    # First pass: build pid → comm map.  Needed because we want to look
    # up the parent's comm by ppid in the second pass.
    pid_to_comm: dict[str, str] = {}
    pid_to_ppid: dict[str, str] = {}
    try:
        for pid_dir in Path("/proc").iterdir():
            if not pid_dir.name.isdigit():
                continue
            try:
                stat = (pid_dir / "stat").read_text()
            except (OSError, PermissionError):
                continue
            # Format: PID (comm) state ppid ...   comm may contain
            # spaces/parens, so split on the LAST ')'.
            lparen = stat.find("(")
            rparen = stat.rfind(")")
            if lparen < 0 or rparen < 0:
                continue
            comm = stat[lparen + 1:rparen]
            rest = stat[rparen + 2:].split()
            if len(rest) < 2:
                continue
            ppid = rest[1]
            pid_to_comm[pid_dir.name] = comm
            pid_to_ppid[pid_dir.name] = ppid
    except OSError:
        return line("parent anomaly", DIM, "/proc unreadable")

    hits: list[str] = []
    for pid, comm in pid_to_comm.items():
        if comm not in SHELLS:
            continue
        ppid = pid_to_ppid.get(pid, "0")
        pcomm = pid_to_comm.get(ppid, "")
        if pcomm in DAEMONS:
            hits.append(f"{pcomm}→{comm}[{pid}]")
            if len(hits) >= 8:   # cap iteration; render at most 5
                break

    if not hits:
        return line("parent anomaly", OK, "none")

    n = len(hits)
    DETAIL_CAP = 42
    if n == 1:
        return line("parent anomaly", BAD, hits[0][:DETAIL_CAP])

    # Multi-hit: header + indented continuation rows, mirroring the
    # check_suspicious_paths pattern.  Every hit here is severity BAD,
    # so the rows all get BAD colouring uniformly.
    out: list[str] = [
        line("parent anomaly", BAD, f"{n} pairs:")
    ]
    MAX_ROWS = 5
    indent = " " * 20
    for h in hits[:MAX_ROWS]:
        out.append(f"{indent}{BAD}{h[:DETAIL_CAP]}{RESET}")
    if n > MAX_ROWS:
        out.append(f"{indent}{DIM}…and {n - MAX_ROWS} more{RESET}")
    return "\n".join(out)


# ── 20. Kernel-module drift ──────────────────────────────────
def check_module_drift() -> str:
    """SHA-256 of `lsmod` output vs a persisted baseline.

    First run captures the baseline.  Subsequent runs alert on any
    difference — a new module loaded, an existing one removed, even a
    reload (which changes the size column).  Captures:
      • Malicious LKM (rootkit) load events.
      • Unexpected DKMS rebuild after kernel upgrade — also worth
        knowing about even if benign.
      • Manual `insmod` / `modprobe` you forgot about overnight.

    Baseline lives at ~/.config/conky/baseline-modules.txt — to ack a
    legitimate change (e.g., after `nvidia-driver` reinstall), delete
    the file; the next run rebuilds it silently.
    """
    base = Path.home() / ".config" / "conky" / "baseline-modules.txt"
    base.parent.mkdir(parents=True, exist_ok=True, mode=0o755)

    out = _run(["lsmod"])
    if not out:
        return line("module drift", DIM, "lsmod failed")
    # Drop the "Module Size Used by" header so a kernel-version bump
    # that changes column widths doesn't false-positive.  Keep only
    # the module names + the "Used by" count, NOT the size (which can
    # vary across kernel rebuilds without any real semantic change).
    current_lines = []
    for ln in out.splitlines()[1:]:
        parts = ln.split()
        if len(parts) >= 3:
            current_lines.append(f"{parts[0]} {parts[2]}")
    current = sorted(current_lines)
    current_text = "\n".join(current) + "\n"

    if not base.exists():
        try:
            base.write_text(current_text)
        except OSError:
            return line("module drift", DIM, "baseline write fail")
        return line("module drift", DIM, f"baseline set ({len(current)})")

    try:
        baseline = base.read_text().splitlines()
    except OSError:
        return line("module drift", DIM, "baseline unreadable")

    base_names    = {ln.split()[0] for ln in baseline if ln.strip()}
    current_names = {ln.split()[0] for ln in current  if ln.strip()}
    added   = current_names - base_names
    removed = base_names - current_names
    if not added and not removed:
        return line("module drift", OK, f"matches baseline ({len(current_names)})")
    bits = []
    if added:
        bits.append(f"+{len(added)} {sorted(added)[0][:10]}")
    if removed:
        bits.append(f"-{len(removed)} {sorted(removed)[0][:10]}")
    sev = BAD if added else WARN     # adds are scarier than removes
    return line("module drift", sev, " ".join(bits))


# ── 21. Supply-chain pin freshness ──────────────────────────
def check_pins() -> str:
    """Phase 0 supply-chain row.

    Shells out to scripts/verify-pins.sh and classifies by exit code:
      0 → OK   ("all fresh")
      1 → WARN ("<N> stale")        — at least one pin past refresh_after_days
      2 → BAD  ("<N> failed")       — sha-256 / gpg verification fail
      missing script  → DIM ("verify-pins.sh missing")
      tool error (rc≥3 / no exec) → DIM ("err: <token>")

    Sits in the drift cluster because it answers the same kind of
    question those checks do ("did something change without me
    noticing?") — just one rung further up the supply chain.

    Resolution of the script path uses a small search list so the
    panel works whether health.py is invoked from ~/.config/conky/
    (the deployed location) OR straight out of the dotfiles repo.
    """
    # Candidate paths, in order.  We resolve relative to:
    #   1. an explicit ~/Share/dotfiles checkout (this user's layout)
    #   2. a sibling-of-this-script layout (deployed conky dir + repo)
    #   3. PATH (last-ditch — verify-pins.sh isn't usually on PATH but
    #      a future install step might add it).
    home = Path.home()
    candidates = [
        home / "Share" / "dotfiles" / "scripts" / "verify-pins.sh",
        Path(__file__).resolve().parent.parent.parent / "scripts" / "verify-pins.sh",
    ]
    script: Path | None = None
    for c in candidates:
        if c.is_file() and os.access(c, os.X_OK):
            script = c
            break
    if script is None:
        return line("supply chain", DIM, "verify-pins.sh missing")

    # Run the script and capture rc + stdout.  Short timeout — pin
    # verification is a local sha-256 + age check, not a network
    # operation, so anything >5s is pathological.
    try:
        proc = subprocess.run(
            [str(script)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=5, text=True,
        )
    except subprocess.TimeoutExpired:
        return line("supply chain", DIM, "verify-pins timeout")
    except Exception:
        return line("supply chain", DIM, "verify-pins err")

    rc = proc.returncode
    out = proc.stdout or ""

    # Parse counts from the human-readable output.  We DON'T re-run with
    # --json — running it twice would double-cost a check the panel
    # repaints frequently.  Counts pulled by regex; tolerant of format
    # drift (Agent C may evolve column widths / wording).
    n_stale = len(re.findall(r"^\[stale\]", out, flags=re.MULTILINE))
    n_bad   = len(re.findall(r"^\[bad\]",   out, flags=re.MULTILINE))
    n_ok    = len(re.findall(r"^\[ok\]",    out, flags=re.MULTILINE))

    if rc == 0:
        # rc==0 should always mean "all fresh".  Surface the count when
        # we can parse it for context; fall back to a generic label.
        if n_ok > 0:
            return line("supply chain", OK, f"{n_ok} fresh")
        return line("supply chain", OK, "all fresh")
    if rc == 1:
        n = n_stale or "?"
        return line("supply chain", WARN, f"{n} stale")
    if rc == 2:
        n = n_bad or "?"
        return line("supply chain", BAD, f"{n} failed")
    # rc >= 3 (or anything unrecognised) → tool fault, don't pretend.
    return line("supply chain", DIM, f"verify-pins rc={rc}")


# ── Driver ──────────────────────────────────────────────────
# `disk SMART` and `storage pools` (ZFS/mdadm/btrfs) checks were
# removed — neither was actionable for this user's setup and both
# required sudo to be useful, which made them noisy in the panel.
# If you want either back, lift them from a prior git rev — the
# functions were named `check_smart` and `check_storage_pools`.
CHECKS = [
    check_failed_services,
    check_fs,
    check_psi_memory,
    check_oom,
    check_high_cpu,
    check_kernel_taint,
    check_failed_sudo,
    check_recent_sudo_invocations,
    # Drift checks clustered: same persistence-baseline pattern,
    # same "delete baseline to ack" UX.  `check_pins` is supply-chain
    # rather than runtime drift but shares the same "did something
    # change since last sweep" mental model, so it lives in the
    # cluster.
    check_port_drift,
    check_module_drift,
    check_critical_file_drift,
    check_suid_drift,
    check_pins,
    # Anomaly checks clustered: process-tree / exe-path heuristics.
    check_suspicious_paths,
    check_parent_anomaly,
    check_hidden_pids,
    check_mullvad,
    check_fwupd,
    check_ntp,
    check_dot,
    check_reboot_required,
]


def main() -> int:
    for fn in CHECKS:
        try:
            print(fn())
        except Exception as e:
            # Never break the panel because one check threw.  Print a
            # dim line so the user sees the failure in-place.
            print(line(fn.__name__.replace("check_", "")[:18],
                       DIM, f"err: {type(e).__name__}"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
