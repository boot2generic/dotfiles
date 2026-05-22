#!/usr/bin/env bash
# scripts/dotfiles-doctor.sh
#
# "Comprehensive health: what's going on with this machine?" — a
# one-page CLI report that's the standalone counterpart to the conky
# HEALTH panel rendered by ~/.config/conky/health.py.
#
# Conky's health panel is great when you're at the desk and the panel
# is open.  When you're SSH'd into the machine, running a cron audit,
# or just want a single textual snapshot to paste into a bug report,
# you want this script instead.  It covers the same checks plus a few
# desktop-only ones (deploy-state drift between ~/.config and the
# repo, default route iface, DNS resolvers, Mullvad).
#
# It SHELLS OUT to scripts/audit.sh for the baseline-drift checks
# rather than re-implementing them — there's exactly one source of
# truth for "what does drift mean".
#
# Output sections (in order):
#   1. DRIFT          — audit.sh summary
#   2. SUPPLY CHAIN   — verify-pins.sh per-app freshness + sha/gpg pins
#   3. SYSTEM         — disk, memory, OOM kills, kernel taint, NTP,
#                       pending firmware updates, pending reboot
#   4. NETWORK        — listening ports / established conns, default
#                       route, DNS, Mullvad
#   5. DEPLOY         — is ~/.config/{plasma,i3}/ in sync with the repo?
#
# Behaviour:
#   default     full report, every row printed
#   --brief     only non-OK rows (cron + MAILTO friendly)
#   --no-color  strip ANSI even on a tty
#
# Exit code (Nagios-style):
#   0  everything OK
#   1  at least one WARN
#   2  at least one BAD
#
# Usage:
#   ./scripts/dotfiles-doctor.sh
#   ./scripts/dotfiles-doctor.sh --brief
#   ./scripts/dotfiles-doctor.sh --no-color
#   ./scripts/dotfiles-doctor.sh --help

set -euo pipefail

# ── Resolve own location regardless of CWD ─────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
AUDIT_SH="${SCRIPT_DIR}/audit.sh"
VERIFY_PINS_SH="${SCRIPT_DIR}/verify-pins.sh"

# ── Argument parsing ───────────────────────────────────────────────
BRIEF=0
USE_COLOR=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --brief)    BRIEF=1 ;;
        --no-color) USE_COLOR=0 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown flag: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

# ── Colour helpers (same palette as take-over-wifi.sh) ─────────────
if (( USE_COLOR )) && [[ -t 1 ]]; then
    C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'
    C_DIM=$'\e[2m'; C_BOLD=$'\e[1m'; C_RST=$'\e[0m'
else
    C_OK= ; C_WARN= ; C_ERR= ; C_DIM= ; C_BOLD= ; C_RST=
fi

# Track worst status seen for the exit code.  ok < warn < bad.
WORST="ok"
bump() {
    local s="$1"
    case "$s:$WORST" in
        bad:*)         WORST="bad" ;;
        warn:ok|warn:dim) WORST="warn" ;;
    esac
}

# Print a row "[status] label: detail" with colouring.  In --brief
# mode, suppress OK rows entirely (so cron mails are short).
row() {
    local status="$1" label="$2" detail="$3"
    bump "$status"
    if (( BRIEF )) && [[ "$status" == "ok" || "$status" == "dim" ]]; then
        return 0
    fi
    case "$status" in
        ok)   printf '%s[ok]%s     %-22s %s\n'   "$C_OK"  "$C_RST" "$label" "$detail" ;;
        warn) printf '%s[warn]%s   %-22s %s\n'   "$C_WARN" "$C_RST" "$label" "$detail" ;;
        bad)  printf '%s[bad]%s    %-22s %s\n'   "$C_ERR" "$C_RST" "$label" "$detail" ;;
        dim|*)printf '%s[dim]%s    %-22s %s\n'   "$C_DIM" "$C_RST" "$label" "$detail" ;;
    esac
}

section() {
    # In --brief mode the section header still helps the reader locate
    # which subsystem the (sparse) non-OK rows came from.
    local title="$1"
    printf '\n%s── %s ──────────────────────────────%s\n' \
        "$C_BOLD" "$title" "$C_RST"
}

# ── 1. DRIFT ───────────────────────────────────────────────────────
# We shell out to audit.sh rather than re-implement the four drift
# checks — there's one canonical source of truth and audit.sh already
# handles the colour vs no-colour and JSON output modes we need.
do_drift() {
    section "DRIFT (baselines)"
    if [[ ! -x "$AUDIT_SH" ]]; then
        row dim "audit.sh" "not executable at $AUDIT_SH — skipping"
        return
    fi
    # Force no-color from audit.sh; we'll re-colour ourselves to keep
    # the output uniform with the rest of the doctor report.  audit.sh
    # uses the same ok/warn/bad/dim vocabulary as us.
    local out rc
    # Capture stdout AND exit code separately.  Naïvely chaining
    # `if ! out=... ; then echo $?` doesn't work — by the time the
    # then-branch runs, `$?` reflects the [[ ... ]] negation, not
    # audit.sh's exit.  Stash audit's rc immediately after the
    # command-substitution closes.  `|| true` prevents `set -e` from
    # aborting on audit's expected exit 1.
    out="$(NO_COLOR=1 "$AUDIT_SH" 2>&1)" && rc=0 || rc=$?
    # audit.sh exits 1 on BAD — that's expected, not an error here.
    # Only treat exit >=2 as a hard failure of the audit tool itself.
    if (( rc >= 2 )); then
        row bad "audit.sh" "exited $rc (tool failure, not drift)"
        return
    fi
    # Parse "[status]    name: summary" lines back into row() calls.
    while IFS= read -r line; do
        # Strip ANSI just in case (we passed NO_COLOR but defence-in-
        # depth — and the colour helpers also gate on isatty so a
        # piped invocation already comes out clean).
        line="$(printf '%s' "$line" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g')"
        # shellcheck disable=SC2001
        # (sed is the simplest way to do this strip without GNU bash
        # extension uncertainty.)
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^\[(ok|warn|bad|dim)\]+[[:space:]]+([^:]+):[[:space:]]*(.*)$ ]]; then
            local st="${BASH_REMATCH[1]}"
            local nm="${BASH_REMATCH[2]}"
            local sm="${BASH_REMATCH[3]}"
            row "$st" "$nm" "$sm"
        fi
    done <<<"$out"
}

# ── 2. SUPPLY CHAIN ────────────────────────────────────────────────
# Per-app pin freshness + sha/gpg verification.  We shell out to
# verify-pins.sh (Agent C, scripts/verify-pins.sh) in non-JSON mode and
# parse its [ok]/[stale]/[bad] markers back into row() — same trick as
# do_drift() but the underlying severity vocabulary uses "stale"
# instead of "warn".  Map stale → warn for consistency with the rest
# of the doctor report.
#
# When verify-pins.sh hasn't landed yet (parallel agent rollout) the
# section emits a single dim row instead of misclassifying the absence
# as a tool failure.
do_supply_chain() {
    section "SUPPLY CHAIN (pins)"
    if [[ ! -x "$VERIFY_PINS_SH" ]]; then
        row dim "verify-pins.sh" "not installed at $VERIFY_PINS_SH"
        return
    fi
    local out rc
    # Same exit-code capture pattern as do_drift's audit.sh invocation:
    # verify-pins.sh exits non-zero on stale/bad pins (expected, not a
    # tool failure).  Stash rc separately so we can distinguish.
    out="$(NO_COLOR=1 "$VERIFY_PINS_SH" 2>&1)" && rc=0 || rc=$?
    # Conventionally: rc=0 ok, rc=1 stale, rc=2 bad, rc>=3 tool fault.
    if (( rc >= 3 )); then
        row bad "verify-pins.sh" "exited $rc (tool failure)"
        return
    fi
    local any_row=0
    while IFS= read -r line; do
        line="$(printf '%s' "$line" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g')"
        [[ -z "$line" ]] && continue
        # verify-pins.sh format is column-aligned (Agent C):
        #   "[<status>]    <app>          <age>d <method>"
        # We don't use `:` as a field separator — split on whitespace
        # and take the first three tokens.
        if [[ "$line" =~ ^\[(ok|stale|bad)\][[:space:]]+([A-Za-z0-9_.+-]+)[[:space:]]+(.*)$ ]]; then
            local st="${BASH_REMATCH[1]}"
            local nm="${BASH_REMATCH[2]}"
            local sm="${BASH_REMATCH[3]}"
            # Trim trailing whitespace introduced by column padding.
            sm="${sm%"${sm##*[![:space:]]}"}"
            # stale → warn in doctor's vocabulary; ok/bad pass through.
            [[ "$st" == "stale" ]] && st="warn"
            row "$st" "$nm" "$sm"
            any_row=1
        fi
    done <<<"$out"
    if (( ! any_row )); then
        # verify-pins.sh ran but produced no parseable rows — surface
        # the raw first line so the operator can debug.
        local first; first="$(head -1 <<<"$out")"
        row dim "verify-pins.sh" "no parseable output${first:+ (saw: ${first:0:40})}"
    fi
}

# ── 3. SYSTEM ──────────────────────────────────────────────────────
# Mirrors a subset of health.py's non-drift checks, plus a couple of
# extras that don't fit on the conky panel (high-CPU spike already in
# health.py, so we omit it here — it's an instantaneous snapshot
# whose CLI value is low).

do_disk() {
    # >=95% bad, >=85% warn, else ok.  -x excludes the noise filesystems
    # health.py ignores.
    local out worst="ok" detail="all <85%"
    out="$(df --output=pcent,target,fstype -x tmpfs -x devtmpfs -x squashfs -x overlay --local 2>/dev/null | tail -n +2)"
    local hits=()
    while IFS= read -r ln; do
        [[ -z "$ln" ]] && continue
        local pct mount
        pct="$(awk '{print $1}' <<<"$ln" | tr -d '%')"
        mount="$(awk '{print $2}' <<<"$ln")"
        [[ "$pct" =~ ^[0-9]+$ ]] || continue
        if (( pct >= 95 )); then
            hits+=("${mount}=${pct}%"); worst="bad"
        elif (( pct >= 85 )); then
            hits+=("${mount}=${pct}%")
            [[ "$worst" == "ok" ]] && worst="warn"
        fi
    done <<<"$out"
    if (( ${#hits[@]} > 0 )); then
        detail="${hits[*]}"
    fi
    row "$worst" "disk space" "$detail"
}

do_memory_pressure() {
    if [[ ! -r /proc/pressure/memory ]]; then
        row dim "mem pressure" "PSI unavailable"
        return
    fi
    local avg10
    avg10="$(awk '/^some/ { for (i=1;i<=NF;i++) if ($i ~ /^avg10=/) {sub(/^avg10=/,"",$i); print $i} }' /proc/pressure/memory)"
    [[ -z "$avg10" ]] && { row dim "mem pressure" "no avg10"; return; }
    # awk-friendly float compare (bash arithmetic is int-only).
    local cmp
    cmp="$(awk -v v="$avg10" 'BEGIN{ if (v>=10) print "bad"; else if (v>=5) print "warn"; else print "ok" }')"
    row "$cmp" "mem pressure" "avg10=${avg10}%"
}

do_oom() {
    # Same query as health.py.  journalctl -k limits to kernel-tagged
    # log entries; --grep is a regex.
    local n
    n="$(journalctl -b -k --no-pager -q --grep='Out of memory|Killed process' 2>/dev/null \
         | grep -ciE 'out of memory|killed process' || true)"
    [[ -z "$n" ]] && n=0
    if (( n == 0 )); then
        row ok "OOM kills" "none this boot"
    else
        row bad "OOM kills" "${n} this boot"
    fi
}

do_kernel_taint() {
    if [[ ! -r /proc/sys/kernel/tainted ]]; then
        row dim "kernel taint" "n/a"
        return
    fi
    local v; v="$(cat /proc/sys/kernel/tainted)"
    if (( v == 0 )); then
        row ok "kernel taint" "clean"
        return
    fi
    # Same benign mask as health.py: proprietary (1) + OOT (4096) + unsigned (8192)
    local benign=$(( 1 | 4096 | 8192 ))
    if (( (v & ~benign) == 0 )); then
        row warn "kernel taint" "=${v} (driver-only)"
    else
        row bad "kernel taint" "=${v} hw/oops/etc"
    fi
}

do_ntp() {
    # `timedatectl show` is more parseable than `status`.  Two values:
    # NTPSynchronized=yes|no, NTP=yes|no.
    local out; out="$(timedatectl show -p NTPSynchronized -p NTP --value 2>/dev/null || true)"
    if [[ -z "$out" ]]; then
        row dim "NTP sync" "timedatectl n/a"
        return
    fi
    # Two-line output: first line is NTPSynchronized, second is NTP.
    # `timedatectl show -p A -p B --value` honours the order of -p,
    # so line 1=NTPSynchronized, line 2=NTP.
    local synced enabled
    synced="$(awk 'NR==1{print}' <<<"$out")"
    enabled="$(awk 'NR==2{print}' <<<"$out")"
    if [[ "$enabled" != "yes" ]]; then
        row warn "NTP sync" "service off"
    elif [[ "$synced" != "yes" ]]; then
        row bad "NTP sync" "not synced"
    else
        row ok "NTP sync" "synced"
    fi
}

do_firmware() {
    # fwupdmgr makes a network call; we don't cache like health.py does
    # because this script is run on-demand, not on a 5s loop.  Honour a
    # short timeout so an unreachable LVFS mirror doesn't hang the
    # whole doctor run.
    if ! command -v fwupdmgr >/dev/null 2>&1; then
        row dim "firmware (LVFS)" "fwupdmgr not installed"
        return
    fi
    local out
    out="$(timeout 10 fwupdmgr get-updates --json 2>/dev/null || true)"
    if [[ -z "$out" ]]; then
        row ok "firmware (LVFS)" "up to date (or no LVFS remote)"
        return
    fi
    local n
    n="$(grep -c '"AppstreamId"' <<<"$out" || true)"
    [[ -z "$n" ]] && n=0
    if (( n == 0 )); then
        row ok "firmware (LVFS)" "up to date"
    else
        row warn "firmware (LVFS)" "${n} pending"
    fi
}

do_reboot_required() {
    local running latest
    running="$(uname -r)"
    latest="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1)"
    if [[ -z "$latest" ]]; then
        row dim "kernel reboot" "no /boot/vmlinuz-*"
    elif [[ "$running" == "$latest" ]]; then
        row ok "kernel reboot" "running latest ($running)"
    else
        row warn "kernel reboot" "reboot for $latest (running $running)"
    fi
}

do_failed_services() {
    local out n first
    out="$(systemctl --failed --no-legend --plain 2>/dev/null || true)"
    n="$(grep -c '.' <<<"$out" || true)"
    [[ -z "$n" ]] && n=0
    if (( n == 0 )); then
        row ok "services" "all running"
    else
        first="$(awk 'NR==1{print $1}' <<<"$out")"
        row bad "services" "${n} failed (e.g. ${first})"
    fi
}

do_system() {
    section "SYSTEM"
    do_failed_services
    do_disk
    do_memory_pressure
    do_oom
    do_kernel_taint
    do_ntp
    do_reboot_required
    do_firmware
}

# ── 4. NETWORK ─────────────────────────────────────────────────────
# Standalone-CLI extras not in the conky panel.  None of these are
# severity-coded — they're informational rows you scan visually.  But
# we still emit them via row() so colours / brief mode behave.
do_network() {
    section "NETWORK"

    # Listening + established socket counts.  `ss -tln` for listeners
    # (TCP only — UDP listeners are rarely interesting on a workstation),
    # `ss -tn state established` for active connections.
    local n_listen n_established
    n_listen="$(ss -tln 2>/dev/null | awk 'NR>1' | grep -c '.' || true)"
    n_established="$(ss -tn state established 2>/dev/null | awk 'NR>1' | grep -c '.' || true)"
    [[ -z "$n_listen" ]] && n_listen=0
    [[ -z "$n_established" ]] && n_established=0
    row dim "sockets" "${n_listen} listening, ${n_established} established"

    # Default route iface + source IP.
    local route_line iface gw src
    route_line="$(ip -4 route show default 2>/dev/null | head -1)"
    if [[ -n "$route_line" ]]; then
        iface="$(awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' <<<"$route_line")"
        gw="$(awk '{for(i=1;i<=NF;i++) if ($i=="via") print $(i+1)}' <<<"$route_line")"
        src="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | head -1)"
        row ok "default route" "${iface} via ${gw} (src ${src:-?})"
    else
        # No default route is generally a problem (no internet) but
        # not always BAD — could be a deliberately air-gapped session.
        # Pick WARN as the middle ground.
        row warn "default route" "none configured"
    fi

    # DNS resolvers.  Source order: resolvectl > /etc/resolv.conf.
    # resolvectl is the better answer on systemd-resolved systems
    # because /etc/resolv.conf often just points at 127.0.0.53.
    local dns=""
    if command -v resolvectl >/dev/null 2>&1; then
        # `resolvectl dns` first line is "Global:", per-link follow.
        # Combine and dedupe.
        dns="$(resolvectl dns 2>/dev/null \
              | sed -E 's/^.*:[[:space:]]*//' \
              | tr ' ' '\n' \
              | awk 'NF' \
              | LC_ALL=C sort -u \
              | paste -sd' ' -)"
    fi
    if [[ -z "$dns" && -r /etc/resolv.conf ]]; then
        dns="$(awk '$1=="nameserver"{print $2}' /etc/resolv.conf \
              | paste -sd' ' -)"
    fi
    if [[ -z "$dns" ]]; then
        row warn "DNS" "no resolvers found"
    else
        row ok "DNS" "$dns"
    fi

    # Mullvad: only if installed.  Match health.py's classification
    # (connected = ok, disconnected = bad, anything else = warn) but
    # without the "is monitoring expected?" gate — on the CLI we always
    # report whatever state Mullvad is in.
    if command -v mullvad >/dev/null 2>&1; then
        local mout first
        mout="$(timeout 4 mullvad status 2>/dev/null || true)"
        first="$(printf '%s' "$mout" | head -1 | tr '[:upper:]' '[:lower:]')"
        if [[ -z "$first" ]]; then
            row warn "mullvad" "no response"
        elif [[ "$first" == connected* ]]; then
            # Extract relay short-name like health.py does.
            local relay
            relay="$(printf '%s' "$first" | sed -nE 's/.*connected to ([^ ,]+).*/\1/p')"
            row ok "mullvad" "connected${relay:+ ($relay)}"
        elif [[ "$first" == disconnected* ]]; then
            # Workstation, no expected-VPN flag set, just dim — we
            # don't know if disconnected is intentional.
            row dim "mullvad" "disconnected"
        else
            row warn "mullvad" "$(printf '%s' "$first" | cut -c1-40)"
        fi
    else
        row dim "mullvad" "not installed"
    fi
}

# ── 5. DEPLOY ──────────────────────────────────────────────────────
# Compare specific config dirs under ~/.config against the corresponding
# repo dirs under $REPO_DIR/config.  This catches "I edited the live
# config and forgot to copy it back to the repo" (or vice versa).
do_deploy() {
    section "DEPLOY (config drift vs repo)"
    local subdirs=(plasma i3 conky alacritty tmux)
    local sub repo_path live_path n_diff
    for sub in "${subdirs[@]}"; do
        repo_path="${REPO_DIR}/config/${sub}"
        live_path="${HOME}/.config/${sub}"
        if [[ ! -d "$repo_path" ]]; then
            row dim "$sub" "no $repo_path in repo"
            continue
        fi
        if [[ ! -d "$live_path" ]]; then
            row dim "$sub" "no $live_path on disk"
            continue
        fi
        # `diff -rq` exits 1 on any difference.  We DO want to count
        # diffs but not abort the script on a non-zero exit — wrap with
        # || true and trust the output.  Exclude noisy ephemeral
        # subdirs (__pycache__, .git, cache files).
        local diff_out
        diff_out="$(diff -rq \
            --exclude='__pycache__' \
            --exclude='.git' \
            --exclude='*.pyc' \
            --exclude='baseline-*.txt' \
            "$repo_path" "$live_path" 2>/dev/null || true)"
        n_diff="$(grep -c '.' <<<"$diff_out" || true)"
        [[ -z "$n_diff" ]] && n_diff=0
        if (( n_diff == 0 )); then
            row ok "$sub" "in sync"
        else
            # First diff line is a useful sample.  Truncate paths from
            # the left so we keep the filename.
            local sample
            sample="$(head -1 <<<"$diff_out")"
            sample="${sample:0:80}"
            row warn "$sub" "${n_diff} diff(s): ${sample}"
        fi
    done
}

# ── Run all sections ───────────────────────────────────────────────
# Print a one-line header so a brief invocation has context if mailed.
host="$(hostname 2>/dev/null || echo '?')"
when="$(date -Iseconds 2>/dev/null || date)"
printf '%sdotfiles-doctor%s @ %s  on  %s\n' "$C_BOLD" "$C_RST" "$when" "$host"

do_drift
do_supply_chain
do_system
do_network
do_deploy

# Final summary line — useful when --brief might have hidden every row.
printf '\n'
case "$WORST" in
    ok)   printf '%sOVERALL: ok%s\n'   "$C_OK"   "$C_RST" ;;
    warn) printf '%sOVERALL: warn%s\n' "$C_WARN" "$C_RST" ;;
    bad)  printf '%sOVERALL: bad%s\n'  "$C_ERR"  "$C_RST" ;;
    *)    printf 'OVERALL: %s\n' "$WORST" ;;
esac

case "$WORST" in
    bad)  exit 2 ;;
    warn) exit 1 ;;
    *)    exit 0 ;;
esac
