#!/usr/bin/env bash
# Polybar launch script
# Kills any existing polybar instances before starting fresh.
# Called from i3 config via exec_always so it re-runs on i3 restart.

# Kill existing instances (use pkill; killall may not be installed)
pkill -x polybar 2>/dev/null || true
# Bounded wait — don't loop forever on a hung polybar.  After 5 s,
# escalate to SIGKILL.
for _ in {1..50}; do
    pgrep -u "$UID" -x polybar > /dev/null || break
    sleep 0.1
done
pgrep -u "$UID" -x polybar > /dev/null && pkill -9 -x polybar 2>/dev/null || true

# If multiple monitors are connected, launch one bar per monitor
if type "xrandr" > /dev/null 2>&1; then
    for m in $(xrandr --query | grep " connected" | cut -d" " -f1); do
        MONITOR="$m" polybar --reload --config="$HOME/.config/polybar/config.ini" main &
    done
else
    polybar --reload --config="$HOME/.config/polybar/config.ini" main &
fi
