#!/usr/bin/env bash
# config/plasma/cheatsheet.sh
#
# Renders a cheatsheet of OUR Plasma global shortcuts in a kdialog
# msgbox.  Bound to Meta+/ via a [services][cyberpunk-cheatsheet.desktop]
# _launch entry in kglobalshortcutsrc (mirrors the i3 idiom of
# bindsym $mod+slash for a help popup).
#
# The cheatsheet is GENERATED at runtime from ~/.config/kglobalshortcutsrc,
# so adding/changing a binding in the source-of-truth automatically
# updates the popup — no hand-maintained second list to drift.
#
# Fallback chain when kdialog isn't installed:
#   1. kdialog --msgbox  (preferred — themed Plasma popup)
#   2. zenity / yad      (occasional Plasma users keep one around)
#   3. plain stdout      (a terminal-printed table; useful when run
#                         from a TTY for debugging, or when no GUI
#                         dialog tool is available at all)
#
# Idempotent — re-running just reopens the popup.  No state written.

set -u

KGSRC="${HOME}/.config/kglobalshortcutsrc"

if [[ ! -r "$KGSRC" ]]; then
    echo "[!]  $KGSRC not found or unreadable — has the plasma deploy run?" >&2
    exit 2
fi

# ───────────────────────────────────────────────────────────────────
# Parse kglobalshortcutsrc.
#
# Format reminder (KDE Frameworks 6 / kglobalaccel):
#     [Section]
#     Action Name=primary,secondary,Friendly Description
#   The primary slot may contain a literal "\t" between alternates
#   when Plasma's GUI rewrites the file — we treat the first "\t"-
#   delimited token as the canonical primary for display purposes.
#
# We filter to a WHITELIST of the action names that we own (the ones
# present in config/plasma/kglobalshortcutsrc).  The live file at
# ~/.config/kglobalshortcutsrc is many hundreds of lines — every
# Plasma factory binding, plus the user's own additions — so a
# section-based filter like `[kwin] = include everything` would dump
# 100+ rows of Plasma defaults into the popup.  Whitelist keeps the
# cheatsheet to the bindings the cyberpunk dotfiles actually define.
#
# Adding a new binding to config/plasma/kglobalshortcutsrc?  Add the
# Action Name to the appropriate list below and the cheatsheet picks
# it up automatically — that's the "single source of truth" property
# we're protecting.
#
# Output of this awk: TSV "label<TAB>keys<TAB>description" lines.
# ───────────────────────────────────────────────────────────────────
rows="$(awk '
BEGIN {
    sec=""; svc=""; FS="="
    # KWin action names we ship.  Mirror config/plasma/kglobalshortcutsrc
    # [kwin] section verbatim — if you change one there, change it here.
    kwin_actions["Switch to Desktop 1"]=1
    kwin_actions["Switch to Desktop 2"]=1
    kwin_actions["Switch to Desktop 3"]=1
    kwin_actions["Switch to Desktop 4"]=1
    kwin_actions["Window to Desktop 1"]=1
    kwin_actions["Window to Desktop 2"]=1
    kwin_actions["Window to Desktop 3"]=1
    kwin_actions["Window to Desktop 4"]=1
    kwin_actions["Switch One Desktop to the Right"]=1
    kwin_actions["Switch One Desktop to the Left"]=1
    kwin_actions["Overview"]=1
    kwin_actions["Window Close"]=1
    # Services we ship — [services][<.desktop>][_launch].
    svc_actions["Alacritty.desktop"]=1
    svc_actions["cyberpunk-cheatsheet.desktop"]=1
}
# Section header.  Capture [kwin], and the two-level
# [services][<id>] heads that kglobalshortcutsrc uses.
/^\[/ {
    # Try [services][<id>] (two bracket pairs concatenated).
    if (match($0, /^\[services\]\[[^]]+\]$/)) {
        sec = "services"
        # Strip leading "[services][" (11 chars) and trailing "]" (1 char).
        svc = substr($0, 12, length($0) - 12)
        next
    }
    # Single [<name>] section.
    if (match($0, /^\[[^]]+\]$/)) {
        sec = substr($0, 2, length($0) - 2)
        svc = ""
    }
    next
}
# Skip blanks and comments.
/^[[:space:]]*(#|$)/ { next }
# Body line: "Action Name=primary,secondary,Friendly Description".
{
    name = $1
    rest = substr($0, length(name) + 2)         # everything after the first "="
    # Plasma KConfig file escaping: backslashes are stored doubled
    # ("\\") and keystroke commas inside the value are stored as "\,"
    # (and may be double-escaped to "\\,").  Sequence:
    #   1. Collapse "\\" → single "\" (unescape backslashes).
    #   2. Replace the now-singular "\," with a sentinel (so it
    #      survives the comma split below).
    #   3. Split on the field separator ",".
    #   4. Swap the sentinel back to "," in the resulting fields.
    gsub(/\\\\/, "\\", rest)
    gsub(/\\,/, "\x01", rest)
    n = split(rest, parts, ",")
    primary = (n >= 1) ? parts[1] : ""
    desc    = (n >= 3) ? parts[3] : name
    gsub(/\x01/, ",", primary)
    gsub(/\x01/, ",", desc)
    # Plasma writes alternate keys as "Meta+1\tCtrl+F1" with a literal
    # backslash-t inside the primary slot.  After the backslash
    # unescape above this looks like "Meta+1<TAB>Ctrl+F1" — show only
    # the canonical primary (up to the first tab).
    sub(/\t.*/, "", primary)
    sub(/\\t.*/, "", primary)
    # Filter: skip unbound + skip the conflict-resolver clears.
    if (primary == "" || primary == "none") next
    # Whitelist filter — ignore Plasma factory bindings.
    if (sec == "kwin") {
        if (!(name in kwin_actions)) next
        label = "KWin"
    } else if (sec == "services" && (svc in svc_actions)) {
        if (name != "_launch") next
        label = "Launch"
        # Use the service id as the description fallback — it''s
        # friendlier than "_launch".  Friendly description, when
        # present, still wins.
        if (n < 3 || parts[3] == "") desc = svc
    } else {
        next
    }
    printf("%s\t%s\t%s\n", label, primary, desc)
}
' "$KGSRC")"

if [[ -z "$rows" ]]; then
    msg=$'No cyberpunk dotfiles bindings found in:\n'"$KGSRC"$'\n\nHas the plasma deploy run yet?'
    if command -v kdialog >/dev/null 2>&1; then
        kdialog --title "Cyberpunk hotkey cheatsheet" --msgbox "$msg"
    else
        printf '%s\n' "$msg"
    fi
    exit 0
fi

# ───────────────────────────────────────────────────────────────────
# Format as a fixed-width table.  kdialog --msgbox renders plain text
# in a proportional font BUT honours leading/trailing whitespace; we
# render as `[Section] Keys  →  Description` so it stays legible even
# when the font collapses columns.
# ───────────────────────────────────────────────────────────────────
body="$(printf '%s\n' "$rows" | awk -F'\t' '
{
    line = sprintf("  [%s]  %-22s  %s", $1, $2, $3)
    print line
}
')"

popup_text="Cyberpunk dotfiles global shortcuts (Meta = Super/Win key)

$body

(Generated from ~/.config/kglobalshortcutsrc — edit there to change.)"

# Render.  kdialog is the canonical KDE message-box CLI and is part of
# kde-cli-tools (already in DESKTOP_PLASMA_PACKAGES, so it's a near-
# certain present); zenity/yad are graceful fallbacks if a non-Plasma
# user trips this script.  Plain stdout is the last resort.
if command -v kdialog >/dev/null 2>&1; then
    # --geometry hint keeps the box wide enough for ~80-char lines
    # without forcing word-wrap on our binding rows.
    kdialog --title "Cyberpunk hotkey cheatsheet" \
            --geometry 640x520 \
            --msgbox "$popup_text" \
        || printf '%s\n' "$popup_text"
elif command -v zenity >/dev/null 2>&1; then
    printf '%s\n' "$popup_text" \
        | zenity --text-info --title="Cyberpunk hotkey cheatsheet" \
                 --width=640 --height=520
elif command -v yad >/dev/null 2>&1; then
    printf '%s\n' "$popup_text" \
        | yad --text-info --title="Cyberpunk hotkey cheatsheet" \
              --width=640 --height=520
else
    printf '%s\n' "$popup_text"
fi
