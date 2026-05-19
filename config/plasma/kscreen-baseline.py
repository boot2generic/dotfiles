#!/usr/bin/env python3
# config/plasma/kscreen-baseline.py
#
# Per-monitor display baseline driver for Plasma 6 / Wayland.
#
# WHY a separate script and not inline kscreen-doctor calls in
# apply-theme.sh:
#   • apply-theme.sh's existing scale-enforcement loop is one knob
#     (scale=N) applied uniformly to every output — fine because the
#     user wants 100% scale everywhere on every machine.
#   • Refresh-rate / VRR / HDR are NOT uniform.  The desktop wants
#     monitor #1 at 240 Hz and #2/#3 at 144 Hz; HDR is opt-in per
#     monitor.  Hard-coding monitor names into the repo would be wrong
#     on the T14 (different connector names: eDP-1 vs DP-1/2/3 on the
#     desktop) and would break for anyone else who forked this repo.
#   • Therefore the baseline is per-machine state.  Two-phase usage:
#       1. User configures monitors once via System Settings → Display
#          (or accepts whatever Plasma defaults to on first plug-in).
#       2. `kscreen-baseline.py --snapshot` captures that to
#          ~/.config/dotfiles/kscreen-baseline.json.
#       3. apply-theme.sh runs `kscreen-baseline.py apply` on every
#          login / re-run; it re-applies the captured mode + vrr + hdr
#          on every output that's currently connected.  Missing
#          outputs (laptop undocked, monitor unplugged) are skipped
#          with a warning — never an abort.
#
# WHY the baseline JSON is NOT in the repo:
#   It contains a machine-id and host-specific connector names that
#   change between machines.  The repo deploys this SCRIPT; users
#   generate their own baseline file the first time they run
#   `--snapshot`.
#
# WHY Python and not bash:
#   • `jq` isn't always in the install set, and apply-theme.sh already
#     carries a sed-based fallback for that reason.  The baseline file
#     is JSON; doing schema-aware reads/writes in bash + sed is
#     painful.  python3 is universally present.
#   • Matches the precedent set by config/plasma/kga_push.py.
#
# kscreen-doctor syntax used (verified against /usr/bin/kscreen-doctor
# on Debian 13 / Plasma 6 — strings on the binary confirms the option
# names):
#   output.<NAME>.mode.<WxH@RR>
#   output.<NAME>.vrrpolicy.<never|automatic|always>
#   output.<NAME>.hdr.<enable|disable>
#   output.<NAME>.scale.<FACTOR>
#   output.<NAME>.enable / .disable
# All are atomic in one invocation; we batch per-output for a single
# kscreen-doctor call per output (cheaper and avoids racy partial
# applies).
#
# Capability detection (D7 HDR): the JSON output of `kscreen-doctor
# -j` on Plasma 6.2.x does NOT include explicit `vrrCapable` /
# `hdrCapable` fields on outputs that lack the feature — they only
# appear when the capability is supported (verified on T14: the eDP-1
# entry has no hdr/vrr keys at all).  The TEXT output of
# `kscreen-doctor -o`, however, prints lines like
#   "Vrr: incapable"   /   "HDR: incapable"
# vs.
#   "Vrr: Automatic"   /   "HDR: Disabled"
# for capable hardware.  So we parse the text output for capability
# probing.  If detection fails we still try the command and let
# kscreen-doctor's own error path skip it (with a warning) — never
# crash apply-theme.sh.

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME",
                                 Path.home() / ".config")) / "dotfiles"
BASELINE_PATH = CONFIG_DIR / "kscreen-baseline.json"

# ANSI colour escape stripper — kscreen-doctor -o emits colour even on
# a pipe, exactly as apply-theme.sh notes around line 96.
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def _log(msg: str) -> None:
    """Match apply-theme.sh's [ok]/[!]/[*] style for grep-ability."""
    print(msg, flush=True)


def _ok(msg: str) -> None:  _log(f"[ok] {msg}")
def _warn(msg: str) -> None: _log(f"[!]  {msg}")
def _info(msg: str) -> None: _log(f"[*]  {msg}")


# ─── kscreen-doctor interaction ────────────────────────────────────

def _have_kscreen_doctor() -> bool:
    return subprocess.run(["which", "kscreen-doctor"],
                          capture_output=True).returncode == 0


def _run_kscreen(args: list[str]) -> tuple[int, str, str]:
    """Run kscreen-doctor with args; return (rc, stdout, stderr).
    Never raises — caller decides how to handle failures."""
    try:
        r = subprocess.run(["kscreen-doctor", *args],
                           capture_output=True, text=True, timeout=10)
        return r.returncode, r.stdout, r.stderr
    except FileNotFoundError:
        return 127, "", "kscreen-doctor not on PATH"
    except subprocess.TimeoutExpired:
        return 124, "", "kscreen-doctor timed out (10 s)"


def _get_json() -> dict:
    rc, out, err = _run_kscreen(["-j"])
    if rc != 0:
        raise RuntimeError(f"kscreen-doctor -j failed: {err.strip()}")
    return json.loads(out)


def _get_text_outputs() -> dict[str, dict[str, str]]:
    """Parse `kscreen-doctor -o`'s human-readable per-output block.

    Returns {output_name: {field_name: value}} — field_name is the
    lowercase tag before the colon ("vrr", "hdr", "modes", …).

    Why parse text when JSON exists: the JSON output on Plasma 6.2.x
    omits fields the output lacks (no `hdrEnabled` key on an HDR-
    incapable panel).  The text output is exhaustive and prints
    "incapable" for unsupported features, which is what we need to
    decide whether to even attempt `hdr.enable`.
    """
    rc, out, err = _run_kscreen(["-o"])
    if rc != 0:
        return {}
    out = ANSI_RE.sub("", out)
    blocks: dict[str, dict[str, str]] = {}
    current: str | None = None
    for line in out.splitlines():
        m = re.match(r"^Output:\s+\d+\s+(\S+)", line)
        if m:
            current = m.group(1)
            blocks[current] = {}
            continue
        if current is None:
            continue
        # field lines are tab-indented "Key: Value"
        m = re.match(r"^\s+([A-Za-z][A-Za-z _]*?):\s*(.*)$", line)
        if m:
            key = m.group(1).strip().lower().replace(" ", "_")
            blocks[current][key] = m.group(2).strip()
    return blocks


def _capable(text_field: str | None) -> bool:
    """Heuristic: a kscreen-doctor capability field is "capable" iff
    it isn't blank, isn't "incapable", and isn't "unsupported"."""
    if not text_field:
        return False
    val = text_field.strip().lower()
    return val not in ("incapable", "unsupported", "not supported", "n/a")


# ─── Baseline I/O ──────────────────────────────────────────────────

def _machine_id() -> str:
    try:
        return Path("/etc/machine-id").read_text().strip()
    except OSError:
        return ""


def _load_baseline() -> dict | None:
    if not BASELINE_PATH.is_file():
        return None
    try:
        return json.loads(BASELINE_PATH.read_text())
    except (OSError, json.JSONDecodeError) as e:
        _warn(f"baseline file unreadable: {e}")
        return None


def _save_baseline(data: dict) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    # Pretty-print so a human can `vim` it and tweak hdr/vrr fields.
    BASELINE_PATH.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def _current_mode_name(out: dict) -> str | None:
    """Pull "WxH@RR" string for the output's currently-active mode."""
    cur = out.get("currentModeId")
    for m in out.get("modes", []):
        if m.get("id") == cur:
            return m.get("name")
    return None


def _snapshot_current() -> dict:
    """Build a baseline dict from the running session."""
    j = _get_json()
    text = _get_text_outputs()
    outputs: dict[str, dict] = {}
    for o in j.get("outputs", []):
        if not o.get("connected"):
            continue
        name = o.get("name")
        if not name:
            continue
        mode = _current_mode_name(o)
        # Pull current VRR / HDR state from the text output where
        # available — JSON often omits the fields entirely.
        t = text.get(name, {})
        vrr_state = t.get("vrr", "").lower()
        if vrr_state in ("never", "automatic", "always"):
            vrr = vrr_state
        else:
            # incapable / blank → leave the policy unset so apply()
            # doesn't try to clobber it on a non-VRR monitor.
            vrr = None
        hdr_state = t.get("hdr", "").lower()
        hdr = hdr_state == "enabled"
        outputs[name] = {
            "mode": mode,
            "scale": o.get("scale", 1),
            "vrr": vrr,
            "hdr": hdr,
            "enabled": bool(o.get("enabled", True)),
        }
    return {
        "machine_id": _machine_id(),
        "snapshot_date": _dt.datetime.now().isoformat(timespec="seconds"),
        "outputs": outputs,
    }


# ─── Commands ──────────────────────────────────────────────────────

def cmd_snapshot(_args) -> int:
    if not _have_kscreen_doctor():
        _warn("kscreen-doctor missing — cannot snapshot")
        return 2
    data = _snapshot_current()
    if not data["outputs"]:
        _warn("no connected outputs — refusing to write empty baseline")
        return 2
    _save_baseline(data)
    _ok(f"wrote baseline: {BASELINE_PATH} ({len(data['outputs'])} output(s))")
    for name, cfg in data["outputs"].items():
        _info(f"    {name}: mode={cfg['mode']} vrr={cfg['vrr']} hdr={cfg['hdr']}")
    return 0


def cmd_show(_args) -> int:
    data = _load_baseline()
    if data is None:
        _info(f"no baseline at {BASELINE_PATH}")
        return 1
    print(json.dumps(data, indent=2, sort_keys=True))
    return 0


def cmd_reset(_args) -> int:
    if BASELINE_PATH.exists():
        BASELINE_PATH.unlink()
        _ok(f"removed {BASELINE_PATH}")
    else:
        _info("no baseline file to remove")
    return 0


def cmd_apply(args) -> int:
    """Apply each output's mode/vrr/hdr from the baseline.

    Per-output failures (output not connected, kscreen-doctor reject)
    are warnings — never abort.  apply-theme.sh relies on this:
    failure here must not stop the rest of theme application.
    """
    if not _have_kscreen_doctor():
        _warn("kscreen-doctor missing — skipping baseline apply")
        return 0  # not an error from apply-theme.sh's perspective
    data = _load_baseline()
    if data is None:
        _info(f"no baseline at {BASELINE_PATH} — run with --snapshot first")
        return 0  # silent no-op on a fresh machine

    # Machine-id sanity check.  A baseline copied between machines is
    # almost certainly wrong (different connector names), so we warn
    # but still attempt — the user may have intentionally rsync'd it.
    cur_mid = _machine_id()
    base_mid = data.get("machine_id", "")
    if cur_mid and base_mid and cur_mid != base_mid:
        _warn(f"baseline machine-id mismatch (this={cur_mid[:8]}… "
              f"baseline={base_mid[:8]}…); applying anyway")

    j = _get_json()
    live = {o["name"]: o for o in j.get("outputs", []) if o.get("connected")}
    text = _get_text_outputs()

    applied = 0
    skipped_missing = 0
    for name, cfg in data.get("outputs", {}).items():
        if name not in live:
            _info(f"{name}: not connected — skipping (saved for later)")
            skipped_missing += 1
            continue

        kargs: list[str] = []
        # mode (also implicitly sets refresh).  Skip if already on
        # that mode — kscreen-doctor accepts re-setting but the no-op
        # case is cheaper and avoids transient blanks on real
        # hardware.
        cur_mode = _current_mode_name(live[name])
        want_mode = cfg.get("mode")
        if want_mode and cur_mode != want_mode:
            kargs.append(f"output.{name}.mode.{want_mode}")

        # VRR — only if monitor is capable AND baseline has a policy.
        t = text.get(name, {})
        vrr_field = t.get("vrr", "")
        want_vrr = cfg.get("vrr")
        if want_vrr in ("never", "automatic", "always"):
            if _capable(vrr_field):
                kargs.append(f"output.{name}.vrrpolicy.{want_vrr}")
            else:
                _info(f"{name}: VRR requested ({want_vrr}) but monitor is "
                      f"'{vrr_field or 'unknown'}' — skipping")

        # HDR — strictly opt-in.  Only enable if baseline says true
        # AND the monitor is HDR-capable.  Otherwise explicitly
        # disable to avoid leftover state from a previous session.
        hdr_field = t.get("hdr", "")
        want_hdr = bool(cfg.get("hdr"))
        if want_hdr:
            if _capable(hdr_field):
                kargs.append(f"output.{name}.hdr.enable")
            else:
                # The graceful-degradation case from the spec: a
                # baseline copied from an HDR-capable box must NOT
                # crash on an SDR-only one.
                _warn(f"{name}: HDR requested but monitor reports "
                      f"'{hdr_field or 'unknown'}' — skipping HDR step")
        # We intentionally do NOT auto-disable HDR when want_hdr=False
        # — touching the field on an incapable monitor errors out.
        # Users can toggle off explicitly via --disable-hdr.

        if not kargs:
            if args.verbose:
                _info(f"{name}: already at baseline — no change")
            continue

        rc, _out, err = _run_kscreen(kargs)
        if rc == 0:
            _ok(f"{name}: " + " ".join(kargs))
            applied += 1
        else:
            _warn(f"{name}: kscreen-doctor rejected {kargs}: {err.strip()}")

    # D8 (connected-output mismatch detection) is intentionally NOT
    # done here — apply-theme.sh owns that check so the
    # reconfigure-and-warn path is centralized with the rest of the
    # session-recovery logic.  This script just reports per-output
    # state; the caller counts.

    if skipped_missing and args.verbose:
        _info(f"{skipped_missing} output(s) in baseline are not "
              f"currently connected")
    return 0


def _toggle_hdr(name: str, enable: bool) -> int:
    """Shared body for --enable-hdr / --disable-hdr.

    Updates the live session AND the baseline file so the next
    `apply` re-asserts the new state.
    """
    if not _have_kscreen_doctor():
        _warn("kscreen-doctor missing")
        return 2
    # Capability probe — refuse to "enable" on an incapable panel
    # rather than letting kscreen-doctor's error surface confusingly.
    text = _get_text_outputs()
    if name not in text:
        _warn(f"output {name!r} not found (run `kscreen-doctor -o` "
              f"to list)")
        return 2
    hdr_field = text[name].get("hdr", "")
    if enable and not _capable(hdr_field):
        _warn(f"{name}: HDR field is '{hdr_field or 'unknown'}' — "
              f"this monitor does not advertise HDR")
        return 2
    verb = "enable" if enable else "disable"
    rc, _out, err = _run_kscreen([f"output.{name}.hdr.{verb}"])
    if rc != 0:
        _warn(f"kscreen-doctor failed: {err.strip()}")
        return rc
    _ok(f"{name}: HDR {verb}d")

    # Persist to baseline if one exists; otherwise just live-set.
    data = _load_baseline()
    if data is not None and name in data.get("outputs", {}):
        data["outputs"][name]["hdr"] = enable
        _save_baseline(data)
        _ok(f"baseline updated: {name}.hdr = {enable}")
    return 0


def cmd_enable_hdr(args) -> int:
    return _toggle_hdr(args.output, enable=True)


def cmd_disable_hdr(args) -> int:
    return _toggle_hdr(args.output, enable=False)


# ─── Argparse plumbing ─────────────────────────────────────────────

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="kscreen-baseline",
        description="Apply / snapshot per-monitor display baseline "
                    "(refresh, VRR, HDR).",
    )
    # The spec asks for `apply` as a positional default plus
    # --snapshot / --show / --reset flags.  Mixed-style is annoying
    # in argparse; we model the flags as mutually exclusive modes.
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("action", nargs="?", default="apply",
                      choices=["apply"],
                      help="apply baseline (default)")
    mode.add_argument("--snapshot", action="store_true",
                      help="snapshot current display state to "
                           f"{BASELINE_PATH}")
    mode.add_argument("--show", action="store_true",
                      help="print current baseline JSON")
    mode.add_argument("--reset", action="store_true",
                      help="delete baseline file")
    mode.add_argument("--enable-hdr", metavar="OUTPUT",
                      dest="enable_hdr",
                      help="enable HDR on OUTPUT and persist to baseline")
    mode.add_argument("--disable-hdr", metavar="OUTPUT",
                      dest="disable_hdr",
                      help="disable HDR on OUTPUT and persist to baseline")
    p.add_argument("-v", "--verbose", action="store_true")
    return p


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    if args.snapshot:
        return cmd_snapshot(args)
    if args.show:
        return cmd_show(args)
    if args.reset:
        return cmd_reset(args)
    if args.enable_hdr:
        args.output = args.enable_hdr
        return cmd_enable_hdr(args)
    if args.disable_hdr:
        args.output = args.disable_hdr
        return cmd_disable_hdr(args)
    return cmd_apply(args)


if __name__ == "__main__":
    sys.exit(main())
