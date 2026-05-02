#!/usr/bin/env bash
# ~/.config/polybar/scripts/wifi-menu.sh
#
# Click handler on the polybar [module/wlan].
#
# Pops a rofi menu with the standard wifi operations:
#   - Connect: active rescan, list networks sorted by signal, prompt for
#     password if the SSID isn't already saved
#   - Show current connection: SSID, IP, gateway, DNS, signal, bitrate
#   - Forget a saved network
#   - Toggle the wifi radio
#   - Open nm-connection-editor (full GUI) or nmtui (TUI)
#
# Notifications via notify-send (dunst).  All sub-prompts use rofi's
# fuzzy filter so typing a few characters narrows the list quickly.
#
# Exits silently if NetworkManager isn't installed (e.g., a headless VM).

set -u

if ! command -v nmcli >/dev/null 2>&1; then
    notify-send -u critical "Wifi" "nmcli not installed (NetworkManager missing)"
    exit 1
fi

# Resolve the wifi device once — referenced by several actions.  May be
# empty on a desktop / VM with no wireless hardware (then "Connect" still
# shows but produces "No networks found", which is the right UX).
WIFI_IFACE="$(nmcli -t -f DEVICE,TYPE device 2>/dev/null \
              | awk -F: '$2 == "wifi" {print $1; exit}')"

# Active SSID (empty if disconnected)
ACTIVE_SSID="$(nmcli -t -f ACTIVE,SSID device wifi list 2>/dev/null \
               | awk -F: '$1 == "yes" {print $2; exit}')"

WIFI_RADIO="$(nmcli radio wifi 2>/dev/null)"

# ── Top-level menu ───────────────────────────────────────────
main_choices=()
[[ -n "$ACTIVE_SSID" ]] && main_choices+=("󰖪  Disconnect from ${ACTIVE_SSID}")
main_choices+=(
  "  Connect to network"
  "  Show current connection"
)
if [[ "$WIFI_RADIO" == "enabled" ]]; then
  main_choices+=("󰖪  Disable wifi radio")
else
  main_choices+=("  Enable wifi radio")
fi
main_choices+=(
  "  Forget a saved network"
  "  Open connection editor"
  "  Open nmtui"
)

choice="$(printf '%s\n' "${main_choices[@]}" | rofi -dmenu -p "Wifi" -i)"
[[ -z "$choice" ]] && exit 0

# ── Connect ──────────────────────────────────────────────────
do_connect() {
  notify-send -t 2000 "Wifi" "Scanning…"
  nmcli device wifi rescan 2>/dev/null || true
  sleep 1.5

  # Build a "<SSID> | bars | sig% | sec" picker line.  We strip empty
  # SSIDs and "--" placeholders that nmcli emits for hidden networks.
  list="$(nmcli -t -f IN-USE,SSID,SECURITY,SIGNAL,BARS device wifi list 2>/dev/null \
    | awk -F: '
        $2 != "" && $2 != "--" {
          mark = ($1 == "*") ? " " : "  "
          sec  = ($3 == "" ? "open" : $3)
          # signal -> bars glyph if blank
          bars = ($5 == "" ? "____" : $5)
          # printf with field widths so columns line up in rofi
          printf "%s%-30s  %-4s  %3d%%  %s\n", mark, $2, bars, $4, sec
        }' \
    | sort -k4 -r -n -t '%')"

  if [[ -z "$list" ]]; then
    notify-send "Wifi" "No networks found"
    exit 0
  fi

  pick="$(printf '%s\n' "$list" | rofi -dmenu -p "Network" -i)"
  [[ -z "$pick" ]] && exit 0

  # Strip the "* " or "  " marker; the SSID is everything up to the
  # first run of >=2 spaces (which separates it from the bars column).
  ssid="$(echo "$pick" | sed -E 's/^.{2}//; s/  +.*$//')"
  sec="$(echo "$pick"  | awk '{print $NF}')"

  # Already-saved profile? Bring it up directly.
  if nmcli -t -f NAME connection show 2>/dev/null \
     | grep -Fxq -- "$ssid"; then
    out="$(nmcli connection up id "$ssid" 2>&1)"
    rc=$?
  elif [[ "$sec" == "open" ]]; then
    out="$(nmcli device wifi connect "$ssid" 2>&1)"
    rc=$?
  else
    pw="$(rofi -dmenu -password -lines 0 -p "Password for $ssid" </dev/null)"
    [[ -z "$pw" ]] && exit 0
    out="$(nmcli device wifi connect "$ssid" password "$pw" 2>&1)"
    rc=$?
  fi

  if [[ $rc -eq 0 ]]; then
    notify-send "Wifi" "Connected → $ssid"
  else
    notify-send -u critical "Wifi" "Connect failed: $(echo "$out" | tail -n1)"
  fi
}

# ── Show current ─────────────────────────────────────────────
do_show() {
  if [[ -z "$ACTIVE_SSID" ]]; then
    notify-send "Wifi" "Not connected"
    exit 0
  fi
  # Build a multi-line info dump and pipe through rofi for paged display.
  {
    printf "SSID: %s\n" "$ACTIVE_SSID"
    if [[ -n "$WIFI_IFACE" ]] && [[ -x /usr/sbin/iw ]]; then
      /usr/sbin/iw dev "$WIFI_IFACE" link 2>/dev/null \
        | grep -E 'signal|tx bitrate|freq|SSID' \
        | sed 's/^[ \t]*/  /'
    fi
    nmcli -t -f IP4.ADDRESS,IP4.GATEWAY,IP4.DNS \
      connection show id "$ACTIVE_SSID" 2>/dev/null \
      | sed 's/^/  /'
  } | rofi -dmenu -p "Wifi: $ACTIVE_SSID" -i -lines 12
}

# ── Forget ───────────────────────────────────────────────────
do_forget() {
  saved="$(nmcli -t -f NAME,TYPE connection show \
           | awk -F: '$2 ~ /wireless/ {print $1}')"
  if [[ -z "$saved" ]]; then
    notify-send "Wifi" "No saved networks"
    exit 0
  fi
  pick="$(printf '%s\n' "$saved" | rofi -dmenu -p "Forget" -i)"
  [[ -z "$pick" ]] && exit 0
  if nmcli connection delete id "$pick" >/dev/null 2>&1; then
    notify-send "Wifi" "Forgot: $pick"
  else
    notify-send -u critical "Wifi" "Forget failed for: $pick"
  fi
}

# ── Dispatch ─────────────────────────────────────────────────
case "$choice" in
  *"Disconnect from"*)
    if [[ -n "$WIFI_IFACE" ]]; then
      nmcli device disconnect "$WIFI_IFACE" >/dev/null 2>&1 \
        && notify-send "Wifi" "Disconnected"
    fi
    ;;
  *"Connect to network")        do_connect ;;
  *"Show current connection")   do_show ;;
  *"Disable wifi radio")        nmcli radio wifi off && notify-send "Wifi" "Radio off" ;;
  *"Enable wifi radio")         nmcli radio wifi on  && notify-send "Wifi" "Radio on" ;;
  *"Forget a saved network")    do_forget ;;
  *"Open connection editor")    nm-connection-editor & disown ;;
  *"Open nmtui")                alacritty -e nmtui & disown ;;
esac
