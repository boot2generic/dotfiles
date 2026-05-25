# Apps subsystem — manifest-driven third-party installs

The dotfiles install ~27 third-party applications outside the base OS suite
(password managers, browsers, editors, mail clients, screenshot tools, …).
Each one is described by a single TOML entry in
[`config/apps/apps.toml`](../config/apps/apps.toml); a CLI dispatcher
([`scripts/apps-cli.sh`](../scripts/apps-cli.sh)) reads the manifest,
validates it, resolves the active machine profile, and shells out to one
of four install-method adapters.

Why a manifest layer at all (vs. a pile of `apt install` lines in
`local_setup.sh`)? Three reasons:

- **Trust uniformity** — every app rides one of four documented trust
  paths (apt → apt-pinned-repo → github-release → direct-deb) instead of
  bespoke `curl | sh` scripts. GPG fingerprints + SHA-256 hashes are
  pinned in-repo and verified before anything lands on disk.
- **Auditability** — what's installed (the manifest), what's actually on
  disk (the per-app lockfile at `config/apps/.locks/<name>.lock`), and
  what was last reviewed (`pin.last_refreshed`) are three separate
  records you can diff.
- **Lifecycle commands** — `apps-cli.sh` exposes the same `validate /
  install / freeze / unfreeze / refresh / verify / remove` subcommands
  for every app, regardless of install method.

---

## At a glance

```
config/apps/
├── apps.toml             ← single source of truth (27 [[apps]] entries)
├── schema.toml           ← field-by-field reference
├── schema.example.toml   ← worked example per method + pin mode
├── README.md             ← dev guide (add/remove an app, files-to-modify table)
├── <name>/               ← optional per-app config sources referenced by [apps.configs]
└── .locks/<name>.lock    ← per-app lockfile sidecar (what was actually installed)
```

```sh
./scripts/apps-cli.sh validate            # hard gate — every mutating cmd runs this first
./scripts/apps-cli.sh list                # NAME / METHOD / TIER / PIN-MODE / VERSION / INSTALLED
./scripts/apps-cli.sh install             # install everything that matches the profile
./scripts/apps-cli.sh install --tier 1    # only privacy/sec daily-drivers
./scripts/apps-cli.sh install --app code --dry-run
./scripts/apps-cli.sh status  --app obsidian
./scripts/apps-cli.sh freeze  --app obsidian   # capture installed version → manifest pin
./scripts/apps-cli.sh unfreeze --app obsidian
./scripts/apps-cli.sh refresh --app obsidian   # re-fetch upstream, recompute sha, bump last_refreshed
./scripts/apps-cli.sh verify                   # re-hash on-disk artefacts, compare to lockfile + manifest
./scripts/apps-cli.sh remove  --app obsidian   # uninstall + drop lockfile (manifest entry retained)
```

The apps stage runs as **stage 3 of 5** inside `./local_setup.sh setup`
(install → deploy → **apps** → terminal → validate). Skip with
`--no-apps`; restrict to a subset of tiers with `--apps=tier1,tier4`;
walk the pipeline without installing with `--apps-dry-run`.

---

## Install methods + trust ordering

Four `install.method` values, ordered most → least trusted. Pick the
leftmost method that's available for a given app — `apt` whenever the
package is in Debian main, then `apt-pinned-repo` if upstream signs an
apt repo, then `github-release` for tagged release artefacts,
`direct-deb` only when nothing else is possible.

| Method | Trust anchor | Pin mode | Notes |
|---|---|---|---|
| `apt` | Debian release key | `track-latest` only | Implicit — apt validates Release file signatures. No manifest-side sha. |
| `apt-pinned-repo` | 40-hex GPG fingerprint in manifest | `track-latest` (or `frozen` as a "we audited this" marker) | Adds a third-party apt repo; the keyring + deb822 sources files ship in `config/system/etc/apt/`. Once registered, apt manages versions. |
| `github-release` | 64-hex sha256 in manifest + optional 40-hex `VALIDSIG` GPG | `frozen` recommended, `track-latest` allowed | Downloads a tagged release asset, sha-verifies, optionally GPG-verifies, drops on disk at `install_to`. |
| `direct-deb` | 64-hex sha256 in manifest | `frozen` only — track-latest forbidden by the validator | Downloads a vendor `.deb` over https, sha-verifies, `apt install ./file.deb`. No apt-style signing chain — use sparingly. |

The full per-pillar contract (apt repo signing, sha pinning, optional
GPG `VALIDSIG`) is documented in
[`security.md`](security.md) → "Application install supply chain".

### apt

```toml
[[apps]]
name = "mosh"
[apps.install]
method = "apt"
# Optional: package = "batcat" when the apt name differs from the
# manifest `name` (e.g. `bat` ships as `batcat` on Debian).
```

### apt-pinned-repo

```toml
[apps.install]
method = "apt-pinned-repo"

[apps.install.apt_pinned_repo]
package         = "mullvad-vpn"
suite_url       = "https://repository.mullvad.net/deb/stable"
suite           = "$(distro_codename)"     # substituted with `lsb_release -cs`
components      = ["main"]
key_url         = "https://repository.mullvad.net/deb/mullvad-keyring.asc"
key_fingerprint = "A1198702FC3E0A09A9AE5B75D5A1D4F266DE8DDF"  # 40-hex UPPERCASE
keyring_file    = "mullvad-keyring.asc"    # → config/system/etc/apt/keyrings/<file>
sources_file    = "mullvad.sources"        # → config/system/etc/apt/sources.list.d/<file>
```

Five apt-pinned repos ship today, with vendor public fingerprints
committed to `config/system/etc/apt/keyrings/`:

| App | Fingerprint |
|---|---|
| `mullvad-vpn` / `mullvad-browser` | `A1198702FC3E0A09A9AE5B75D5A1D4F266DE8DDF` |
| `signal-desktop` | `DBA36B5181D0C816F630E889D980A17457F6FB06` |
| `syncthing` | `FBA2E162F2F44657B38F0309E5665F9BD5970C47` |
| `vscodium` | `1302DE60231889FE1EBACADC54678CF75A278D9C` |
| `code` (Microsoft VSCode, opt-in) | `BC528686B50D79E339D3721CEB3E94ADBE1229CF` |

Key rotation is interactive, single-app, and routes through
`./scripts/refresh-keys.sh --app <name>` — see "Lifecycle commands"
below.

### github-release

```toml
[apps.install]
method = "github-release"

[apps.install.github_release]
repo            = "starship/starship"
asset_pattern   = "starship-{arch}-unknown-linux-gnu.tar.gz"   # {arch}=x86_64/aarch64
install_to      = "/usr/local/bin/starship"                    # absolute path
version         = "v1.25.1"                                    # required when frozen
sha256_x86_64   = "4488c11ca632327d1f1f16fb2f102c0646094c35479cd5435991385da43c61ac"
sha256_aarch64  = ""           # empty string = "x86_64-only" (do NOT omit the key)
gpg_fingerprint = ""           # empty string = no GPG check (e.g. starship doesn't sign)
extract_path    = "starship"   # rel path inside archive; "" for raw single-file assets
```

### direct-deb

```toml
[apps.install]
method = "direct-deb"
# Optional: package = "rage-musl" when the .deb's Package: field differs
# from the manifest `name` (rage upstream ships `rage-musl_…amd64.deb`).

[apps.install.direct_deb]
url     = "https://github.com/gopasspw/gopass/releases/download/v1.16.1/gopass_1.16.1_linux_amd64.deb"
sha256  = "c96b0e10813598799f2154f22456501ec190f45eaa7fead7beba21f17993a514"
version = "1.16.1"
```

direct-deb is **frozen-only** by contract — `pin.mode = "track-latest"`
is rejected by the validator. The only liveness check `refresh` can do
on a direct-deb entry is a HEAD on the pinned URL; the sha is the
trust anchor and the manifest IS the audit record.

---

## Pin modes — `track-latest` vs `frozen`

Every entry carries an `[apps.pin]` block. Two modes:

### track-latest

```toml
[apps.pin]
mode               = "track-latest"
last_refreshed     = "2026-05-23"   # ISO-8601; "I audited this on date X"
refresh_after_days = 90             # default 90; flags as stale after this
```

- No manifest-side version or sha pin.
- The dispatcher defers to apt (or the upstream channel) for version
  selection. The lockfile records what was actually installed.
- Legal **only** for `method ∈ {apt, apt-pinned-repo}`.
- `last_refreshed` is optional but strongly recommended.

### frozen

```toml
[apps.pin]
mode               = "frozen"
last_refreshed     = "2026-05-19"
refresh_after_days = 30
```

- Manifest carries a hard pin (version + sha256). The installer refuses
  on hash mismatch.
- **Required** for `direct-deb`.
- Recommended for `github-release` (the supply-chain audit lives in the
  manifest diff).
- Permitted for `apt-pinned-repo` as a documentation-only marker
  (apt still manages the actual version).
- Mandatory companion fields:
  - `pin.last_refreshed` (ISO-8601 date)
  - `github-release`: `version` + `sha256_x86_64`
  - `direct-deb`: `version` + `sha256`

The `apps-cli.sh freeze --app <name>` subcommand flips a track-latest
entry to frozen and copies the lockfile's installed version + sha into
the manifest's pin block. `apps-cli.sh unfreeze --app <name>` reverses
it (REFUSES on direct-deb — frozen-only by contract).

---

## Lockfile sidecars — `config/apps/.locks/<name>.lock`

Every successful install writes a TOML lockfile. The lockfile records
what's actually on disk **now**; the manifest records what the repo
wants.

```toml
schema_version = 1

[lock]
name              = "starship"
install_method    = "github-release"
installed_at      = "2026-05-23T14:30:00Z"
installed_version = "v1.25.1"
installed_sha256  = "<64-hex>"
install_path      = "/usr/local/bin/starship"
verified_by       = "sha256"           # or "apt-archive", "gpg+sha256", "direct-deb-sha256"
manifest_pin_mode = "frozen"
```

Optional-per-method fields land as empty strings rather than being
omitted (keeps the schema uniform for any downstream parser). The
`apps-cli.sh status --app <name>` subcommand prints a three-block
report (manifest entry / lockfile / live state) that's the right
starting point for any "what's actually installed" question.

The `.locks/` directory is owner-only (mode 0700) to prevent another
local user from pre-positioning a crafted lockfile under the assumption
that `freeze` will trust it; freeze additionally re-validates the
lockfile-supplied values (64-hex sha, sane version regex) before
copying them into apps.toml.

---

## Lifecycle commands — `scripts/apps-cli.sh`

Top-level dispatcher. Every mutating subcommand runs the validator as a
pre-flight gate.

| Subcommand | Behaviour |
|---|---|
| `validate [--app NAME]` | Hard-gate validator. Exit 0 clean, 1 errors, 2 warnings-only. Every mutating subcommand runs this first. |
| `list [--tier N]` | Table: NAME / METHOD / TIER / PIN-MODE / VERSION / INSTALLED. `--tier` filters to one or more comma-separated tiers (`--tier 1,4`). |
| `install [--tier N] [--app NAME] [--dry-run]` | Forwards to `scripts/install-apps.sh`. Resolves the machine profile (`common`/`t14`/`desktop`/`i3`/`plasma`), installs every app whose `machines` list intersects. Ensures `jq` is on PATH first (each adapter needs it). |
| `status --app NAME` | Three blocks: manifest entry, lockfile contents, live state (dpkg-query for apt/.deb methods; sha + size for github-release files). Human inspector — output goes to stdout. |
| `freeze --app NAME` | Read the lockfile, set `pin.mode = "frozen"`, copy `installed_version` + `installed_sha256` into the manifest's pin block. Refuses with empty version. apt methods: informational only (no `last_refreshed` bump — that's owned by `refresh`). |
| `unfreeze --app NAME` | Flip `pin.mode → "track-latest"`. github-release: clears `version` + `sha256_x86_64` + `sha256_aarch64`. direct-deb: REFUSES (frozen-only by contract). |
| `refresh [--app NAME]` | Forwards to `scripts/refresh-pins.sh`. Per-method behaviour: `apt` skipped; `apt-pinned-repo` scoped `apt-get update` (bumps `last_refreshed` if Release verifies; logs CRITICAL on key rotation); `github-release` recomputes shas on tag drift; `direct-deb` does a HEAD liveness check only. Rewrites TOML in place; **never** auto-commits. |
| `verify [--app NAME]` | Forwards to `scripts/verify-pins.sh`. Exit 0 fresh / 1 stale / 2 bad / 3 typo. Read-only. |
| `remove --app NAME [--dry-run] [--yes]` | Method-aware uninstaller. apt/apt-pinned-repo/direct-deb → `apt-get remove`. github-release → `rm` the install path (allowlisted to `/usr/local/`, `/opt/`, `/usr/local/share/`; canonical path re-checked after `realpath -m` to defeat symlink shenanigans). Deletes the lockfile on success. Leaves the manifest entry — delete by hand. |

The manifest format-preserving rewrites (freeze / unfreeze) require
`python3-tomlkit`, already in `BASE_PACKAGES`. Naive `sed`/`awk` would
strip the hand-curated comments + section headers.

---

## Tier system

Optional integer 1-5 on each `[[apps]]` entry. `install-apps.sh --tier`
restricts the install set; entries with no `tier` field pass every
filter (treated as "no tier, always installed").

| Tier | Purpose | Examples (tier 1 → tier 4 today) |
|---|---|---|
| **1** | Core privacy + security daily-drivers | KeePassXC, pass, age/rage, Mullvad VPN, Mullvad Browser, Firefox ESR, Signal Desktop, gopass, mosh, libpam-yubico, yubikey-manager |
| **2** | Dev tooling | VSCodium, Microsoft VSCode (opt-in), starship, JetBrainsMono Nerd Font |
| **3** | Virtualization | (reserved — no entries today) |
| **4** | Work / productivity | Thunderbird, LibreOffice, Obsidian, aerc, CopyQ, Flameshot (i3), Spectacle (plasma), Okular (plasma), Zathura/MuPDF (i3), Syncthing |
| **5** | System hygiene (opt-in via `harden`) | (reserved) |

The tier is a filter, not a dependency graph — installing tier 1 in
isolation works (the apps don't require each other). Use
`./scripts/apps-cli.sh install --tier 1,4` to land just the
privacy + work set on a fresh box and skip the dev stack.

---

## Machine profiles

Resolved by `resolve_profile()` in `scripts/install-apps.sh`. An app
installs iff its `machines` list intersects the resolved set.

| Profile | Always present? | Detection signal |
|---|---|---|
| `common` | yes | unconditional |
| `t14` | when laptop | `/sys/class/dmi/id/chassis_type ∈ {8,9,10,14}` |
| `desktop` | when NVIDIA | `/proc/driver/nvidia/version` exists, or `lspci` reports `vga.*nvidia` |
| `i3` | when i3 session | `~/.config/dotfiles-state/desktop` (recorded by `local_setup.sh setup`), or `$XDG_CURRENT_DESKTOP`, or `pgrep -x i3` |
| `plasma` | when plasma session | as above (`pgrep -x plasmashell`) |

Several apps are desktop-scoped:

- `flameshot`, `mupdf`, `zathura` → `machines = ["i3"]`
- `spectacle`, `okular` → `machines = ["plasma"]`

A machine running both sessions across boots will accrue both stacks
over time; the installer is idempotent and only does work where state
has drifted.

---

## Per-machine overrides — `~/.config/dotfiles-local/apps.toml`

Anything you drop at `~/.config/dotfiles-local/apps.toml` is overlaid on
top of the repo's manifest at install time. Per-machine deviations that
don't belong in git (a development build pinned to a different sha, a
disabled-by-default app turned on for this box, an extra
`[[browser_extensions]]` entry) live here.

```toml
# ~/.config/dotfiles-local/apps.toml
schema_version = 2

# Override a single field on an existing entry — match by `name`.
[[apps]]
name    = "code"
enabled = true     # the repo ships enabled=false (VSCodium is default); flip on per machine

# Override the extension list on a browser policy.  Same `name`, replace
# the whole [[apps.browser_extensions]] array.
[[apps]]
name = "firefox-esr"

[[apps.browser_extensions]]
name     = "uBlock Origin"
guid     = "uBlock0@raymondhill.net"
amo_slug = "ublock-origin"
mode     = "force_installed"
# (drop the rest — your overlay defines the complete list)
```

The override file goes through the same validator gate — typos and
malformed entries fail fast. `enabled = false` on a per-machine override
turns an app off without deleting the entry from the in-repo manifest.

---

## Two browsers + opt-in MS VSCode pattern

The default browser stack ships two browsers:

- **Firefox ESR** (`tier=1`, `machines=["common"]`) — apt-backed. The
  `[[apps.browser_extensions]]` array drives six force-installed
  add-ons: uBlock Origin, KeePassXC-Browser, Privacy Badger, ClearURLs,
  LocalCDN, Multi-Account Containers. `policies.json` lands under
  `/etc/firefox-esr/policies/` and is regenerated from
  `config/apps/firefox-esr/policies.json.base` + the extension list via
  the `browser-policies-gen.py` pre-install hook.
- **Mullvad Browser** (`tier=1`, `machines=["common"]`) — apt-pinned-repo
  via Mullvad's signed apt repo. Carries a minimal extension set
  (uBlock + KeePassXC only) to preserve Mullvad's anonymity-set;
  policies land under `/usr/lib/mullvad-browser/distribution/` (where
  Mullvad's portable bundle reads them).

The editor stack ships two editors with an opt-in:

- **VSCodium** (`tier=2`, `enabled=true`) — FLOSS rebuild of VSCode.
  No Microsoft telemetry. Extensions resolve from Open VSX Registry;
  the `apps.hooks.post_install` runs `codium --install-extension` for
  each id in `config/apps/vscodium/extensions.txt`.
- **Microsoft VSCode** (`tier=2`, `enabled=false`) — opt-in only. Edit
  `apps.toml` (or a `~/.config/dotfiles-local/apps.toml` override), set
  `enabled = true`, run `./scripts/apps-cli.sh install --app code`.
  Carries the MS marketplace extensions (`ms-python.*`, `ms-toolsai.*`
  Jupyter, `ms-vscode-remote.*`, `github.copilot-chat`) that VSCodium
  can't install from Open VSX.

Both editors are in tier 2; either pick one via the `enabled` flag or
keep both side-by-side (their config trees don't collide).

---

## Add an app (5 steps)

1. **Pick a canonical `name`.** kebab-case, ≤64 chars, unique across the
   manifest. For apt apps this is typically the apt package name; for
   github-release apps it's the binary's name on `$PATH`.
2. **Identify the closest example** in `config/apps/schema.example.toml`
   — match install method + pin mode.
3. **Append a `[[apps]]` block to `config/apps/apps.toml`** under the
   right method-group section header (apt → apt-pinned-repo →
   github-release → direct-deb, alphabetical within a group). Fill in
   `name`, `display_name`, `tier`, `machines`, `description`, `docs_url`,
   the `[apps.install]` subtable, and `[apps.pin]`.
4. **Ship config files (optional).** Drop them under
   `config/apps/<name>/` and reference them from `[apps.configs]` with
   relative `source =` paths. `overlay = true` lets per-machine
   overrides layer on top via `~/.config/dotfiles-local/<name>/`.
5. **Validate + dry-run + install:**

   ```sh
   ./scripts/apps-cli.sh validate
   ./scripts/apps-cli.sh list --tier <tier>
   ./scripts/apps-cli.sh install --app <name> --dry-run
   ./scripts/apps-cli.sh install --app <name>
   ```

Apt-pinned-repo entries additionally need a tracked keyring at
`config/system/etc/apt/keyrings/<keyring_file>` and a deb822 sources
file at `config/system/etc/apt/sources.list.d/<sources_file>` — both
filenames declared in the manifest.

---

## Remove an app (3 steps)

1. **Uninstall + drop the lockfile:**

   ```sh
   ./scripts/apps-cli.sh remove --app <name>
   ```

   This handles the OS-level uninstall (`apt-get remove` for the three
   apt methods; allowlisted `rm` for github-release) and deletes
   `config/apps/.locks/<name>.lock`.

2. **Delete the `[[apps]]` stanza from `config/apps/apps.toml`** and the
   matching `config/apps/<name>/` subdirectory if any. (`remove` leaves
   the entry — soft-disable via `enabled = false` if you want to keep
   the manifest history.)

3. **Apt-pinned-repo only:** drop the keyring + sources files under
   `config/system/etc/apt/{keyrings,sources.list.d}/` and the matching
   `key_fingerprint` reference in any documentation. `./local_setup.sh
   deploy` no longer needs to maintain them.

The validator catches dangling references — a stale `[apps.configs]
source` pointing at a deleted file fails validate; a deleted manifest
entry whose lockfile + keyring + sources remain is fine but cosmetically
untidy.

---

## Recent fixes worth knowing

- **`jq` in `BASE_PACKAGES`.** Every `scripts/install-methods/*.sh`
  adapter shells out to jq to parse the manifest JSON the dispatcher
  hands it. jq used to live behind the apps stage entry point but had a
  bootstrap-order problem (the very first install run, on a fresh box,
  had no jq yet — every adapter exited with a confusing "jq-missing"
  skipped_reason). It now lands as part of stage 1, alongside the other
  shell tools, so stage 3's apps install can rely on it. The `apps-cli`
  preflight also re-checks and `sudo apt-get install -y jq` on demand
  when invoked outside the setup flow.
- **`python3-tomlkit` in `BASE_PACKAGES`.** Format-preserving TOML
  writes for `freeze` / `unfreeze` / `refresh-pins.sh` need tomlkit
  (naive sed/awk would strip the manifest's hand-curated comments and
  section headers). Lands alongside jq in `BASE_PACKAGES`.
- **gopass + rage migrated to `direct-deb`.** Both packages were removed
  from Debian trixie (gopass in the bookworm → trixie transition; rage
  exists only in sid/experimental). The manifest entries now point at
  upstream GitHub release `.deb` artefacts with `pin.mode = "frozen"` and
  sha-pinned 64-hex hashes. The next pin refresh is a
  `./scripts/apps-cli.sh refresh --app gopass` followed by a manual
  TOML edit of `url` + `sha256` + `version` when upstream cuts a new
  release.
- **`polkit-kde-agent-1` dpkg check.** Plasma path adds this dependency
  explicitly so sudo prompts inside graphical sessions actually surface
  a Plasma password dialog (some Plasma upgrades drop the dep
  silently). Verified in the validate phase.
- **Obsidian replacing Joplin.** Obsidian's plain-`.md` vault format
  pairs cleanly with Syncthing (vault path → another machine), where
  Joplin's encrypted-blob storage doesn't. AppImage from GitHub
  releases with a post-install hook that drops a `/usr/local/bin/obsidian
  → obsidian.AppImage` symlink. Recommended workflow: install once with
  `track-latest`, then `apps-cli.sh freeze --app obsidian` to lock the
  install to the verified version + sha.

---

## Where each part of the install flow lives

| Concern | File |
|---|---|
| Primary manifest | `config/apps/apps.toml` |
| Manifest schema reference | `config/apps/schema.toml` |
| Worked example | `config/apps/schema.example.toml` |
| Per-app source files (for `[apps.configs]`) | `config/apps/<name>/` |
| Per-app lockfile sidecar | `config/apps/.locks/<name>.lock` |
| CLI dispatcher | `scripts/apps-cli.sh` |
| Per-stage installer | `scripts/install-apps.sh` |
| Validator | `scripts/apps-validate.py` |
| Method adapters | `scripts/install-methods/{apt,apt-pinned-repo,github-release,direct-deb}.sh` |
| Pin verification | `scripts/verify-pins.sh` |
| Pin refresh (TOML edits in place) | `scripts/refresh-pins.sh` |
| Key refresh (interactive, single-app) | `scripts/refresh-keys.sh` |
| Lockfile helpers | `scripts/lib/lockfile.sh` |
| Browser policies generator | `scripts/lib/browser-policies-gen.py` |
| Apt keyrings (managed) | `config/system/etc/apt/keyrings/` |
| Apt sources (managed) | `config/system/etc/apt/sources.list.d/` |
| Stale-pin audit (one-shot) | `scripts/audit.sh` → `pins` baseline row |
| Stale-pin live dashboard | `config/conky/health.py` → `check_pins()` |
| End-to-end health probe | `scripts/dotfiles-doctor.sh` → SUPPLY CHAIN section |
| Setup stage orchestration | `local_setup.sh apps_install_phase()` (stage 3 of 5) |

See [`config/apps/README.md`](../config/apps/README.md) for the
dev-facing companion (add/remove gotchas, name-uniqueness rule, the
files-to-modify checklist).
