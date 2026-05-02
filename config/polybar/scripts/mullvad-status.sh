#!/usr/bin/env bash
# ~/.config/polybar/scripts/mullvad-status.sh
#
# Polybar custom/script — emits a single status line each time polybar
# polls (every `interval` seconds in config.ini).
#
# Output format uses polybar's `%{F#hex}…%{F-}` foreground escapes so
# the colour matches the connection state without needing a separate
# colour-cycling module.

set -u

# Keep these in sync with config/polybar/config.ini [colors] block.
CYAN=#00e5ff       # connected
YELLOW=#ffcc00     # connecting / blocked
DIM=#5555aa        # disconnected / not installed
RED=#ff0055        # error / unknown

if ! command -v mullvad >/dev/null 2>&1; then
    printf '%%{F%s}  not installed%%{F-}\n' "$DIM"
    exit 0
fi

# `mullvad status` returns one of:
#   "Connected to gb-lon-wg-001 in London, GB. WireGuard"
#   "Connecting to ..."
#   "Disconnected"
#   "Blocked: <reason>"
status="$(mullvad status 2>/dev/null || echo Disconnected)"

case "$status" in
  Connected*)
    # Pull the relay hostname (e.g., gb-lon-wg-001) out of the line.
    relay="$(echo "$status" | grep -oE '\b[a-z]{2,3}-[a-z]{3,4}-(wg|ovpn)-[0-9]+\b' | head -1)"
    [[ -z "$relay" ]] && relay="connected"
    printf '%%{F%s}  %s%%{F-}\n' "$CYAN" "$relay"
    ;;
  Connecting*)
    printf '%%{F%s}  connecting…%%{F-}\n' "$YELLOW"
    ;;
  Blocked*)
    printf '%%{F%s}  blocked%%{F-}\n' "$YELLOW"
    ;;
  Disconnected*)
    printf '%%{F%s}  off%%{F-}\n' "$DIM"
    ;;
  *)
    printf '%%{F%s}  ?%%{F-}\n' "$RED"
    ;;
esac
