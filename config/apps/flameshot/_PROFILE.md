# flameshot — privacy profile (i3 only)

Flameshot is the i3 screenshot capture tool. By default it ships with
a one-click "upload to Imgur" button that this profile does NOT
disable (Imgur uploads still require an explicit user click in the
annotation toolbar), but everything else is tightened to local-save
behavior.

## What this profile changes

| Knob | Setting | Why |
| --- | --- | --- |
| `General.showStartupLaunchMessage` | `false` | Don't pop a "Flameshot started" banner every login. |
| `General.checkForUpdates` | `false` | Suppress in-app update checks — apt owns the version. |
| `Updates.updatesCheckEnabled` | `false` | Belt-and-braces; some builds honor this key but not the above. |
| `General.saveAfterCopy` | `true` | After the user copies a region to clipboard, also drop a PNG to disk. |
| `General.saveAsFileExtension` | `png` | Lossless local format. |
| `General.savePathFixed` | `true` | Don't keep an MRU of save paths in the config. |
| `General.allowMultipleGuiInstances` | `false` | One flameshot instance per session — avoids double-screenshot races. |
| `General.useGrimAdapter` | `false` | Force the native X11 capture path; we're an i3-only profile so wlroots/grim isn't needed. |

## What this profile does NOT do

- **Imgur upload is still available** from the annotation toolbar. If
  you want to disable the upload button entirely, recompile flameshot
  with `-DUSE_IMGUR=OFF`. We don't ship a patched build.
- **No OCR.** Flameshot has an OCR feature in newer builds; it's not
  in apt's version yet. When it lands, this profile should set
  `General.ocrLanguages=""` to avoid downloading language models.

## Reset

```sh
rm ~/.config/flameshot/flameshot.ini
scripts/apps-cli.sh apply --app flameshot
```

## See also

- Upstream: <https://flameshot.org/>
- KDE / plasma sessions use `kde-spectacle` instead — see
  `config/apps/spectacle/`.
