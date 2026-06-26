#!/usr/bin/env python3
"""
Security event log — the persistent, detailed companion to the conky
HEALTH panel.

The HEALTH panel (health.py) is a *live* one-line-per-check indicator: it
tells you THAT something is wrong right now, but it keeps no history and
its drift checks can't show you WHAT changed.  This module is the other
half: an append-only JSONL event log that the security checks write to on
every OK→WARN/BAD transition, capturing the *why* — which file drifted,
old→new sha, a redacted diff, which port appeared, etc.

It is used three ways:

  1. As a LIBRARY imported by health.py / netstat.py / listenports.py.
     Those call `note(check, sev, summary, detail)` and this module
     decides (via per-check de-dup state) whether the event is a new
     transition worth persisting.

  2. As the WATCHER.  `verify()` re-reads the active log and compares it
     against an integrity sidecar this module maintains.  Any change the
     legitimate append path did NOT make — an edit, a truncation, or a
     bare mtime bump (`touch`) — is surfaced AND itself logged as a
     `seclog_tamper` event carrying a unified diff of what was altered.
     health.py's `check_seclog_integrity()` renders the verdict.

  3. As a CLI VIEWER.  `python3 ~/.config/conky/seclog.py --tail` prints
     the active log path + a colourised tail; `--follow` streams it.
     The shell alias `seclog` wraps this.

──────────────────────────────────────────────────────────────────────
Two integrity tiers (see readme/security.md → "Security event log")
──────────────────────────────────────────────────────────────────────
  • Tier 1 (always-on, unprivileged): the log lives under
    ~/.local/state/dotfiles/ and is written directly by these
    user-owned processes.  Tamper-EVIDENT: the sidecar (sha256 + size +
    mtime + a shadow copy of the last-good bytes) lets the watcher prove
    the file changed out from under it and diff what changed.  It is NOT
    tamper-PROOF — a malicious process running as the same UID can edit
    the log and rewrite the sidecar to match.  That ceiling is inherent
    to the threat model and is why Tier 2 exists.

  • Tier 2 (opt-in via `local_setup.sh harden`): the log lives at
    /var/log/dotfiles/security.log, root-owned and `chattr +a`
    (append-only).  A non-root process — including one running as your
    UID — cannot edit, truncate, or backdate it; appends go through the
    root helper /usr/local/lib/dotfiles/seclog-append invoked via a
    narrow NOPASSWD sudoers rule.  The watcher additionally asserts the
    file is still root-owned and still append-only; losing either takes
    root, so it's a high-signal event.

We deliberately do NOT HMAC-chain the records: against the conceded
same-UID adversary the key is readable too, so it would add audit cost
without changing the guarantee.  The real guarantee is Tier 2's
root + append-only attribute; Tier 1 is honest tamper-evidence.
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path

# ── Tunables ─────────────────────────────────────────────────
# Small on purpose: the user asked for a tight cap so the log can never
# eat the filesystem.  256 KiB active + one 256 KiB rollover = 512 KiB
# worst case per tier.  At ~200 bytes/event that's ~1300 events live and
# ~2600 retained — plenty for a "recent bad behaviour" glance.
SECLOG_MAX_BYTES = 256 * 1024
# Hard ceiling on a single record so one giant diff can't blow the cap
# (and matches the stdin length limit enforced by the root helper).
MAX_RECORD_BYTES = 8 * 1024
# How much of a tamper diff we keep in the event detail.
MAX_DIFF_CHARS = 1500

ROOT_LOG = Path("/var/log/dotfiles/security.log")
ROOT_HELPER = Path("/usr/local/lib/dotfiles/seclog-append")


# ── Paths ────────────────────────────────────────────────────
def _state_dir() -> Path:
    """~/.local/state/dotfiles (honours XDG_STATE_HOME).  Holds the Tier-1
    log, the integrity sidecar, the shadow copy, and the lock — all
    private (dir 0700, files 0600).  Survives logout (unlike the conky
    runtime dir), so tampering done while logged out is still caught on
    the next login."""
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    d = Path(base) / "dotfiles"
    d.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    return d


def _user_log() -> Path:
    return _state_dir() / "security.log"


def _state_file() -> Path:
    return _state_dir() / ".seclog.state.json"


def _shadow_file() -> Path:
    return _state_dir() / ".seclog.shadow"


def _lock_file() -> Path:
    return _state_dir() / ".seclog.lock"


def active_log() -> tuple[Path, int]:
    """Return (path, tier).  Tier 2's root log wins only when BOTH the
    root log AND the append helper exist — so `unharden` (which removes
    the helper and leaves the old root log as a historical artifact)
    cleanly falls back to the Tier-1 user log instead of trying to append
    through a helper that's no longer there."""
    try:
        if ROOT_LOG.exists() and ROOT_HELPER.exists():
            return ROOT_LOG, 2
    except OSError:
        pass
    return _user_log(), 1


# ── Locking ──────────────────────────────────────────────────
@contextmanager
def _locked():
    """flock the sidecar critical section.  netstat.py, listenports.py and
    health.py are separate processes on different conky intervals; without
    a lock their read-modify-write of the sidecar could interleave and
    corrupt it.  Best-effort: if the lock can't be taken we proceed
    anyway rather than drop the event."""
    fd = None
    try:
        fd = os.open(str(_lock_file()), os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
    except OSError:
        fd = None
    try:
        yield
    finally:
        if fd is not None:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)


# ── Sidecar state ────────────────────────────────────────────
def _load_state() -> dict:
    try:
        return json.loads(_state_file().read_text())
    except (OSError, ValueError):
        return {}


def _save_state(st: dict) -> None:
    """Atomic write (tmp + rename) so a crash mid-write can't leave a
    half-JSON sidecar that the next run reads as 'no baseline'."""
    f = _state_file()
    tmp = f.with_suffix(".tmp")
    try:
        fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(json.dumps(st, separators=(",", ":")))
        os.replace(tmp, f)
    except OSError:
        pass


def _write_shadow(data: bytes) -> None:
    tmp = _shadow_file().with_suffix(".tmp")
    try:
        fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.replace(tmp, _shadow_file())
    except OSError:
        pass


def _refresh_integrity(st: dict, path: Path) -> int:
    """Re-snapshot the active log into the sidecar after a legitimate
    write (or to (re)establish the trusted baseline).  Returns the event
    count.  Every legit append flows through here, so any later divergence
    between the file and this snapshot is, by construction, NOT ours."""
    try:
        data = path.read_bytes()
    except OSError:
        data = b""
    try:
        mtime_ns = path.stat().st_mtime_ns
    except OSError:
        mtime_ns = 0
    st["integrity"] = {
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": len(data),
        "mtime_ns": mtime_ns,
    }
    _write_shadow(data)
    return data.count(b"\n")


# ── Append path ──────────────────────────────────────────────
def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _tier1_write(path: Path, line: str) -> None:
    """Append one record line to the user-owned log, rotating first if the
    cap would be exceeded.  Rotation is a *legitimate* write, so the
    caller refreshes the sidecar immediately after — otherwise rotation
    would self-trigger a tamper alert."""
    line_b = line.encode("utf-8", "replace")
    try:
        size = path.stat().st_size if path.exists() else 0
    except OSError:
        size = 0
    if size + len(line_b) > SECLOG_MAX_BYTES and size > 0:
        rotated = path.with_name(path.name + ".1")
        try:
            os.replace(path, rotated)      # security.log → security.log.1
            os.chmod(rotated, 0o600)
        except OSError:
            pass
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, line_b)
    finally:
        os.close(fd)


def _tier2_append(line: str) -> bool:
    """Hand one record line to the root append helper via NOPASSWD sudo.
    Returns True on success.  The helper enforces the same size cap +
    rotation and is the ONLY writer of the +a root log."""
    try:
        r = subprocess.run(
            ["sudo", "-n", str(ROOT_HELPER)],
            input=line, text=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=4,
        )
        return r.returncode == 0
    except Exception:
        return False


def _emit_line(st: dict, path: Path, tier: int, record: dict) -> None:
    """Serialize + write one record, assigning the next sequence number.
    Does NOT refresh integrity — the caller does that once after all of
    its writes.  Must be called under the lock."""
    record.setdefault("ts", _now_iso())
    record["seq"] = int(st.get("seq", 0)) + 1
    st["seq"] = record["seq"]
    line = json.dumps(record, separators=(",", ":"))
    if len(line) > MAX_RECORD_BYTES:
        line = line[:MAX_RECORD_BYTES]
    line += "\n"
    if tier == 2:
        if not _tier2_append(line):
            # Hardened but the helper failed (sudo cache lapsed, helper
            # removed).  Don't lose the alert silently — make it visible in
            # conky's stderr log (the live check line still goes red too).
            sys.stderr.write("seclog: tier-2 append failed\n")
    else:
        _tier1_write(path, line)


def _detect(st: dict, path: Path, tier: int) -> list[dict]:
    """Compare the live log against the integrity baseline and return any
    tamper records (NOT yet written).  Pure read — the caller writes the
    returned records and re-baselines.  Must be called under the lock.

    This is the single point of tamper detection, shared by BOTH append()
    and verify(): every code path that is about to (re)baseline the file
    first runs this, so a tamper can never be silently absorbed by a
    later legitimate append — whichever process appends next catches it.
    """
    base = st.get("integrity")
    if not base:
        return []
    try:
        live = path.read_bytes()
    except OSError:
        return []
    recs: list[dict] = []

    # Tier-2 structural assertions: losing root ownership or the
    # append-only attribute takes root → high signal.
    if tier == 2:
        if _owner_uid(path) != 0:
            recs.append({"sev": "bad", "check": "seclog_tamper",
                         "summary": "root log owner changed",
                         "detail": {"path": str(path), "kind": "owner"}})
        if _is_append_only(path) is False:
            recs.append({"sev": "bad", "check": "seclog_tamper",
                         "summary": "append-only attribute removed",
                         "detail": {"path": str(path), "kind": "attr"}})

    live_sha = hashlib.sha256(live).hexdigest()
    if live_sha != base.get("sha256"):
        # Content diverged from the last legitimate snapshot → external
        # edit/truncation.  Diff against the shadow copy of the last-good
        # bytes to show exactly what was altered.
        try:
            shadow = _shadow_file().read_bytes()
        except OSError:
            shadow = b""
        diff_text, added, removed = _unified_diff(shadow, live)
        recs.append({"sev": "bad", "check": "seclog_tamper",
                     "summary": f"log edited: +{added} -{removed} lines",
                     "detail": {"path": str(path), "kind": "content",
                                "added": added, "removed": removed,
                                "diff": diff_text}})
    else:
        try:
            live_mtime = path.stat().st_mtime_ns
        except OSError:
            live_mtime = base.get("mtime_ns")
        if live_mtime != base.get("mtime_ns"):
            # Content identical but timestamp moved — someone touched/
            # utime'd it.  The mtime must move ONLY when the writer writes.
            recs.append({"sev": "warn", "check": "seclog_tamper",
                         "summary": "log mtime changed without a write",
                         "detail": {"path": str(path), "kind": "mtime"}})
    return recs


def append(record: dict) -> None:
    """Persist one event.  Best-effort and exception-safe — a logging
    failure must never break the calling health check.

    Before writing, detect (and log) any tampering that happened since our
    last write, so this append can't absorb it."""
    try:
        with _locked():
            st = _load_state()
            path, tier = active_log()
            for t in _detect(st, path, tier):
                _emit_line(st, path, tier, t)
            _emit_line(st, path, tier, record)
            _refresh_integrity(st, path)
            _save_state(st)
    except Exception:
        pass


def _detail_hash(summary: str, detail: object) -> str:
    h = hashlib.sha1()
    h.update(summary.encode("utf-8", "replace"))
    if detail is not None:
        h.update(json.dumps(detail, sort_keys=True, default=str).encode("utf-8", "replace"))
    return h.hexdigest()[:16]


def note(check: str, sev: str, summary: str, detail: object = None) -> None:
    """Called by a security check every cycle with its current verdict.

    We log only TRANSITIONS, not every 30 s cycle, so a persistent BAD
    state writes one event, not 2880/day:
      • WARN/BAD whose (severity, detail) differs from last time → logged.
      • WARN/BAD → OK → logged once as an `info` "resolved" event so the
        log shows the condition cleared (and when).
      • OK → OK and unchanged WARN/BAD → nothing.
    """
    try:
        sev = sev.lower()
        with _locked():
            st = _load_state()
            last = st.setdefault("last", {})
            h = _detail_hash(summary, detail)
            prev = last.get(check)
            changed = (prev is None or prev.get("sev") != sev or prev.get("h") != h)
            last[check] = {"sev": sev, "h": h}
            _save_state(st)
        if not changed:
            return
        if sev in ("warn", "bad"):
            append({"sev": sev, "check": check, "summary": summary,
                    "detail": detail} if detail is not None
                   else {"sev": sev, "check": check, "summary": summary})
        elif sev == "ok" and prev and prev.get("sev") in ("warn", "bad"):
            append({"sev": "info", "check": check,
                    "summary": f"resolved: {summary}"})
    except Exception:
        pass


# ── Watcher / integrity verification ─────────────────────────
def _owner_uid(path: Path) -> int:
    try:
        return path.stat().st_uid
    except OSError:
        return -1


def _is_append_only(path: Path) -> bool | None:
    """True/False if we can read the attribute, None if we can't tell.
    None means 'don't assert' — better than a false BAD on a filesystem
    that doesn't support lsattr."""
    try:
        out = subprocess.run(["lsattr", "-d", str(path)],
                             capture_output=True, text=True, timeout=2)
        if out.returncode != 0:
            return None
        flags = out.stdout.split()[0] if out.stdout.split() else ""
        return "a" in flags
    except Exception:
        return None


def _unified_diff(old: bytes, new: bytes) -> tuple[str, int, int]:
    import difflib
    old_lines = old.decode("utf-8", "replace").splitlines()
    new_lines = new.decode("utf-8", "replace").splitlines()
    added = removed = 0
    out_lines: list[str] = []
    for ln in difflib.unified_diff(old_lines, new_lines, lineterm="", n=1):
        if ln.startswith("+++") or ln.startswith("---") or ln.startswith("@@"):
            continue
        if ln.startswith("+"):
            added += 1
        elif ln.startswith("-"):
            removed += 1
        out_lines.append(ln)
    diff_text = "\n".join(out_lines)
    if len(diff_text) > MAX_DIFF_CHARS:
        diff_text = diff_text[:MAX_DIFF_CHARS] + "\n…(diff truncated)"
    return diff_text, added, removed


def verify() -> tuple[str, str]:
    """Compare the active log to the integrity sidecar and return
    (level, detail) for the conky row, where level ∈
    {"ok","warn","bad","dim"}.

    On detected tampering this writes the `seclog_tamper` event(s) — each
    carrying a diff / kind of what changed — and re-baselines so it
    doesn't re-alert forever on the same edit.  (If a concurrent appender
    already caught the same tamper, it's recorded in the log either way;
    this row may then read green while `seclog` shows the event.)
    """
    try:
        with _locked():
            path, tier = active_log()
            if not path.exists():
                return ("dim", "no log yet")
            try:
                live = path.read_bytes()
            except OSError:
                return ("dim", "log unreadable")
            n_events = live.count(b"\n")

            st = _load_state()
            if not st.get("integrity"):
                # First sight of this log → trust current content as the
                # baseline.  We can't retroactively prove the past; Tier-2
                # +a covers the offline/no-watcher window.
                _refresh_integrity(st, path)
                _save_state(st)
                return ("dim", f"baseline ({n_events})")

            tampers = _detect(st, path, tier)
            if tampers:
                for t in tampers:
                    _emit_line(st, path, tier, t)
                _refresh_integrity(st, path)
                _save_state(st)
                # Worst-first summary for the row.
                kinds = {t["detail"]["kind"] for t in tampers}
                if "content" in kinds:
                    t = next(t for t in tampers if t["detail"]["kind"] == "content")
                    return ("bad", f"TAMPERED +{t['detail']['added']} "
                                   f"-{t['detail']['removed']}")
                if "owner" in kinds:
                    return ("bad", "root log owner changed")
                if "attr" in kinds:
                    return ("bad", "append-only removed")
                return ("warn", "mtime touched")

            # Clean.
            if tier == 2:
                return ("ok", f"guarded+a ({n_events})")
            return ("ok", f"guarded ({n_events})")
    except Exception as e:
        return ("dim", f"verify err: {type(e).__name__}")


# ── Clear / acknowledge ──────────────────────────────────────
# The drift checks (critical-files / SUID / kernel-modules / listening
# ports) alert by comparing live state to a baseline file in
# ~/.config/conky/.  "Clearing" such an alert = accepting the current
# state as the new baseline: delete the file and the next health cycle
# rebuilds it silently (the check then renders green, and its OK→BAD
# transition logic auto-emits a "resolved" event so the ack is recorded).
#
# We deliberately do NOT delete the event log — that's the audit trail,
# the whole point of seclog.  `seclog --clear` acks the live PANEL; the
# history stays viewable with `seclog`.
_CONKY_DIR = Path.home() / ".config" / "conky"
_BASELINES = {
    "critfile": "baseline-critical-files.txt",
    "suid":     "baseline-suid.txt",
    "ports":    "baseline-ports.txt",
    "modules":  "baseline-modules.txt",
}


def clear(names: list[str] | None = None) -> dict:
    """Re-baseline the selected drift checks (default: all).  Returns a
    summary dict.  Logs a `user_ack` event recording exactly what was
    accepted, so 'I cleared this' is itself in the security log."""
    if not names or "all" in names:
        targets = list(_BASELINES)
    else:
        targets = [n for n in names if n in _BASELINES]
    removed: list[str] = []
    unknown = [n for n in (names or []) if n not in _BASELINES and n != "all"]
    for t in targets:
        f = _CONKY_DIR / _BASELINES[t]
        try:
            if f.exists():
                f.unlink()
                removed.append(t)
        except OSError:
            pass
    append({"sev": "info", "check": "user_ack",
            "summary": f"alerts cleared by user: "
                       f"{', '.join(removed) if removed else 'none (already clean)'}",
            "detail": {"cleared": removed}})
    return {"removed": removed, "targets": targets, "unknown": unknown}


# ── CLI viewer ───────────────────────────────────────────────
_C = {
    "bad": "\033[91m", "warn": "\033[93m", "ok": "\033[92m",
    "info": "\033[96m", "dim": "\033[90m", "rst": "\033[0m",
    "bold": "\033[1m",
}


def _supports_color() -> bool:
    return sys.stdout.isatty()


def _fmt_event(raw: str, color: bool) -> str:
    """One line per event — a simple, lightly-coloured display of the log
    line, NOT a reformat.  Fields are colourised (dim timestamp, coloured
    severity, bold check) and the full detail is appended compactly on the
    SAME line, so nothing is hidden and nothing is exploded into tabbed
    blocks.  Use `seclog-raw` for the untouched JSON, `--all` for history.
    """
    try:
        ev = json.loads(raw)
    except ValueError:
        return raw.rstrip("\n")
    c = _C if color else {k: "" for k in _C}
    sev = ev.get("sev", "info")
    col = c.get(sev, c["info"])
    detail = ev.get("detail")
    detail_str = ""
    if detail is not None:
        # Compact, single-line; diffs keep their \n escaped so the row
        # stays one line.
        detail_str = (f"  {c['dim']}"
                      f"{json.dumps(detail, separators=(',', ':'))}{c['rst']}")
    return (f"{c['dim']}{ev.get('ts','?')}{c['rst']} "
            f"{col}{sev.upper():<4}{c['rst']} "
            f"{c['bold']}{ev.get('check','?')}{c['rst']} "
            f"{ev.get('summary','')}{detail_str}")


def _cli_tail(n: int, follow: bool) -> int:
    path, tier = active_log()
    color = _supports_color()
    c = _C if color else {k: "" for k in _C}
    if not path.exists():
        print(f"{c['dim']}No security log yet at {path}{c['rst']}")
        print(f"{c['dim']}(it is created the first time a security check "
              f"transitions to WARN/BAD){c['rst']}")
        return 0

    try:
        size = path.stat().st_size
    except OSError:
        size = 0
    rotated = path.with_name(path.name + ".1")
    print(f"{c['bold']}Security event log{c['rst']}  "
          f"{c['dim']}(tier {tier}: "
          f"{'root, append-only' if tier == 2 else 'user, tamper-evident'}){c['rst']}")
    print(f"  active : {path}  {c['dim']}({size} bytes){c['rst']}")
    if rotated.exists():
        print(f"  rolled : {rotated}")
    print(f"  cap    : {SECLOG_MAX_BYTES // 1024} KiB"
          f"{' + 1 rollover' if rotated.exists() else ''}")
    print(c["dim"] + "─" * 60 + c["rst"])

    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError as e:
        print(f"{c['bad']}cannot read log: {e}{c['rst']}")
        return 1
    # --all (n is None): include the rollover too and show everything.
    if n is None:
        if rotated.exists():
            try:
                lines = rotated.read_text(errors="replace").splitlines() + lines
            except OSError:
                pass
        shown = lines
    else:
        shown = lines[-n:]
    for ln in shown:
        if ln.strip():
            print(_fmt_event(ln, color))

    if not follow:
        return 0
    # Simple poll-based follow (no inotify dep).
    try:
        pos = path.stat().st_size
        while True:
            time.sleep(1.0)
            try:
                cur = path.stat().st_size
            except OSError:
                continue
            if cur < pos:          # rotated/truncated → restart
                pos = 0
            if cur > pos:
                with open(path, "r", errors="replace") as fh:
                    fh.seek(pos)
                    chunk = fh.read()
                    pos = fh.tell()
                for ln in chunk.splitlines():
                    if ln.strip():
                        print(_fmt_event(ln, color))
    except KeyboardInterrupt:
        return 0


def _cli_clear(names: list[str]) -> int:
    color = _supports_color()
    c = _C if color else {k: "" for k in _C}
    res = clear(names or None)
    if res["unknown"]:
        print(f"{c['warn']}unknown target(s) ignored: "
              f"{', '.join(res['unknown'])}{c['rst']}")
        print(f"{c['dim']}valid: {', '.join(_BASELINES)} (or 'all'){c['rst']}")
    if res["removed"]:
        print(f"{c['ok']}cleared (re-baselined):{c['rst']} "
              f"{', '.join(res['removed'])}")
        print(f"{c['dim']}the next conky cycle rebuilds the baseline(s) and "
              f"the row(s) go green;{c['rst']}")
        print(f"{c['dim']}note: SUID re-baseline triggers a one-time full "
              f"rootfs scan (~30-60 s).{c['rst']}")
    else:
        print(f"{c['dim']}nothing to clear — no matching baseline files "
              f"present (already clean).{c['rst']}")
    print(f"{c['dim']}an ack event was written to the log "
          f"(view with `seclog`).{c['rst']}")
    return 0


def _cli_raw() -> int:
    """Dump the active log (and its rollover) verbatim — exactly what
    `cat` would show, no formatting.  For piping into jq / grep."""
    path, _tier = active_log()
    rotated = path.with_name(path.name + ".1")
    rc = 0
    for p in (rotated, path):           # oldest first
        if p.exists():
            try:
                sys.stdout.write(p.read_text(errors="replace"))
            except OSError as e:
                sys.stderr.write(f"cannot read {p}: {e}\n")
                rc = 1
    return rc


def main(argv: list[str]) -> int:
    n = 20
    follow = False
    args = argv[1:]

    # --clear / --ack [targets…] : re-baseline drift alerts (panel ack).
    if args and args[0] in ("--clear", "--ack"):
        return _cli_clear(args[1:])
    # --raw / --cat : verbatim dump (machine-readable / pipe to jq).
    if args and args[0] in ("--raw", "--cat"):
        return _cli_raw()

    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-f", "--follow"):
            follow = True
        elif a in ("-a", "--all"):
            n = None                    # show every event, formatted
        elif a in ("-n", "--lines") and i + 1 < len(args):
            try:
                n = int(args[i + 1])
            except ValueError:
                pass
            i += 1
        elif a == "--tail":
            pass
        elif a in ("-h", "--help"):
            print("usage: seclog.py [--tail] [-n N | -a/--all] [-f/--follow]")
            print("       seclog.py --raw|--cat   verbatim dump (pipe to jq/grep)")
            print("       seclog.py --clear [critfile|suid|ports|modules|all]")
            print("              re-baseline drift alerts so conky goes green "
                  "(default: all)")
            return 0
        i += 1
    return _cli_tail(n, follow)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
