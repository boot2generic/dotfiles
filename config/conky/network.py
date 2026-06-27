#!/usr/bin/env python3
"""
Conky network section — auto-detects default-route interface(s) and
prints addr + live tx/rx rates.

Why a script (and not conky's `${upspeed eth0}` etc.): conky resolves
those variable names at config-load time, so an `if_existing` guard
chain only fires for hardcoded interface names.  Modern Linux uses
systemd-predictable names (enp4s0, wlp3s0, …) that vary per machine,
which broke the hardcoded list.  This script reads
  /sys/class/net/<iface>/statistics/{rx,tx}_bytes
directly, caches between conky ticks, and prints conky template
strings for whichever iface is actually the default route.

Output format (one block per active interface):
    enp4s0  192.0.2.42                         # docs use TEST-NET-1
      ▲ 12.3 KB/s   ▼ 4.7 MB/s

State: $XDG_RUNTIME_DIR/conky/network-bw (JSON).  Falls back to
/run/user/<uid>/conky/network-bw or /tmp.
"""
from __future__ import annotations
import json, os, re, subprocess, time
from pathlib import Path

CACHE_DIR_CANDIDATES = [
    Path(os.environ.get("XDG_RUNTIME_DIR", "")) / "conky"
        if os.environ.get("XDG_RUNTIME_DIR") else None,
    Path(f"/run/user/{os.getuid()}/conky"),
    Path("/tmp") / f"conky-{os.getuid()}",
]
CACHE_FILE = next(p for p in CACHE_DIR_CANDIDATES if p)
CACHE_FILE.mkdir(parents=True, exist_ok=True, mode=0o700)
CACHE_FILE = CACHE_FILE / "network-bw.json"

# Conky template colours (the conky.conf colorN aliases — keep in sync)
# NB: up/down use green/magenta as DIRECTION hues (a throughput readout),
# deliberately NOT the panel's green=ok / red=bad SEVERITY paradigm — these
# numbers are informational, never an alert.  Security signals (beacons,
# rogue listeners) live in the CONNECTIONS/PORTS sections and use the
# severity palette there.
C_LABEL = "${color4}"
C_VAL   = "${color}"
C_UP    = "${color2}"   # green  — bytes sent
C_DOWN  = "${color1}"   # magenta — bytes received


def _run(cmd: list[str], timeout: int = 2) -> str:
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL,
                                       text=True, timeout=timeout)
    except Exception:
        return ""


def default_ifaces() -> list[str]:
    """All ifaces that have a default route (v4 and v6 both included).

    A laptop with both wifi and a tether may legitimately have two;
    we'll print one block per.  Order: v4 default first, then v6.
    """
    seen: list[str] = []
    for fam in ("-4", "-6"):
        out = _run(["ip", "-o", fam, "route", "show", "default"])
        for ln in out.splitlines():
            m = re.search(r"\bdev\s+(\S+)", ln)
            if m and m.group(1) not in seen:
                seen.append(m.group(1))
    return seen


def iface_addr(iface: str) -> str:
    """Primary IPv4 of <iface>, or '' if none."""
    out = _run(["ip", "-o", "-4", "addr", "show", "dev", iface])
    m = re.search(r"\binet\s+([0-9.]+)/", out)
    return m.group(1) if m else ""


def read_counters(iface: str) -> tuple[int, int]:
    """Return (rx_bytes, tx_bytes) for iface, or (0, 0) on error."""
    base = Path(f"/sys/class/net/{iface}/statistics")
    try:
        rx = int((base / "rx_bytes").read_text().strip())
        tx = int((base / "tx_bytes").read_text().strip())
    except (OSError, ValueError):
        return 0, 0
    return rx, tx


def humanise(bps: float) -> str:
    """Human-readable bytes/sec — matches conky's own format roughly."""
    for unit in ("B", "KiB", "MiB", "GiB"):
        if bps < 1024 or unit == "GiB":
            return f"{bps:6.1f} {unit}/s"
        bps /= 1024
    return f"{bps:.1f} TiB/s"


def main() -> int:
    ifaces = default_ifaces()
    if not ifaces:
        print(f"{C_LABEL}(no default route){C_VAL}")
        return 0

    # Load previous counters.
    prev: dict[str, dict] = {}
    if CACHE_FILE.exists():
        try:
            prev = json.loads(CACHE_FILE.read_text())
        except (OSError, ValueError):
            prev = {}

    now = time.monotonic()
    new: dict[str, dict] = {}

    for iface in ifaces:
        rx, tx = read_counters(iface)
        addr = iface_addr(iface)

        # Compute rates if we have a previous sample for this iface.
        prev_iface = prev.get(iface) or {}
        dt = now - prev_iface.get("t", 0)
        if dt > 0 and dt < 60 and "rx" in prev_iface:
            rx_rate = max(0, (rx - prev_iface["rx"]) / dt)
            tx_rate = max(0, (tx - prev_iface["tx"]) / dt)
        else:
            rx_rate = 0.0
            tx_rate = 0.0

        new[iface] = {"t": now, "rx": rx, "tx": tx}

        # Render block.
        addr_str = addr if addr else "(no IPv4)"
        print(f"{C_LABEL}{iface:<7}{C_VAL}{addr_str}")
        print(f"{C_LABEL}  ▲ {C_UP}{humanise(tx_rate)}"
              f"  {C_LABEL}▼ {C_DOWN}{humanise(rx_rate)}{C_VAL}")

    # Persist updated counters for next tick.
    try:
        CACHE_FILE.write_text(json.dumps(new))
        os.chmod(CACHE_FILE, 0o600)
    except OSError:
        pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
