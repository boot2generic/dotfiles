# copyq — privacy profile

CopyQ is a clipboard manager. By design it keeps every value the
clipboard has ever held — including KeePassXC passwords, GPG/SSH
passphrases, and OTP codes. This profile's stance: **do not auto-store
the clipboard at all.** No history is kept, so nothing can leak.

## Why no filtering, just no storing

The obvious-looking fix — "ignore clipboard changes from KeePassXC and
other password-manager windows" — does not work reliably:

- The `ignored_window_titles` key that earlier versions of this profile
  set is **not a real CopyQ option**. The running daemon rejects it
  (`copyq config ignored_window_titles` → `Invalid option`), so it was
  a silent no-op and every password copied while it was in place was
  captured into history.
- The proper window-title approach (a CopyQ Command matching the source
  window) is **unreliable on Wayland**: KWin generally does not expose
  the source window title to the clipboard monitor, so the match fails
  and the secret is captured anyway.
- KeePassXC's 10-second clipboard auto-clear does **not** help — CopyQ
  grabs the value the instant it's copied, long before the clear fires.

A filter that silently fails is worse than no filter. So we disable
capture outright.

## What this profile changes

| Knob | Setting | Why |
| --- | --- | --- |
| `General.check_clipboard` | `false` | **The key setting.** CopyQ does not monitor or store the clipboard. No capture ⇒ no leak. Copy/paste still works at the OS level. |
| `General.check_selection` | `false` | Same for the X11 primary selection. |
| `General.maxitems` | `200` | History depth cap — only relevant if you re-enable storing. |
| `General.edit_ctrl_return` | `true` | Editing an item requires Ctrl+Return, not plain Enter. |
| `General.disable_tray` | `false` | Keep the tray icon visible. |
| `General.hide_main_window_in_task_bar` | `true` | Correct key (note the underscore); the no-underscore spelling is an Invalid option. |
| `Options.autostart` | `false` | The user opts in via their session, not via copyq itself. |
| `Options.check_for_updates` | `false` | apt manages the version. |

## Verifying it's safe

```sh
copyq config check_clipboard      # must print: false
printf SECRET | wl-copy           # (or xclip -selection clipboard) on X11
copyq count                       # must stay 0 — nothing captured
```

## If you want history back (accepting the risk)

Set `check_clipboard=true`. Understand that passwords copied from any
app **will** be stored in plaintext under `~/.config/copyq/`. If you go
this route, also enable encryption-at-rest via the `itemencrypted`
plugin (`Preferences → Plugins → Item Encryption`, set a master
passphrase) — though that still won't keep secrets out of the unencrypted
default tab unless you route them carefully.

## Reset

```sh
rm ~/.config/copyq/copyq.conf
scripts/apps-cli.sh apply --app copyq
```

## Overriding

Drop your own `copyq.conf` at
`~/.config/dotfiles-local/copyq/copyq.conf` to override the
repo-tracked baseline. Overlay is on by default for this app.

## See also

- Upstream docs: <https://hluk.github.io/CopyQ/>
- KeepassXC clipboard-clear setting:
  `Settings → General → Clipboard Auto-Clear → 10 seconds`
