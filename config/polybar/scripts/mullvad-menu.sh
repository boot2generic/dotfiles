#!/usr/bin/env bash
# ~/.config/polybar/scripts/mullvad-menu.sh
#
# Right-click handler on the polybar [module/mullvad].
#
# Pops a rofi menu with the common Mullvad operations: connect /
# disconnect / pick a relay / change settings / show status / open the
# native GUI.
#
# All sub-menus use `rofi -dmenu -i` for case-insensitive fuzzy
# filtering, which makes searching ~600 relays painless.

set -u

if ! command -v mullvad >/dev/null 2>&1; then
    notify-send -u critical "Mullvad" "mullvad CLI not installed"
    exit 1
fi

# ── Top-level menu ────────────────────────────────────────────
main_choices=(
  "  Connect"
  "  Disconnect"
  "  Reconnect"
  "  Pick relay"
  "  Settings"
  "  Account / Status"
  "  Open Mullvad GUI"
)

choice="$(printf '%s\n' "${main_choices[@]}" \
    | rofi -dmenu -p "Mullvad" -i)"
[[ -z "$choice" ]] && exit 0

case "$choice" in
  *"Connect")     mullvad connect    >/dev/null ;;
  *"Disconnect")  mullvad disconnect >/dev/null ;;
  *"Reconnect")   mullvad reconnect  >/dev/null ;;

  *"Pick relay")
    # Each line of `mullvad relay list` that names an actual host has the
    # form `gb-lon-wg-001 (1.2.3.4) - WireGuard`.  We extract the hostname
    # and present the flat list to rofi.  Hostname format is always
    # <country>-<city>-<protocol>-<id>, so we can split it back into
    # country + city + hostname for the location command.
    relay="$(mullvad relay list 2>/dev/null \
      | grep -oE '\b[a-z]{2,3}-[a-z]{3,4}-(wg|ovpn)-[0-9]+\b' \
      | sort -u \
      | rofi -dmenu -p "Relay" -i)"
    if [[ -n "$relay" ]]; then
      country="${relay%%-*}"          # leading "gb"
      rest="${relay#*-}"              # "lon-wg-001"
      city="${rest%%-*}"              # leading "lon"
      mullvad relay set location "$country" "$city" "$relay" >/dev/null \
        && notify-send -u low "Mullvad" "Relay → $relay" \
        && mullvad reconnect >/dev/null
    fi
    ;;

  *"Settings")
    settings=(
      "Tunnel: WireGuard (recommended)"
      "Tunnel: OpenVPN"
      "LAN access: Allow (printers, casting)"
      "LAN access: Block (default)"
      "Block when disconnected: ON  (kill switch)"
      "Block when disconnected: OFF (default)"
      "Auto-connect on boot: ON"
      "Auto-connect on boot: OFF"
    )
    s="$(printf '%s\n' "${settings[@]}" | rofi -dmenu -p "Setting" -i)"
    case "$s" in
      "Tunnel: WireGuard"*)              mullvad relay set tunnel-protocol wireguard ;;
      "Tunnel: OpenVPN"*)                mullvad relay set tunnel-protocol openvpn ;;
      "LAN access: Allow"*)              mullvad lan set allow ;;
      "LAN access: Block"*)              mullvad lan set block ;;
      "Block when disconnected: ON"*)    mullvad lockdown-mode set on ;;
      "Block when disconnected: OFF"*)   mullvad lockdown-mode set off ;;
      "Auto-connect on boot: ON"*)       mullvad auto-connect set on ;;
      "Auto-connect on boot: OFF"*)      mullvad auto-connect set off ;;
    esac
    ;;

  *"Account / Status")
    info="$(
      {
        echo "── Status ──"
        mullvad status 2>/dev/null
        echo
        echo "── Account ──"
        mullvad account get 2>/dev/null \
          | grep -E 'Mullvad account|Expires|Device' || echo "(not logged in)"
      } 2>&1
    )"
    notify-send -u low "Mullvad" "$info"
    ;;

  *"Open Mullvad GUI")
    # The Mullvad .deb installs the GUI binary at `/opt/Mullvad VPN/mullvad-vpn`
    # (path with a space) and ships a `mullvad-vpn.desktop` entry; the
    # package does NOT create a `mullvad-vpn` symlink on $PATH.
    #
    # SECURITY: we prefer the absolute /opt path FIRST.  gtk-launch
    # parses .desktop files from $XDG_DATA_DIRS, including the user's
    # ~/.local/share/applications which any process running as the user
    # can write to.  An attacker who plants a malicious mullvad-vpn.desktop
    # there would have it picked up by gtk-launch.  Hard-coding the
    # /opt path takes that vector off the table.
    if [[ -x "/opt/Mullvad VPN/mullvad-vpn" ]]; then
      "/opt/Mullvad VPN/mullvad-vpn" >/dev/null 2>&1 &
    elif command -v mullvad-vpn >/dev/null 2>&1; then
      mullvad-vpn >/dev/null 2>&1 &
    elif command -v gtk-launch >/dev/null 2>&1 \
         && [[ -f /usr/share/applications/mullvad-vpn.desktop ]]; then
      # Last-resort fallback: only used when neither absolute path works.
      gtk-launch mullvad-vpn >/dev/null 2>&1 &
    else
      notify-send -u critical "Mullvad" "GUI not installed"
    fi
    ;;
esac
