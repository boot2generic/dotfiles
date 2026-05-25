# `config/apps/` — application-install manifests

This directory holds the dotfiles repo's single source of truth for every
third-party application it installs. The CLI dispatcher
[`scripts/apps-cli.sh`](../../scripts/apps-cli.sh) reads the manifest,
resolves the active machine profile, validates every entry, and delegates
the actual install to method-specific adapters under
`scripts/install-methods/`.

The repo runs on **schema version 2**: one consolidated `apps.toml`
(TOML array-of-tables) instead of one file per app. The validator is
a **hard gate** — a broken `apps.toml` blocks every install subcommand.
The legacy per-file manifests have been removed; `apps.toml` is the
single source of truth.

## Contents at a glance

| Path | Purpose |
| --- | --- |
| `apps.toml` | Primary manifest. Every `[[apps]]` entry the repo installs. |
| `schema.toml` | Authoritative field-by-field schema reference. Not loaded by the dispatcher. |
| `schema.example.toml` | Heavily-commented worked example covering every method + pin mode. Copy-and-trim. |
| `README.md` | This file. |
| `<name>/` | Optional per-app subdirectory holding source files referenced by `[apps.configs]`. |
| `.locks/<name>.lock` | Lockfile sidecar — records what was actually installed (one TOML file per app). |
| `.locks/.gitkeep` | Keeps the empty `.locks/` directory tracked. |

The dispatcher and validator skip filenames matching:

- `schema*.toml`
- `_*.toml` (use this prefix for work-in-progress drafts)
- `.*.toml` (dotfiles)

Any other `.toml` file in this directory whose top-level table contains
an `[[apps]]` array is loaded. Today only `apps.toml` ships; future
tier-split files (`core.toml`, `desktop.toml`, etc.) would work the same
way without dispatcher changes.

## Single `apps.toml` (or future tier-split files when large)

For now everything lives in `apps.toml`. When the file gets unwieldy
(rule of thumb: ≥40 entries, or ≥2 logical tiers), split it by tier:

- `apps.toml` — keep the core/tier-1 set here
- `desktop.toml` — visual / GUI applications
- `dev.toml` — language toolchains, IDEs, build tools
- …

The dispatcher unions every matching file, then enforces the
**name-uniqueness rule** across the union. No magic precedence — a name
collision is a validator error.

## Install methods + trust ordering

The schema accepts four `install.method` values. Trust ordering, most →
least trusted (mirror this in your method choice):

1. `apt` — already-enabled OS suite. Apt's own signing chain validates
   Release files. No pin block carries a hash.
2. `apt-pinned-repo` — third-party apt repo with a manifest-pinned GPG
   fingerprint. Once the key is verified and the source list is
   registered, apt manages versions.
3. `github-release` — tagged release asset; sha256-pinned in the
   manifest, optional GPG signature when upstream signs.
4. `direct-deb` — vendor-hosted `.deb` over https. Pinned only by
   sha256; no apt-style signing chain. Use sparingly.

Prefer the leftmost method that's available for a given app.

### `apt`

Standard OS-suite install via `apt-get install -y`. Verification is
implicit — apt validates Release file signatures. No manifest-side
sha256.

- Required: `name`, `install.method = "apt"`.
- Optional: `install.package` if the apt name differs from `name`
  (e.g. `bat` → `batcat`).

### `apt-pinned-repo`

Adds a third-party apt repository with a verified GPG key, then
`apt-get install`s the package. The fingerprint pinned in the manifest
is what `verify-pins.sh` compares against the key actually on disk
under `/etc/apt/keyrings/`.

- Required: `[apps.install.apt_pinned_repo]` table.
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

- Required: `[apps.install.github_release]` table.
- `asset_pattern` may include `{arch}` (substituted with `x86_64` /
  `aarch64`) and `{version}` (substituted with the `version` field).
- When `pin.mode = "frozen"`, both `version` and `sha256_x86_64` are
  mandatory; `sha256_aarch64` may be the empty string to signal
  "x86_64-only".
- When `pin.mode = "track-latest"`, all three of `version`,
  `sha256_x86_64`, `sha256_aarch64` must be absent or empty strings.
- `gpg_fingerprint` is optional; empty string disables the signature
  check (e.g. for upstreams that don't sign).
- `extract_path` points at the file or directory inside the archive
  the adapter should install — relative, no leading slash. Empty for
  raw single-file assets.

### `direct-deb`

Downloads a `.deb` from a stable URL, sha256-verifies it, then
`dpkg -i`s it. Useful for vendors that ship outside any apt repo
(Microsoft Edge, Slack, etc.).

- Required: `[apps.install.direct_deb]` table.
- `version` is a human label only — the canonical identifier is the
  `sha256`. Update both whenever upstream bumps.
- **direct-deb is frozen-only**: `pin.mode = "frozen"` is the only
  legal value. The validator rejects track-latest for direct-deb.

## Pin modes — `track-latest` vs `frozen`

`[apps.pin] mode` is required for every entry, every method.

### `track-latest`

- The manifest carries **no** version/sha hard pin.
- The dispatcher defers to apt (or the upstream channel) for version
  selection. Lockfile at `.locks/<name>.lock` records what was actually
  installed.
- Legal **only** for `method ∈ {apt, apt-pinned-repo}`.
- `pin.last_refreshed` is optional but strongly recommended as an "I
  audited this on date X" annotation.

### `frozen`

- The manifest carries a hard pin and the installer refuses on hash
  mismatch.
- **Required** for `direct-deb`.
- Recommended (but not required) for `github-release`.
- Permitted for `apt-pinned-repo` as a documentation-only marker ("this
  is the version we've reviewed"). The install path still defers to apt.
- Mandatory companion fields:
  - `pin.last_refreshed` (ISO-8601 date)
  - `github-release`: `version` + `sha256_x86_64`
  - `direct-deb`: `version` + `sha256` (already required by the
    method's own subtable)

## Lockfile sidecar — `.locks/<name>.lock`

Every successful install produces a TOML lockfile at
`config/apps/.locks/<name>.lock`. The lockfile records what's actually
on disk right now (vs. the manifest, which records what the repo wants).

Lockfile format:

```toml
schema_version = 2
name           = "<app name>"
installed_at   = "<ISO-8601 timestamp>"
method         = "<apt | apt-pinned-repo | github-release | direct-deb>"
version        = "<version-as-installed>"
sha256         = "<64-hex when applicable, else empty>"
source         = "<URL the artifact came from, when applicable>"
machine        = "<profile that triggered the install>"
```

For `track-latest` apps, `version` is whatever apt reported via
`dpkg-query -W -f '${Version}'` at install time. For `frozen` apps,
`version` mirrors the manifest exactly.

`scripts/apps-cli.sh verify` cross-checks each lockfile against the
manifest and against on-disk state, flagging drift.

## Lifecycle commands — `scripts/apps-cli.sh`

The CLI dispatcher exposes one subcommand per lifecycle step. Every
subcommand is wired to real behaviour — the validator pre-flight gates
every mutating call.

| Subcommand | Purpose |
| --- | --- |
| `validate` | Hard-gate validator. Runs `scripts/apps-validate.py` over every loaded manifest. Exit 0 clean, 1 errors, 2 warnings-only. |
| `list` | Table view of every `[[apps]]` entry — name, method, pin mode, last refreshed, target machines. |
| `install` | Install matching apps. Runs `validate` first; refuses on any ERROR. Honors `--app NAME`, `--dry-run`, `--machine PROFILE`. |
| `status` | For each app, compare manifest vs lockfile vs on-disk reality. |
| `freeze` | Flip a `track-latest` entry to `frozen`: capture the currently-installed version + hash into the manifest. |
| `unfreeze` | Flip a `frozen` entry to `track-latest`: strip version/sha pins from the manifest (after a sanity check). |
| `refresh` | For `frozen` entries: re-fetch the upstream artifact, recompute sha256, update the manifest + bump `last_refreshed`. |
| `verify` | Re-hash on-disk artifacts and compare against the lockfile + manifest. Read-only. |
| `remove` | Uninstall an app + delete its lockfile. Manifest entry is left in place (with `enabled = false`) unless `--purge` is passed. |

Every mutating subcommand runs `validate` as a pre-flight. A broken
`apps.toml` aborts the operation before anything touches disk.

## Add an app (8 steps)

1. **Pick a canonical `name`.** kebab-case, ≤64 chars. For apt apps this
   is typically the apt package name; for github-release apps it's the
   binary's name on `$PATH`.
2. **Identify the closest example.** Open `schema.example.toml` and find
   the entry whose method + pin mode matches.
3. **Append a new `[[apps]]` block to `apps.toml`** under the right
   method-group section header (apt → apt-pinned-repo → github-release
   → direct-deb), alphabetical within the group.
4. **Fill in the top-level fields.** `name`, `display_name`, `machines`
   (`["common"]` for everything that's not hardware-tied), `description`,
   `docs_url`.
5. **Pick `[apps.install] method`** + the matching method subtable
   (`[apps.install.apt_pinned_repo]` / `_github_release]` /
   `_direct_deb]`). Delete the placeholders that don't apply.
6. **Set `[apps.pin]`.** Pick `mode`. For `frozen`, fill `version` +
   `sha256_x86_64` (github-release) or `sha256` (direct-deb), and set
   `last_refreshed = "<today>"`.
7. **Ship config files (optional).** Drop them under
   `config/apps/<name>/` and point `[apps.configs]` at them with
   relative `source =` paths.
8. **Validate locally:**

   ```sh
   scripts/apps-cli.sh validate
   scripts/apps-cli.sh list
   scripts/apps-cli.sh install --app <name> --dry-run
   ```

   The validator catches schema errors, cross-field violations, and
   missing config sources. Fix until exit 0.

## Remove an app

1. **Decide between soft-disable and hard-remove.** Setting
   `enabled = false` on the `[[apps]]` entry preserves the manifest
   history but tells the dispatcher to skip the app. A hard-remove
   deletes the entry.
2. **(hard-remove) Delete the `[[apps]]` stanza from `apps.toml`** and
   the matching `config/apps/<name>/` subdirectory if any.
3. **(apt-pinned-repo only) Remove the keyring + sources files** under
   `config/system/etc/apt/keyrings/<keyring_file>` and
   `config/system/etc/apt/sources.list.d/<sources_file>`.
4. **Drop the lockfile sidecar** at `config/apps/.locks/<name>.lock`.
5. **Drop any bespoke references** from `scripts/audit.sh`,
   `scripts/dotfiles-doctor.sh`, and `config/conky/conky.conf`'s
   `check_pins()` if the app had per-name hooks there. Generic
   manifest-driven paths need no edit.
6. **Run the validator.** `scripts/apps-cli.sh validate` should exit 0.
   `scripts/apps-cli.sh list` should no longer mention the app.

## The validator is a hard gate

`scripts/apps-validate.py` is the single chokepoint between a broken
manifest and any install action.

- Every mutating `apps-cli.sh` subcommand (`install`, `freeze`,
  `unfreeze`, `refresh`, `remove`) runs the validator first.
- Exit 1 from the validator (any ERROR) aborts the subcommand.
- Exit 2 (warnings only) is a permissible state; the subcommand proceeds.

Common errors the validator catches:

- Missing required field
- Wrong method subtable present (e.g. `[apps.install.github_release]`
  on an `apt-pinned-repo` entry)
- `pin.mode = "track-latest"` with hard pins set
- `pin.mode = "frozen"` without `last_refreshed`
- `direct-deb` with `pin.mode = "track-latest"`
- Bad fingerprint (≠ 40 hex chars) or sha256 (≠ 64 lowercase hex)
- Duplicate `name` across `[[apps]]` entries
- `[apps.configs]` source path that doesn't exist on disk

See `schema.toml` for the field-by-field contract and
`schema.example.toml` for a worked example exercising every method
and both pin modes.

## Browser policies — generated, not hand-edited

For `firefox-esr` and `mullvad-browser`, `policies.json` is **generated**
from a per-app `policies.json.base` template plus the
`[[apps.browser_extensions]]` list inside that app's `[[apps]]` entry.

- The generator is `scripts/lib/browser-policies-gen.py`.
- It runs as a `pre_install` hook before the `[apps.configs]` deploy
  copies the result to the system path
  (`/etc/firefox-esr/policies/policies.json` or
  `/usr/lib/mullvad-browser/distribution/policies.json`).
- The validator's `_check_browser_extensions` enforces shape
  (well-formed AMO slug, GUID matching one of the four legal forms, mode
  ∈ {`force_installed`, `allowed`, `blocked`}) before the generator runs.
- A deny-by-default `*` entry is appended automatically, so any
  extension not on the manifest is blocked.

To change the extension set, edit `apps.toml`; do NOT hand-edit the
generated `policies.json`.

## Tiers and the daily-driver app set

The repo currently ships:

- **Tier 1** — core privacy + security daily-drivers: `age`, `gopass`,
  `keepassxc`, `pass`, `firefox-esr`, `mullvad-browser`, `mullvad-vpn`,
  `signal-desktop`, `yubikey-manager`, `libpam-yubico`, plus the
  CLI essentials (`mosh`).
- **Tier 2** — dev tooling: `vscodium` (default) and an opt-in
  `code` (Microsoft VSCode, disabled by default).
- **Tier 4** — work / productivity: `aerc`, `copyq`, `flameshot` (i3),
  `spectacle` (Plasma), `libreoffice`, `mupdf`, `okular`, `zathura`,
  `thunderbird`, `syncthing`, `obsidian`, `drawio-desktop`, `bruno`.

Pass `--tier 1,2,4` to `install-apps.sh` (or `apps-cli.sh install`)
to install a subset. Entries with no `tier` field pass every filter.

### Notes on specific entries

- **obsidian** replaced Joplin as the notes editor on 2026-05-24.
  Vaults are folders of `.md` files (no proprietary store), pairing
  cleanly with the existing Syncthing entry for cross-machine sync.
- **gopass + rage** install via the `direct-deb` method
  (`pin.mode = "frozen"`) because no apt-pinned-repo is available
  upstream. Both are sha256-pinned in `apps.toml`.
- **jq** is a hard runtime dep for the install-method adapters
  (`apt-pinned-repo`, `github-release`, `direct-deb`). The bootstrap
  step in `local_setup.sh` ensures `jq` is installed before the
  `apps_install` phase runs.
- **signal-desktop** drops its `config.json` with mode `0600` because
  Signal Desktop persists its SQLCipher database key into the same
  file after first launch — world-readable would leak the key.

## Machine profiles

Resolved by `resolve_profile()` in `scripts/install-apps.sh`. The
dispatcher always emits a space-separated list:

| Profile | Always present? | Detection signal |
| --- | --- | --- |
| `common` | yes | unconditional |
| `t14` | when laptop | `/sys/class/dmi/id/chassis_type ∈ {8,9,10,14}` (mirrors `is_laptop_chassis` in `local_setup.sh`) |
| `desktop` | when Nvidia | `/proc/driver/nvidia/version` exists, OR `lspci` reports `vga.*nvidia` |
| `i3` | when i3 session | session-detection in `local_setup.sh` (i3 install path) |
| `plasma` | when plasma session | session-detection in `local_setup.sh` (plasma install path) |

An app installs iff `machines` intersects the active set.

## Where each part of the install flow lives

| Concern | File |
| --- | --- |
| Manifest schema reference | `config/apps/schema.toml` |
| Worked example | `config/apps/schema.example.toml` |
| Primary manifest | `config/apps/apps.toml` |
| Per-app source files (for `[apps.configs]`) | `config/apps/<name>/` |
| Per-app lockfile sidecar | `config/apps/.locks/<name>.lock` |
| CLI dispatcher | `scripts/apps-cli.sh` |
| Lower-level installer dispatcher | `scripts/install-apps.sh` |
| Validator | `scripts/apps-validate.py` |
| Method adapters | `scripts/install-methods/<method>.sh` |
| Lockfile read/write helpers | `scripts/lib/lockfile.sh` |
| GPG fingerprint / sig helpers | `scripts/lib/gpg-helpers.sh` |
| Validator-gate (shared pre-flight) | `scripts/lib/validator-gate.sh` |
| Browser policies generator | `scripts/lib/browser-policies-gen.py` |
| XDG mime-default applier | `scripts/lib/xdg-defaults.sh` |
| Setup-state (resume) | `scripts/lib/setup-state.sh` |
| End-of-run report | `scripts/lib/setup-report.sh` |
| Pin verification | `scripts/verify-pins.sh` |
| Pin refresh | `scripts/refresh-pins.sh` |
| Key refresh | `scripts/refresh-keys.sh` |
| Apt keyrings (managed) | `config/system/etc/apt/keyrings/` |
| Apt sources (managed) | `config/system/etc/apt/sources.list.d/` |
| Stale-pin audit (one-shot) | `scripts/audit.sh` |
| Stale-pin dashboard (live) | `config/conky/conky.conf` — `check_pins()` |
| End-to-end health probe | `scripts/dotfiles-doctor.sh` |

## Common gotchas

- `[[apps]]` entries are an **array of tables**. The `[[apps]]` line
  delimits one entry; every `[apps.something]` line after it belongs to
  that entry until the next `[[apps]]`.
- `machines = []` (empty array) installs nowhere. To install everywhere,
  use `["common"]`.
- `key_fingerprint` is UPPERCASE 40-hex with no spaces. The fingerprint
  GPG prints by default contains spaces — strip them.
- `sha256_aarch64 = ""` is the convention for "x86_64-only". Do not
  omit the key — `verify-pins.sh` checks for its presence on github-release
  frozen entries.
- Hook commands run as the install user, not root. Use `sudo` inside the
  command when needed.
- A name collision across `[[apps]]` entries (or across multiple
  tier-split `*.toml` files in this directory) is a hard validator
  error — there is no precedence rule.
