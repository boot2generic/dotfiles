#!/usr/bin/env bash
# ~/.config/i3/scripts/media.sh
#
# Media-player helper invoked from i3 media-key bindings.  Talks to any
# MPRIS-compatible player (Spotify, mpv, Firefox, VLC, browser HTML5
# audio, …) via `playerctl` so a single key press controls whatever is
# currently playing.
#
# Usage: media.sh playpause | play | pause | next | prev | stop
#
# Shows a dunst notification with the current artist + title after the
# action, using a "synchronous" hint so successive presses replace the
# same toast instead of stacking up.
#
set -euo pipefail

action="${1:-playpause}"

# `playerctl` exits non-zero if no MPRIS players are running.  We don't
# want set -e to abort the notification step in that case, so each call
# is wrapped with `|| true`.
case "$action" in
  playpause|toggle)  playerctl play-pause   2>/dev/null || true ;;
  play)              playerctl play         2>/dev/null || true ;;
  pause)             playerctl pause        2>/dev/null || true ;;
  next)              playerctl next         2>/dev/null || true ;;
  prev|previous)     playerctl previous     2>/dev/null || true ;;
  stop)              playerctl stop         2>/dev/null || true ;;
  *)
    echo "usage: $0 playpause | play | pause | next | prev | stop" >&2
    exit 2
    ;;
esac

# Give the player a beat to update its MPRIS state before we read it.
sleep 0.1

status=$(playerctl status 2>/dev/null || echo "No player")
title=$(playerctl metadata --format '{{ artist }} — {{ title }}' \
          2>/dev/null || echo "")

# Pick a glyph based on the new state.
case "$status" in
  Playing) icon="▶" ;;
  Paused)  icon="⏸" ;;
  Stopped) icon="⏹" ;;
  *)       icon="⏺" ;;
esac

notify-send -u low \
  -h "string:x-canonical-private-synchronous:media" \
  "${icon}  ${status}" "${title:-—}"
