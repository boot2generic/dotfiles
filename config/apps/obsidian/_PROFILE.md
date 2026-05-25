# Obsidian profile

## Status

Obsidian replaced Joplin as the Tier 4 notes editor on 2026-05-24.
Rationale: vaults are folders of plain `.md` files (no proprietary
format), pairing cleanly with the dotfiles' existing Syncthing entry
for cross-machine sync without needing Obsidian's paid Sync service.

The tradeoff is the binary itself is proprietary (no AGPL like Joplin),
but the storage format is open — if Obsidian ever turns evil, your
vault is portable to vim, VSCodium, Joplin, or anything else that
reads markdown.

## What ships

- AppImage at `/usr/local/bin/obsidian.AppImage` (the github-release adapter
  installs this from `obsidianmd/obsidian-releases`)
- Symlink at `/usr/local/bin/obsidian` (via post_install hook) so you
  can run `obsidian` from the shell without typing the `.AppImage`
  suffix
- NO per-vault config — Obsidian creates `<vault>/.obsidian/` on first
  launch.  The privacy hardening is a one-time setting tweak you do
  through Settings > About + Settings > Community plugins.

## First-launch checklist (privacy + security hardening)

After running `apps install --app obsidian`, launch it once and apply
these:

1. **Choose vault location**: pick a folder that's syncable. The
   intended setup is a folder under your Syncthing share so the vault
   syncs across machines automatically.  Avoid putting the vault under
   `~/.config/` — that gets per-machine treatment.

2. **Settings > General > Automatic updates**: turn OFF.  apt manages
   updates via the dotfiles' `apps refresh` flow.

3. **Settings > About > Help us improve Obsidian**: confirm OFF
   (default).  Obsidian doesn't telemeter by default but make sure.

4. **Settings > Community plugins > Restricted Mode**: leave ON.  This
   blocks all community plugins by default; you must explicitly opt
   each one in.  Community plugins are arbitrary JavaScript loaded
   into your editor — treat them like browser extensions, with the
   same audit discipline.  See the "Plugin hygiene" section below.

5. **Settings > Editor > Default view mode for new tabs**: pick "Live
   Preview" or "Source" (avoid "Reading" — it disables editing on tab
   open which gets confusing fast).

6. **Settings > Files & Links > Confirm file deletion**: ON.

7. **Settings > Hotkeys**: optional — set "Open in default app" and
   "Show in system explorer" to keys you'll remember.  Vimium-style
   navigation is via the community Vim plugin (opt in after audit).

## Sync workflow (Syncthing)

The dotfiles' Tier 4 already ships syncthing (apt-pinned-repo from
apt.syncthing.net, pinned `FBA2E162F2F44657B38F0309E5665F9BD5970C47`).
The recommended cross-machine workflow:

1. Pick a path for your vault — e.g. `~/Notes/main-vault/`.
2. In Syncthing's web UI (`http://localhost:8384`), add that folder.
3. On the other machine, accept the share invitation, point it at the
   same path.
4. Open Obsidian on each machine, "Open folder as vault" → select the
   Syncthing-synced path.
5. Edits propagate via Syncthing.  Obsidian re-reads the file on
   focus, so changes appear when you switch back to the app.

Conflicts are extremely rare with note-taking workflows (you're
typically only editing on one machine at a time), but Syncthing
preserves conflicts as `*.sync-conflict-<timestamp>-<peer>.md` files
in the same folder if they happen.  Diff-and-merge manually.

## E2EE at rest

Obsidian's free tier has no built-in vault encryption.  Two options:

- **LUKS**: your disk is already LUKS-encrypted, so the vault is
  encrypted at rest by definition.  This is the dotfiles' baseline
  threat model.
- **Per-vault encryption** via the Meld Encrypt community plugin (or
  similar).  Adds friction; useful only if you sync the vault to a
  non-trusted backend.

The Syncthing wire is already TLS-encrypted by default, so transit
between your machines is covered without any extra work.

## Plugin hygiene

Community plugins are the main risk surface.  Default rules:

- **Stay in Restricted Mode** unless you need a specific plugin.
- When enabling one: read the plugin's GitHub repo first.  Look for
  recent activity, issue tracker, and ANY review of the plugin code.
- Prefer plugins from well-known maintainers (Obsidian's curated list
  at https://obsidian.md/plugins).
- Disable plugins you don't actively use — they load JavaScript into
  your editor on every launch.

## Supply-chain note (track-latest mode)

The `obsidian` entry runs in `pin.mode = "track-latest"` by default —
the install adapter resolves the latest tag from GitHub on each
install and downloads the AppImage over HTTPS.  Obsidian does NOT
GPG-sign its releases, so HTTPS is the only integrity check.

Recommended workflow:

1. Install once with `track-latest` so you get the current version.
2. Lock the install with `./scripts/apps-cli.sh freeze --app obsidian`.
   This rewrites the manifest with the exact version + SHA-256 of
   what just installed.
3. Refresh quarterly via `./scripts/apps-cli.sh refresh --app obsidian`
   — that fetches the latest tag's SHA-256, lets you review the diff
   (version bump only — no version-rewrite without your hand on it),
   then commit.
