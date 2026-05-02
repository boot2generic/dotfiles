#!/usr/bin/env bash
# ~/.config/conky/launch.sh — relaunch the desktop monitor panel.
#
# Mirrors the pattern used by ~/.config/polybar/launch.sh: kill any
# running conky processes for this user, wait until they're really
# gone, then start a single fresh instance from conky.conf.
#
# Why we need this:
#   • i3's `exec --no-startup-id conky …` only fires once at session
#     start.  When the user deploys a new conky.conf and reloads i3,
#     the running conky still has the OLD config — appearing as a
#     ghost panel "on top of" the new one.
#   • Earlier versions of this repo shipped a SECOND conky instance
#     (conky-listen.conf for listening ports) that was later merged
#     into the main panel.  A box that was provisioned under the old
#     layout and then re-provisioned would still have the old listen
#     panel running until the user manually `pkill conky`'d.
#
# Calling this from i3 via `exec_always --no-startup-id …` means
# `Mod+Shift+c` cycles conky cleanly every time.

# Sanity-check that we're actually inside an X session.  Some conky
# builds segfault rather than printing a clean "can't open display"
# error when DISPLAY is unset (e.g., if this script runs over an SSH
# session without `-X`).  Bail out early so the script's exit code is
# meaningful.
if [ -z "${DISPLAY:-}" ]; then
    echo "$(basename "$0"): DISPLAY is not set — refusing to launch conky" >&2
    exit 1
fi

# Kill any existing conky processes belonging to this user.  -x matches
# the literal command name (i.e., "conky"), so we don't accidentally
# kill `conky-companion` or anything that happens to contain the word.
pkill -u "$UID" -x conky 2>/dev/null || true

# Wait up to 5 s for the SIGTERM to take effect, then SIGKILL anything
# still alive.  An infinite wait was previously possible — a hung
# uninterruptible-sleep conky process could spin this loop forever
# (e.g., stuck on a slow filesystem read in execpi).
for _ in {1..50}; do
    pgrep -u "$UID" -x conky >/dev/null || break
    sleep 0.1
done
if pgrep -u "$UID" -x conky >/dev/null; then
    pkill -9 -u "$UID" -x conky 2>/dev/null || true
fi

# Daemonise (-d) and read the canonical config.  No further stacking
# trickery needed: conky.conf has own_window_type = 'override', which
# means the X server flags it as override-redirect — the WM never
# manages it, never raises it on focus events, never re-stacks it
# when other apps map.  It just sits on the desktop layer where
# conky put it, drawing on top of the wallpaper.
#
# (Earlier revisions of this script tried `xdotool windowlower` and
# an `xprop -root -spy` daemon to re-lower a `'desktop'`-type conky
# whenever a new window mapped.  That layer of complexity is gone
# along with the window-type change that necessitated it.)
conky -c "$HOME/.config/conky/conky.conf" -d
