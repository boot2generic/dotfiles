#!/usr/bin/env python3
"""apps-validate.py — schema-v2 validator for config/apps/*.toml.

Hard pre-flight for every mutating subcommand of ``apps-cli.sh`` (and
for ``install-apps.sh`` directly).  Walks every TOML file under
``config/apps/`` that contains a top-level ``[[apps]]`` array
(schema_version 2), validates each entry against the cross-field rules
documented in ``config/apps/schema.toml``, and reports ALL violations
in a single pass — no fail-fast.

Standalone by design: stdlib only, no third-party deps.  Read-only with
respect to the repository (this script never writes; ``apps-cli.sh``
delegates mutating subcommands to scripts that import ``tomlkit`` to
preserve formatting).

Exit codes:
    0   — clean run, optionally with no warnings either
    1   — one or more ERROR-level findings
    2   — clean of errors, but at least one WARNING

All human-facing output is emitted on stderr with an ``[apps-validate]``
prefix so stdout stays reserved for future structured output (e.g. JSON
machine-readable mode).  This mirrors the convention in
``scripts/install-apps.sh`` and ``scripts/verify-pins.sh``.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import tomllib
from pathlib import Path

# ── Constants ───────────────────────────────────────────────────────────
# Centralised here so future schema bumps only touch one place.

SCHEMA_VERSION_EXPECTED = 2

NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,62}[a-z0-9]$")
HEX40_RE = re.compile(r"^[0-9A-Fa-f]{40}$")
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
REPO_RE = re.compile(r"^[\w.-]+/[\w.-]+$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
VERSION_RE = re.compile(r"^\d+(\.\d+)*$")
AMO_SLUG_RE = re.compile(r"^[a-z0-9-]+$")
# Three valid GUID shapes per the design spec:
#   <slug>@<domain.tld> OR <slug>@jetpack OR {UUID} OR @<slug>
# (Mozilla-developed extensions like @testpilot-containers use the bare
# @<slug> form with nothing before the @.)
EXT_GUID_RE = re.compile(
    r"^("
    r"[\w._-]+@[\w.-]+"         # slug@domain.tld
    r"|\{[0-9a-fA-F-]{36}\}"    # {UUID-form}
    r"|[\w._-]+@jetpack"        # slug@jetpack (legacy Jetpack)
    r"|@[\w._-]+"               # @slug (Mozilla-developed, e.g. @testpilot-containers)
    r")$"
)

VALID_METHODS = {"apt", "apt-pinned-repo", "github-release", "direct-deb"}
VALID_PIN_MODES = {"track-latest", "frozen"}
VALID_MACHINES = {"common", "t14", "desktop", "i3", "plasma"}
VALID_EXT_MODES = {"force_installed", "allowed", "blocked"}

# Per-method sub-table name (in install.<sub>) keyed by install.method.
METHOD_SUBTABLE = {
    "apt": None,  # no sub-table required
    "apt-pinned-repo": "apt_pinned_repo",
    "github-release": "github_release",
    "direct-deb": "direct_deb",
}


# ── Finding dataclass via plain tuples ──────────────────────────────────
# A dataclass would work but is overkill for three fields used in one
# place; keep it light so the script stays grep-friendly.

class Finding:
    """One validation error or warning.  Severity is 'ERROR' or 'WARNING'."""

    __slots__ = ("severity", "entry_idx", "entry_name", "field", "value", "reason")

    def __init__(
        self,
        severity: str,
        entry_idx: int | None,
        entry_name: str | None,
        field: str,
        value: object,
        reason: str,
    ) -> None:
        self.severity = severity
        self.entry_idx = entry_idx
        self.entry_name = entry_name
        self.field = field
        self.value = value
        self.reason = reason


# ── Output helpers ──────────────────────────────────────────────────────

def log(msg: str) -> None:
    """Progress line on stderr, prefixed like the rest of the dotfiles toolchain."""
    print(f"[apps-validate] {msg}", file=sys.stderr)


def render_value(v: object) -> str:
    """Format a value for the 'value:' line of a finding block.

    Strings are quoted; lists/tuples become bracketed quoted lists; bools
    and ints fall through to ``repr()``.  Truncates long strings so a
    single bad entry doesn't blow up the terminal.
    """
    if isinstance(v, str):
        s = v if len(v) <= 200 else v[:197] + "..."
        return f'"{s}"'
    if isinstance(v, (list, tuple)):
        rendered = ", ".join(render_value(x) for x in v)
        return f"[{rendered}]"
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "(absent)"
    return repr(v)


def emit_finding(f: Finding) -> None:
    """Pretty-print one Finding to stderr in the spec's example format."""
    header = f.severity
    # Pad ERROR/WARNING so the columns of the field/value/reason lines
    # line up regardless of which severity emitted them.
    if header == "ERROR":
        header_str = "ERROR  "
    else:
        header_str = "WARNING"
    if f.entry_idx is not None:
        entry_str = f"entry #{f.entry_idx} '{f.entry_name or '?'}'"
    else:
        entry_str = "(file-level)"
    print("", file=sys.stderr)
    print(f"{header_str} {entry_str}", file=sys.stderr)
    print(f"       field: {f.field}", file=sys.stderr)
    # value: line is omitted only for purely structural complaints where
    # there's nothing meaningful to render (e.g. "missing required field").
    if f.value is not None or f.field.endswith(" missing"):
        print(f"       value: {render_value(f.value)}", file=sys.stderr)
    print(f"       reason: {f.reason}", file=sys.stderr)


# ── Per-entry validators ────────────────────────────────────────────────
# Each validator appends to ``findings``.  Validators do NOT short-circuit
# on the first problem — we want one validator run to surface every fix
# the user needs to make.

def _check_name(
    entry: dict,
    idx: int,
    findings: list[Finding],
) -> str | None:
    """Validate ``name``.  Returns the name if structurally usable, else None."""
    name = entry.get("name")
    if name is None:
        findings.append(Finding(
            "ERROR", idx, None, "name", None,
            "required field is missing",
        ))
        return None
    if not isinstance(name, str):
        findings.append(Finding(
            "ERROR", idx, None, "name", name,
            "must be a string",
        ))
        return None
    if not NAME_RE.match(name):
        findings.append(Finding(
            "ERROR", idx, name, "name", name,
            "must be kebab-case, 2-64 chars, "
            "match ^[a-z][a-z0-9-]{0,62}[a-z0-9]$",
        ))
        # Still return the name — downstream messages are more useful
        # when they can reference it, even if the form is malformed.
    return name


def _check_machines(
    entry: dict,
    idx: int,
    name: str | None,
    findings: list[Finding],
) -> None:
    machines = entry.get("machines")
    if machines is None:
        findings.append(Finding(
            "ERROR", idx, name, "machines", None,
            "required field is missing",
        ))
        return
    if not isinstance(machines, list) or not machines:
        findings.append(Finding(
            "ERROR", idx, name, "machines", machines,
            "must be a non-empty list of strings",
        ))
        return
    for m in machines:
        if not isinstance(m, str):
            findings.append(Finding(
                "ERROR", idx, name, "machines", machines,
                "every element must be a string",
            ))
            return
    unknown = [m for m in machines if m not in VALID_MACHINES]
    if unknown:
        findings.append(Finding(
            "WARNING", idx, name, "machines", unknown,
            f"{unknown[0]!r} is not a recognized machine profile "
            f"(known: {sorted(VALID_MACHINES)})",
        ))


def _check_enabled(
    entry: dict,
    idx: int,
    name: str | None,
    findings: list[Finding],
) -> None:
    if "enabled" not in entry:
        return
    v = entry["enabled"]
    if not isinstance(v, bool):
        findings.append(Finding(
            "ERROR", idx, name, "enabled", v,
            "must be a boolean when present",
        ))


# Tier values are integers 1-5; mirrors the user's tier classification
# (1=core privacy, 2=dev, 3=virtualization, 4=work, 5=hygiene).  Entries
# without a tier field pass --tier filters unconditionally — useful for
# universal tools that don't belong to any tier in particular.
VALID_TIERS = frozenset({1, 2, 3, 4, 5})


def _check_tier(
    entry: dict,
    idx: int,
    name: str | None,
    findings: list[Finding],
) -> None:
    if "tier" not in entry:
        return
    v = entry["tier"]
    # tomllib parses bare integers as int; reject anything else (in
    # particular `tier = "1"` and `tier = true`).  bool is a subclass of
    # int in Python — exclude it explicitly.
    if not isinstance(v, int) or isinstance(v, bool):
        findings.append(Finding(
            "ERROR", idx, name, "tier", v,
            "must be an integer when present",
        ))
        return
    if v not in VALID_TIERS:
        findings.append(Finding(
            "ERROR", idx, name, "tier", v,
            f"must be one of {sorted(VALID_TIERS)}",
        ))


def _check_install_section(
    entry: dict,
    idx: int,
    name: str | None,
    findings: list[Finding],
) -> tuple[str | None, dict]:
    """Validate ``install.method`` and the method-consistency rule.

    Returns ``(method, install_section)``.  ``method`` is None if the
    section is unusable.
    """
    install = entry.get("install")
    if not isinstance(install, dict):
        findings.append(Finding(
            "ERROR", idx, name, "install", install,
            "required table is missing or not a table",
        ))
        return None, {}

    method = install.get("method")
    if method is None:
        findings.append(Finding(
            "ERROR", idx, name, "install.method", None,
            "required field is missing",
        ))
        return None, install
    if method not in VALID_METHODS:
        findings.append(Finding(
            "ERROR", idx, name, "install.method", method,
            f"must be one of {sorted(VALID_METHODS)}",
        ))
        return None, install

    expected_sub = METHOD_SUBTABLE[method]
    # Required sub-table must be present (when one is expected).
    if expected_sub is not None and expected_sub not in install:
        findings.append(Finding(
            "ERROR", idx, name, f"install.{expected_sub}", None,
            f"required for method={method!r}",
        ))

    # Any OTHER method sub-tables must be absent.
    for other_method, sub in METHOD_SUBTABLE.items():
        if sub is None or sub == expected_sub:
            continue
        if sub in install:
            findings.append(Finding(
                "ERROR", idx, name, f"install.{sub}", install[sub],
                f"present but method is {method!r} "
                f"(only install.{expected_sub or '<none>'} is allowed)",
            ))

    # ``install.package`` is the dpkg package name override (when it
    # differs from meta.name).  Meaningful for any dpkg-based method:
    #   • apt              — passed to `apt-get install <pkg>`
    #   • apt-pinned-repo  — same, after the vendor source is registered
    #                        (typically duplicates apt_pinned_repo.package;
    #                        the per-subtable package wins for that method)
    #   • direct-deb       — passed to `dpkg -s <pkg>` for the
    #                        already-installed short-circuit when the .deb's
    #                        Package field differs from meta.name (e.g.
    #                        upstream `rage` ships as `rage-musl` to dpkg).
    # NOT meaningful for github-release (no dpkg involvement).
    if "package" in install and method == "github-release":
        findings.append(Finding(
            "ERROR", idx, name, "install.package", install["package"],
            "not allowed when install.method = 'github-release' "
            "(no dpkg package — set install.github_release.install_to instead)",
        ))

    return method, install


def _check_apt_pinned_repo(
    install: dict,
    idx: int,
    name: str | None,
    findings: list[Finding],
) -> None:
    apr = install.get("apt_pinned_repo")
    if not isinstance(apr, dict):
        # Already reported as missing by _check_install_section if absent.
        return

    def err(field: str, value: object, reason: str) -> None:
        findings.append(Finding("ERROR", idx, name, field, value, reason))

    # Required string fields (basenames are validated separately).
    for key in ("package", "suite_url", "suite", "key_url"):
        v = apr.get(key)
        if not isinstance(v, str) or not v:
            err(f"install.apt_pinned_repo.{key}", v,
                "required non-empty string")

    # URL-shaped fields — https-only.  Plain-http key_url lets a MITM swap
    # the upstream keyring before the manifest-pinned fingerprint can anchor
    # it; suite_url over http would force the same attack against apt's own
    # signature checks.  Both match the https-only contract direct_deb
    # already enforces.
    for key in ("suite_url", "key_url"):
        v = apr.get(key)
        if isinstance(v, str) and v and not v.startswith("https://"):
            err(f"install.apt_pinned_repo.{key}", v,
                "must be an https URL")

    # components — non-empty list of strings.
    comps = apr.get("components")
    if not isinstance(comps, list) or not comps or not all(
        isinstance(c, str) and c for c in comps
    ):
        err("install.apt_pinned_repo.components", comps,
            "must be a non-empty list of non-empty strings")

    # key_fingerprint — exactly 40 hex chars.
    fp = apr.get("key_fingerprint")
    if not isinstance(fp, str) or not HEX40_RE.match(fp):
        # The spec example shows "found 39" reasoning when length is wrong,
        # so be specific about what's wrong (length vs non-hex char).
        found = len(fp) if isinstance(fp, str) else "n/a"
        reason = (
            f"must be exactly 40 hexadecimal characters (found {found})"
        )
        err("install.apt_pinned_repo.key_fingerprint", fp, reason)

    # keyring_file / sources_file — basenames only (no path separator).
    for key in ("keyring_file", "sources_file"):
        v = apr.get(key)
        if not isinstance(v, str) or not v:
            err(f"install.apt_pinned_repo.{key}", v,
                "required non-empty string (basename)")
        elif "/" in v or "\\" in v:
            err(f"install.apt_pinned_repo.{key}", v,
                "must be a basename — no path separators")


def _check_github_release(
    install: dict,
    pin_mode: str | None,
    idx: int,
    name: str | None,
    findings: list[Finding],
) -> None:
    gh = install.get("github_release")
    if not isinstance(gh, dict):
        return

    def err(field: str, value: object, reason: str) -> None:
        findings.append(Finding("ERROR", idx, name, field, value, reason))

    # repo — owner/name shape.
    repo = gh.get("repo")
    if not isinstance(repo, str) or not REPO_RE.match(repo):
        err("install.github_release.repo", repo,
            "must match ^[\\w.-]+/[\\w.-]+$ (e.g. 'owner/repo')")

    asset = gh.get("asset_pattern")
    if not isinstance(asset, str) or not asset:
        err("install.github_release.asset_pattern", asset,
            "required non-empty string")

    install_to = gh.get("install_to")
    if not isinstance(install_to, str) or not install_to.startswith("/"):
        err("install.github_release.install_to", install_to,
            "required absolute path (must start with '/')")

    # gpg_fingerprint — optional, but if present must be 40 hex or empty.
    if "gpg_fingerprint" in gh:
        gpg_fp = gh["gpg_fingerprint"]
        if not isinstance(gpg_fp, str) or (
            gpg_fp != "" and not HEX40_RE.match(gpg_fp)
        ):
            err("install.github_release.gpg_fingerprint", gpg_fp,
                "must be empty string or exactly 40 hex characters")

    # Pin-mode-driven required/forbidden fields.
    ver = gh.get("version")
    sha_x = gh.get("sha256_x86_64")
    sha_a = gh.get("sha256_aarch64")

    if pin_mode == "frozen":
        if not isinstance(ver, str) or not ver:
            err("install.github_release.version", ver,
                "required when pin.mode = 'frozen'")
        if not isinstance(sha_x, str) or not HEX64_RE.match(sha_x or ""):
            err("install.github_release.sha256_x86_64", sha_x,
                "required 64 lowercase hex chars when pin.mode = 'frozen'")
        # sha256_aarch64 is optional but if present must be empty or 64 hex.
        if sha_a is not None:
            if not isinstance(sha_a, str) or (
                sha_a != "" and not HEX64_RE.match(sha_a)
            ):
                err("install.github_release.sha256_aarch64", sha_a,
                    "must be empty string or 64 lowercase hex chars")
    elif pin_mode == "track-latest":
        # All three must be absent OR empty string.
        for fld, val in (
            ("version", ver),
            ("sha256_x86_64", sha_x),
            ("sha256_aarch64", sha_a),
        ):
            if val is not None and val != "":
                err(f"install.github_release.{fld}", val,
                    "must be absent or empty string when "
                    "pin.mode = 'track-latest'")

    # extract_path: optional, but if present must be a sane relative path.
    # The github-release adapter interpolates it directly into the install
    # source path; ".." components or absolute paths would let a hostile
    # manifest exfiltrate / write arbitrary files via the `install -D`
    # step that follows extraction.  Reject path-traversal patterns and
    # absolute paths defensively.
    ep = gh.get("extract_path")
    if ep is not None:
        if not isinstance(ep, str):
            err("install.github_release.extract_path", ep,
                "must be a string (empty for raw single-file assets)")
        elif ep:
            if ep.startswith("/"):
                err("install.github_release.extract_path", ep,
                    "must be a relative path (no leading '/')")
            elif ".." in ep.split("/"):
                err("install.github_release.extract_path", ep,
                    "must not contain '..' components (path traversal)")
            elif "\x00" in ep:
                err("install.github_release.extract_path", ep,
                    "must not contain NUL bytes")


def _check_direct_deb(
    install: dict,
    pin_mode: str | None,
    idx: int,
    name: str | None,
    findings: list[Finding],
) -> None:
    dd = install.get("direct_deb")
    if not isinstance(dd, dict):
        return

    def err(field: str, value: object, reason: str) -> None:
        findings.append(Finding("ERROR", idx, name, field, value, reason))

    url = dd.get("url")
    if not isinstance(url, str) or not url.startswith("https://"):
        err("install.direct_deb.url", url,
            "required URL starting with 'https://'")

    sha = dd.get("sha256")
    if not isinstance(sha, str) or not HEX64_RE.match(sha or ""):
        err("install.direct_deb.sha256", sha,
            "required 64 lowercase hex chars")

    ver = dd.get("version")
    if not isinstance(ver, str) or not ver:
        err("install.direct_deb.version", ver,
            "required non-empty string")

    # direct-deb is frozen-only — track-latest is a hard error.
    if pin_mode == "track-latest":
        err("pin.mode", "track-latest",
            "install.method = 'direct-deb' requires pin.mode = 'frozen'")


def _check_pin(
    entry: dict,
    method: str | None,
    idx: int,
    name: str | None,
    findings: list[Finding],
) -> str | None:
    """Validate ``[apps.pin]`` and return the resolved pin.mode (or None)."""
    pin = entry.get("pin")
    if not isinstance(pin, dict):
        findings.append(Finding(
            "ERROR", idx, name, "pin", pin,
            "required table is missing or not a table",
        ))
        return None

    mode = pin.get("mode")
    if mode not in VALID_PIN_MODES:
        findings.append(Finding(
            "ERROR", idx, name, "pin.mode", mode,
            f"must be one of {sorted(VALID_PIN_MODES)}",
        ))
        # Don't return — last_refreshed / refresh_after_days are still
        # worth checking shape-wise even if mode is bogus.

    # last_refreshed — required when frozen for apt/apt-pinned-repo;
    # also conventionally set for other frozen cases; YYYY-MM-DD when present.
    last = pin.get("last_refreshed")
    if last is not None:
        if not isinstance(last, str) or not DATE_RE.match(last):
            findings.append(Finding(
                "ERROR", idx, name, "pin.last_refreshed", last,
                "must be a YYYY-MM-DD date string",
            ))

    # For apt/apt-pinned-repo + frozen, last_refreshed is REQUIRED.
    if mode == "frozen" and method in ("apt", "apt-pinned-repo"):
        if last is None:
            findings.append(Finding(
                "ERROR", idx, name, "pin.last_refreshed", None,
                "required for apt/apt-pinned-repo with pin.mode = 'frozen'",
            ))

    rad = pin.get("refresh_after_days")
    if rad is not None:
        if not isinstance(rad, int) or isinstance(rad, bool) or rad <= 0:
            findings.append(Finding(
                "ERROR", idx, name, "pin.refresh_after_days", rad,
                "must be a positive integer when present",
            ))

    return mode if mode in VALID_PIN_MODES else None


# Explicit allowlist for `[apps.configs].<dest>` paths.  Any dest that
# doesn't match one of these prefixes is rejected by the validator.
# Without this gate the deploy step would become an arbitrary-file-write
# primitive if a manifest were tampered with — the validator is the
# chokepoint.  Prefixes are checked AFTER path normalization
# (".."/control-char rejection happens first), so traversal can't slip
# through.
#
# Adding a new system-dir prefix requires a code change here AND a
# review pass — opaque entries like /etc/sudoers, /etc/pam.d/sudo,
# /etc/cron.d, /etc/ssh, /etc/systemd/system, /etc/profile, /root, etc.
# must NEVER be added.
_DEST_USER_PREFIXES = (
    "${HOME}/",
    "$HOME/",
    "~/",
)
_DEST_SYSTEM_PREFIXES = (
    # Per-app configuration trees only.  No /etc top-level catch-all.
    "/etc/firefox-esr/",
    "/etc/mullvad-browser/",
    "/etc/zen/",             # Zen Browser policies (RemotingName=zen)
    "/etc/thunderbird/",
    "/etc/skel/",            # user-template path; safe defaults for new users
    "/etc/dconf/db/site.d/", # site-wide GSettings overrides — Plasma/GTK
    "/usr/local/share/",     # /usr/local hierarchy is admin-managed
    "/usr/local/lib/",
    "/usr/local/etc/",
    "/usr/lib/firefox-esr/", # autoconfig.js may live here per Mozilla docs
    "/usr/lib/thunderbird/",
    "/usr/lib/mullvad-browser/",
    "/opt/",
)


def _check_dest_allowlist(
    dest: object,
    idx: int,
    name: str | None,
    prefix: str,
    findings: list[Finding],
) -> None:
    """Reject [apps.configs].<dest> paths outside the explicit allowlist."""
    if not isinstance(dest, str) or not dest:
        findings.append(Finding(
            "ERROR", idx, name, prefix, dest,
            "dest must be a non-empty string path",
        ))
        return
    # Hard refusals — characters/patterns we never want in a dest path.
    if "\x00" in dest:
        findings.append(Finding(
            "ERROR", idx, name, prefix, "<NUL byte>",
            "dest must not contain NUL bytes",
        ))
        return
    if ".." in dest.split("/"):
        findings.append(Finding(
            "ERROR", idx, name, prefix, dest,
            "dest must not contain '..' components (path traversal)",
        ))
        return
    # Must match one of the allowlisted prefixes.
    matched = False
    for p in _DEST_USER_PREFIXES + _DEST_SYSTEM_PREFIXES:
        if dest.startswith(p):
            matched = True
            break
    if not matched:
        allowed = ", ".join(_DEST_USER_PREFIXES + _DEST_SYSTEM_PREFIXES)
        findings.append(Finding(
            "ERROR", idx, name, prefix, dest,
            f"dest outside allowlist (allowed prefixes: {allowed})",
        ))


def _check_configs(
    entry: dict,
    repo_root: Path,
    idx: int,
    name: str | None,
    findings: list[Finding],
) -> None:
    """Validate the optional [apps.configs] table + source-file existence.

    The path-traversal check resolves both source and the per-app dir to
    absolute paths and rejects sources that escape the latter.
    """
    cfg = entry.get("configs")
    if cfg is None:
        return
    if not isinstance(cfg, dict):
        findings.append(Finding(
            "ERROR", idx, name, "configs", cfg,
            "must be a table",
        ))
        return

    if not name:
        # We can't resolve source paths without a name; just skip the
        # existence check.  Shape errors below still get reported.
        pass

    app_dir = None
    if name:
        try:
            app_dir = (repo_root / "config" / "apps" / name).resolve(strict=False)
        except (OSError, RuntimeError):
            app_dir = None

    for dest, spec in cfg.items():
        prefix = f"configs.{dest}"
        if not isinstance(spec, dict):
            findings.append(Finding(
                "ERROR", idx, name, prefix, spec,
                "must be a table with source/mode/overlay",
            ))
            continue

        # dest path allowlist — refuse anything outside the explicit set of
        # system/user dirs the install step is allowed to write to.  Phase D's
        # deploy step would otherwise become an "arbitrary-file-write-as-root"
        # primitive driven by a hostile manifest.  The allowlist intentionally
        # excludes /etc/sudoers*, /etc/cron*, /etc/pam.d, /etc/ssh, /root,
        # /etc/profile*, /etc/systemd/system, /etc/passwd, /etc/shadow, etc.
        _check_dest_allowlist(dest, idx, name, prefix, findings)

        source = spec.get("source")
        if not isinstance(source, str) or not source:
            findings.append(Finding(
                "ERROR", idx, name, f"{prefix}.source", source,
                "required non-empty string",
            ))
        elif app_dir is not None:
            # Resolve source under the per-app dir; reject path traversal.
            try:
                candidate = (app_dir / source).resolve(strict=False)
            except (OSError, RuntimeError):
                candidate = None
            if candidate is None:
                findings.append(Finding(
                    "ERROR", idx, name, f"{prefix}.source", source,
                    "could not be resolved to an absolute path",
                ))
            else:
                # Path-traversal guard: resolved path must stay under
                # app_dir.  Using Path.is_relative_to (3.9+).
                try:
                    inside = candidate.is_relative_to(app_dir)
                except ValueError:
                    inside = False
                if not inside:
                    findings.append(Finding(
                        "ERROR", idx, name, f"{prefix}.source", source,
                        "resolves outside config/apps/"
                        f"{name}/ (path traversal rejected)",
                    ))
                elif not candidate.is_file():
                    findings.append(Finding(
                        "ERROR", idx, name, f"{prefix}.source", source,
                        f"source file does not exist on disk: {candidate}",
                    ))

        mode = spec.get("mode")
        # Reject setuid/setgid/sticky-bit modes: the deploy adapter runs
        # as root for system configs, and an attacker who could edit
        # apps.toml (e.g. via a compromised local process) would otherwise
        # land setuid-root copies of attacker-controlled files on disk.
        # Plain 3-octal modes (0NNN) only — no 4-octal forms.
        if not isinstance(mode, str) or not re.match(r"^0[0-7]{3}$", mode):
            findings.append(Finding(
                "ERROR", idx, name, f"{prefix}.mode", mode,
                "must be a plain 3-octal mode string like '0644' "
                "(setuid/setgid/sticky-bit modes are rejected)",
            ))

        overlay = spec.get("overlay")
        if not isinstance(overlay, bool):
            findings.append(Finding(
                "ERROR", idx, name, f"{prefix}.overlay", overlay,
                "must be a boolean",
            ))


def _check_hooks(
    entry: dict,
    idx: int,
    name: str | None,
    findings: list[Finding],
) -> None:
    hooks = entry.get("hooks")
    if hooks is None:
        return
    if not isinstance(hooks, dict):
        findings.append(Finding(
            "ERROR", idx, name, "hooks", hooks,
            "must be a table",
        ))
        return
    for phase in ("pre_install", "post_install"):
        if phase not in hooks:
            continue
        arr = hooks[phase]
        if not isinstance(arr, list):
            findings.append(Finding(
                "ERROR", idx, name, f"hooks.{phase}", arr,
                "must be a list of tables",
            ))
            continue
        for j, hk in enumerate(arr):
            prefix = f"hooks.{phase}[{j}]"
            if not isinstance(hk, dict):
                findings.append(Finding(
                    "ERROR", idx, name, prefix, hk,
                    "must be a table with description + command",
                ))
                continue
            desc = hk.get("description")
            cmd = hk.get("command")
            if not isinstance(desc, str):
                findings.append(Finding(
                    "ERROR", idx, name, f"{prefix}.description", desc,
                    "required string field",
                ))
            if not isinstance(cmd, str) or not cmd:
                findings.append(Finding(
                    "ERROR", idx, name, f"{prefix}.command", cmd,
                    "required non-empty string",
                ))
            elif "\x00" in cmd:
                # NUL bytes are invalid in shell command lines and a
                # well-known smuggling vector when commands are passed
                # to bash -c.  Reject them outright.
                findings.append(Finding(
                    "ERROR", idx, name, f"{prefix}.command", "<NUL byte>",
                    "must not contain NUL bytes",
                ))
            elif len(cmd) > 4096:
                # Practical upper bound — keeps a single hook line
                # well under typical ARG_MAX / log-line limits and
                # rejects pathological / corrupted manifests.
                findings.append(Finding(
                    "ERROR", idx, name, f"{prefix}.command",
                    f"<{len(cmd)} chars>",
                    "must be ≤ 4096 characters",
                ))


def _check_browser_extensions(
    entry: dict,
    idx: int,
    name: str | None,
    findings: list[Finding],
) -> None:
    exts = entry.get("browser_extensions")
    if exts is None:
        return
    if not isinstance(exts, list):
        findings.append(Finding(
            "ERROR", idx, name, "browser_extensions", exts,
            "must be a list of tables",
        ))
        return

    seen_guids: dict[str, int] = {}
    for j, ext in enumerate(exts):
        prefix = f"browser_extensions[{j}]"
        if not isinstance(ext, dict):
            findings.append(Finding(
                "ERROR", idx, name, prefix, ext,
                "must be a table",
            ))
            continue

        ename = ext.get("name")
        if not isinstance(ename, str) or not ename:
            findings.append(Finding(
                "ERROR", idx, name, f"{prefix}.name", ename,
                "required non-empty string",
            ))

        guid = ext.get("guid")
        if not isinstance(guid, str) or not EXT_GUID_RE.match(guid or ""):
            findings.append(Finding(
                "ERROR", idx, name, f"{prefix}.guid", guid,
                "must match <slug>@<domain>, <slug>@jetpack, {UUID}, or @<slug>",
            ))
        else:
            # Track for within-app duplicate check.
            if guid in seen_guids:
                findings.append(Finding(
                    "ERROR", idx, name, f"{prefix}.guid", guid,
                    f"duplicate of browser_extensions[{seen_guids[guid]}].guid",
                ))
            else:
                seen_guids[guid] = j

        slug = ext.get("amo_slug")
        if not isinstance(slug, str) or not AMO_SLUG_RE.match(slug or ""):
            findings.append(Finding(
                "ERROR", idx, name, f"{prefix}.amo_slug", slug,
                "required, must match ^[a-z0-9-]+$",
            ))

        mode = ext.get("mode")
        if mode not in VALID_EXT_MODES:
            findings.append(Finding(
                "ERROR", idx, name, f"{prefix}.mode", mode,
                f"required, must be one of {sorted(VALID_EXT_MODES)}",
            ))

        if "version" in ext:
            ver = ext["version"]
            if not isinstance(ver, str) or not VERSION_RE.match(ver):
                findings.append(Finding(
                    "ERROR", idx, name, f"{prefix}.version", ver,
                    "must match ^\\d+(\\.\\d+)*$",
                ))


# ── Entry orchestrator ──────────────────────────────────────────────────

def validate_entry(
    entry: object,
    idx: int,
    repo_root: Path,
    findings: list[Finding],
) -> str | None:
    """Run all per-entry checks; return the entry's name (or None)."""
    if not isinstance(entry, dict):
        findings.append(Finding(
            "ERROR", idx, None, "apps[]", entry,
            "must be a table",
        ))
        return None

    name = _check_name(entry, idx, findings)
    _check_machines(entry, idx, name, findings)
    _check_enabled(entry, idx, name, findings)
    _check_tier(entry, idx, name, findings)
    method, install = _check_install_section(entry, idx, name, findings)
    pin_mode = _check_pin(entry, method, idx, name, findings)

    # Method-specific sub-table validators (each is a no-op if its
    # sub-table is absent; the install-level check already flags absence).
    if method == "apt-pinned-repo":
        _check_apt_pinned_repo(install, idx, name, findings)
    elif method == "github-release":
        _check_github_release(install, pin_mode, idx, name, findings)
    elif method == "direct-deb":
        _check_direct_deb(install, pin_mode, idx, name, findings)
    # apt: no sub-table; install.package optionality already handled.

    _check_configs(entry, repo_root, idx, name, findings)
    _check_hooks(entry, idx, name, findings)
    _check_browser_extensions(entry, idx, name, findings)
    return name


# ── File discovery + parsing ────────────────────────────────────────────

def discover_manifests(repo_root: Path) -> list[Path]:
    """Find candidate .toml files under config/apps/.

    Skips ``schema*.toml``, ``_*.toml``, and dotfiles (``.*.toml``).
    Does NOT yet read or parse files — the caller filters further by
    presence of an ``[[apps]]`` array (silent-skip per design).
    """
    apps_dir = repo_root / "config" / "apps"
    if not apps_dir.is_dir():
        return []
    out: list[Path] = []
    for p in sorted(apps_dir.glob("*.toml")):
        base = p.name
        if base.startswith(".") or base.startswith("_"):
            continue
        if base.startswith("schema"):
            continue
        out.append(p)
    return out


def parse_toml(
    path: Path,
    findings: list[Finding],
) -> dict | None:
    """Read+parse a TOML file.  Reports decode errors as file-level findings."""
    try:
        # Read in text mode with strict UTF-8 enforcement, then re-encode
        # for tomllib.  tomllib only accepts binary input; doing the read
        # ourselves lets us catch invalid UTF-8 explicitly rather than
        # letting it slip through as Latin-1 reinterpretation.
        with open(path, "r", encoding="utf-8", errors="strict") as fh:
            text = fh.read()
        return tomllib.loads(text)
    except UnicodeDecodeError as e:
        findings.append(Finding(
            "ERROR", None, None, str(path), None,
            f"file is not valid UTF-8: {e}",
        ))
        return None
    except tomllib.TOMLDecodeError as e:
        findings.append(Finding(
            "ERROR", None, None, str(path), None,
            f"TOML parse error: {e}",
        ))
        return None
    except OSError as e:
        findings.append(Finding(
            "ERROR", None, None, str(path), None,
            f"could not read file: {e}",
        ))
        return None


# ── Main ────────────────────────────────────────────────────────────────

def main(argv: list[str] | None = None) -> int:
    """Entry point.  Returns the desired process exit code."""
    # Default --root = parent of the scripts/ dir holding this file.
    default_root = Path(__file__).resolve().parent.parent

    parser = argparse.ArgumentParser(
        prog="apps-validate",
        description="Validate config/apps/*.toml against schema_version=2.",
    )
    parser.add_argument(
        "--root", type=Path, default=default_root,
        help="Repository root (default: auto-detected from script location)",
    )
    parser.add_argument(
        "--app", type=str, default=None,
        help="Validate only entries with this name "
             "(global duplicate check still runs)",
    )
    args = parser.parse_args(argv)

    repo_root = args.root.resolve()
    only_app = args.app

    manifests = discover_manifests(repo_root)
    findings: list[Finding] = []

    # Names seen across ALL parsed entries, mapped to (file, idx) of the
    # first occurrence.  Used for the cross-entry uniqueness rule.
    seen_names: dict[str, tuple[Path, int]] = {}

    total_entries = 0
    parsed_files = 0
    for path in manifests:
        # Read+parse.  Strategy:
        #   schema_version = 2 + [[apps]] present  → validate (the normal case)
        #   schema_version = 2 + [[apps]] missing  → ERROR (typo'd apps array)
        #   schema_version absent / != 2           → silent skip (legacy per-file
        #                                            manifests during transition)
        # The asymmetry catches the case where a contributor adds
        # `schema_version = 2` but accidentally drops `[[apps]]` (typo
        # `[[ap]]` etc.) — without this check the file would silently vanish
        # from the validator's view.
        data = parse_toml(path, findings)
        if data is None:
            continue
        sv = data.get("schema_version")
        apps = data.get("apps")
        if sv != SCHEMA_VERSION_EXPECTED:
            # Legacy per-file manifest (or unrelated TOML) — silent skip.
            continue
        if not isinstance(apps, list):
            findings.append(Finding(
                "ERROR", None, None, "apps", apps,
                f"schema_version = {SCHEMA_VERSION_EXPECTED} declared but no "
                f"[[apps]] array found (typo? wrong file?) in {path}",
            ))
            continue
        parsed_files += 1
        log(f"reading {path.relative_to(repo_root) if path.is_relative_to(repo_root) else path}")

        log(f"{len(apps)} entries found")

        # Per-entry pass.  Run validate_entry on every entry (so duplicate
        # detection sees them all); --app filtering happens AFTER the loop
        # to keep the duplicate check honest.
        for i, entry in enumerate(apps, start=1):
            total_entries += 1
            name = validate_entry(entry, i, repo_root, findings)
            if name is None:
                continue
            if name in seen_names:
                prev_path, prev_idx = seen_names[name]
                findings.append(Finding(
                    "ERROR", i, name, "name", name,
                    f"duplicate of entry #{prev_idx} in "
                    f"{prev_path.relative_to(repo_root) if prev_path.is_relative_to(repo_root) else prev_path}",
                ))
            else:
                seen_names[name] = (path, i)

    # --app post-filter: drop findings for non-matching entries, but keep
    # file-level findings (entry_idx is None) and duplicate-name findings
    # against the targeted name.
    if only_app is not None:
        kept: list[Finding] = []
        for f in findings:
            if f.entry_idx is None:
                kept.append(f)
            elif f.entry_name == only_app:
                kept.append(f)
        findings = kept

    # ── Emit findings ──
    errors = [f for f in findings if f.severity == "ERROR"]
    warnings = [f for f in findings if f.severity == "WARNING"]

    if parsed_files == 0:
        # Nothing to validate — neither error nor warning condition.
        log("0 entries found")

    for f in findings:
        emit_finding(f)

    # Summary line — match the spec's "N error(s), N warning(s)" format.
    if findings:
        e_word = "error" if len(errors) == 1 else "errors"
        w_word = "warning" if len(warnings) == 1 else "warnings"
        log(f"{len(errors)} {e_word}, {len(warnings)} {w_word}")

    if errors:
        log("REFUSING to proceed — fix errors and re-run")
        return 1
    if warnings:
        log("OK (with warnings)")
        return 2
    log("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
