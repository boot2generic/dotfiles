#!/usr/bin/env python3
"""
Conky GPU section — nvidia-smi formatter.

Replaces the inline `${execpi 5 nvidia-smi … | awk '{printf "${color4}…"}'}`
block that used to live in conky.conf.  That inline pipeline had a real
bug: conky's execpi pre-parses `${…}` substitutions in the command
BEFORE handing to /bin/sh, which combined with awk's `$1`/`$2`
positional vars produced ~one "sh: Syntax error: Unterminated quoted
string" per render cycle — visible in conky's stderr but not on the
panel.  Worse, `${if_existing /proc/driver/nvidia/version}` only gates
DISPLAY of the resulting text, it does NOT prevent the execpi from
spawning the shell, so the bug fired even on machines (like the T14)
that have no nvidia hardware at all.

This script:
  • Returns nothing (and exits 0) if /proc/driver/nvidia/version is
    missing — replaces the old `if_existing` gate cleanly.
  • Otherwise runs nvidia-smi and emits conky-template-coloured lines
    in the same layout as the old inline awk pipeline.

Output format matches the old layout char-for-char so no panel-width
adjustments are needed in conky.conf.
"""
from __future__ import annotations
import subprocess, sys
from pathlib import Path

# Conky template colour aliases — match conky.conf's color0..color6.
C_LABEL = "${color4}"
C_VAL   = "${color}"


def _fmt(value: str, unit: str) -> str:
    """Render a numeric metric + unit, but skip the unit when the value
    is `[N/A]` (nvidia-smi's sentinel for "this GPU doesn't expose
    that field" — common for `power.draw` on laptops, Quadros, and some
    Tesla cards).  Renders `[N/A]°C` → just `[N/A]`, no orphan unit."""
    return value if value == "[N/A]" else f"{value}{unit}"


def _query_nvidia_smi() -> str:
    """Returns nvidia-smi CSV output, or "" on any failure (no nvidia,
    nvidia-smi not on PATH, driver mismatch, query timeout)."""
    if not Path("/proc/driver/nvidia/version").exists():
        return ""
    query = (
        "name,utilization.gpu,utilization.memory,"
        "memory.used,memory.total,temperature.gpu,power.draw"
    )
    try:
        return subprocess.check_output(
            ["nvidia-smi", f"--query-gpu={query}",
             "--format=csv,noheader,nounits"],
            stderr=subprocess.DEVNULL, text=True, timeout=3,
        ).strip()
    except (subprocess.SubprocessError, FileNotFoundError):
        # nvidia driver present but nvidia-smi failed (rare — driver
        # /utility version skew, container with /proc/driver/nvidia
        # bind-mounted but not nvidia-smi).  Stay silent rather than
        # panic the panel.
        return ""


def render(raw: str) -> list[str]:
    """Parse nvidia-smi CSV `raw` into conky-formatted lines.  Returned
    list is empty when input is empty.  Pulled out as a pure function
    so the parsing logic is unit-testable (caller injects raw output
    rather than us shelling out to nvidia-smi)."""
    lines: list[str] = []
    # `nvidia-smi` returns one CSV row per GPU.  Most users have one
    # card; the loop handles multi-GPU rigs (the desktop's 3080 Ti is
    # single-GPU but the code stays correct if the user adds a second
    # card later).
    #
    # Parse from the RIGHT: the last 6 fields are always the numeric
    # metrics (util_gpu, util_mem, mem_used, mem_total, temp, power),
    # so everything BEFORE that is the GPU name.  This way a name
    # containing a comma (theoretical today but possible on future
    # devices or in localised firmware strings) doesn't silently
    # truncate or skip the row — we rejoin the name parts.
    for row in raw.splitlines():
        parts = [f.strip() for f in row.split(",")]
        if len(parts) < 7:
            continue
        util_gpu, util_mem, mem_used, mem_total, temp, power = parts[-6:]
        name = ",".join(parts[:-6]).strip() or "?"
        # Layout (verbatim from the old inline awk):
        #   GPU    <name>
        #   Load   <gpu%> util  <mem%> mem
        #   VRAM   <used>/<total> MB
        #   Temp   <temp>°C  <power>W
        lines.append(f"{C_LABEL}{'GPU':<7}{C_VAL}{name}")
        lines.append(f"{C_LABEL}{'Load':<7}{C_VAL}{_fmt(util_gpu, '%')} util  {_fmt(util_mem, '%')} mem")
        lines.append(f"{C_LABEL}{'VRAM':<7}{C_VAL}{mem_used}/{mem_total} MB")
        lines.append(f"{C_LABEL}{'Temp':<7}{C_VAL}{_fmt(temp, '°C')}  {_fmt(power, 'W')}")
    return lines


def main() -> int:
    raw = _query_nvidia_smi()
    if not raw:
        return 0
    for ln in render(raw):
        print(ln)
    return 0


if __name__ == "__main__":
    # Guard against module-level sys.exit() poisoning — importing this
    # module from a test or another script previously killed the
    # interpreter via the module-top sys.exit(0).  All side-effecting
    # work now lives in main(), reachable only via direct invocation
    # (or `python -m`).
    raise SystemExit(main())
