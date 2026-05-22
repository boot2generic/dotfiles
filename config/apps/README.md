# `config/apps/` — application-install manifests

This directory holds one self-describing TOML manifest per third-party
application installed by the dotfiles repo. The dispatcher
[`scripts/install-apps.sh`](../../scripts/install-apps.sh) iterates the
manifests, resolves the current machine's profile, and delegates the
actual install to method-specific adapters under
`scripts/install-methods/`.

Phase 0 ships the schema, the dispatcher, and the dev guide. The
adapters, pin-verification tooling, and the first real per-app
manifests land in later phases. Until then this directory may be
manifest-empty — that's expected.

## Contents at a glance

| File | Purpose |
| --- | --- |
| `schema.toml` | Authoritative field-by-field schema reference. Not loaded as a manifest. |
| `schema.example.toml` | Heavily-commented worked example exercising every install method. Copy-and-trim. |
| `README.md` | This file. |
| `<name>.toml` | One per app. Filename = `meta.name`. |
| `<name>/` | Optional per-app subdirectory holding source files referenced by `[configs]`. |

The dispatcher's manifest glob skips:

- `schema*.toml`
- `_*.toml` (use this prefix for work-in-progress drafts)
- dotfiles (anything starting with `.`)

## How it connects to the dispatcher

1. `scripts/install-apps.sh` discovers every non-excluded `*.toml` here.
2. Each manifest is parsed via Python's `tomllib` and re-emitted as
   JSON (no extra package dependencies; Debian 13 ships Python 3.11+).
3. The dispatcher computes the active machine profile set from DMI +
   PCI signals, and skips manifests whose `meta.machines` doesn't
   intersect it.
4. For each surviving manifest, the dispatcher:
   - calls `scripts/verify-pins.sh --app NAME` if present (refuses on
     exit code 2);
   - runs `hooks.pre_install` commands in order;
   - shells out to `scripts/install-methods/<method>.sh <json-path>`;
   - runs `hooks.post_install` commands;
   - tallies one of `installed | skipped | failed`.
5. A summary line is printed at the end.

The adapter contract is documented inline at the top of
`scripts/install-apps.sh` and reproduced below for convenience:

```text
DOTFILES_MACHINE=<profile> DRY_RUN=<0|1> REPO_DIR=<...> \
    scripts/install-methods/<method>.sh <path-to-manifest-json>

stdout : one machine-readable line — `installed=true` or
         `installed=false [skipped_reason=<str>]`
stderr : human progress
exit 0 : success or intentional skip
exit 1 : pre-flight failure
exit 2 : installation error
```

## Add an app (8 steps)

1. Pick a canonical `name`. Use the binary's name on `$PATH` (or the
   apt package name if those match). This becomes the manifest
   filename and the lookup key everywhere downstream.
2. `cp config/apps/schema.example.toml config/apps/<name>.toml`.
3. Delete the `[install.*]` subtables you aren't using; keep exactly
   one per the schema's mutual-exclusion rules.
4. Set `meta.machines` to the smallest profile set that needs the app
   (`["common"]` for almost everything; add `"t14"` or `"desktop"`
   only for hardware-tied tools).
5. Fill in install-method-specific fields:
   - **apt** — usually nothing beyond `install.method = "apt"` and
     optional `install.package` override.
   - **apt-pinned-repo** — full `[install.apt_pinned_repo]` table,
     including a 40-hex `key_fingerprint`. Keep the keyring + sources
     file basenames consistent with what lives under
     `config/system/etc/apt/keyrings/` and `sources.list.d/`.
   - **github-release** — full `[install.github_release]` table with
     `sha256_x86_64` mandatory and `sha256_aarch64` set to the empty
     string if you don't ship arm64.
   - **direct-deb** — full `[install.direct_deb]` table with a single
     `sha256`.
6. Set `[pin] last_refreshed` to today and `refresh_after_days = 90`
   (the audit / conky pin-staleness threshold).
7. If you ship config files, drop them under `config/apps/<name>/` and
   point the `[configs]` table at them with `source =` relative paths.
8. Validate locally:

   ```sh
   python3 -c 'import tomllib; tomllib.loads(open("config/apps/<name>.toml","rb").read().decode())'
   scripts/install-apps.sh --list
   scripts/install-apps.sh --app <name> --dry-run
   ```

## Remove an app (4 steps)

1. `git rm config/apps/<name>.toml` and the matching `config/apps/<name>/`
   subdirectory if any.
2. Remove the corresponding keyring + sources files under
   `config/system/etc/apt/keyrings/` and `sources.list.d/` if the app
   used `apt-pinned-repo`.
3. Drop any references from `scripts/audit.sh`,
   `scripts/dotfiles-doctor.sh`, and `config/conky/conky.conf`'s
   `check_pins()` if the app had bespoke hooks there. The generic
   manifest-driven paths need no edit.
4. Test: `scripts/install-apps.sh --list` should no longer mention the
   app; `scripts/install-apps.sh --dry-run` should run clean.

## Refresh a single pin

```sh
scripts/refresh-pins.sh --app <name>           # Agent C deliverable
```

The script:

- recomputes `sha256_x86_64` / `sha256_aarch64` / `direct_deb.sha256`
  against the live upstream artifact;
- updates `pin.last_refreshed` to today;
- prints a diff against the previous values;
- exits non-zero if upstream is unreachable or the new hash differs
  without an obvious tag bump.

## Refresh all stale pins

```sh
scripts/refresh-pins.sh --stale                # any pin past refresh_after_days
scripts/refresh-pins.sh --all                  # every pin in the repo
```

Pair with `scripts/audit.sh` to see what's currently stale without
mutating anything.

## Install methods

### `apt`

Standard OS-suite install via `apt-get install -y`. No pin block
required (the suite is pinned by the OS release). Verification is
implicit — the apt machinery validates Release file signatures.

- Required fields: `meta.name`, `install.method = "apt"`.
- Optional: `install.package` if the apt name differs from `meta.name`
  (e.g. `bat` → `batcat`).

### `apt-pinned-repo`

Adds a third-party apt repository with a verified GPG key, then
`apt-get install`s the package. The key fingerprint pinned in the
manifest is what `verify-pins.sh` compares against the key actually
on disk under `/etc/apt/keyrings/`.

- Required: `[install.apt_pinned_repo]` table.
- `suite` may contain the literal token `$(distro_codename)`; the
  adapter substitutes `lsb_release -cs` at install time.
- The keyring + sources file basenames must match files committed
  under `config/system/etc/apt/keyrings/` and
  `config/system/etc/apt/sources.list.d/`.
- Verification: `refresh-keys.sh` re-pulls the key from `key_url`,
  checks fingerprint, and rewrites the keyring file in place.

### `github-release`

Downloads an asset from a tagged GitHub release, sha256-verifies it,
optionally GPG-verifies it, and drops the result on disk.

- Required: `[install.github_release]` table.
- `asset_pattern` must include the `{arch}` placeholder
  (`x86_64` / `aarch64`); `{version}` is also substituted.
- `sha256_x86_64` is mandatory; `sha256_aarch64` may be the empty
  string to signal "x86_64-only".
- `gpg_fingerprint` is optional; an empty string disables the
  signature check (e.g. for upstreams that don't sign).
- `extract_path` points at the file or directory inside the archive
  the adapter should install — relative, no leading slash. Empty for
  raw single-file assets.
- Verification: `verify-pins.sh --app <name>` checks the sha256 (and
  GPG sig when fingerprint set) against the currently installed
  binary, exit 2 on mismatch.

### `direct-deb`

Downloads a `.deb` from a stable URL, sha256-verifies it, then
`dpkg -i`s it. Useful for vendors that ship outside any apt repo
(Microsoft Edge, Slack, etc.).

- Required: `[install.direct_deb]` table.
- `version` is a human label only — the canonical identifier is the
  `sha256`. Update both whenever upstream bumps.
- Verification: identical sha256 logic to `github-release`, minus the
  GPG path (most direct-deb vendors don't expose detached sigs).

## Machine profiles

Resolved by `resolve_profile()` in `scripts/install-apps.sh`. Always
emits a space-separated list:

| Profile | Always present? | Detection signal |
| --- | --- | --- |
| `common`  | yes | unconditional |
| `t14`     | when laptop | `/sys/class/dmi/id/chassis_type ∈ {8,9,10,14}` (mirror of `is_laptop_chassis` in `local_setup.sh`) |
| `desktop` | when Nvidia | `/proc/driver/nvidia/version` exists, OR `lspci` reports `vga.*nvidia` |

An app installs iff `meta.machines` intersects the active set.

### Extend with a new profile

1. Add a detection branch to `resolve_profile()` in
   `scripts/install-apps.sh`.
2. Document it in the table above.
3. Reference it in `schema.toml`'s `[meta] machines` comment block.
4. Add it to the legal-values set in `scripts/dotfiles-doctor.sh` if
   the doctor validates manifest profile names (it should).

## Where each part of the install flow lives

| Concern | File |
| --- | --- |
| Manifest schema reference | `config/apps/schema.toml` |
| Worked example | `config/apps/schema.example.toml` |
| Per-app manifests | `config/apps/<name>.toml` |
| Per-app source files (for `[configs]`) | `config/apps/<name>/` |
| Dispatcher | `scripts/install-apps.sh` |
| Method adapters | `scripts/install-methods/<method>.sh` |
| Pin verification | `scripts/verify-pins.sh` |
| Pin refresh | `scripts/refresh-pins.sh` |
| Key refresh | `scripts/refresh-keys.sh` |
| Apt keyrings (managed) | `config/system/etc/apt/keyrings/` |
| Apt sources (managed) | `config/system/etc/apt/sources.list.d/` |
| Stale-pin audit (one-shot) | `scripts/audit.sh` |
| Stale-pin dashboard (live) | `config/conky/conky.conf` — `check_pins()` |
| End-to-end health probe | `scripts/dotfiles-doctor.sh` |

## Files to modify when…

| When you… | Edit |
| --- | --- |
| Add an app | `config/apps/<name>.toml` (+ optional `config/apps/<name>/`) |
| Change an app's install pin | `config/apps/<name>.toml` (`[install.*]` + `[pin]` blocks) |
| Add an `apt-pinned-repo` key | `config/apps/<name>.toml` + `config/system/etc/apt/keyrings/<file>.gpg` + `config/system/etc/apt/sources.list.d/<file>.sources` |
| Add a brand-new install method | `scripts/install-methods/<method>.sh` + `config/apps/schema.toml` + `config/apps/schema.example.toml` |
| Add a new machine profile | `resolve_profile()` in `scripts/install-apps.sh` + profile table in this README + comment in `schema.toml` |
| Change pin-staleness threshold | `[pin] refresh_after_days` in the affected manifest |
| Wire dispatcher into the bootstrap | `local_setup.sh` (Phase 1 work; do not touch in Phase 0) |

## Wired-into-existing-tooling reference

Phase 0 leaves the existing scripts untouched. Phase 1 will wire them
up; the table below records the intended cross-references so future
edits land in all the right places:

| Existing tool | Intended interaction with `config/apps/` |
| --- | --- |
| `scripts/verify-pins.sh` | Reads `config/apps/<name>.toml`. Compares manifest hashes against on-disk artifacts. Exit 2 ⇒ dispatcher refuses to install. |
| `scripts/refresh-pins.sh` | Mutates `[pin]` + `[install.*]` sha256 / version fields in `config/apps/*.toml`. Bumps `last_refreshed`. |
| `scripts/refresh-keys.sh` | Pulls `key_url`, validates against `key_fingerprint`, rewrites `config/system/etc/apt/keyrings/<keyring_file>`. |
| `scripts/audit.sh` | Walks `config/apps/*.toml`, flags pins past `refresh_after_days`, missing keyrings, dangling `docs_url` links. |
| `scripts/dotfiles-doctor.sh` | Validates each manifest against `schema.toml` (required keys, enum values, fingerprint format), reports drift. |
| `config/conky/conky.conf` — `check_pins()` | Renders live stale-pin counter on the desktop, sourced from the same manifests. |
| `local_setup.sh --apps` | Phase 1 wires the existing `--apps` flag through `scripts/install-apps.sh` instead of the legacy inline install paths. |

## Common gotchas

- Manifest filename **must** equal `meta.name`. The dispatcher allows
  a mismatch (it falls back to `meta.name` for matching) but every
  other tool greps by filename, so keep them aligned.
- `meta.machines = []` (empty array) installs nowhere. To install
  everywhere, use `["common"]`.
- `key_fingerprint` is UPPERCASE 40-hex with no spaces. The fingerprint
  GPG prints by default contains spaces — strip them.
- `sha256_aarch64 = ""` is the convention for "x86_64-only". Do not
  omit the key — `verify-pins.sh` checks for its presence.
- Hook commands run as the install user, not root. Use `sudo` inside
  the command when needed; do not rely on the dispatcher being run via
  `sudo`.
- `bash -n scripts/install-apps.sh` is the cheapest sanity check.
  Always run it before committing.
