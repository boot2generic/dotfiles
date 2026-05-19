#!/usr/bin/env bash
# scripts/diagnose-wifi.sh
#
# Read-only diagnostic dump for "wifi isn't working".  Captures the
# 12 things I'd otherwise ask you to paste individually.  No destructive
# operations — runs lspci / nmcli / systemctl / rfkill / dmesg /
# journalctl / ls / grep only.
#
# Usage:
#   ~/dotfiles/scripts/diagnose-wifi.sh                 # to terminal
#   ~/dotfiles/scripts/diagnose-wifi.sh > /tmp/wifi.txt # to file
#
# Some sections need root for full visibility (dmesg, /etc/NetworkManager/
# conf.d/ contents).  We use `sudo -n` (no prompt) where possible and
# fall back to a clearly-labelled "no sudo" line if the password isn't
# cached.  Run this as your normal user.
set -u

section() { printf '\n=== %s ===\n' "$*"; }
sub()     { printf '\n--- %s ---\n' "$*"; }

# ── Detect wifi iface (best-effort; falls back to wlp* glob) ──
WIFI_IFACE="$(nmcli -t -f DEVICE,TYPE device 2>/dev/null \
              | awk -F: '$2 == "wifi" {print $1; exit}' || true)"
if [[ -z "${WIFI_IFACE:-}" ]]; then
    # nmcli doesn't see one — fall back to the kernel.
    for d in /sys/class/net/*/wireless; do
        [[ -d "$d" ]] && WIFI_IFACE="$(basename "$(dirname "$d")")" && break
    done
fi
WIFI_IFACE="${WIFI_IFACE:-???}"

printf 'wifi-diagnostic — %s — host=%s — iface=%s\n' \
    "$(date -Iseconds)" "$(uname -n)" "$WIFI_IFACE"

# ── 1. Hardware: is there even a wifi card? ─────────────────
section "1. Wifi hardware (lspci)"
if command -v lspci >/dev/null 2>&1; then
    lspci -nnk | grep -A3 -iE 'network|wireless|wifi' || echo "(none found)"
else
    echo "lspci not installed (apt: pciutils)"
fi

# ── 2. Kernel-level iface state ─────────────────────────────
section "2. Kernel /sys/class/net/$WIFI_IFACE/"
if [[ -d "/sys/class/net/$WIFI_IFACE" ]]; then
    for k in operstate carrier address flags type wireless; do
        v="$(cat "/sys/class/net/$WIFI_IFACE/$k" 2>/dev/null \
              || ls -d "/sys/class/net/$WIFI_IFACE/$k" 2>/dev/null \
              || echo '(missing)')"
        printf '  %-12s %s\n' "$k" "$v"
    done
else
    echo "(/sys/class/net/$WIFI_IFACE missing — driver may not be loaded)"
fi

# ── 3. Driver / firmware (lsmod + dmesg) ───────────────────
section "3. Driver modules"
if command -v lsmod >/dev/null 2>&1; then
    lsmod | grep -E 'iwl|cfg80211|mac80211|rtw|ath' || echo "(no wifi-related modules loaded)"
fi

section "3b. dmesg wifi/firmware mentions (last 20 matching)"
if sudo -n true 2>/dev/null; then
    sudo dmesg --time-format=iso 2>/dev/null \
      | grep -iE 'iwlwifi|firmware|wlp|wlan|microcode|brcm|rtw' \
      | tail -20 \
      || echo "(no matching dmesg lines)"
else
    dmesg --time-format=iso 2>/dev/null \
      | grep -iE 'iwlwifi|firmware|wlp|wlan|microcode|brcm|rtw' \
      | tail -20 \
      || echo "(dmesg empty or no sudo — try \`sudo $0\`)"
fi

# ── 4. RFKill ──────────────────────────────────────────────
section "4. rfkill state"
if command -v rfkill >/dev/null 2>&1; then
    rfkill list || rfkill list all 2>/dev/null
elif [[ -x /usr/sbin/rfkill ]]; then
    /usr/sbin/rfkill list
else
    echo "rfkill not on PATH"
fi

# ── 5. NetworkManager + alternative backends ───────────────
section "5. Service states (active/inactive/failed)"
for svc in NetworkManager wpa_supplicant iwd systemd-networkd dhcpcd \
           dhclient networking; do
    state="$(systemctl is-active  "$svc" 2>/dev/null || true)"
    enab="$(systemctl  is-enabled "$svc" 2>/dev/null || true)"
    printf '  %-22s active=%-10s enabled=%s\n' "$svc" "${state:--}" "${enab:--}"
done

# ── 6. NetworkManager view ─────────────────────────────────
section "6. NetworkManager device list"
if command -v nmcli >/dev/null 2>&1; then
    nmcli general status
    sub "device list"
    nmcli device status
    sub "connections (saved profiles)"
    nmcli -t -f NAME,TYPE,DEVICE,STATE connection show 2>/dev/null \
      | head -20
    sub "wifi scan"
    nmcli device wifi list 2>&1 | head -10
else
    echo "nmcli not installed — apt install network-manager"
fi

# ── 7. iw subsystem view (independent of NM) ───────────────
section "7. iw dev (wireless subsystem)"
if command -v iw >/dev/null 2>&1; then
    iw dev || true
    [[ "$WIFI_IFACE" != "???" ]] && iw dev "$WIFI_IFACE" link 2>&1 || true
elif [[ -x /usr/sbin/iw ]]; then
    /usr/sbin/iw dev || true
    [[ "$WIFI_IFACE" != "???" ]] && /usr/sbin/iw dev "$WIFI_IFACE" link 2>&1 || true
else
    echo "iw not installed"
fi

# ── 8. NM config — anything that says 'unmanaged'? ─────────
section "8. /etc/NetworkManager/ config"
sub "conf.d/ contents"
ls -la /etc/NetworkManager/conf.d/ 2>/dev/null \
  | grep -v '^total\|^\.' || echo "(empty)"
sub "any 'unmanaged' or 'managed' lines anywhere in NM config"
if sudo -n true 2>/dev/null; then
    sudo grep -rn 'unmanaged\|managed' /etc/NetworkManager/ 2>/dev/null \
      | head -20 \
      || echo "(none)"
else
    grep -rn 'unmanaged\|managed' /etc/NetworkManager/ 2>/dev/null \
      | head -20 \
      || echo "(none — run with sudo for full coverage)"
fi
sub "main NetworkManager.conf"
if sudo -n true 2>/dev/null; then
    sudo cat /etc/NetworkManager/NetworkManager.conf 2>/dev/null \
      || echo "(unreadable)"
else
    cat /etc/NetworkManager/NetworkManager.conf 2>/dev/null \
      || echo "(unreadable without sudo)"
fi

# ── 9. /etc/network/interfaces (ifupdown legacy) ──────────
# Redact wpa-psk / wpa-passphrase / wpa-password / wep-key lines —
# these appear in /etc/network/interfaces in plaintext on Debian
# installer-configured wifi setups.  PSKs leaked into a paste are
# treated as fully compromised and have to be rotated on the AP, so
# we go out of our way to never include them in the diagnostic dump.
redact_iface_secrets() {
    # ifupdown supports a long list of `wpa-*` directives, several of
    # which carry sensitive material.  An earlier version of this
    # function listed them individually (psk, passphrase, password,
    # preshared-key, wep-key[0-9]?) and missed eappsk, identity,
    # private-key-passwd, etc.  We now redact ANY wpa-* directive
    # whose name suggests secret content.  False positives (e.g.,
    # wpa-driver = "nl80211") are explicitly excluded.
    sed -E '
        # Things that look secret-bearing — redact the value.
        s/^([[:space:]]*wpa-(psk|passphrase|password|preshared-key|wep-key[0-9]?|eappsk|private-key|private-key-passwd|private-key2|private-key-passwd2|identity|anonymous-identity|pin)[[:space:]]+).*/\1<REDACTED>/
        # Per-IEEE8021X password files (path may leak; truncate value).
        s/^([[:space:]]*wpa-(passphrase-file|psk-file)[[:space:]]+).*/\1<REDACTED-PATH>/
    '
}
section "9. /etc/network/interfaces*"
if [[ -f /etc/network/interfaces ]]; then
    redact_iface_secrets < /etc/network/interfaces
    sub "interfaces.d/ contents"
    ls /etc/network/interfaces.d/ 2>/dev/null
    for f in /etc/network/interfaces.d/*; do
        [[ -f "$f" ]] || continue
        sub "$f"
        redact_iface_secrets < "$f"
    done
else
    echo "(no /etc/network/interfaces — pure-NM system)"
fi

# ── 10. systemd-networkd config ────────────────────────────
section "10. systemd-networkd (.network units, if any)"
ls /etc/systemd/network/ 2>/dev/null \
  | grep -v '^total' || echo "(empty)"
ls /run/systemd/network/ 2>/dev/null \
  | grep -v '^total' || echo "(/run/ also empty)"

# ── 11. wpa_supplicant config (if any) ────────────────────
# Mirror the ifupdown redactor (above) for the wpa_supplicant.conf
# keyfile syntax (`key=value`, not `wpa-key value`).  The previous
# implementation used a narrow blocklist `grep -vE "psk=|password=|
# ext_password="` which silently leaked WEP keys, EAP passwords,
# private-key passphrases, machine PINs, and pac_file paths — all of
# which can appear in real-world enterprise / legacy supplicant
# configs.  This redactor keeps the line so structure is visible but
# zeroes out the secret-bearing value, matching how `redact_iface_
# secrets` handles /etc/network/interfaces.
redact_supplicant_secrets() {
    # Keys below are real wpa_supplicant.conf directives.  An earlier
    # draft included a handful of names the security agent suggested
    # that aren't actually directives (eap_pwd_password, machine_password,
    # *_cert_blob, etc.) — harmless because they'd never match, but
    # listing them was misleading.  Anything ending in `password` /
    # `passwd` / `pass` is caught by the broad `.*pass.*` clause too.
    sed -E '
        # Secret-bearing values — replace the RHS with <REDACTED>.
        s/^([[:space:]]*(psk|passphrase|password|ext_password|ext_psk|wep_key[0-9]?|wep_tx_keyidx|pin|sim_num|private_key_passwd|private_key2_passwd|new_password)[[:space:]]*=[[:space:]]*).*/\1<REDACTED>/
        # Defence in depth: redact any directive whose name contains
        # `pass` (catches future / vendor-specific `*_password`,
        # `passwd`, `pass_phrase` variants we didn'\''t enumerate).
        s/^([[:space:]]*[A-Za-z_][A-Za-z0-9_]*pass[A-Za-z0-9_]*[[:space:]]*=[[:space:]]*).*/\1<REDACTED>/
        # File paths that may leak filesystem layout — truncate value.
        s/^([[:space:]]*(pac_file|ca_path|ca_cert|client_cert|client_cert2|private_key|private_key2)[[:space:]]*=[[:space:]]*).*/\1<REDACTED-PATH>/
    '
}
section "11. /etc/wpa_supplicant/"
ls /etc/wpa_supplicant/ 2>/dev/null
if sudo -n true 2>/dev/null; then
    # Iterate readable wpa_supplicant-*.conf files explicitly (instead of
    # piping through xargs+sh -c, which lost stdin/stdout semantics and
    # made it impossible to apply a function-based redactor).
    while IFS= read -r f; do
        echo
        echo "--- $f (sanitised) ---"
        sudo cat "$f" 2>/dev/null | redact_supplicant_secrets
    done < <(sudo grep -lE '^[[:space:]]*ssid=' /etc/wpa_supplicant/*.conf 2>/dev/null | head -3)
fi

# ── 12. Recent NetworkManager journal ──────────────────────
section "12. journalctl -u NetworkManager -b 0 (last 60 lines)"
if sudo -n true 2>/dev/null; then
    sudo journalctl -u NetworkManager -b 0 --no-pager 2>/dev/null \
      | tail -60 \
      || echo "(no journalctl access)"
else
    journalctl -u NetworkManager -b 0 --no-pager 2>/dev/null \
      | tail -60 \
      || echo "(no journalctl access — try sudo)"
fi

section "12b. journalctl -u wpa_supplicant -b 0 (last 30 lines)"
if sudo -n true 2>/dev/null; then
    sudo journalctl -u wpa_supplicant -b 0 --no-pager 2>/dev/null \
      | tail -30 \
      || echo "(no journalctl access)"
fi

section "END"
echo
echo "Paste this output back to me.  Sensitive values redacted: psk= /"
echo "password= / ext_password= lines from wpa_supplicant configs are"
echo "filtered.  Everything else is environmental / state info."
