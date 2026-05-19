#!/usr/bin/env bash
# config/plasma/apply-theme.sh
#
# Idempotent.  Applies, to the running Plasma session:
#   1. 100% scale on every connected output (override Plasma's auto-DPI),
#   2. CyberpunkCyan color scheme + breeze-dark look-and-feel,
#   3. Deployed wallpaper PNG,
#   4. Force-written [WM] cyan-accent kdeglobals keys (must run AFTER
#      lookandfeel — see comment in that block),
#   5. Thin (PANEL_HEIGHT) autohide panel + always-visible battery widget,
#   6. KWin live-reconfigure (so [Desktops] Number=4 takes effect),
#   7. Live D-Bus push of every global shortcut binding via
#      `org.kde.KGlobalAccel.setShortcut` (flag=4 NoAutoloading) —
#      replaces the old `kquitapp6 kglobalaccel && kstart6 kglobalaccel`
#      approach, which CANNOT work on Plasma 6 Wayland: kglobalaccel
#      lives inside kwin_wayland there, with no separate daemon to
#      restart.  Pre-clears the three plasmashell/emojier defaults that
#      would otherwise win kglobalaccel's conflict resolver (Meta+1..4
#      task-manager entries, Meta+Q manage activities, Meta+. emojier
#      _launch).
#
# No-ops on a tty / before plasmashell starts.
#
# Run automatically by local_setup.sh deploy_phase (on --desktop=plasma)
# and listed in ~/.config/autostart/cyberpunk-theme.desktop so first
# plasma login picks it up after install.  Safe to run by hand anytime.
#
# Why a script and not a static plasma-org.kde.plasma.desktop-appletsrc:
# that file has runtime UUIDs and plasmoid version pins that vary
# between Plasma point releases and per-machine.  plasma-apply-* (for
# theme bits), `qdbus6 org.kde.plasmashell /PlasmaShell evaluateScript`
# (for panel geometry), and `dbus-send` to `org.kde.kglobalaccel` (for
# hotkeys) are the supported, version-stable surfaces.

set -u

WALLPAPER="${HOME}/.config/wallpaper/wallpaper.png"
SCHEME="CyberpunkCyan"
PANEL_HEIGHT="${PANEL_HEIGHT:-28}"           # px; thin but readable
PANEL_HIDING="${PANEL_HIDING:-autohide}"     # autohide|none|dodgewindows|windowsbelow
DEFAULT_SCALE="${DEFAULT_SCALE:-1}"          # 100% = 1, 125% = 1.25, …

# ── Env-var whitelist ──────────────────────────────────────────────
# PANEL_HEIGHT and PANEL_HIDING flow into a JS heredoc later that's
# evaluated by `qdbus6 … evaluateScript` inside plasmashell.  The user
# can only override these via env vars they control, so the realistic
# threat is "I typo'd `PANEL_HIDING='";dangerous();//'` and plasmashell
# now runs arbitrary JS in MY session" — low impact, but defense in
# depth costs ~5 lines.  Refuse anything outside the documented set;
# the documented values are the only ones Plasma's Panel API accepts.
case "$PANEL_HIDING" in
    autohide|none|dodgewindows|windowsbelow) : ;;
    *)
        echo "[!]  PANEL_HIDING='$PANEL_HIDING' invalid — must be one of:" >&2
        echo "     autohide | none | dodgewindows | windowsbelow" >&2
        exit 2
        ;;
esac
if [[ ! "$PANEL_HEIGHT" =~ ^[0-9]{1,3}$ ]] || (( PANEL_HEIGHT < 16 || PANEL_HEIGHT > 200 )); then
    echo "[!]  PANEL_HEIGHT='$PANEL_HEIGHT' invalid — need an integer 16..200 px" >&2
    exit 2
fi
# DEFAULT_SCALE: kscreen-doctor accepts decimal scale factors; same
# defence-in-depth rationale — it flows into `kscreen-doctor "output.X.scale.$DEFAULT_SCALE"`
# which is argv only (no shell), but spurious values would just fail.
if [[ ! "$DEFAULT_SCALE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "[!]  DEFAULT_SCALE='$DEFAULT_SCALE' invalid — need a decimal like 1, 1.25, 1.5" >&2
    exit 2
fi

have() { command -v "$1" >/dev/null 2>&1; }

# ───────────────────────────────────────────────────────────────────
# Helper: detect that a KWin session is alive.
#
# Defined here (early) because the D8 mismatch block below the scale
# loop calls it.  See the comment block above the second use further
# down for the full rationale — `pgrep -x kwin_wayland` alone is
# fragile on Trixie where `kwin_wayland_wrapper` truncates to
# `kwin_wayland_wr` in /proc/comm and so does NOT match `pgrep -x`.
# Probing the org.kde.KWin D-Bus name is authoritative.
# ───────────────────────────────────────────────────────────────────
_kwin_running() {
    if have dbus-send; then
        dbus-send --session --print-reply --dest=org.freedesktop.DBus \
            /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
            string:org.kde.KWin 2>/dev/null | grep -q 'boolean true' \
            && return 0
    fi
    pgrep -x kwin_wayland >/dev/null 2>&1 && return 0
    pgrep -x kwin_x11      >/dev/null 2>&1 && return 0
    return 1
}

# ───────────────────────────────────────────────────────────────────
# Display scaling — every connected output to DEFAULT_SCALE.
#
# Why this exists: a fresh Plasma install on a HiDPI-ish laptop (the
# T14's 1920×1080 14" panel reports ~157 DPI to Wayland) can be
# auto-set to 1.05 / 1.10 by Plasma's "auto" scale heuristic.  The
# user explicitly wants 100% on every monitor on every machine, so we
# ENFORCE it here rather than relying on Plasma's first-run heuristic.
#
# kscreen-doctor accepts `output.<NAME>.scale.<FACTOR>`; we iterate
# every output it knows about (works on the T14 with one panel and the
# desktop with three external monitors alike — no per-machine list).
# kscreen persists the change to ~/.local/share/kscreen/<id>/<output>.
# ───────────────────────────────────────────────────────────────────
if have kscreen-doctor; then
    # `kscreen-doctor -j` returns JSON; jq pulls every output name.
    if have jq; then
        outputs="$(kscreen-doctor -j 2>/dev/null \
                   | jq -r '.outputs[] | select(.connected==true) | .name' 2>/dev/null)"
    else
        # Fallback parser if jq isn't in DESKTOP_PLASMA_PACKAGES yet
        # (or apply-theme.sh runs before terminal_phase finishes).
        # `kscreen-doctor -o` emits ANSI colour escapes even on a non-
        # tty (it doesn't honour NO_COLOR / isatty), so strip them
        # FIRST, then grep `Output: N <name>` lines.  Without the
        # ANSI strip the regex never matches and we silently skip
        # the scale enforcement entirely (the symptom that originally
        # left the user at 105% scaling on a fresh T14 install).
        outputs="$(kscreen-doctor -o 2>/dev/null \
                   | sed 's/\x1b\[[0-9;]*m//g' \
                   | sed -n 's/^Output:[[:space:]]\+[0-9]\+[[:space:]]\+\([^[:space:]]\+\).*/\1/p')"
    fi

    if [[ -n "${outputs:-}" ]]; then
        while IFS= read -r out; do
            [[ -z "$out" ]] && continue
            if kscreen-doctor "output.${out}.scale.${DEFAULT_SCALE}" >/dev/null 2>&1; then
                echo "[ok] scale ${DEFAULT_SCALE}× → ${out}"
            else
                echo "[!]  kscreen-doctor failed to set scale on ${out}"
            fi
        done <<< "$outputs"
    else
        echo "[*]  no outputs reported by kscreen-doctor — skipping scale enforcement"
    fi
fi

# ───────────────────────────────────────────────────────────────────
# Per-monitor refresh + VRR + HDR baseline (D3 / D7).
#
# Why this is split out into a helper and NOT inline like the scale
# loop above: scale is one knob applied uniformly (every output to
# DEFAULT_SCALE), but refresh / VRR / HDR are per-output and per-
# machine.  The desktop wants 240 Hz on monitor #1 and 144 Hz on
# #2/#3; the T14 has only an internal panel.  Baking the names DP-1/
# DP-2 / eDP-1 into the repo would be wrong everywhere except one
# specific machine.
#
# kscreen-baseline.py reads ~/.config/dotfiles/kscreen-baseline.json
# (NOT in the repo — per-machine state; user generates it once with
# `kscreen-baseline.py --snapshot` after configuring monitors in
# System Settings).  If the file is missing the script is a silent
# no-op, so a fresh install doesn't break.
#
# Failure here MUST NOT abort apply-theme.sh: a monitor unplugged at
# login time is normal (laptop undocked), and the rest of the theme
# still needs to apply.  The `|| true` enforces that — the script's
# own per-output error handling already only warns on failure.
# ───────────────────────────────────────────────────────────────────
KSCREEN_BASELINE="${HOME}/.config/plasma/kscreen-baseline.py"
if [[ -x "$KSCREEN_BASELINE" ]] && have python3 && have kscreen-doctor; then
    python3 "$KSCREEN_BASELINE" apply || true
fi

# ───────────────────────────────────────────────────────────────────
# D8: "KWin only sees one monitor after a driver bump" detection.
#
# Failure mode: after `nvidia-dkms` reinstall + reboot, KWin
# occasionally initializes with only one of the 3080 Ti's three
# outputs visible (kernel modesetting handed it one connector by the
# time the compositor started polling).  Detect by comparing
# currently-connected outputs against the baseline's expected count.
#
# We deliberately do NOT auto-restart kwin_wayland — that would close
# every open window in the session.  A `qdbus6 reconfigure` ping is
# the strongest non-destructive nudge available.  If that doesn't
# bring the monitors back, the user is told to restart SDDM or
# reseat cables.
#
# Cross-machine safety: the baseline records /etc/machine-id at
# snapshot time.  We only flag a mismatch if BOTH match — otherwise
# the user copied a baseline between boxes (e.g. via Syncthing) and
# any count delta is expected.
#
# jq fallback: same sed pattern apply-theme.sh already uses around
# the scale block; the helper script itself uses Python's json so
# the JSON parsing here is only for the count.
# ───────────────────────────────────────────────────────────────────
BASELINE_JSON="${HOME}/.config/dotfiles/kscreen-baseline.json"
if [[ -f "$BASELINE_JSON" ]] && have kscreen-doctor; then
    # Expected output count + baseline machine-id (parsed without
    # jq: the schema is simple and python3 is already a dep above).
    _baseline_meta="$(python3 -c '
import json, sys
try:
    d = json.load(open("'"$BASELINE_JSON"'"))
    print(len(d.get("outputs", {})))
    print(d.get("machine_id", ""))
except Exception:
    pass
' 2>/dev/null)"
    expected_outputs="$(echo "$_baseline_meta" | sed -n 1p)"
    baseline_mid="$(echo "$_baseline_meta" | sed -n 2p)"
    current_mid="$(cat /etc/machine-id 2>/dev/null)"

    # Fail-OPEN on missing baseline_mid: a baseline written before the
    # machine_id field was added (or hand-edited) has no machine_id, and
    # we don't want to silently skip D8 forever for those users.  Only
    # SKIP D8 when both ids are present AND they differ (the explicit
    # cross-machine-copy case).
    _mid_ok=1
    if [[ -n "$baseline_mid" && -n "$current_mid" \
          && "$baseline_mid" != "$current_mid" ]]; then
        _mid_ok=0
    fi
    if [[ -n "$expected_outputs" && "$_mid_ok" == 1 ]]; then
        _count_connected() {
            if have jq; then
                kscreen-doctor -j 2>/dev/null \
                    | jq '[.outputs[] | select(.connected==true)] | length'
            else
                # Sed-fallback mirror of apply-theme.sh's scale-block
                # parser: same ANSI strip + same Output: regex,
                # counting matches.
                kscreen-doctor -o 2>/dev/null \
                    | sed 's/\x1b\[[0-9;]*m//g' \
                    | grep -c '^Output:'
            fi
        }
        actual_outputs="$(_count_connected)"
        if [[ -n "$actual_outputs" ]] \
           && (( actual_outputs < expected_outputs )); then
            echo "[!]  output count mismatch: expected ${expected_outputs}, see ${actual_outputs}"
            # Non-destructive nudge.  kscreen-doctor has no
            # --reload-config flag on Plasma 6.2 (verified:
            # "Unknown option 'reload-config'"), so qdbus6
            # reconfigure is the only viable handle.
            if have qdbus6 && _kwin_running; then
                qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
            fi
            sleep 2
            actual_outputs="$(_count_connected)"
            if [[ -n "$actual_outputs" ]] \
               && (( actual_outputs < expected_outputs )); then
                echo "[!]  still ${actual_outputs}/${expected_outputs} outputs after KWin reconfigure — try \`sudo systemctl restart sddm\` or reseat cables" >&2
                # Also log to the journal so the warning survives
                # a closed terminal (apply-theme.sh runs from
                # autostart on first login).
                if have logger; then
                    logger -t apply-theme \
                        "Expected ${expected_outputs} outputs, see ${actual_outputs}; try \`sudo systemctl restart sddm\` or reconnect cables"
                fi
            else
                echo "[ok] output count recovered after reconfigure: ${actual_outputs}/${expected_outputs}"
            fi
        fi
    fi
fi

# plasma-apply-colorscheme writes the active scheme to kdeglobals + live-
# reloads if plasmashell is running.  It silently no-ops on a tty if
# DISPLAY/WAYLAND_DISPLAY are unset, so this is safe in deploy_phase even
# before the user has logged into Plasma.
if have plasma-apply-colorscheme; then
    plasma-apply-colorscheme "$SCHEME" >/dev/null 2>&1 \
        && echo "[ok] color scheme applied: $SCHEME" \
        || echo "[!]  plasma-apply-colorscheme returned non-zero (plasma not running yet?)"
fi

# NOTE: the [WM] section enforcement happens at the BOTTOM of this
# script, AFTER plasma-apply-lookandfeel — see comment there for why
# (lookandfeel rewrites [WM] from breeze-dark and would clobber any
# kwriteconfig6 we did up here).

# Wallpaper: only meaningful when plasmashell is running.  Outside a
# session, kscreenlockerrc still points at the same PNG (templated at
# deploy time), so the lock screen + first-login default wallpaper both
# already use it.
if have plasma-apply-wallpaperimage && [[ -f "$WALLPAPER" ]]; then
    if pgrep -x plasmashell >/dev/null 2>&1; then
        plasma-apply-wallpaperimage "$WALLPAPER" >/dev/null 2>&1 \
            && echo "[ok] wallpaper set: $WALLPAPER" \
            || echo "[!]  plasma-apply-wallpaperimage failed"
    else
        echo "[*]  plasmashell not running — wallpaper will take effect on next login"
    fi
fi

# Default Plasma desktop theme (panel/tray styling) — breeze-dark
# inherits our color scheme cleanly.  plasma-apply-desktoptheme is
# version-stable across Plasma 6.x.
if have plasma-apply-desktoptheme; then
    plasma-apply-desktoptheme breeze-dark >/dev/null 2>&1 || true
fi

# Look-and-feel package — pulls in breeze-dark globally (window
# decoration + splash + lockscreen styling).  No-op if already set.
#
# CAVEAT: plasma-apply-lookandfeel rewrites kdeglobals [WM] with the
# breeze-dark grey/white values, undoing whatever the .colors file or
# previous plasma-apply-colorscheme set.  This is why the [WM]
# enforcement block below runs LAST — anything between it and the
# kwriteconfig6 calls below would clobber our cyan accent.
if have plasma-apply-lookandfeel; then
    plasma-apply-lookandfeel -a org.kde.breezedark.desktop >/dev/null 2>&1 || true
fi

# ───────────────────────────────────────────────────────────────────
# Force-write the [WM] section ourselves — MUST be after lookandfeel.
#
# Why this is necessary even after plasma-apply-colorscheme +
# plasma-apply-lookandfeel:
#   1. ASYNC WRITE — plasma-apply-* commands return immediately, but
#      their actual writes to ~/.config/kdeglobals happen
#      asynchronously through kded6 over D-Bus.  A 1.5 s sleep is
#      enough for the deferred writes to settle on every machine
#      tested (T14 + 3-monitor desktop); shorter values race.
#   2. lookandfeel CLOBBER — plasma-apply-lookandfeel
#      org.kde.breezedark.desktop rewrites [WM] from breeze-dark's
#      values (grey 39,44,49 / white 252,252,252).  We MUST run after
#      it, not before, or the cyan accent silently reverts to
#      Breeze's default greyscale.
#   3. CACHE BYPASS — if the colour scheme is already active,
#      plasma-apply-colorscheme prints "already set" and skips
#      re-reading the .colors file, so an updated CyberpunkCyan.colors
#      never propagates by itself.  Direct kwriteconfig6 sidesteps
#      that cache too.
#
# The .colors file remains the source of truth for the rest of the
# scheme (button / view / selection / window colours); this block
# only owns [WM] (window-decoration title-bar colours).  Values mirror
# config/plasma/color-schemes/CyberpunkCyan.colors [WM] verbatim;
# updating one without the other is a bug — see the comment in
# CyberpunkCyan.colors [WM] for the contract.
# ───────────────────────────────────────────────────────────────────
if have kwriteconfig6; then
    sleep 1.5
    kwriteconfig6 --file ~/.config/kdeglobals --group WM --key activeBackground   "13,13,26"
    kwriteconfig6 --file ~/.config/kdeglobals --group WM --key activeBlend        "0,229,255"
    kwriteconfig6 --file ~/.config/kdeglobals --group WM --key activeForeground   "0,229,255"
    kwriteconfig6 --file ~/.config/kdeglobals --group WM --key inactiveBackground "18,18,31"
    kwriteconfig6 --file ~/.config/kdeglobals --group WM --key inactiveBlend      "85,85,170"
    kwriteconfig6 --file ~/.config/kdeglobals --group WM --key inactiveForeground "136,136,204"
    echo "[ok] [WM] cyan accent enforced in kdeglobals (after lookandfeel)"
fi

# ───────────────────────────────────────────────────────────────────
# Panel geometry — thin (PANEL_HEIGHT px) + autohide.
#
# We CAN'T edit ~/.config/plasma-org.kde.plasma.desktop-appletsrc by
# hand: the file's container indices, applet UUIDs and plugin version
# pins are runtime artefacts that the user's machine generates the
# first time plasmashell starts.  Editing it offline either races the
# session writer (Plasma rewrites the file every few minutes) or pins
# stale UUIDs that don't exist in the new session.
#
# The supported alternative is plasma's JS scripting interface,
# reached over D-Bus via `qdbus6 org.kde.plasmashell /PlasmaShell
# evaluateScript`.  `panels()` returns a live array of every panel;
# we set .height + .hiding on each.  Idempotent — re-running just
# overwrites with the same values.
# ───────────────────────────────────────────────────────────────────
if pgrep -x plasmashell >/dev/null 2>&1; then
    qdbus_bin=""
    for cand in qdbus6 qdbus-qt6 qdbus; do
        if have "$cand"; then qdbus_bin="$cand"; break; fi
    done
    if [[ -n "$qdbus_bin" ]]; then
        # Heredoc → variable so we can interpolate $PANEL_HEIGHT /
        # $PANEL_HIDING into the JS.  The script silently no-ops on
        # any panel that isn't a horizontal/vertical containment.
        #
        # Battery widget (org.kde.plasma.battery) is added as a top-
        # level panel applet — separate from the systray's auto-hidden
        # battery icon so it's ALWAYS visible (the polybar wlan-pill
        # equivalent for power state on the i3 path).  Guarded by
        # iterating widgetIds so re-runs don't pile up duplicate
        # battery widgets.  On a desktop with no battery the widget
        # falls back to showing the AC adapter icon — useful UX, not
        # a wasted slot.
        script="$(cat <<EOF
var allPanels = panels();
for (var i = 0; i < allPanels.length; ++i) {
    var p = allPanels[i];
    p.height = ${PANEL_HEIGHT};
    p.hiding = "${PANEL_HIDING}";

    var ids = p.widgetIds;
    var hasBattery = false;
    for (var j = 0; j < ids.length; ++j) {
        var w = p.widgetById(ids[j]);
        if (w && w.type === "org.kde.plasma.battery") {
            hasBattery = true;
            break;
        }
    }
    if (!hasBattery) {
        p.addWidget("org.kde.plasma.battery");
    }
}
EOF
        )"
        if "$qdbus_bin" org.kde.plasmashell /PlasmaShell evaluateScript "$script" >/dev/null 2>&1; then
            echo "[ok] panel: height=${PANEL_HEIGHT}px hiding=${PANEL_HIDING} (+battery)"
        else
            echo "[!]  plasmashell evaluateScript failed (panel geometry unchanged)"
        fi
    else
        echo "[*]  no qdbus binary — install qttools5-dev-tools or qt6-tools-dev"
    fi
else
    echo "[*]  plasmashell not running — panel geometry will apply on next login"
fi

# ───────────────────────────────────────────────────────────────────
# (Helper `_kwin_running` is defined near the top of this file —
# moved up so the D8 output-count mismatch block can call it before
# the panel-geometry section reaches here.  Original docs there.)
# ───────────────────────────────────────────────────────────────────

# ───────────────────────────────────────────────────────────────────
# Live-reload KWin so [Desktops] Number=4 takes effect immediately.
# ───────────────────────────────────────────────────────────────────
if have qdbus6 && _kwin_running; then
    qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
fi

# ───────────────────────────────────────────────────────────────────
# Push global-shortcut bindings into the LIVE session via D-Bus.
#
# Why this is necessary even though kwriteconfig6 / install -D already
# wrote ~/.config/kglobalshortcutsrc:
#   • On Plasma 6 Wayland, kglobalaccel runs INSIDE kwin_wayland (it
#     owns the `org.kde.kglobalaccel` D-Bus name).  There is no
#     separate `kglobalacceld` process to `kquitapp6 && kstart6` —
#     restarting it means restarting kwin, which closes every window
#     in the session.
#   • kglobalaccel caches bindings at kwin startup and does NOT
#     re-read kglobalshortcutsrc on file change.  So an edit to the
#     file ONLY takes effect on the NEXT login unless we push it.
#   • Direct D-Bus updates via `setShortcut` w/ flag=4 (NoAutoloading)
#     work without restarting anything: the user can run install /
#     apply-theme.sh from inside a running session and the new keys
#     fire immediately.
#
# History: this used to be 17 sequential `dbus-send` invocations + a
# `_kga_set` bash helper.  Each fork was ~10 ms (process spawn, libdbus
# connect, single method call, exit), so the loop burnt ~170 ms on
# every session start.  The work moved to config/plasma/kga_push.py —
# one Python process, one D-Bus session connection, every setShortcut
# call down it.  Wall clock dropped to ~25-35 ms on the T14 and the
# error reporting per binding is much nicer.
# ───────────────────────────────────────────────────────────────────
if _kwin_running; then
    KGA_PY="${HOME}/.config/plasma/kga_push.py"
    if [[ -x "$KGA_PY" ]] && have python3; then
        # python3-dbus is in DESKTOP_PLASMA_PACKAGES.  If the import
        # fails the helper exits non-zero with a clear message — fall
        # back to the legacy dbus-send loop below so we never leave
        # bindings unpushed in a session.
        if python3 "$KGA_PY"; then
            :
        else
            echo "[!]  kga_push.py failed — falling back to dbus-send" >&2
            _kga_fallback_needed=1
        fi
    else
        _kga_fallback_needed=1
    fi

    # Legacy fallback — only runs if kga_push.py is missing or failed.
    # Mirrors the previous bash implementation byte-for-byte so a
    # missing python3-dbus install still leaves a working session.
    if [[ "${_kga_fallback_needed:-0}" == 1 ]] && have dbus-send; then
        QT_SHIFT=$((0x02000000))
        QT_CTRL=$((0x04000000))
        QT_ALT=$((0x08000000))
        QT_META=$((0x10000000))
        QT_KEY_RETURN=$((0x01000004))
        QT_KEY_F1=$((0x01000030))
        QT_KEY_LEFT=$((0x01000012))
        QT_KEY_RIGHT=$((0x01000014))
        QT_KEY_COMMA=0x2c
        QT_KEY_PERIOD=0x2e
        QT_KEY_SLASH=0x2f
        QT_KEY_Q=0x51

        _kga_set() {
            local keys_arg
            if [[ -n "${6:-}" ]]; then
                keys_arg="array:int32:$5,$6"
            else
                keys_arg="array:int32:$5"
            fi
            dbus-send --session --print-reply --dest=org.kde.kglobalaccel \
                /kglobalaccel org.kde.KGlobalAccel.setShortcut \
                array:string:"$1","$2","$3","$4" \
                "$keys_arg" uint32:4 >/dev/null 2>&1
        }

        for n in 1 2 3 4; do
            _kga_set plasmashell "activate task manager entry $n" \
                     plasmashell "Activate Task Manager Entry $n" 0 0
        done
        _kga_set plasmashell "manage activities" plasmashell "Show Activity Switcher" 0 0
        _kga_set org.kde.plasma.emojier.desktop _launch "Emoji Selector" "Emoji Selector" 0

        for n in 1 2 3 4; do
            primary=$(( QT_META | (0x30 + n) ))
            secondary=$(( QT_CTRL | (QT_KEY_F1 - 1 + n) ))
            _kga_set kwin "Switch to Desktop $n" KWin "Switch to Desktop $n" \
                     "$primary" "$secondary"
        done
        for n in 1 2 3 4; do
            primary=$(( QT_META | QT_SHIFT | (0x30 + n) ))
            _kga_set kwin "Window to Desktop $n" KWin "Window to Desktop $n" \
                     "$primary"
        done
        _kga_set kwin "Switch One Desktop to the Left"  KWin "Switch One Desktop to the Left" \
                 $(( QT_META | QT_KEY_COMMA ))  $(( QT_META | QT_CTRL | QT_KEY_LEFT ))
        _kga_set kwin "Switch One Desktop to the Right" KWin "Switch One Desktop to the Right" \
                 $(( QT_META | QT_KEY_PERIOD )) $(( QT_META | QT_CTRL | QT_KEY_RIGHT ))
        _kga_set kwin "Window Close" KWin "Close Window" \
                 $(( QT_META | QT_KEY_Q )) $(( QT_ALT | (QT_KEY_F1 + 3) ))
        _kga_set Alacritty.desktop _launch Alacritty Alacritty \
                 $(( QT_META | QT_KEY_RETURN ))
        _kga_set cyberpunk-cheatsheet.desktop _launch \
                 "Cyberpunk hotkey cheatsheet" "Cyberpunk hotkey cheatsheet" \
                 $(( QT_META | QT_KEY_SLASH ))
        echo "[ok] live global-shortcut bindings pushed via dbus-send fallback"
    fi
fi

exit 0
