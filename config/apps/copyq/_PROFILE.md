# copyq — privacy profile

CopyQ is a clipboard manager. By design it keeps every value the
clipboard has ever held; we narrow that exposure to the minimum that
still gives the user a useful "scroll back to that snippet"
experience.

## What this profile changes

| Knob | Setting | Why |
| --- | --- | --- |
| `General.maxitems` | `200` | Hard cap on history depth. Older items roll off; nothing accumulates forever. |
| `General.edit_ctrl_return` | `true` | Editing an item requires Ctrl+Return instead of plain Enter. Avoids destroying a useful history entry with one stray keystroke. |
| `General.disable_tray` | `false` | Keep the tray icon visible so the user has a glanceable "clipboard manager is recording" signal. |
| `History.ignored_window_titles` | `keepassxc;pinentry;Sign in;Sign Up;1Password;Bitwarden` | CopyQ ignores clipboard changes that originate from any window whose title contains one of these substrings. Stops password-manager paste payloads from being captured into history. |
| `Options.autostart` | `false` | The user opts in via their session, not via copyq itself. |
| `Options.check_for_updates` | `false` | apt manages the version. |

## What this profile does NOT do

- **No encryption-at-rest.** CopyQ supports an encrypted history via
  the `itemencrypted` plugin; we did not enable it here because
  configuring the master password is interactive. If you want
  encrypted history, enable the plugin in CopyQ's preferences
  (`Preferences → Plugins → Item Encryption`) and set a master
  passphrase.
- **No scripted clearing.** The clipboard is NOT auto-cleared on
  screen lock or after N seconds. For password-manager workflows,
  trust KeepassXC's built-in 10-second clear — and verify the
  `ignored_window_titles` filter is doing its job by checking that
  the most-recent KeepassXC paste does NOT appear in copyq history
  after the password manager's clear fires.

## Important caveat: exact key names

CopyQ has shipped several variants of the "ignore by window title"
feature across versions. The key set here is the legacy
`History.ignored_window_titles`. If you see a Plasma / Wayland session
NOT filtering as expected:

1. Open the in-app `Preferences → History → Tabs` and verify the
   "Ignored windows" list shows the same entries.
2. If the in-app list is empty, the key may have moved to
   `Plugins\itemencrypted\password_window_titles` (newer builds).
   Set the same substrings there and rerun.

The intent is documented here so a future copyq version that renames
the key can be re-tracked in one place.

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
