#!/usr/bin/env bash
# ~/.config/polybar/scripts/wireguard-menu.sh
#
# Left-click handler on the polybar [module/wireguard].
#
# Lists every config in /etc/wireguard/*.conf, shows which (if any) is
# currently up, and lets the user pick one to bring up or down.  Also
# offers a "Show status" entry that pops the full `wg show` output as a
# notification.
#
# All sudo calls assume NOPASSWD (set by the dotfiles bootstrap).  If
# sudo prompts, the menu still works but the user sees a graphical
# password dialog from polkit (or the action silently fails on a
# headless box).

set -u

# ── Discover available configs ──────────────────────────────
# /etc/wireguard is mode 700 root:root (so the private keys in *.conf
# can't be read by other users).  That means our user can't expand the
# `*.conf` glob client-side — the shell's getdents() call would fail.
# Listing has to happen as root via sudo.  We `sudo ls /etc/wireguard/`
# (an exact match in the narrow sudoers allowlist) and grep client-side.
mapfile -t configs < <(
  sudo -n ls /etc/wireguard/ 2>/dev/null \
    | grep -E '\.conf$' \
    | sed 's/\.conf$//'
)

# ── Discover currently-up interfaces ────────────────────────
mapfile -t up_ifaces < <(
  ip -br link show type wireguard 2>/dev/null \
    | awk '$2=="UP" || $2=="UNKNOWN" {print $1}'
)

# ── Build menu entries ──────────────────────────────────────
items=()
if [[ ${#configs[@]} -eq 0 ]]; then
  items+=("(no configs in /etc/wireguard/)")
else
  for c in "${configs[@]}"; do
    if printf '%s\n' "${up_ifaces[@]}" | grep -qx "$c"; then
      items+=("  $c (up — click to bring down)")
    else
      items+=("  $c")
    fi
  done
fi
items+=("  Show status")
items+=("  Bring all down")

# ── Show menu ──────────────────────────────────────────────
choice="$(printf '%s\n' "${items[@]}" | rofi -dmenu -p "WireGuard" -i)"
[[ -z "$choice" ]] && exit 0

case "$choice" in
  "(no configs"*)
    notify-send -u low "WireGuard" \
      "Drop a .conf file into /etc/wireguard/ first."
    ;;

  *"(up — click to bring down)")
    name="$(echo "$choice" | awk '{print $2}')"
    if sudo wg-quick down "$name" 2>&1 | tail -1; then
      notify-send -u low "WireGuard" "$name down"
    else
      notify-send -u critical "WireGuard" "Failed to bring $name down"
    fi
    ;;

  *"Show status")
    info="$(sudo -n wg show 2>/dev/null || echo "(no tunnels active)")"
    [[ -z "$info" ]] && info="(no tunnels active)"
    notify-send -u low "WireGuard" "$info"
    ;;

  *"Bring all down")
    for u in "${up_ifaces[@]}"; do
      sudo wg-quick down "$u" >/dev/null 2>&1
    done
    notify-send -u low "WireGuard" "All tunnels stopped"
    ;;

  *)
    # User picked a config that wasn't up — bring it up.
    name="$(echo "$choice" | awk '{print $2}')"
    if sudo wg-quick up "$name" >/dev/null 2>&1; then
      notify-send -u low "WireGuard" "$name up"
    else
      err="$(sudo wg-quick up "$name" 2>&1 | tail -3)"
      notify-send -u critical "WireGuard" "Failed to bring $name up: $err"
    fi
    ;;
esac
