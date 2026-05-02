#!/usr/bin/env bash
# ~/.config/polybar/scripts/battery.sh
#
# Polybar battery module — replaces internal/battery so we can:
#   1. Auto-detect BAT0 vs BAT1 vs BAT2 (X1 / dual-battery models),
#      avoiding the "stuck at 100%" symptom from a hardcoded `BAT0`
#      that doesn't match the real hardware.
#   2. Show time-remaining in addition to percentage, both while
#      discharging ("78% (02:31)") and while charging ("45% (+01:23)").
#   3. Color-code the glyph by remaining capacity (red → orange →
#      yellow → green) and switch to a charging bolt when plugged in.
#
# Exits silently with no output on machines without a battery
# (desktops / VMs); polybar then renders an empty slot.

shopt -s nullglob
BATS=(/sys/class/power_supply/BAT*)
[[ ${#BATS[@]} -eq 0 ]] && exit 0

bat="${BATS[0]##*/}"
sysdir="/sys/class/power_supply/$bat"

[[ -r "$sysdir/capacity" && -r "$sysdir/status" ]] || exit 0
capacity=$(< "$sysdir/capacity")
status=$(< "$sysdir/status")

# Cyberpunk palette
COL_RED="#ff0055"
COL_ORANGE="#ff6b35"
COL_YELLOW="#ffcc00"
COL_GREEN="#00ff41"
COL_CYAN="#00e5ff"

# Capacity ramp — Font Awesome battery glyphs
if   (( capacity < 15 )); then icon=""; col="$COL_RED"
elif (( capacity < 35 )); then icon=""; col="$COL_ORANGE"
elif (( capacity < 60 )); then icon=""; col="$COL_YELLOW"
elif (( capacity < 85 )); then icon=""; col="$COL_GREEN"
else                            icon=""; col="$COL_GREEN"
fi

# Time remaining — `acpi -b` prints in a stable format:
#   "Battery 0: Discharging, 78%, 02:31:45 remaining"
#   "Battery 0: Charging, 45%, 01:23:00 until charged"
#   "Battery 0: Full, 100%"
#   "Battery 0: Not charging, 80%"
# We pluck the HH:MM portion (ignore seconds).
hours_min=""
if command -v acpi >/dev/null 2>&1; then
  acpi_line="$(acpi -b 2>/dev/null | head -n1)"
  time_field="$(echo "$acpi_line" | grep -oE '[0-9]+:[0-9]+(:[0-9]+)?' | head -n1)"
  hours_min="${time_field%:*}"
fi

case "$status" in
  Charging)
    icon=""; col="$COL_CYAN"
    if [[ -n "$hours_min" && "$hours_min" != "0:00" ]]; then
      label="${capacity}% (+${hours_min})"
    else
      label="${capacity}%"
    fi
    ;;
  Discharging)
    if [[ -n "$hours_min" && "$hours_min" != "0:00" ]]; then
      label="${capacity}% (${hours_min})"
    else
      label="${capacity}%"
    fi
    ;;
  Full|"Not charging")
    icon=""; col="$COL_GREEN"
    label="${capacity}%"
    ;;
  *)
    label="${capacity}%"
    ;;
esac

printf '%%{F%s}%s%%{F-} %s\n' "$col" "$icon" "$label"
