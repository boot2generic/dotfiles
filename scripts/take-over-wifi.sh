#!/usr/bin/env bash
# scripts/take-over-wifi.sh
#
# Hand the wifi card from ifupdown / wpa_supplicant / iwd /
# systemd-networkd OVER to NetworkManager so the polybar wlan pill
# and ~/.config/polybar/scripts/wifi-menu.sh work as designed.
#
# Why this is a separate script and not part of `./local_setup.sh
# install`: doing this handover during install kills the network the
# installer is using, and leaves NM with no saved profile to
# reconnect.  This script is a deliberate, prompt-driven action you
# run AFTER the install — once you have ethernet plugged in or your
# wifi creds ready to type.
#
# Behaviour summary:
#   1. Probes the current state and prints what it finds.
#   2. Asks for confirmation (--yes to skip the prompts; useful when
#      driving from another script).
#   3. Backs up /etc/network/interfaces and comments out wifi blocks.
#   4. Stops + disables wpa_supplicant / iwd / systemd-networkd
#      whichever is active for the wifi iface.
#   5. Drops a NetworkManager conf.d snippet that flips `[ifupdown]
#      managed=true`, so NM takes over even if /etc/network/interfaces
#      survives.
#   6. Restarts NetworkManager.
#   7. Prompts for SSID + password, then `nmcli device wifi connect`.
#
# Reversal: see readme/system.md → "WiFi shows 'unmanaged'" for the
# rollback steps (rm the conf.d file, re-enable the previous backend).

set -euo pipefail

# ── Colour helpers (same palette as local_setup.sh's log/ok/warn) ──
if [[ -t 1 ]]; then
    C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'
    C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
    C_OK= ; C_WARN= ; C_ERR= ; C_DIM= ; C_RST=
fi
log()  { echo "${C_DIM}[*]${C_RST} $*"; }
ok()   { echo "${C_OK}[ok]${C_RST} $*"; }
warn() { echo "${C_WARN}[!]${C_RST} $*" >&2; }
err()  { echo "${C_ERR}[!!]${C_RST} $*" >&2; }
die()  { err "$*"; exit 1; }

YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && YES=1

confirm() {
    (( YES )) && return 0
    local prompt="${1:-Continue?} [y/N] " ans
    read -rp "$prompt" ans || ans=""
    [[ "${ans:-}" =~ ^[Yy] ]]
}

# ── Sanity ─────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] && die "Run as a regular user — sudo will be invoked where needed."
command -v nmcli >/dev/null 2>&1 || die "nmcli not installed — run \`sudo apt install network-manager\`"

# ── Detect the wifi interface ──────────────────────────────────────
WIFI_IFACE="$(nmcli -t -f DEVICE,TYPE device 2>/dev/null \
              | awk -F: '$2 == "wifi" {print $1; exit}' || true)"
[[ -z "$WIFI_IFACE" ]] \
  && die "No wifi device found.  Check \`lspci -k | grep -A2 -i network\` and \`dmesg | grep firmware\`."

CURRENT_STATE="$(nmcli -t -f DEVICE,STATE device 2>/dev/null \
                 | awk -F: -v d="$WIFI_IFACE" '$1==d {print $2; exit}' || true)"
log "wifi iface       : $WIFI_IFACE"
log "current NM state : ${CURRENT_STATE:-?}"

case "$CURRENT_STATE" in
    "")
        die "NetworkManager doesn't see $WIFI_IFACE — check \`nmcli device\`."
        ;;
    connected|connecting|disconnected)
        warn "$WIFI_IFACE is already managed by NM (state=$CURRENT_STATE)."
        warn "Nothing to take over.  If the polybar pill still misbehaves,"
        warn "run \`~/.config/polybar/scripts/wifi-menu.sh --diag\` and look"
        warn "at the output."
        exit 0
        ;;
    unmanaged|unavailable)
        : # proceed
        ;;
    *)
        warn "Unexpected state ($CURRENT_STATE) — proceeding cautiously"
        ;;
esac

# ── Pre-flight: are we about to drop the network we're using? ──────
ETH_UP=0
while IFS= read -r line; do
    [[ "$line" =~ ^[a-z]+[0-9]+f[0-9]+:[[:space:]]+UP ]] && ETH_UP=1
    [[ "$line" =~ ^en[a-z]+[0-9]+:[[:space:]]+UP ]]      && ETH_UP=1
    [[ "$line" =~ ^enx[0-9a-f]+:[[:space:]]+UP ]]        && ETH_UP=1
done <<<"$(ip -br link 2>/dev/null || true)"

echo
if (( ETH_UP )); then
    ok "Ethernet is up — safe to bounce wifi."
else
    warn "No ethernet detected as UP.  This script is about to:"
    warn "  • stop wpa_supplicant / iwd / systemd-networkd"
    warn "  • restart NetworkManager"
    warn "Both will TEMPORARILY DROP your wifi connection."
    warn "If you're SSH'd into this machine over wifi, abort now."
    warn "Otherwise, you'll need your SSID + password to reconnect."
fi

confirm "Proceed with takeover for $WIFI_IFACE?" \
  || { log "Aborted."; exit 0; }

# ── Step 0: pre-import credentials from /etc/network/interfaces ───
# The original failure mode of this script was: stop wpa_supplicant →
# wifi link drops → NM has no saved profile → user is offline AND
# inside the wifi-menu password prompt with no working clipboard, no
# search engine, etc.  We avoid that here by reading the wpa-ssid and
# wpa-psk that ifupdown was already using and pre-creating a matching
# NM connection profile FIRST.  When NM takes over the device, it
# already knows what to connect to and reconnects automatically.
INTERFACES_SSID=""
INTERFACES_PSK=""
if [[ -r /etc/network/interfaces ]]; then
    # Look in the iface block whose interface name matches WIFI_IFACE.
    # awk reads the file once, tracks whether we're inside the right
    # block, and emits SSID + PSK as `KEY=VALUE` shell-quoted lines.
    eval "$(sudo awk -v IF="$WIFI_IFACE" '
        BEGIN { in_block=0 }
        /^[[:space:]]*iface[[:space:]]+/ {
            in_block = ($2 == IF) ? 1 : 0
            next
        }
        in_block && /^[[:space:]]*wpa-ssid[[:space:]]+/ {
            sub(/^[[:space:]]*wpa-ssid[[:space:]]+/, "")
            gsub(/'\''/, "'\''\\'\'\''")   # shell-escape any literal apostrophes
            print "INTERFACES_SSID='\''" $0 "'\''"
        }
        in_block && /^[[:space:]]*wpa-(psk|passphrase|password)[[:space:]]+/ {
            sub(/^[[:space:]]*wpa-(psk|passphrase|password)[[:space:]]+/, "")
            gsub(/'\''/, "'\''\\'\'\''")
            print "INTERFACES_PSK='\''" $0 "'\''"
        }
    ' /etc/network/interfaces 2>/dev/null)"
fi

if [[ -n "$INTERFACES_SSID" && -n "$INTERFACES_PSK" ]]; then
    log "Found existing wifi creds in /etc/network/interfaces (SSID: ${INTERFACES_SSID})"
    log "Pre-importing into NetworkManager so reconnect is automatic …"
    # Use a profile name distinct from any existing NM connection.
    PROFILE_NAME="ifupdown-import-${INTERFACES_SSID}"
    if nmcli -t -f NAME connection show 2>/dev/null \
         | grep -Fxq "$PROFILE_NAME"; then
        log "  profile $PROFILE_NAME already exists — leaving it"
    else
        sudo nmcli connection add \
            type wifi \
            con-name "$PROFILE_NAME" \
            ifname "$WIFI_IFACE" \
            ssid "$INTERFACES_SSID" \
            wifi-sec.key-mgmt wpa-psk \
            wifi-sec.psk "$INTERFACES_PSK" \
            connection.autoconnect yes \
            >/dev/null \
            && ok "imported as NM profile: $PROFILE_NAME" \
            || warn "nmcli connection add failed — will fall back to interactive prompt"
    fi
else
    warn "Couldn't extract SSID/PSK from /etc/network/interfaces."
    warn "You'll be prompted for them at the end of this script — be"
    warn "ready with both before continuing."
fi

# ── Step 1: comment out wifi entries in /etc/network/interfaces ────
NEEDED_INTERFACES_EDIT=0
if grep -qE "^[[:space:]]*(auto|iface|allow-hotplug)[[:space:]]+${WIFI_IFACE}([[:space:]]|$)" \
        /etc/network/interfaces 2>/dev/null \
   || (
        shopt -s nullglob
        for f in /etc/network/interfaces.d/*; do
            grep -qE "^[[:space:]]*(auto|iface|allow-hotplug)[[:space:]]+${WIFI_IFACE}([[:space:]]|$)" "$f" 2>/dev/null \
                && exit 0
        done
        exit 1
      ); then
    NEEDED_INTERFACES_EDIT=1
fi

if (( NEEDED_INTERFACES_EDIT )); then
    log "Found $WIFI_IFACE references in /etc/network/interfaces*"
    TS="$(date +%Y%m%d-%H%M%S)"
    sudo cp -a /etc/network/interfaces "/etc/network/interfaces.bak.${TS}" \
        2>/dev/null || true
    sudo find /etc/network/interfaces.d -maxdepth 1 -type f \
        -exec cp -a {} {}".bak.${TS}" \; 2>/dev/null || true
    log "  backed up: /etc/network/interfaces*.bak.${TS}"

    # Comment out: any `auto`/`iface`/`allow-hotplug` line referencing
    # the wifi iface, AND every indented continuation line beneath an
    # `iface` block.  Use awk for the indentation-aware part.
    sudo awk -v IF="$WIFI_IFACE" '
        BEGIN { in_block=0 }
        # Standalone marker lines for the wifi iface — always comment.
        /^[[:space:]]*(auto|allow-hotplug)[[:space:]]+/ \
            && $2 == IF                                 { print "# disabled-by-take-over-wifi: " $0; next }
        # Start of `iface <iface> ...` block — comment header, enter block.
        /^[[:space:]]*iface[[:space:]]+/ && $2 == IF    { print "# disabled-by-take-over-wifi: " $0; in_block=1; next }
        # Header for some OTHER iface — exit the block.
        /^[[:space:]]*(iface|auto|allow-hotplug)[[:space:]]+/ && $2 != IF { in_block=0; print; next }
        # Indented continuation of OUR block — comment it out.
        in_block && /^[[:space:]]/                      { print "# disabled-by-take-over-wifi: " $0; next }
        # Anything else passes through untouched.
        { print }
    ' /etc/network/interfaces \
        | sudo install -m 0644 /dev/stdin /etc/network/interfaces.new \
        && sudo mv /etc/network/interfaces.new /etc/network/interfaces
    ok "commented out $WIFI_IFACE block in /etc/network/interfaces"
fi

# ── Step 2: bring the iface down via ifupdown if it knows about it ─
if command -v ifdown >/dev/null 2>&1; then
    log "ifdown $WIFI_IFACE (best-effort) …"
    sudo ifdown --force "$WIFI_IFACE" >/dev/null 2>&1 || true
fi

# ── Step 3: stop the previous backend(s) ───────────────────────────
for svc in iwd wpa_supplicant systemd-networkd; do
    if systemctl is-active "$svc" >/dev/null 2>&1; then
        log "stopping $svc (was active) …"
        sudo systemctl disable --now "$svc" >/dev/null 2>&1 \
            && ok "$svc stopped + disabled" \
            || warn "couldn't stop $svc — check \`systemctl status $svc\`"
    fi
done

# Also kill any per-iface wpa_supplicant unit (Debian's installer
# sometimes runs `wpa_supplicant@<iface>.service` rather than the
# global one).
for svc in "wpa_supplicant@${WIFI_IFACE}" "wpa_supplicant-nl80211@${WIFI_IFACE}" \
           "wpa_supplicant-wired@${WIFI_IFACE}"; do
    if systemctl is-active "$svc" >/dev/null 2>&1; then
        log "stopping ${svc} (per-iface unit) …"
        sudo systemctl disable --now "$svc" >/dev/null 2>&1 \
            && ok "${svc} stopped + disabled" \
            || warn "couldn't stop ${svc}"
    fi
done

# ── Step 4: NetworkManager conf.d → managed=true ───────────────────
NM_CONF=/etc/NetworkManager/conf.d/10-globally-managed-devices.conf
if [[ ! -f "$NM_CONF" ]]; then
    log "writing $NM_CONF …"
    sudo install -d -m 0755 /etc/NetworkManager/conf.d
    sudo tee "$NM_CONF" >/dev/null <<'EOF'
# Written by scripts/take-over-wifi.sh.  Forces NetworkManager to
# manage every interface, defeating Debian's default
# `[ifupdown] managed=false` deference.  Remove this file to revert.
[ifupdown]
managed=true
EOF
    ok "$NM_CONF written"
else
    log "$NM_CONF already exists — leaving as-is"
fi

# ── Step 5: restart NM ─────────────────────────────────────────────
log "restarting NetworkManager …"
sudo systemctl restart NetworkManager
sleep 4

NEW_STATE="$(nmcli -t -f DEVICE,STATE device 2>/dev/null \
             | awk -F: -v d="$WIFI_IFACE" '$1==d {print $2; exit}' || true)"
log "post-restart NM state: ${NEW_STATE:-?}"

case "$NEW_STATE" in
    disconnected|connecting|connected)
        ok "$WIFI_IFACE is now NM-managed"
        ;;
    unmanaged)
        die "Still unmanaged after restart.  Investigate:\n"\
"  sudo grep -rn 'unmanaged' /etc/NetworkManager/\n"\
"  ls /etc/systemd/network/\n"\
"  cat /etc/network/interfaces"
        ;;
    unavailable)
        warn "Device is 'unavailable' — usually rfkill or driver loading."
        warn "Try: \`sudo rfkill unblock all\` then \`sudo systemctl restart NetworkManager\`"
        warn "If that doesn't help: \`dmesg | tail -50\` for driver errors."
        ;;
esac

# ── Step 6: connect ────────────────────────────────────────────────
if [[ "$NEW_STATE" == "connected" ]]; then
    SSID="$(nmcli -t -f ACTIVE,SSID device wifi list 2>/dev/null \
            | awk -F: '$1=="yes" {print $2; exit}' || true)"
    ok "Already on '${SSID}' — nothing to do."
    exit 0
fi

# If we pre-imported a profile in Step 0, NM should auto-connect on
# its own (autoconnect=yes); give it a few seconds before falling
# back to the interactive prompt.
if [[ -n "${PROFILE_NAME:-}" ]]; then
    log "Waiting up to 15s for NM to bring up the imported profile …"
    for _ in $(seq 1 15); do
        st="$(nmcli -t -f DEVICE,STATE device 2>/dev/null \
              | awk -F: -v d="$WIFI_IFACE" '$1==d {print $2; exit}' \
              || true)"
        if [[ "$st" == "connected" ]]; then
            ok "Connected via imported profile: $PROFILE_NAME"
            exit 0
        fi
        sleep 1
    done
    warn "Auto-connect didn't complete in 15s — trying explicit `nmcli connection up`"
    if sudo nmcli connection up "$PROFILE_NAME" >/dev/null 2>&1; then
        ok "Brought up: $PROFILE_NAME"
        exit 0
    fi
    warn "Imported profile failed — falling back to interactive prompt."
fi

echo
log "Now connect to your wifi.  Three options:"
log "  (1) Enter SSID + password here"
log "  (2) Open nmtui (full TUI)            — type 'tui' below"
log "  (3) Skip and connect manually later  — type 'skip' below"
read -rp "SSID (or 'tui' / 'skip'): " SSID
case "${SSID:-skip}" in
    tui)
        exec nmtui
        ;;
    skip|"")
        log "Done.  Connect later with: nmcli device wifi connect 'SSID' password 'PW'"
        exit 0
        ;;
esac

read -rsp "Password for '${SSID}': " PW
echo
if [[ -z "$PW" ]]; then
    log "Empty password — assuming open network."
    sudo nmcli device wifi connect "$SSID"
else
    sudo nmcli device wifi connect "$SSID" password "$PW"
fi

ok "Done.  Polybar wlan pill should render in the next few seconds."
