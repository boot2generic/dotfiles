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
# Reversal: pass --revert.  Restores the most recent set of backup
# files written by a prior takeover (or prompts for a generation if
# multiple exist), removes our conf.d snippet, re-enables whichever
# backend (wpa_supplicant / iwd / ifupdown) was running before, and
# restarts NetworkManager.  See readme/system.md → "WiFi shows
# 'unmanaged'" for the manual equivalent.

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
REVERT=0
# Accept --yes / -y and --revert in either order.  Keep the loop tiny
# rather than reaching for getopts — only two flags and existing code
# assumed a single optional arg.
for _arg in "$@"; do
    case "$_arg" in
        --yes|-y)  YES=1 ;;
        --revert)  REVERT=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown flag: $_arg" >&2; exit 2 ;;
    esac
done
unset _arg

confirm() {
    (( YES )) && return 0
    local prompt="${1:-Continue?} [y/N] " ans
    read -rp "$prompt" ans || ans=""
    [[ "${ans:-}" =~ ^[Yy] ]]
}

# ── nm_write_psk_profile: create a .nmconnection file with PSK on disk only ──
# Args: <profile_name> <wifi_iface> <ssid> <psk>
# Writes /etc/NetworkManager/system-connections/<profile>.nmconnection (mode
# 0600 owned by root) then `nmcli connection reload`s.  The PSK NEVER appears
# on any process argv: `printf` is a bash builtin (no fork/exec) and `install`
# only sees `/dev/stdin` as its file argument.  The alternative —
# `nmcli connection add … wifi-sec.psk "$PSK"` — leaks the PSK via
# `ps`/`/proc/<pid>/cmdline` for the lifetime of the nmcli call.
#
# Returns 0 on success, non-zero on failure (and removes the partial file).
nm_write_psk_profile() {
    local profile="$1" iface="$2" ssid="$3" psk="$4"
    local path="/etc/NetworkManager/system-connections/${profile}.nmconnection"
    local uuid
    if command -v uuidgen >/dev/null 2>&1; then
        uuid="$(uuidgen)"
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        uuid="$(cat /proc/sys/kernel/random/uuid)"
    else
        warn "no uuidgen and /proc/sys/kernel/random/uuid unreadable"
        return 1
    fi
    if {
        printf '[connection]\nid=%s\nuuid=%s\ntype=wifi\ninterface-name=%s\nautoconnect=true\n\n' \
            "$profile" "$uuid" "$iface"
        printf '[wifi]\nmode=infrastructure\nssid=%s\n\n' "$ssid"
        printf '[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n' "$psk"
        printf '[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n'
    } | sudo install -m 0600 -o root -g root /dev/stdin "$path" \
       && sudo nmcli connection reload >/dev/null 2>&1; then
        return 0
    fi
    sudo rm -f "$path" 2>/dev/null || true
    return 1
}

# ── Sanity ─────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] && die "Run as a regular user — sudo will be invoked where needed."
command -v nmcli >/dev/null 2>&1 || die "nmcli not installed — run \`sudo apt install network-manager\`"

# ── --revert: undo a prior takeover ────────────────────────────────
# Why a dedicated branch this early in the script: the rest of the
# script probes NM device state and exits if the iface is already
# NM-managed — which is exactly the state we expect a user reverting
# FROM.  Handle revert before any of that.
if (( REVERT )); then
    NM_CONF=/etc/NetworkManager/conf.d/10-globally-managed-devices.conf

    # Discover every distinct timestamp suffix across interfaces +
    # interfaces.d/ in one pass.  We use the suffix (not the path) so a
    # user reverting in one shot gets BOTH the parent file and any
    # split-out interfaces.d/* fragments restored together.
    declare -a TS_LIST=()
    while IFS= read -r ts; do
        [[ -n "$ts" ]] && TS_LIST+=("$ts")
    done < <(
        {
            ls -1 /etc/network/interfaces.bak.* 2>/dev/null || true
            ls -1 /etc/network/interfaces.d/*.bak.* 2>/dev/null || true
        } | sed -nE 's/.*\.bak\.([0-9]{8}-[0-9]{6})$/\1/p' \
          | sort -ru
    )

    if (( ${#TS_LIST[@]} == 0 )) && [[ ! -f "$NM_CONF" ]]; then
        log "No backup files under /etc/network/ and no $NM_CONF —"
        log "nothing to revert.  (Has this script ever been run here?)"
        exit 0
    fi

    # Pick a generation.  --yes auto-selects the newest (sort -ru above
    # already put it first); otherwise prompt only if there's ambiguity.
    CHOSEN_TS=""
    if (( ${#TS_LIST[@]} == 1 )); then
        CHOSEN_TS="${TS_LIST[0]}"
    elif (( ${#TS_LIST[@]} > 1 )); then
        if (( YES )); then
            CHOSEN_TS="${TS_LIST[0]}"
            log "Multiple backup generations found; --yes → using newest: $CHOSEN_TS"
        else
            echo "Multiple backup generations found:"
            local_i=1
            for ts in "${TS_LIST[@]}"; do
                echo "  [$local_i] $ts$([[ "$ts" == "${TS_LIST[0]}" ]] && echo '  (newest)')"
                local_i=$((local_i + 1))
            done
            read -rp "Pick a generation [1-${#TS_LIST[@]}] (default 1): " sel
            sel="${sel:-1}"
            if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#TS_LIST[@]} )); then
                die "Invalid selection: $sel"
            fi
            CHOSEN_TS="${TS_LIST[$((sel - 1))]}"
            unset local_i sel
        fi
    fi

    if [[ -n "$CHOSEN_TS" ]]; then
        log "Reverting backup generation: $CHOSEN_TS"
        confirm "Restore /etc/network/interfaces* from .bak.${CHOSEN_TS}?" \
            || { log "Aborted."; exit 0; }

        # Restore by moving (not copying) — backups are consumed.  This
        # matches the "one revert per generation" semantics and avoids
        # leaving stale .bak files around that confuse the next revert.
        if [[ -f "/etc/network/interfaces.bak.${CHOSEN_TS}" ]]; then
            sudo mv "/etc/network/interfaces.bak.${CHOSEN_TS}" /etc/network/interfaces \
                && ok "restored /etc/network/interfaces"
        fi
        # Each interfaces.d/<file>.bak.TS restores back to <file>.
        shopt -s nullglob
        for bak in /etc/network/interfaces.d/*.bak."${CHOSEN_TS}"; do
            orig="${bak%.bak.${CHOSEN_TS}}"
            sudo mv "$bak" "$orig" \
                && ok "restored $orig"
        done
        shopt -u nullglob
    else
        warn "No /etc/network/interfaces*.bak.* files found — skipping restore"
    fi

    # Remove our managed=true override.  Its own comment header says
    # "Remove this file to revert" — do exactly that.
    if [[ -f "$NM_CONF" ]]; then
        sudo rm -f "$NM_CONF" \
            && ok "removed $NM_CONF"
    else
        log "$NM_CONF already absent"
    fi

    # Pre-imported NM profiles ("ifupdown-import-*") will conflict with
    # ifupdown reclaiming the iface.  Offer to delete; default yes under
    # --yes, prompt otherwise.
    declare -a NM_IMPORTED=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && NM_IMPORTED+=("$name")
    done < <(nmcli -t -f NAME connection show 2>/dev/null \
             | grep -E '^ifupdown-import-' || true)
    if (( ${#NM_IMPORTED[@]} > 0 )); then
        log "Found pre-imported NM profiles from takeover:"
        for n in "${NM_IMPORTED[@]}"; do log "  • $n"; done
        if confirm "Delete these NM profiles?"; then
            for n in "${NM_IMPORTED[@]}"; do
                sudo nmcli connection delete "$n" >/dev/null 2>&1 \
                    && ok "deleted NM profile: $n" \
                    || warn "couldn't delete NM profile: $n"
            done
        else
            warn "Leaving NM profiles in place — they may fight ifupdown for the iface"
        fi
    fi

    # Figure out which backend to bring back.  Heuristic ordering:
    #   1. /etc/wpa_supplicant/wpa_supplicant-<iface>.conf → wpa_supplicant
    #   2. anything under /var/lib/iwd/                    → iwd
    #   3. otherwise → ifupdown only (now that interfaces is restored)
    # If none of these match, don't guess — tell the user what to do.
    REVERT_IFACE="$(nmcli -t -f DEVICE,TYPE device 2>/dev/null \
                    | awk -F: '$2 == "wifi" {print $1; exit}' || true)"
    [[ -z "$REVERT_IFACE" ]] && REVERT_IFACE="wlan0"

    chose_backend=""
    if [[ -f "/etc/wpa_supplicant/wpa_supplicant-${REVERT_IFACE}.conf" ]]; then
        chose_backend="wpa_supplicant@${REVERT_IFACE}"
    elif [[ -d /var/lib/iwd ]] && \
         find /var/lib/iwd -maxdepth 1 -type f \( -name '*.psk' -o -name '*.open' -o -name '*.8021x' \) \
              2>/dev/null | grep -q .; then
        chose_backend="iwd"
    fi

    if [[ -n "$chose_backend" ]]; then
        log "Re-enabling previous backend: $chose_backend"
        sudo systemctl enable --now "$chose_backend" >/dev/null 2>&1 \
            && ok "$chose_backend enabled + started" \
            || warn "couldn't start $chose_backend — check \`systemctl status $chose_backend\`"
    else
        warn "Couldn't detect a previous wifi backend automatically."
        warn "If you used ifupdown alone (wpa-ssid in /etc/network/interfaces),"
        warn "the restore above is enough — \`sudo ifup $REVERT_IFACE\` should work."
        warn "Otherwise re-enable manually, e.g.:"
        warn "  sudo systemctl enable --now wpa_supplicant"
        warn "  sudo systemctl enable --now iwd"
        warn "  sudo systemctl enable --now systemd-networkd"
    fi

    # Restart NM regardless — we just yanked its conf.d snippet and may
    # have left it with a now-stale view of the iface.
    log "restarting NetworkManager …"
    sudo systemctl restart NetworkManager >/dev/null 2>&1 || true

    echo
    ok "Revert complete."
    log "Verify with:"
    log "  ip a show $REVERT_IFACE"
    log "  ping -c1 \$(ip route show default | awk '{print \$3}')"
    log "  systemctl status ${chose_backend:-NetworkManager}"
    exit 0
fi

# ── Detect the wifi interface ──────────────────────────────────────
WIFI_IFACE="$(nmcli -t -f DEVICE,TYPE device 2>/dev/null \
              | awk -F: '$2 == "wifi" {print $1; exit}' || true)"
[[ -z "$WIFI_IFACE" ]] \
  && die "No wifi device found.  Check \`lspci -k | grep -A2 -i network\` and \`dmesg | grep firmware\`."

CURRENT_STATE="$(nmcli -t -f DEVICE,STATE device 2>/dev/null \
                 | awk -F: -v d="$WIFI_IFACE" '$1==d {print $2; exit}' || true)"
log "wifi iface       : $WIFI_IFACE"
log "current NM state : ${CURRENT_STATE:-?}"

NM_CONF=/etc/NetworkManager/conf.d/10-globally-managed-devices.conf

# ── Privileged reads of /etc/network/interfaces* ───────────────────
# Debian writes /etc/network/interfaces as mode 0600 root whenever it
# holds a wpa-psk, so EVERY read of it has to go through sudo.  This
# used to be an unprivileged `grep … 2>/dev/null`, which made
# "permission denied" indistinguishable from "no wifi stanza here":
# the comment-out step below silently never ran, ifupdown kept the
# stanza, and `ifup -a` reclaimed the card on the next boot.  That is
# the bug that made this script something you had to re-run after
# every restart — the runtime half took effect, the persistent half
# never did.  If you touch these helpers, keep the sudo.

# Every ifupdown config file that can claim an interface.
iface_files() {
    [[ -e /etc/network/interfaces ]] && printf '%s\n' /etc/network/interfaces
    shopt -s nullglob
    local f
    for f in /etc/network/interfaces.d/*; do
        [[ "$f" == *.bak.* ]] && continue
        printf '%s\n' "$f"
    done
    shopt -u nullglob
}

# Does $1 carry an ACTIVE (uncommented) stanza for the wifi iface?
# Field-based rather than one big regex, so that detection and the
# rewrite below agree by construction: an `auto` line may list several
# ifaces, and matching that with an ERE needs `(^|[[:space:]])`, whose
# mid-pattern `^` is undefined in POSIX (GNU grep happens to accept it;
# busybox need not).  A silent false negative here is the exact bug
# this script exists to fix — don't reintroduce it for terseness.
# Lines already commented out start with `#` and match nothing, so
# re-running this is a no-op.
file_claims_iface() {
    local f="$1"
    sudo test -f "$f" || return 1
    sudo awk -v IF="$WIFI_IFACE" '
        /^[[:space:]]*(auto|allow-hotplug)[[:space:]]+/ {
            for (i = 2; i <= NF; i++) if ($i == IF) { found = 1; exit }
        }
        /^[[:space:]]*iface[[:space:]]+/ {
            if ($2 == IF) { found = 1; exit }
        }
        END { exit(found ? 0 : 1) }
    ' "$f"
}

# Comment out the wifi iface's stanza in $1, backing up to $1.bak.$2.
comment_out_iface_in_file() {
    local f="$1" ts="$2" mode
    # Preserve the original mode.  The commented-out lines STILL carry
    # the PSK (`# disabled-by-take-over-wifi: wpa-psk hunter2`), so
    # rewriting a 0600 file as 0644 would publish the passphrase to
    # every local user.  Never hardcode a mode here.
    mode="$(sudo stat -c %a "$f" 2>/dev/null || echo 600)"
    sudo cp -a "$f" "${f}.bak.${ts}"
    sudo awk -v IF="$WIFI_IFACE" '
        BEGIN { in_block = 0 }
        # `auto`/`allow-hotplug` may list several ifaces on one line.
        # Drop just our iface; comment the line only if it named ours
        # alone.
        /^[[:space:]]*(auto|allow-hotplug)[[:space:]]+/ {
            kept = ""; found = 0
            for (i = 2; i <= NF; i++) {
                if ($i == IF) { found = 1 } else { kept = kept " " $i }
            }
            if (!found) { print; next }
            print "# disabled-by-take-over-wifi: " $0
            if (kept != "") { print $1 kept }
            next
        }
        # `iface <ours> …` — comment the header, enter the block.
        /^[[:space:]]*iface[[:space:]]+/ {
            if ($2 == IF) { print "# disabled-by-take-over-wifi: " $0; in_block = 1; next }
            in_block = 0; print; next
        }
        # Any other top-level directive closes the block.
        /^[^[:space:]#]/                { in_block = 0; print; next }
        # Indented continuation of OUR block (wpa-ssid, wpa-psk, …).
        in_block && /^[[:space:]]/      { print "# disabled-by-take-over-wifi: " $0; next }
        { print }
    ' "$f" | sudo install -m "$mode" /dev/stdin "${f}.new"
    # install + mv is two privileged steps; a Ctrl-C between them would
    # strand the .new file.  Reap it on every exit path.  The mv itself
    # is atomic (rename(2), same filesystem).
    # shellcheck disable=SC2064  # $f must expand now, not at trap time
    trap "sudo rm -f '${f}.new' 2>/dev/null || true" EXIT
    sudo mv "${f}.new" "$f"
    trap - EXIT
}

# ── persist_takeover: the half that has to survive a reboot ────────
# Stopping the old backend and restarting NM only fixes the CURRENT
# boot.  What makes a takeover stick is all three of:
#   1. no active wifi stanza in /etc/network/interfaces{,.d/*} — else
#      ifupdown's boot-time `ifup -a` spawns its own wpa_supplicant
#      and grabs the card before NM sees it;
#   2. the NM conf.d snippet (managed=true);
#   3. the old backends disabled at boot, not merely stopped.
# Idempotent, and it never touches the live link — safe to run when
# wifi is already up and NM-managed.  Sets PERSIST_CHANGED.
PERSIST_CHANGED=0
persist_takeover() {
    local ts f svc
    ts="$(date +%Y%m%d-%H%M%S)"

    # 1. ifupdown stanzas — parent file AND interfaces.d/* fragments.
    #    (The old code backed up the fragments but only ever rewrote
    #    the parent, so a stanza living in interfaces.d/ survived.)
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        file_claims_iface "$f" || continue
        log "active $WIFI_IFACE stanza found in $f"
        comment_out_iface_in_file "$f" "$ts"
        ok "commented out $WIFI_IFACE in $f  (backup: ${f}.bak.${ts})"
        PERSIST_CHANGED=1
    done < <(iface_files)

    # 2. NetworkManager conf.d → managed=true.
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
        PERSIST_CHANGED=1
    else
        log "$NM_CONF already present"
    fi

    # 3. Disable the old backends at BOOT.  No `--now` here: this
    #    function runs on the already-connected path too, and we must
    #    not drop a working link.  Note wpa_supplicant.service being
    #    `disabled` yet `active` is the correct end state — NM
    #    D-Bus-activates it on demand; only the boot-time standalone
    #    start is the problem.
    for svc in iwd wpa_supplicant systemd-networkd \
               "wpa_supplicant@${WIFI_IFACE}" \
               "wpa_supplicant-nl80211@${WIFI_IFACE}" \
               "wpa_supplicant-wired@${WIFI_IFACE}"; do
        if [[ "$(systemctl is-enabled "$svc" 2>/dev/null || true)" == "enabled" ]]; then
            log "disabling $svc at boot …"
            sudo systemctl disable "$svc" >/dev/null 2>&1 \
                && { ok "$svc disabled at boot"; PERSIST_CHANGED=1; } \
                || warn "couldn't disable $svc"
        fi
    done

    return 0
}

case "$CURRENT_STATE" in
    "")
        die "NetworkManager doesn't see $WIFI_IFACE — check \`nmcli device\`."
        ;;
    connected|connecting|disconnected)
        ok "$WIFI_IFACE is already NM-managed (state=$CURRENT_STATE)."
        log "Checking whether that survives a reboot …"
        echo
        # Don't just bail here.  "NM owns the card right now" and "NM
        # will still own it after a reboot" are different claims, and
        # the gap between them is exactly why this script kept needing
        # a re-run: a previous run applied the runtime half, the
        # persistent half was skipped, and ifupdown took the card back
        # on every boot.  Repair the persistent half in place — none of
        # it touches the live link.
        persist_takeover
        echo
        if (( PERSIST_CHANGED )); then
            ok "Persistent state repaired — the takeover should now survive reboots."
            log "ifupdown will no longer claim $WIFI_IFACE at boot."
        else
            ok "Already persistent — nothing to change."
            log "If the polybar pill still misbehaves, run"
            log "  ~/.config/polybar/scripts/wifi-menu.sh --diag"
        fi
        exit 0
        ;;
    unmanaged|unavailable)
        : # proceed with the full (disruptive) takeover
        ;;
    *)
        warn "Unexpected state ($CURRENT_STATE) — proceeding cautiously"
        ;;
esac

# ── Pre-flight: are we about to drop the network we're using? ──────
ETH_UP=0
# `ip -br link` emits "NAME<spaces>STATE<spaces>..." with NO colon, e.g.
#   enp0s31f6    UP    90:2e:16:47:03:a7 <...>
# Match the operational state in field 2 against any ethernet-named iface
# (predictable names start with `en`; legacy with `eth`).  wlan names
# start with `wl` so they can't false-match.
while read -r ifname state _; do
    [[ "$state" == "UP" && "$ifname" =~ ^(en|eth) ]] && ETH_UP=1
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
# `sudo test -r`, not `[[ -r … ]]`: the file is mode 0600 root exactly
# when it holds a wpa-psk, so the unprivileged read test is false
# precisely in the case this block exists to handle.  With the plain
# `[[ -r ]]` gate, the pre-import silently never ran and every takeover
# fell through to the interactive SSID/password prompt.
if sudo test -r /etc/network/interfaces; then
    # Parse the matching `iface <WIFI_IFACE>` block for SSID + PSK.
    #
    # The original implementation `eval`d shell-quoted awk output, which
    # only escaped literal apostrophes — a credential containing `$(...)`
    # or backticks would have executed as shell.  We now emit NUL-
    # delimited `key\tvalue\0` records and consume them via bash `read`,
    # which treats every byte (including $, `, ", \) as a literal — no
    # shell expansion ever sees the secret.
    while IFS=$'\t' read -r -d '' _key _val; do
        case "$_key" in
            ssid) INTERFACES_SSID="$_val" ;;
            psk)  INTERFACES_PSK="$_val"  ;;
        esac
    done < <(sudo awk -v IF="$WIFI_IFACE" '
        BEGIN { in_block = 0 }
        /^[[:space:]]*iface[[:space:]]+/ {
            in_block = ($2 == IF) ? 1 : 0
            next
        }
        in_block && /^[[:space:]]*wpa-ssid[[:space:]]+/ {
            v = $0
            sub(/^[[:space:]]*wpa-ssid[[:space:]]+/, "", v)
            sub(/^"/, "", v); sub(/"$/, "", v)
            printf "ssid\t%s\0", v
        }
        in_block && /^[[:space:]]*wpa-(psk|passphrase|password)[[:space:]]+/ {
            v = $0
            sub(/^[[:space:]]*wpa-(psk|passphrase|password)[[:space:]]+/, "", v)
            sub(/^"/, "", v); sub(/"$/, "", v)
            printf "psk\t%s\0", v
        }
    ' /etc/network/interfaces 2>/dev/null)
    unset _key _val
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
        if nm_write_psk_profile "$PROFILE_NAME" "$WIFI_IFACE" \
                                "$INTERFACES_SSID" "$INTERFACES_PSK"; then
            ok "imported as NM profile: $PROFILE_NAME (file mode 0600)"
        else
            warn "nmconnection write failed — falling back to interactive prompt"
        fi
        unset INTERFACES_PSK
    fi
else
    warn "Couldn't extract SSID/PSK from /etc/network/interfaces."
    warn "You'll be prompted for them at the end of this script — be"
    warn "ready with both before continuing."
fi

# ── Step 1: make the takeover persistent ───────────────────────────
# Comments out the ifupdown stanzas, writes the NM conf.d snippet, and
# disables the old backends at boot.  Done BEFORE we stop anything, so
# that even if the steps below fail we don't leave a machine that
# reverts to ifupdown on the next reboot.
persist_takeover

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

# ── Step 4: (was the conf.d write — now done by persist_takeover) ──

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

# `--yes` (auto_wifi_takeover from local_setup.sh's setup action runs
# this) means there's no human at the keyboard.  If we got HERE, the
# pre-import did NOT produce a working connection — and we can't ask
# the user for a password from a non-interactive context.  Bail with a
# clear error pointing at the manual recovery path rather than block
# on `read` until the SSH session times out.
if (( YES )); then
    err "Pre-import didn't reconnect and we're in --yes mode (no stdin)."
    err "Network is now in a transitional state (NM owns the device but"
    err "no profile is active).  Recover with one of:"
    err "  • Re-run interactively:    $0          # without --yes"
    err "  • Restore the prior backend: see readme/system.md → 'WiFi shows unmanaged'"
    err "  • Manual nmcli:            nmcli device wifi connect 'SSID' password 'PW'"
    exit 1
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
    # Write the .nmconnection file directly so the PSK never appears on
    # argv (`nmcli device wifi connect … password "$PW"` would leak it
    # via `ps` / `/proc/<pid>/cmdline` for the lifetime of the call).
    # Caveat: the file we write hardcodes `key-mgmt=wpa-psk`, which does
    # NOT cover WPA3-Personal (which needs `key-mgmt=sae`).  If
    # `nmcli connection up` fails — likely on a pure WPA3 AP, or on a
    # PSK typo — we delete the partial profile and fall back to
    # `nmcli device wifi connect` (which auto-detects key-mgmt from
    # the scan results).  That fallback briefly puts the PSK on argv,
    # but trading a few-ms ps-visible secret for "can't connect at all"
    # is the right call on a user-driven interactive prompt.
    INTERACTIVE_PROFILE="${SSID}"
    _used_argv_fallback=0
    if nm_write_psk_profile "$INTERACTIVE_PROFILE" "$WIFI_IFACE" "$SSID" "$PW"; then
        ok "profile written to /etc/NetworkManager/system-connections/${INTERACTIVE_PROFILE}.nmconnection"
        if sudo nmcli connection up "$INTERACTIVE_PROFILE" >/dev/null; then
            ok "connected to '$SSID'"
        else
            warn 'profile up failed — likely WPA3 AP (SAE) or PSK typo; falling back to nmcli auto-detect'
            sudo nmcli connection delete "$INTERACTIVE_PROFILE" >/dev/null 2>&1 || true
            _used_argv_fallback=1
        fi
    else
        warn 'couldn'"'"'t write nmconnection file — falling back to plain nmcli (PSK briefly on argv)'
        _used_argv_fallback=1
    fi
    if (( _used_argv_fallback )); then
        sudo nmcli device wifi connect "$SSID" password "$PW"
    fi
    unset PW _used_argv_fallback
fi

ok "Done.  Polybar wlan pill should render in the next few seconds."
