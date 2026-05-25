# KeePassXC — privacy profile

Deployed to `${HOME}/.config/keepassxc/keepassxc.ini` (mode `0600`,
`overlay = true` so a per-machine override in
`~/.config/dotfiles-local/keepassxc/keepassxc.ini` takes precedence).

## What this profile sets and why

| Section / Key | Value | Why |
|---|---|---|
| `General/RememberLastDatabases` | `false` | The "recent databases" menu reveals the on-disk path to every vault you opened on this machine.  Anyone with shoulder-surfing or `find` access to your home dir can already enumerate `.kdbx` files, but the menu makes it a one-click leak. |
| `General/OpenPreviousDatabasesOnStartup` | `false` | Auto-opening the last database silently prompts for the master password every login — both a UX wart (every reboot pops a modal) and a phishing target (a fake KeePassXC dialog would be the obvious next attack). |
| `General/MinimizeAfterUnlock` | `false` | Default is true upstream — feels neat but it hides the unlocked window, so the user forgets the database is open and walks away with the clipboard live. |
| `GUI/CheckForUpdates` | `false` | apt manages the package on Debian; the built-in updater phones home to keepassxc.org on every launch and ends up offering downloads it can't actually install. |
| `Security/LockDatabaseIdle{,Seconds}` | `true` / `300` | 5-minute idle auto-lock.  Tradeoff between "annoying to re-enter the master password" and "leaving the vault open while you go make coffee". |
| `Security/LockDatabaseMinimize` | `true` | Lock the moment the user minimises — they no longer want it visible, so they probably don't want it accessible either. |
| `Security/LockDatabaseScreenLock` | `true` | Lock when the screen locks (loginctl / xss-lock).  Defence in depth — the session lock already gates everything, but a KeePassXC-specific lock means a leaked screen capture or a rogue process inside the same X session still can't pull plaintext from the unlocked database. |
| `Security/ClearClipboard{,Timeout}` | `true` / `10` | 10 s clipboard wipe after auto-fill.  Long enough to paste once, short enough that the next clipboard manager / X selection poll loses the secret. |
| `Security/ClearSearch{,Timeout}` | `true` / `5` | Clear the search box when the database locks — search terms can be sensitive ("aws prod root"). |
| `Security/IconDownloadFallback` | `false` | Disables HTTP icon fetching from each entry's URL field — every database open would otherwise emit a burst of DNS lookups + HTTP fetches keyed to the user's stored URLs.  Pure tracking vector. |
| `Security/AutotypeAsk` | `true` | Confirm before auto-typing into the focused window.  Defends against the "swap the focused window between the user hitting Ctrl+Shift+V and KeePassXC starting to type" attack class. |
| `Browser/Enabled` | `false` | Off by default.  Turn on PER MACHINE if you actually use the KeePassXC-Browser extension; otherwise the native-messaging host is an idle attack surface. |
| `SSHAgent/Enabled` | `false` | Off by default.  Same rationale as Browser — turn on per-machine if you actually need it. |

## KDF (Argon2id) parameters

KeePassXC stores KDF parameters INSIDE each `.kdbx` database, not in this ini.
Pick them at database-creation time via Database Settings → Security → Encryption Settings:

- **Algorithm**: Argon2id (not Argon2d — Argon2id is what KeePassXC's current default and resistant to both side-channel and GPU-based attacks)
- **Memory**: 2 GiB (`2097152` KiB).  Use whatever fits comfortably on every machine that opens this database — 2 GiB matches the T14 + 3080Ti desktop spec sheet.
- **Transformations / iterations**: 5.  KeePassXC's "benchmark to 1-second decryption" button is the practical sweet spot if you'd rather auto-tune.
- **Parallelism**: 8 threads (or `nproc`).  Argon2 parallelism gates GPU attacks; matching the local thread count gives the best per-second cost.

## How to override

- Per-machine knob: drop overrides into `~/.config/dotfiles-local/keepassxc/keepassxc.ini`.  The deploy adapter merges this overlay on top of the repo copy when `overlay = true`.
- Disable the deploy entirely: edit `config/apps/apps.toml` for the local checkout and remove the entry under `[apps.configs]` for `keepassxc`.
- Reset to vanilla KeePassXC defaults: delete the file, re-launch KeePassXC, and it'll write a fresh ini with every key at its upstream default.
