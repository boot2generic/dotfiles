# mupdf — privacy profile (i3 only)

mupdf is a minimal PDF / XPS / e-book viewer. It has essentially no
config file (a few keys can be set via `$XDG_CONFIG_HOME/mupdf/mupdf.conf`
on recent builds but the defaults are already conservative); this
`_PROFILE.md` documents the **invocation** pattern we want.

## Recommended invocation

```sh
mupdf -J 0 <file.pdf>
```

The `-J 0` flag **disables JavaScript-in-PDF**. PDF can embed full
JS through Adobe's Acrobat extensions; mupdf supports a tiny subset
but the safest answer for arbitrary untrusted PDFs is to refuse to
run any of it.

## i3 binding

Add this to `~/.config/i3/config` (or the repo's `config/i3/config`)
so the file manager / dmenu opens PDFs in mupdf-no-JS by default:

```i3
bindsym $mod+p exec --no-startup-id \
  rofi -show file-browser-extended -file-browser-cmd "mupdf -J 0"
```

Or if you prefer xdg-open routing, drop this MIME hint at
`~/.local/share/applications/mupdf-no-js.desktop`:

```desktop
[Desktop Entry]
Type=Application
Name=mupdf (no JS)
Exec=mupdf -J 0 %f
MimeType=application/pdf;
NoDisplay=false
Terminal=false
```

…then make it the default with:

```sh
xdg-mime default mupdf-no-js.desktop application/pdf
```

## Other safety flags

| Flag | Effect |
| --- | --- |
| `-J 0` | Disable JavaScript in PDFs. |
| `-r <dpi>` | Render at fixed dpi instead of detected screen DPI; cosmetic. |
| `-S` | Disable any cache files under `~/.cache/mupdf/`; useful on shared machines. |
| `-T <off|on>` | Disable / enable the toolbar; UI taste. |

## What this profile does NOT do

- **No annotation / form fill.** mupdf is a *viewer*. For annotation
  use `xournalpp`; for form fill use `okular` (Plasma profile) or
  the LibreOffice Draw equivalent.
- **No remote-content rules.** PDF can declare external GoToR / URI
  actions. mupdf prompts before following any of them — leave that
  prompt enabled.

## Reset

mupdf has no per-user config file by default; clearing
`~/.cache/mupdf/` is the only state to wipe:

```sh
rm -rf ~/.cache/mupdf
```

## Override (per-machine)

mupdf does not have a config file deployed by this repo (the hardening
is invocation-driven via the `-J 0` flag). To diverge per-machine,
either:

- Edit your `~/.config/i3/config` binding (or your `xdg-mime` desktop
  entry under `~/.local/share/applications/`) to launch `mupdf`
  without `-J 0` when you trust the PDF source.
- Drop a tweaked `.desktop` under
  `~/.config/dotfiles-local/mupdf/` and reference it from your shell
  config; nothing in apps.toml ships an overlay for mupdf today.

## See also

- Upstream: <https://mupdf.com/>
- The Plasma alternative ships at `config/apps/okular/_PROFILE.md`.
- The "minimal keyboard-driven" alternative is `zathura`; we ship
  both on i3 since they fit different reading flows.
