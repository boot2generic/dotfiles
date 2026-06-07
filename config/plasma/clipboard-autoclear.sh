#!/bin/sh
# clipboard-autoclear.sh — wipe the Wayland clipboard a few seconds after
# the last copy, so passwords / tokens / anything sensitive don't linger.
#
# WHY THIS EXISTS
# ---------------
# Plasma ships Klipper (the system-tray "Clipboard" applet).  With CopyQ
# ALSO running, two managers fight to own the Wayland clipboard selection
# and the loser re-serves its stale cached value — that's the "fake
# paste" bug.  local_setup.sh neuters Klipper (KeepClipboardContents=
# false, MaxClipItems=1) so it keeps no scrollback history to serve a
# stale value from, leaving CopyQ as the effective manager.
#
# NOTE on clearing: KWin/Klipper RESTORE the last value whenever the
# clipboard is *released* (goes empty) — the "onlyReplaceEmpty" behavior,
# which klipperrc's PreventEmptyClipboard=false does NOT reliably disable.
# So this watcher clears by OVERWRITING with an empty offer rather than
# releasing the selection (see the --arm branch); that's what actually
# makes the wipe stick.
#
# This watcher is the auto-clear half: real copy/paste works normally,
# then the clipboard self-wipes CLIPBOARD_CLEAR_TIMEOUT seconds after the
# most recent copy.  Mirrors KeePassXC's ClearClipboardTimeout, applied
# to ALL clipboard content rather than just password-manager fills.
#
# Wayland-only (uses wl-clipboard).  Autostarted from
# ~/.config/autostart/clipboard-autoclear.desktop with OnlyShowIn=KDE, so
# the X11/i3 fallback path never runs it.
set -eu

# Resolve the clear timeout (seconds).  Prefer the inherited env var
# (set session-wide via ~/.config/environment.d/clipboard-autoclear.conf),
# fall back to reading that file directly (covers manual launches outside
# the systemd user session), then to 30.  clipboard-status.sh resolves it
# the same way so the conky readout always matches what the watcher uses.
TIMEOUT="${CLIPBOARD_CLEAR_TIMEOUT:-}"
if [ -z "$TIMEOUT" ]; then
    _envf="${HOME}/.config/environment.d/clipboard-autoclear.conf"
    [ -r "$_envf" ] && TIMEOUT=$(sed -n 's/^[[:space:]]*CLIPBOARD_CLEAR_TIMEOUT=//p' "$_envf" | tail -1)
fi
[ -n "$TIMEOUT" ] || TIMEOUT=30
PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/clipboard-autoclear.timer"

# --arm: invoked by `wl-paste --watch` on every clipboard change, with the
# new clipboard contents on stdin.  Cancel any pending clear and start a
# fresh timer, so the countdown always restarts from the LATEST copy.
if [ "${1:-}" = "--arm" ]; then
    content="$(cat)"
    # Empty content means either nothing useful or our own clear firing —
    # don't re-arm, or we'd loop forever clearing an already-empty board.
    [ -z "$content" ] && exit 0
    # Kill the previous timer (if the last copy was <TIMEOUT seconds ago).
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
    fi
    # Detached timer: wait, then clear by OVERWRITING with an empty offer
    # (`printf '' | wl-copy`), NOT `wl-copy --clear`.  --clear *releases*
    # the selection, leaving it empty — which is exactly the trigger
    # KWin/Klipper's "only replace empty" restore waits for, so the old
    # value comes right back.  Overwriting with empty content keeps a
    # live (empty) owner, so there is no empty state to restore into and
    # the clear sticks.  wl-paste --watch then sees empty content and the
    # branch above short-circuits, so this does not self-retrigger.
    ( sleep "$TIMEOUT"; printf '' | wl-copy 2>/dev/null || true ) &
    echo $! > "$PIDFILE"
    exit 0
fi

# Main entry (from autostart): refuse to double-run, then watch forever.
# --watch only follows the regular clipboard, NOT the PRIMARY selection,
# so middle-click select-paste is left untouched.
if ! command -v wl-paste >/dev/null 2>&1; then
    echo "clipboard-autoclear: wl-paste not found (not a Wayland session?)" >&2
    exit 1
fi
exec wl-paste --watch "$0" --arm
