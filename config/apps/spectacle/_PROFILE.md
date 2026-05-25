# spectacle — privacy profile (plasma only)

KDE Spectacle is the screenshot capture utility shipped with Plasma.
The apt package on Debian is named `kde-spectacle`. It has no
shipped privacy config in this repo because:

- The Plasma session already disables most "phone home" behaviors
  (`config/plasma/kdeglobals` covers `[KDE]` and `[General]` keys).
- Spectacle's defaults — local-save to `~/Pictures/Screenshots/`,
  no cloud upload — are already privacy-aligned.

## Notable defaults

| Behavior | Setting | Source |
| --- | --- | --- |
| Save format | PNG | Spectacle UI default. Lossless. |
| Save location | `~/Pictures/Screenshots/` | Spectacle UI default. |
| Auto-upload | OFF | Spectacle has no built-in cloud uploader (you can plug Imgur via KDE Purpose, but the user has to install that separately). |
| Update checks | OFF | apt manages versions. |

## Manual hardening (optional)

Open Spectacle → `Configure Spectacle…`:

- **Application** → **When Spectacle is running** → set to "Take a
  new screenshot, save and exit" if you want the post-capture window
  closed automatically (cuts the chance of an accidental upload via
  the in-window button).
- **Save** → **Default save location** → set explicitly to
  `~/Pictures/Screenshots/` (instead of "system pictures dir") so a
  user-renamed XDG dir doesn't surprise you later.
- **General** → uncheck **Use light background** unless you
  specifically need it.

## Override (per-machine)

Spectacle reads from `~/.config/spectaclerc`. This profile does not
deploy a managed file (the upstream defaults are already privacy-
aligned); per-machine tweaks happen through the GUI under
`Configure Spectacle…` and land in that same `spectaclerc`. There is
no `~/.config/dotfiles-local/spectacle/` overlay because there is
no repo-tracked baseline to override.

## i3 alternative

The flameshot profile is the i3 counterpart — see
`config/apps/flameshot/_PROFILE.md`.

## See also

- Upstream: <https://apps.kde.org/spectacle/>
- Plasma session settings: `config/plasma/kdeglobals`.
