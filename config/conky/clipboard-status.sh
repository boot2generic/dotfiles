#!/bin/sh
# clipboard-status.sh — conky readout for the clipboard auto-clear watcher
# (~/.config/plasma/clipboard-autoclear.sh).  Invoked from conky.conf via
# ${execpi N ...}; execpi PARSES conky variables in this script's output,
# so the ${colorN}/${color} markup below is rendered, not printed literal.
#
# Three states:
#   • Wayland + watcher running → green  "● auto-clear active (wipes Ns…)"
#   • Wayland + watcher absent   → red    "⚠ auto-clear OFFLINE …"  (alert)
#   • X11 / i3                    → dim    "n/a (X11 session)"  — the watcher
#                                   is Wayland-only, so this is not an error.
#
# The timeout is resolved exactly like the watcher resolves it
# (env var → environment.d file → 30) so the displayed value always
# matches what the watcher actually uses.

timeout="${CLIPBOARD_CLEAR_TIMEOUT:-}"
if [ -z "$timeout" ]; then
    envf="${HOME}/.config/environment.d/clipboard-autoclear.conf"
    [ -r "$envf" ] && timeout=$(sed -n 's/^[[:space:]]*CLIPBOARD_CLEAR_TIMEOUT=//p' "$envf" | tail -1)
fi
[ -n "$timeout" ] || timeout=30

# The watcher uses wl-clipboard, so it only exists on a Wayland session.
# On X11/i3 the feature simply doesn't apply — report that, don't alert.
if [ "${XDG_SESSION_TYPE:-}" != "wayland" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    printf '${color4}  auto-clear  n/a (X11 session)${color}\n'
    exit 0
fi

# Match the WATCHER specifically (the `wl-paste --watch …` process), NOT
# `clipboard-autoclear.sh --arm`: a detached clear-timer subshell carries
# that latter argv while it sleeps, so it would falsely read "active" for
# up to <timeout>s after a copy even if the real watcher had died.
if pgrep -f 'wl-paste --watch.*clipboard-autoclear' >/dev/null 2>&1; then
    printf '${color2}  ● auto-clear active${color}  ${color4}wipes %ss after copy${color}\n' "$timeout"
else
    printf '${color5}  ⚠ auto-clear OFFLINE — clipboard is NOT clearing${color}\n'
fi
