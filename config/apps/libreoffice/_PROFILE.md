# libreoffice — privacy profile

LibreOffice's privacy-relevant settings live in XML registry files
under `/etc/libreoffice/registry/data/` and in the per-user
`~/.config/libreoffice/4/user/registrymodifications.xcu`. Templating
the XML is doable but Phase C deliberately defers it — the registry
is sprawling and any error blocks LibreOffice from launching.

This `_PROFILE.md` documents the manual hardening steps to apply via
the LibreOffice GUI immediately after first launch. The same settings
can be applied with a configuration-management tool later when we
template the XML.

## After first launch, do this

Open any LibreOffice app (Writer is fine), then walk through
`Tools → Options …`:

### Telemetry & "improvement program"

- `LibreOffice → General`
  - **Send improvement data** → OFF (the "Help improve LibreOffice"
    checkbox).
  - **Open with previous documents on startup** → OFF (avoids
    leaking file paths into recents on shared machines).
- `LibreOffice → Online Update` *(absent on Debian's package — apt
  manages updates)*
  - **Check for updates automatically** → OFF (no-op if not present).

### Macros & untrusted documents

- `LibreOffice → Security`
  - **Macro Security…** → **High**. (Medium prompts; Low is wide
    open; Very High requires a signature.)
  - Click **Trusted Sources…** → ensure the list is EMPTY. Adding
    your own directories here is fine but the empty default is
    safest.
- `LibreOffice → Security → Macro Security → Trusted File Locations`
  → ensure list is EMPTY.

### Online services

- `Internet → Proxy` → set to **None** unless your network requires
  a proxy. Default of "System" is fine on most setups.
- `LibreOffice → Advanced` → ensure **Enable experimental features**
  is OFF.
- `LibreOffice → Personalization` → **Default look** (no Mozilla
  Firefox-themed wallpapers, which fetch from the network).

### Documents & save behavior

- `Load/Save → General`
  - **Always create backup copy** → ON.
  - **Save AutoRecovery information every** → 5 minutes.
- `LibreOffice → Security → Security Options and Warnings…`
  - **Remove personal information on saving** → ON. (Strips author
    name, save dates, comments, hidden tracked changes.)
  - **Warn when not saving in ODF or default format** → ON.
  - **Ctrl-click required to follow hyperlinks** → ON. (Prevents
    accidental click-fetches in viewed documents.)

### Calc — formula evaluation

- `LibreOffice Calc → Formula`
  - Under **Detailed calculation settings → Custom**, set
    **Conversion from text to number** to **Generate #VALUE! error**
    rather than `0`. (Catches mistakes that would otherwise silently
    produce wrong sheets.)

### Impress — slideshow

- `LibreOffice Impress → General`
  - **Presentation: New document → Use last selected slide size**
    → OFF. (Avoids leaking previous-doc metadata into new ones.)

## What this profile does NOT do

- **No `unoconv` / CLI scripting hardening.** If you batch-convert
  documents via `unoconv` or `libreoffice --headless --convert-to`,
  you inherit the macro-security setting from the GUI session — the
  CLI loads the same user profile.
- **No font hinting / Bookmarks / dictionaries setup.**

## Reset

LibreOffice's per-user profile lives at `~/.config/libreoffice/`.
Wipe it to start fresh:

```sh
rm -rf ~/.config/libreoffice
```

Re-launch LibreOffice and re-apply the steps above.

## See also

- Upstream security docs:
  <https://wiki.documentfoundation.org/Documentation/Administration/Security>
- Phase D / E plans: ship a templated
  `registrymodifications.xcu.in` and a small sed-based merger.
