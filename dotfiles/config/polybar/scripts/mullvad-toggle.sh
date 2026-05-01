#!/usr/bin/env bash
# ~/.config/polybar/scripts/mullvad-toggle.sh
#
# Left-click handler on the polybar [module/mullvad].
#
# If currently disconnected → connect.
# If currently connected or connecting → disconnect.
#
# A short notification confirms the change so the user gets feedback even
# before polybar's next poll updates the status text.

set -u

if ! command -v mullvad >/dev/null 2>&1; then
    notify-send -u critical "Mullvad" "mullvad CLI not installed"
    exit 1
fi

state="$(mullvad status 2>/dev/null | head -1 || echo)"

case "$state" in
  Connected*|Connecting*|Blocked*)
    mullvad disconnect >/dev/null
    notify-send -u low "Mullvad" "Disconnecting…"
    ;;
  *)
    mullvad connect >/dev/null
    notify-send -u low "Mullvad" "Connecting…"
    ;;
esac
