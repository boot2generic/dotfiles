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
  8. Pending firmware updates (LVFS)   — Lenovo/Dell/Gigabyte firmware
  9. NTP drift > 1 s                   — clock issues affect TLS, logs
 10. Pending reboot for kernel update  — `linux-image-*` upgraded but
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
    check_port_drift,
    check_mullvad,
    check_fwupd,
    check_ntp,
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
