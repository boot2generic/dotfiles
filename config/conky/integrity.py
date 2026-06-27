#!/usr/bin/env python3
"""
File-integrity sentinels.

Maintains a small set of "sentinel" files that no legitimate application
should ever read or modify.  Any access is a high-signal compromise
indicator (something enumerating $HOME for credentials).  When one is
touched the conky `file integrity` row goes red AND a security-log event
is written *including the process responsible* where it can be
determined.

NAMING (deliberate): every on-system identifier — filenames, aliases,
the conky label, the audit key, security-log entries, and these files'
own contents — reads as ordinary file-integrity monitoring.  Someone
enumerating the host (grep, listing ~/.config, reading ~/.zshrc,
`cat`-ing a file) sees a routine integrity control plus realistic-looking
credentials, with no indication of the true purpose.  The repo README
explains the intent for the operator; the on-system surface gives nothing
away.

──────────────────────────────────────────────────────────────────────
Detection (always-on, unprivileged — run from health.py every cycle)
──────────────────────────────────────────────────────────────────────
  • MODIFY  — sha256 of the contents changed.  Always reliable.
  • DELETE  — the file vanished.
  • READ    — detected via an atime trick: each cycle we park the file's
              access-time at the epoch, so on a normal `relatime` mount
              the next read bumps atime and we catch it (we read our own
              copy for hashing with O_NOATIME so we never trip ourselves).
              On `noatime`, or for a reader that also uses O_NOATIME, pure
              reads can't be seen this way — that's what the hardened
              audit watch is for.

Process attribution (the "who touched it" the operator asked for):
  • Best-effort, any mode: scan /proc/*/fd for a process holding the file
    open at detection time (catches editors / long readers / a backup
    pass / an mmap, but a one-shot `cat` is usually gone by the poll).
  • Authoritative, hardened: the audit watch (key below) records every
    access with comm/exe/pid/uid; on a trip we query it (sudo -n
    ausearch, allow-listed) and embed the most recent actor in the event.

State (all names bland, blends with the other baseline-*.txt):
  ~/.config/conky/.integrity-paths        — one sentinel path per line
  ~/.config/conky/baseline-integrity.txt  — path<TAB>sha256
  ~/.config/conky/.integrity-id           — unique token embedded in the
                                            sentinels (grep logs/captures
                                            for it to spot exfiltration)

CLI:
  python3 integrity.py            ensure sentinels exist + scan + print
  python3 integrity.py --status   list sentinels and their state
  python3 integrity.py --reset    regenerate ALL sentinels + re-baseline
                                  (clears a tripped state — investigate
                                  FIRST; this overwrites the files)
"""
from __future__ import annotations

import base64
import hashlib
import os
import re
import subprocess
import sys
import time
from pathlib import Path

CONKY_DIR = Path.home() / ".config" / "conky"
MANIFEST = CONKY_DIR / ".integrity-paths"
BASELINE = CONKY_DIR / "baseline-integrity.txt"
TOKEN_FILE = CONKY_DIR / ".integrity-id"

# Audit key used by the hardened watch (see local_setup.sh).  Bland on
# purpose — "integrity" reads as ordinary FIM, not a trap.
AUDIT_KEY = "integrity"

# Default sentinels across classic "loot" paths.  Chosen so no tool you
# run auto-reads them: aws-cli reads `credentials` not `.bak`; ssh only
# uses keys it's configured to, not `id_rsa_old`; nothing daemon-reads a
# plain passwords.txt.  An attacker grepping/finding for secrets hits them.
DEFAULT_SENTINELS = [
    "~/.aws/credentials.bak",
    "~/.ssh/id_rsa_old",
    "~/Documents/passwords.txt",
]

SENTINEL_ATIME_NS = 0
READ_THRESHOLD = 86400          # atime > 1 day past epoch ⇒ a read happened


def _expand(p: str) -> Path:
    return Path(os.path.expanduser(p.strip()))


# ── Unique token (embedded in the sentinels; grep-able exfil tracer) ──
def _token() -> str:
    try:
        if TOKEN_FILE.exists():
            t = TOKEN_FILE.read_text().strip()
            if t:
                return t
    except OSError:
        pass
    # Looks like an ordinary 40-char secret/token, not a marker.
    t = base64.urlsafe_b64encode(os.urandom(30)).decode().rstrip("=")
    try:
        CONKY_DIR.mkdir(parents=True, exist_ok=True)
        fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(t + "\n")
    except OSError:
        pass
    return t


# ── Sentinel contents — look like REAL credentials, with no tell.  The
# unique token is embedded as a plausible secret value (so exfiltration
# can be traced), never as a comment that would betray the file. ──────
def _gen_content(path: Path, token: str) -> str:
    name = path.name.lower()
    full = str(path).lower()
    if "aws" in full or "credential" in name:
        return (
            "[default]\n"
            "aws_access_key_id = AKIAZXCV5R7Q2W8N4T1B\n"
            f"aws_secret_access_key = {token}\n"
            "region = us-east-1\n"
            "output = json\n"
        )
    if "id_rsa" in name or "id_ed" in name or "/.ssh/" in full or name.endswith(".pem"):
        body = "\n".join([
            "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAA",
            "AAtzc2gtZWQyNTUxOQAAACDeADBEEFc0FFEEdEADbeefC0FFEE1234567890aB",
            token,
            "cDeFgHiJkLmNoPqRsTuVwXyZ0123456789AAAAAGZ1bGwtZGlzay1iYWNrdXAA",
        ])
        return (
            "-----BEGIN OPENSSH PRIVATE KEY-----\n"
            f"{body}\n"
            "-----END OPENSSH PRIVATE KEY-----\n"
        )
    # Generic credential list — plausible personal notes.
    return (
        "# accounts\n"
        "email      personal       me@example.com    S3cur3-Em@il-2024!\n"
        "bank       online         examplebank       Tr0ub4dor&3-bank\n"
        f"github     token          personal         {token}\n"
        "router     admin          192.168.1.1       admin / N3tg3ar!2023\n"
    )


# ── Filesystem helpers ───────────────────────────────────────
def _hash_noatime(path: Path) -> str | None:
    """sha256 the content WITHOUT bumping atime (O_NOATIME) so our own
    integrity read never looks like an access.  Falls back to a normal
    read if O_NOATIME is unavailable (caller stats atime BEFORE this and
    re-parks atime after, so it stays correct either way)."""
    flags = os.O_RDONLY | getattr(os, "O_NOATIME", 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        try:
            fd = os.open(path, os.O_RDONLY)
        except OSError:
            return None
    h = hashlib.sha256()
    try:
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            h.update(chunk)
    except OSError:
        return None
    finally:
        os.close(fd)
    return h.hexdigest()


def _rearm(path: Path, mtime_ns: int) -> None:
    try:
        os.utime(path, ns=(SENTINEL_ATIME_NS, mtime_ns))
    except OSError:
        pass


def _create(path: Path, token: str) -> bool:
    try:
        parent = path.parent
        parent.mkdir(parents=True, exist_ok=True)
        if parent.name == ".ssh":
            try:
                os.chmod(parent, 0o700)
            except OSError:
                pass
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(_gen_content(path, token))
        st = path.stat()
        _rearm(path, st.st_mtime_ns)
        return True
    except FileExistsError:
        return False
    except OSError:
        return False


# ── Process attribution ──────────────────────────────────────
def _proc_openers(path: Path) -> list[str]:
    """Processes holding the file open RIGHT NOW (best-effort, any mode).
    A one-shot read is usually closed by poll time; this catches editors,
    `tail -f`, a backup pass mid-read, or an mmap."""
    try:
        target = os.path.realpath(path)
    except OSError:
        return []
    hits: list[str] = []
    try:
        for pid_dir in Path("/proc").iterdir():
            if not pid_dir.name.isdigit():
                continue
            fddir = pid_dir / "fd"
            try:
                for fd in fddir.iterdir():
                    try:
                        if os.path.realpath(fd) == target:
                            comm = (pid_dir / "comm").read_text().strip()
                            hits.append(f"{comm}({pid_dir.name})")
                            break
                    except OSError:
                        continue
            except OSError:
                continue
            if len(hits) >= 5:
                break
    except OSError:
        pass
    return hits


def _audit_actor(path: Path) -> str | None:
    """Authoritative attribution from the kernel audit trail (hardened).
    Returns 'comm[pid] uid=N' for the most recent access of `path` under
    the integrity watch, or None when auditd/sudo isn't available."""
    try:
        out = subprocess.run(
            ["sudo", "-n", "ausearch", "-k", AUDIT_KEY,
             "-f", str(path), "-ts", "recent", "-i"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, timeout=4,
        ).stdout
    except Exception:
        return None
    if not out:
        return None
    syscalls = [ln for ln in out.splitlines() if "type=SYSCALL" in ln]
    if not syscalls:
        return None
    last = syscalls[-1]               # ausearch prints oldest → newest
    def grab(pat: str) -> str:
        m = re.search(pat, last)
        return m.group(1) if m else ""
    comm = grab(r'\bcomm="?([^"\s]+)"?')
    pid = grab(r'\bpid=(\d+)')
    uid = grab(r'\buid=(\d+)')         # \b avoids matching auid/euid/...
    exe = grab(r'\bexe="?([^"\s]+)"?')
    if not (comm or exe):
        return None
    actor = comm or exe
    bits = actor
    if pid:
        bits += f"[{pid}]"
    if uid:
        bits += f" uid={uid}"
    return bits


def _actor(path: Path) -> dict:
    """Combined attribution for a trip event."""
    info: dict = {}
    openers = _proc_openers(path)
    if openers:
        info["open_now"] = openers
    au = _audit_actor(path)
    if au:
        info["audit"] = au
    if not info:
        info["actor"] = "unknown (enable hardening for audit attribution)"
    return info


# ── Manifest + baseline ──────────────────────────────────────
def _sentinels() -> list[Path]:
    try:
        if MANIFEST.exists():
            return [_expand(ln) for ln in MANIFEST.read_text().splitlines()
                    if ln.strip() and not ln.lstrip().startswith("#")]
    except OSError:
        pass
    try:
        CONKY_DIR.mkdir(parents=True, exist_ok=True)
        MANIFEST.write_text(
            "# Monitored file-integrity paths — one per line.\n"
            + "\n".join(DEFAULT_SENTINELS) + "\n"
        )
    except OSError:
        pass
    return [_expand(p) for p in DEFAULT_SENTINELS]


def _load_baseline() -> dict[str, str]:
    out: dict[str, str] = {}
    try:
        for ln in BASELINE.read_text().splitlines():
            parts = ln.split("\t", 1)
            if len(parts) == 2:
                out[parts[0]] = parts[1].strip()
    except OSError:
        pass
    return out


def _save_baseline(base: dict[str, str]) -> None:
    try:
        CONKY_DIR.mkdir(parents=True, exist_ok=True)
        fd = os.open(BASELINE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            for p in sorted(base):
                f.write(f"{p}\t{base[p]}\n")
    except OSError:
        pass


# ── Public API (used by health.py) ──────────────────────────
def ensure() -> None:
    """Create sentinels that have NEVER been set up + baseline them.  A
    sentinel that IS in the baseline but now MISSING was *deleted* — we
    must NOT recreate it here (that would mask the deletion); scan()
    reports it and the operator re-arms explicitly."""
    token = _token()
    base = _load_baseline()
    changed = False
    for p in _sentinels():
        sp = str(p)
        if not p.exists():
            if sp not in base:
                if _create(p, token):
                    sha = _hash_noatime(p)
                    if sha:
                        base[sp] = sha
                        changed = True
        elif sp not in base:
            sha = _hash_noatime(p)
            if sha:
                base[sp] = sha
                changed = True
    if changed:
        _save_baseline(base)


def count() -> int:
    return sum(1 for p in _sentinels() if p.exists())


def scan() -> list[dict]:
    """Check every sentinel; return trip events (empty == clean).  Each
    event: {path, kind: read|modified|deleted, [atime], + attribution}.
    Re-arms every intact sentinel as a side effect."""
    base = _load_baseline()
    events: list[dict] = []
    changed_base = False
    for p in _sentinels():
        sp = str(p)
        if not p.exists():
            if sp in base:
                ev = {"path": sp, "kind": "deleted"}
                ev.update(_actor(p))
                events.append(ev)
            continue
        try:
            st = p.stat()              # stat does NOT bump atime
        except OSError:
            continue
        atime = st.st_atime            # captured BEFORE we hash
        sha = _hash_noatime(p)
        if sha is None:
            continue
        known = base.get(sp)
        if known is None:
            base[sp] = sha
            changed_base = True
            _rearm(p, st.st_mtime_ns)
            continue
        if sha != known:
            ev = {"path": sp, "kind": "modified"}
            ev.update(_actor(p))
            events.append(ev)
        elif atime > READ_THRESHOLD:
            ev = {"path": sp, "kind": "read",
                  "atime": time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                         time.gmtime(atime))}
            ev.update(_actor(p))
            events.append(ev)
        _rearm(p, st.st_mtime_ns)
    if changed_base:
        _save_baseline(base)
    return events


def reset() -> dict:
    """Regenerate ALL sentinels to fresh content + re-baseline (clears a
    tripped state).  Overwrites — investigate before running."""
    token = _token()
    base: dict[str, str] = {}
    regenerated = []
    for p in _sentinels():
        try:
            p.parent.mkdir(parents=True, exist_ok=True)
            if p.parent.name == ".ssh":
                try:
                    os.chmod(p.parent, 0o700)
                except OSError:
                    pass
            fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                f.write(_gen_content(p, token))
            st = p.stat()
            _rearm(p, st.st_mtime_ns)
            sha = _hash_noatime(p)
            if sha:
                base[str(p)] = sha
                regenerated.append(str(p))
        except OSError:
            pass
    _save_baseline(base)
    return {"regenerated": regenerated}


# ── CLI ──────────────────────────────────────────────────────
def main(argv: list[str]) -> int:
    args = argv[1:]
    if args and args[0] == "--reset":
        res = reset()
        print(f"re-baselined {len(res['regenerated'])} monitored file(s)")
        for p in res["regenerated"]:
            print(f"  • {p}")
        return 0
    if args and args[0] == "--status":
        base = _load_baseline()
        for p in _sentinels():
            state = "missing" if not p.exists() else "armed"
            print(f"  [{state:<7}] {p}")
        return 0
    ensure()
    ev = scan()
    if not ev:
        print(f"all {count()} monitored files intact")
        return 0
    for e in ev:
        extra = e.get("audit") or (", ".join(e.get("open_now", [])) or e.get("actor", ""))
        print(f"ALERT [{e['kind']}] {e['path']}"
              + (f" @ {e.get('atime')}" if e.get("atime") else "")
              + (f"  by {extra}" if extra else ""))
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
