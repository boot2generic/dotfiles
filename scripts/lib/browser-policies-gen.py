#!/usr/bin/env python3
"""scripts/lib/browser-policies-gen.py

Generate <browser>/policies.json from a `policies.json.base` template
merged with the `[[apps.browser_extensions]]` list declared in
``config/apps/apps.toml``.

WHY this exists
---------------
Browser extension policy lives in two places — the static "make the
browser shut up about telemetry / Pocket / sponsored stuff" block, and
the dynamic "here is the list of extensions we want force-installed".
The static block is hand-curated and changes rarely; the extension list
churns and is the source of truth for what the privacy profile pulls in.
Splitting them keeps the manifest the only place a contributor edits
when adding/removing an extension, and the validator (`apps-validate.py`
`_check_browser_extensions`) catches malformed GUIDs / slugs / modes
before they reach this generator.

WHAT this script does
---------------------
For one named browser app (`--app <name>`):

  1.  Parses ``config/apps/apps.toml`` with ``tomllib``.
  2.  Locates the matching [[apps]] entry; bails (exit 1) if not found.
  3.  Reads ``config/apps/<name>/policies.json.base`` as JSON; bails
      (exit 1) if missing or malformed.
  4.  Builds the ExtensionSettings dict from
      ``apps.browser_extensions``.  Per-entry shape (Mozilla Policies):

        "<guid>": {
          "installation_mode": "<force_installed|allowed|blocked>",
          "install_url":   "<AMO latest.xpi URL>",   # force_installed only
          "default_area":  "navbar"                  # force_installed only
        }

      For ``mode = "allowed"`` and ``mode = "blocked"`` the install_url
      and default_area keys are omitted (the user is responsible / the
      extension is denied outright).

  5.  Adds the deny-by-default sentinel:

        "*": {
          "installation_mode": "blocked",
          "blocked_install_message": "Extensions are managed by dotfiles policy"
        }

  6.  Sets ``policies.policies.ExtensionSettings`` and writes the result
      to ``config/apps/<name>/policies.json`` (next to the .base file).
      The actual ``/etc/<browser>/policies/policies.json`` deploy is the
      job of the apt-method config-installer hook, not this script.

Exit codes
----------
  0  — success
  1  — bad input (missing app entry, missing/bad base JSON, bad TOML,
       missing required field on a browser_extensions entry, etc.)
  2  — write failure (destination unwritable, partial write, etc.)

No external dependencies — Python 3.11+ stdlib (tomllib + json +
pathlib + argparse) only.
"""

from __future__ import annotations

import argparse
import json
import sys
import tomllib
from pathlib import Path


# Browsers the generator knows about.  Adding a new entry here lets the
# generator run for it; the validator's allowlist behaviour is unchanged
# (browser_extensions is meaningful for any app, but only the apps below
# get a policies.json deploy path).
KNOWN_BROWSERS = frozenset({"firefox-esr", "mullvad-browser"})

# Deny-by-default sentinel injected into every generated ExtensionSettings
# block.  The Mozilla Policies spec recognises "*" as the catch-all key;
# the order of keys in a JSON dict is insertion order in Python 3.7+, so
# placing this LAST (after the explicit entries) keeps the file readable
# while still applying to anything not matched above.
DENY_GUID = "*"
DENY_VALUE = {
    "installation_mode": "blocked",
    "blocked_install_message": "Extensions are managed by dotfiles policy",
}

# AMO download URL template.  {amo_slug} is required; {filename} is
# "latest.xpi" by default but switches to "<slug>-<version>.xpi" when an
# extension entry pins a specific version.  We do NOT use AMO's
# `/firefox/downloads/file/<id>/` form because that URL requires a
# numeric file ID that's not in the manifest.
AMO_URL_FMT = (
    "https://addons.mozilla.org/firefox/downloads/latest/{amo_slug}/{filename}"
)


def log(msg: str) -> None:
    """Stderr progress line — same convention as apps-validate / install-apps."""
    print(f"[browser-policies-gen] {msg}", file=sys.stderr)


def find_app_entry(apps: list, app_name: str) -> dict | None:
    """Linear scan of the [[apps]] array; returns the first match by name."""
    for entry in apps:
        if isinstance(entry, dict) and entry.get("name") == app_name:
            return entry
    return None


def build_extension_settings(
    extensions: list,
    app_name: str,
) -> dict:
    """Build the ExtensionSettings dict for one browser.

    Order: the explicit entries (in manifest order) followed by the
    deny-by-default sentinel.  Mode-specific key sets:
      - force_installed → installation_mode + install_url + default_area
      - allowed         → installation_mode only (user can install)
      - blocked         → installation_mode only (extension denied)
    """
    out: dict[str, dict] = {}
    for j, ext in enumerate(extensions):
        if not isinstance(ext, dict):
            raise ValueError(
                f"{app_name}: browser_extensions[{j}] is not a table"
            )
        guid = ext.get("guid")
        mode = ext.get("mode")
        amo_slug = ext.get("amo_slug")
        version = ext.get("version")

        if not isinstance(guid, str) or not guid:
            raise ValueError(
                f"{app_name}: browser_extensions[{j}].guid missing or non-string"
            )
        if mode not in ("force_installed", "allowed", "blocked"):
            raise ValueError(
                f"{app_name}: browser_extensions[{j}].mode invalid: {mode!r}"
            )
        if guid in out:
            raise ValueError(
                f"{app_name}: duplicate guid in browser_extensions[{j}]: {guid}"
            )

        entry: dict[str, object] = {"installation_mode": mode}

        if mode == "force_installed":
            if not isinstance(amo_slug, str) or not amo_slug:
                raise ValueError(
                    f"{app_name}: browser_extensions[{j}].amo_slug required "
                    f"for mode=force_installed"
                )
            if isinstance(version, str) and version:
                filename = f"{amo_slug}-{version}.xpi"
            else:
                filename = "latest.xpi"
            entry["install_url"] = AMO_URL_FMT.format(
                amo_slug=amo_slug, filename=filename,
            )
            entry["default_area"] = "navbar"
        # mode in {"allowed", "blocked"}: leave the entry minimal.  AMO
        # downloads aren't valid for these modes per the policy schema.

        out[guid] = entry

    # Sentinel goes last so the generated JSON reads explicit→catch-all.
    out[DENY_GUID] = dict(DENY_VALUE)
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="browser-policies-gen",
        description="Generate <app>/policies.json from "
                    "<app>/policies.json.base + apps.toml browser_extensions.",
    )
    parser.add_argument(
        "--app",
        required=True,
        help="App name as it appears in apps.toml (e.g. 'firefox-esr').",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=None,
        help="Repository root.  Defaults to the parent of scripts/lib/.",
    )
    args = parser.parse_args(argv)

    # Default --root = repo-root.  This file lives at
    # <repo>/scripts/lib/browser-policies-gen.py — climb two parents.
    if args.root is None:
        repo_root = Path(__file__).resolve().parent.parent.parent
    else:
        repo_root = args.root.resolve()

    apps_toml = repo_root / "config" / "apps" / "apps.toml"
    if not apps_toml.is_file():
        log(f"apps.toml not found at {apps_toml}")
        return 1

    try:
        with open(apps_toml, "rb") as fh:
            manifest = tomllib.load(fh)
    except tomllib.TOMLDecodeError as e:
        log(f"apps.toml parse error: {e}")
        return 1
    except OSError as e:
        log(f"could not read apps.toml: {e}")
        return 1

    apps = manifest.get("apps")
    if not isinstance(apps, list):
        log("apps.toml has no [[apps]] array")
        return 1

    entry = find_app_entry(apps, args.app)
    if entry is None:
        log(f"no [[apps]] entry with name = {args.app!r}")
        return 1

    if args.app not in KNOWN_BROWSERS:
        # Not technically an error — the validator already accepts
        # browser_extensions on any entry — but the generator only
        # knows where to deploy results for the named browsers.
        log(f"WARNING: {args.app!r} is not in KNOWN_BROWSERS; generating anyway")

    base_path = repo_root / "config" / "apps" / args.app / "policies.json.base"
    if not base_path.is_file():
        log(f"base policy not found at {base_path}")
        return 1

    try:
        with open(base_path, "r", encoding="utf-8") as fh:
            policies = json.load(fh)
    except json.JSONDecodeError as e:
        log(f"{base_path}: malformed JSON: {e}")
        return 1
    except OSError as e:
        log(f"could not read {base_path}: {e}")
        return 1

    if not isinstance(policies, dict) or "policies" not in policies \
            or not isinstance(policies["policies"], dict):
        log(f"{base_path}: missing top-level 'policies' object")
        return 1

    extensions = entry.get("browser_extensions", [])
    if not isinstance(extensions, list):
        log(f"{args.app}: browser_extensions must be a list of tables")
        return 1

    try:
        ext_settings = build_extension_settings(extensions, args.app)
    except ValueError as e:
        log(str(e))
        return 1

    # Merge.  Replace any existing ExtensionSettings wholesale — the
    # generator OWNS this block; mixing hand-edits with generator output
    # would silently lose hand-edits on the next regeneration.  Base
    # files therefore intentionally do NOT carry ExtensionSettings.
    policies["policies"]["ExtensionSettings"] = ext_settings

    out_path = repo_root / "config" / "apps" / args.app / "policies.json"
    try:
        # Pretty-print with 2-space indent so diffs are reviewable.
        # Trailing newline keeps the file POSIX-clean.
        text = json.dumps(policies, indent=2, ensure_ascii=False) + "\n"
        # Write atomically: write to <out>.tmp then rename.  Guards
        # against partial files if the process is killed mid-write.
        tmp_path = out_path.with_suffix(out_path.suffix + ".tmp")
        with open(tmp_path, "w", encoding="utf-8") as fh:
            fh.write(text)
        tmp_path.replace(out_path)
    except OSError as e:
        log(f"could not write {out_path}: {e}")
        return 2

    # Count explicit extensions (excludes the "*" sentinel) for the summary.
    explicit_count = len(ext_settings) - 1
    rel_out = out_path.relative_to(repo_root) \
        if out_path.is_relative_to(repo_root) else out_path
    log(f"wrote {rel_out} ({explicit_count} extensions)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
