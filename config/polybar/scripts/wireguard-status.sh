#!/usr/bin/env bash
# ~/.config/polybar/scripts/wireguard-status.sh
#
# Polybar custom/script — emit a single line with WireGuard interface
# state.  Hidden (empty output) when no `wg-quick`-style tunnel is up,
# so the bar collapses cleanly when there's nothing to show.
#
# `ip link show type wireguard` runs as a regular user.  The endpoint
# requires `sudo wg show`; we attempt it with `sudo -n` (no prompt) and
# fall back to interface-name-only display if sudo isn't passwordless.
# (The dotfiles bootstrap sets NOPASSWD, so this normally works.)

set -u

CYAN=#00e5ff
DIM=#5555aa

# Find UP wireguard interfaces — no root needed for this.
mapfile -t up_ifaces < <(
  ip -br link show type wireguard 2>/dev/null \
    | awk '$2=="UP" || $2=="UNKNOWN" {print $1}'
)

if [[ ${#up_ifaces[@]} -eq 0 ]]; then
  # No tunnel up — return empty so polybar hides the module.
  echo ""
  exit 0
fi

# Show the first interface (almost always the only one).
iface="${up_ifaces[0]}"

# Endpoint = "<ip>:<port>"  (the `wg show <iface> endpoints` output is
# "peer-pubkey<TAB>ip:port"; we keep just the ip:port).
endpoint="$(sudo -n wg show "$iface" endpoints 2>/dev/null \
  | awk '{print $2}' | head -1 || true)"

# Total bytes transferred (so users can see the tunnel is live).
transfer="$(sudo -n wg show "$iface" transfer 2>/dev/null \
  | awk '{rx+=$2; tx+=$3} END {if (rx+tx) printf "↓%s ↑%s",  rx, tx}' || true)"

# Compose label
if [[ -n "$endpoint" ]]; then
  printf '%%{F%s}󰦝 %s → %s%%{F-}\n' "$CYAN" "$iface" "$endpoint"
else
  printf '%%{F%s}󰦝 %s%%{F-}\n' "$CYAN" "$iface"
fi
