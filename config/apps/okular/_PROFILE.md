# okular — privacy profile (plasma only)

Okular is KDE's PDF / EPUB / DjVu / DVI viewer. This profile narrows
its already-modest attack surface around PDFs that contain
JavaScript, embedded forms, and remote URIs.

## What this profile changes

| Section / Key | Setting | Why |
| --- | --- | --- |
| `[PageView] ChkEnableJavaScriptForms` | `false` | **Load-bearing.** Disables PDF JavaScript execution. PDF/JS is a real attack surface; disabling it costs nothing for normal docs. |
| `[Performance] ChkEnableJavaScriptForms` | `false` | Belt-and-braces: some okular builds read this key from `[Performance]` instead of `[PageView]`. |
| `[PageView] EnableFormCalculatePrintField` | `false` | Prevents automatic field-calculation scripts from firing at print time. |
| `[Dlg Performance] MemoryLevel` | `1` | Low-memory rendering profile — caps the per-page bitmap cache so a malicious oversize PDF can't OOM the session. |
| `[General] SendCrashReports` | `false` | Disables drkonqi auto-upload of crash dumps. |
| `[Dlg Annotations] AuthorName` | `Reader` | Annotation author is a generic literal, not the user's real name. **Override locally** if you need attribution. |
| `[Dlg General] ShowTipsOnStartup` | `false` | Suppress the splash. |

## What this profile does NOT do

- **No remote URI / GoToR blocking.** Okular prompts on every remote
  link, which is the right UX — leave that prompt enabled.
- **No print-to-file lockdown.** Print dialogs go through CUPS; we
  don't touch that.

## Important caveat: exact key names

KDE's settings names have shifted across major versions. The set
above matches Okular 24.x (KF6 / Qt6). If a future Plasma upgrade
silently renames `ChkEnableJavaScriptForms`:

1. Open Okular → `Settings → Configure Okular → Performance` and
   confirm "Enable JavaScript actions" is OFF.
2. Search `~/.config/okularpartrc` after toggling it via the GUI;
   whatever key Okular wrote out is the new name.
3. Update this file + this doc in one commit.

The repo-tracked baseline is documentary as much as it is functional
— the GUI is the source of truth for what's actually applied.

## Reset

```sh
rm ~/.config/okularpartrc ~/.config/okularrc
scripts/apps-cli.sh apply --app okular
```

## See also

- Upstream: <https://okular.kde.org/>
- The i3 alternatives ship at `config/apps/mupdf/_PROFILE.md` (CLI)
  and `config/apps/zathura/_PROFILE.md` (keyboard-driven).
