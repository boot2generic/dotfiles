#!/usr/bin/env bash
# ~/.config/i3/scripts/volume.sh
#
# Audio-volume helper invoked from i3 media-key bindings.  Talks to
# PulseAudio via `pactl` and emits a dunst notification with the new
# volume level + a progress bar so the user gets visual feedback even
# when there's no on-screen indicator.
#
# Usage: volume.sh up | down | mute | mute-mic | get
#
# The notification uses dunst's "synchronous" hint (`x-canonical-private-
# synchronous:vol`) so successive presses replace the same toast instead
# of stacking — feels like a real OS volume bar.
#
set -euo pipefail

SINK="@DEFAULT_SINK@"
SOURCE="@DEFAULT_SOURCE@"
STEP="5%"

# How many bar segments make up the visual indicator (0–100% maps to 0–20).
BAR_LEN=20

action="${1:-get}"

case "$action" in
  up)        pactl set-sink-volume "$SINK"   "+${STEP}"  ;;
  down)      pactl set-sink-volume "$SINK"   "-${STEP}"  ;;
  mute)      pactl set-sink-mute   "$SINK"   toggle      ;;
  mute-mic)  pactl set-source-mute "$SOURCE" toggle      ;;
  get)       : ;;   # just report the current state
  *)
    echo "usage: $0 up | down | mute | mute-mic | get" >&2
    exit 2
    ;;
esac

# ── Microphone mute is its own notification ──────────────────
if [[ "$action" == "mute-mic" ]]; then
  mic_mute=$(pactl get-source-mute "$SOURCE" | awk '{print $2}')
  if [[ "$mic_mute" == "yes" ]]; then
    msg="🎙  Microphone muted"
  else
    msg="🎙  Microphone on"
  fi
  notify-send -u low -h "string:x-canonical-private-synchronous:vol" "$msg"
  exit 0
fi

# ── Read current sink state ──────────────────────────────────
mute=$(pactl get-sink-mute "$SINK" | awk '{print $2}')
# pactl prints lines like:  Volume: front-left: 26214 /  40% / -22.05 dB,   ...
# We grab the first percentage on the first line.
vol=$(pactl get-sink-volume "$SINK" \
        | head -1 \
        | grep -oE '[0-9]+%' \
        | head -1 \
        | tr -d '%')

# ── Build a 20-segment progress bar ──────────────────────────
# Cap the bar at 100% even if the volume can technically go higher.
filled=$(( vol / (100 / BAR_LEN) ))
[[ "$filled" -gt "$BAR_LEN" ]] && filled=$BAR_LEN
bar=""
for i in $(seq 1 "$BAR_LEN"); do
  if [[ "$i" -le "$filled" ]]; then bar+="█"; else bar+="░"; fi
done

# ── Send the notification ────────────────────────────────────
if [[ "$mute" == "yes" ]]; then
  notify-send -u low \
    -h "string:x-canonical-private-synchronous:vol" \
    "🔇  Muted" "$bar"
else
  # The int:value hint also drives dunst's progress-bar feature on
  # versions that support it, giving a smoother visual.
  notify-send -u low \
    -h "string:x-canonical-private-synchronous:vol" \
    -h "int:value:$vol" \
    "🔊  ${vol}%" "$bar"
fi
