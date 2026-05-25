# pass + gpg — privacy/hardening profile

`pass` is the de facto Unix password manager — flat per-secret gpg-encrypted
text files under `~/.password-store/`.  `gopass` is the Go reimplementation
that reads the same on-disk layout.  Both delegate the crypto to GnuPG, so
the meaningful hardening lives in `~/.gnupg/gpg.conf` and
`~/.gnupg/gpg-agent.conf`.

This profile ships two files:

| File | Dest | Mode | Overlay |
|---|---|---|---|
| `gpg.conf` | `~/.gnupg/gpg.conf` | `0600` | `false` |
| `gpg-agent.conf` | `~/.gnupg/gpg-agent.conf` | `0600` | `false` |

Both are NON-overlay — we want every machine running identical crypto policy
so a leak from the weakest machine isn't the limit on the others.

## gpg.conf — what's set and why

### Algorithm preferences
- `cert-digest-algo SHA512` — when you sign someone else's key, the digest is SHA-512.
- `personal-cipher-preferences AES256 AES192 AES` — symmetric cipher preference; AES-256 first.
- `personal-digest-preferences SHA512 SHA384 SHA256` — never SHA-1.
- `default-preference-list …` — preferences embedded in new keys; tells future peers what to use when communicating WITH you.
- `disable-cipher-algo 3DES` — refuse 3DES even if a peer's preference list includes it.
- `weak-digest SHA1` — treat SHA-1 signatures as untrusted.

### S2K (passphrase → key)
- `s2k-digest-algo SHA512`, `s2k-cipher-algo AES256`, `s2k-count 65011712` — slows brute force against a stolen `~/.gnupg/private-keys-v1.d/`.  The iteration count is the GnuPG max.

### Display + sanitisation
- `keyid-format 0xlong` + `with-fingerprint` + `list-options show-uid-validity` — long key-IDs and visible UID validity prevent short-ID collision attacks.
- `no-emit-version`, `no-comments` — strips a fingerprintable line from every armored signature.

### Keyserver
- `keyserver hkps://keys.openpgp.org` — modern validating keyserver.  SKS pool is permanently dead.
- `keyserver-options no-honor-keyserver-url` — refuse to follow a key packet's embedded "go look me up here" URL.  That's an active dial-home / fingerprinting vector.

## gpg-agent.conf — what's set and why

- `default-cache-ttl 600` / `max-cache-ttl 7200` — 10 minutes after last use; absolute ceiling 2 hours.  Same trade-off as KeePassXC's 5-minute idle lock.
- `pinentry-program /usr/bin/pinentry` — Debian's `update-alternatives` dispatcher.  Picks `pinentry-gnome3` / `pinentry-qt5` / `pinentry-curses` per session automatically.  Hard-coding a specific frontend would break on the OTHER desktop profile.

## How to override

Both files are `overlay = false`, so the per-machine overlay mechanism is
intentionally DISABLED for this app.  To diverge:

1. Edit `config/apps/apps.toml` for the local checkout and drop the entry under `[apps.configs]` (or flip `overlay = true` if you really want machine-local crypto policy — generally a bad idea).
2. Edit `~/.gnupg/gpg.conf` directly after apply.  The deploy step won't overwrite it unless `apps-cli.sh apply --force` is invoked.

## Why no `pass` config knobs?

`pass` itself has almost no configuration — it reads `PASSWORD_STORE_DIR`,
`PASSWORD_STORE_KEY`, `PASSWORD_STORE_CLIP_TIME` from the environment, and
that's about it.  Put those in your shell's RC instead of trying to write
a `passrc`.
