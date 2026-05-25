# aerc — privacy profile

Aerc is a TUI mail client; this profile aims to keep it strictly local,
plaintext-first, and keystroke-driven so nothing leaks from the inbox
into network calls the user didn't initiate.

## What this profile changes

| Knob | Setting | Why |
| --- | --- | --- |
| `ui.mouse-enabled` | `false` | Defeats accidental terminal clicks that could open tracker URLs or attachments. Keyboard-only navigation. |
| `viewer.pager` | `less -R` | Passes ANSI through but never renders HTML / images / remote content. |
| `viewer.parse-http-links` | `true` | Lets `:open-link` find URLs in plaintext bodies — the *user* triggers the open, not the renderer. |
| `compose.no-bcc` | `true` | Stops the client from silently bcc'ing the sender (the Sent IMAP folder already records outbound mail). |
| `filters.text/html` | `w3m … -dump` | Renders HTML as inert text — no JavaScript, no remote images, no fonts. |
| `filters.image/*` | `exit 0` | Inline images never resolve until the user explicitly invokes `:open` on the attachment. |
| `multipart-converters.text/plain` | `w3m -dump` | When a message offers both plaintext and HTML alternatives, we coerce to plaintext for display. |

## What this profile does NOT do

- **No accounts.conf** is shipped — that file contains per-user IMAP /
  SMTP credentials and is written manually after install. Aerc's
  built-in `:configure` wizard is the easy path; for IMAP with
  OAuth2 use `aerc-imap` + an `aerc-oauthbearer` helper.
- **No PGP keyring** is configured here. Aerc reads from the user's
  GnuPG keyring by default; install `gpg` + `gopass` and aerc will
  pick up signing keys automatically.
- **No notmuch / mbsync wiring**. If you want offline-first mail,
  install `notmuch` + `mbsync` separately and point aerc's account
  at the local maildir.

## Overriding

Drop the file you want to win at
`~/.config/dotfiles-local/aerc/aerc.conf` and the dispatcher's overlay
layer will use it instead of the repo-tracked source on the next
`apps-cli.sh apply` (overlay is enabled for this app — see the
`[apps.configs]` entry in `apps.toml`).

## Reset

```sh
rm ~/.config/aerc/aerc.conf
scripts/apps-cli.sh apply --app aerc
```

## See also

- Upstream config reference: <https://man.archlinux.org/man/aerc-config.5>
- The wider Tier-4 work-app set: `config/apps/{copyq,thunderbird,…}`.
