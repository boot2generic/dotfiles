#!/usr/bin/env bash
# ~/.config/lockscreen/lock.sh — Cyberpunk Neon lock screen
#
# Layout (relative to whatever resolution we resolve at runtime):
#   centre - 200px : large neon clock
#   centre -  60px : date subtitle
#   centre +   0px : [i3lock indicator circle, always at screen centre]
#
# The text is in the upper half so the i3lock indicator circle (always
# drawn at the screen centre) appears below the text.  Geometry is
# discovered at runtime — see resolve_geometry() — so this works on the
# T14 (1920x1200, 16:10), a 2560x1440 desktop, or a 3440x1440 ultrawide.

WALLPAPER="${XDG_CONFIG_HOME:-$HOME/.config}/wallpaper/wallpaper.png"

# Resolve the screen geometry to render at.  Order of preference:
#   1. xdpyinfo `dimensions:` line — works under any X11 session, gives
#      the union bounding box of all monitors as a single WxH.
#   2. xrandr `Screen 0: ... current WxH ...` line — same union, only
#      used when xdpyinfo isn't installed.  We extract the `current
#      WIDTH x HEIGHT` pair, NOT a per-monitor `*`-marked mode (which
#      would be wrong on multi-monitor setups: it would render the
#      lockscreen at one monitor's resolution while the X screen is
#      the much larger union of all monitors).
#   3. 1920x1080 — last-resort fallback for headless / weird sessions.
# Output: WIDTHxHEIGHT (e.g. "2560x1440") with the literal `x`.
resolve_geometry() {
    local geom
    if command -v xdpyinfo >/dev/null 2>&1; then
        # `xdpyinfo` second field on the dimensions line is WxH:
        #   dimensions:  1920x1080 pixels (508x285 millimeters)
        geom="$(xdpyinfo 2>/dev/null \
                  | awk '/dimensions:/ {print $2; exit}')"
        if [[ "$geom" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]]; then
            echo "$geom"; return
        fi
    fi
    if command -v xrandr >/dev/null 2>&1; then
        # xrandr's first line on a running X server:
        #   Screen 0: minimum 320 x 200, current 3840 x 1080, maximum ...
        # The "current WxH" pair is the X-screen UNION — what we want.
        # Earlier code grabbed the first `*`-marked mode line, which is
        # one monitor's resolution; on multi-monitor that's the wrong
        # answer (lock screen rendered at 1920x1080 while the screen
        # was 3840x1080).  Mawk-portable: regex without 3-arg match().
        geom="$(xrandr --query 2>/dev/null \
                  | awk '/Screen [0-9]+:.*current/ {
                          for (i=1; i<=NF; i++) if ($i == "current") {
                              w=$(i+1); h=$(i+3);
                              gsub(/[^0-9]/, "", w);
                              gsub(/[^0-9]/, "", h);
                              print w "x" h; exit
                          }
                      }')"
        if [[ "$geom" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]]; then
            echo "$geom"; return
        fi
    fi
    echo "1920x1080"
}
GEOMETRY="$(resolve_geometry)"

# SECURITY: use mktemp for the lock-screen overlay rather than a
# predictable /tmp/.lockscreen_<uid>.png path.  On a multi-user box the
# old form was racy — an attacker could read the cleartext wallpaper-
# with-clock-overlay and even replace the file between render and i3lock
# launch (a phishing-style swap).  mktemp gives us an unguessable
# 0600-mode path; we always remove it on exit (success, error, or
# signal).  --suffix=.png keeps the literal extension so ImageMagick
# infers PNG output without us specifying -define png:.
LOCK_IMG="$(mktemp --tmpdir --suffix=.png lockscreen.XXXXXX)"
chmod 600 "$LOCK_IMG"
trap 'rm -f "$LOCK_IMG"' EXIT INT TERM

FONT_BOLD=$(fc-match --format='%{file}' 'JetBrains Mono:style=Bold'    2>/dev/null)
FONT_REG=$( fc-match --format='%{file}' 'JetBrains Mono:style=Regular' 2>/dev/null)
[[ -z "$FONT_BOLD" ]] && FONT_BOLD="/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Bold.ttf"
[[ -z "$FONT_REG"  ]] && FONT_REG="/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Regular.ttf"

TIME=$(date '+%H:%M')
DATE=$(date '+%A, %B %-d %Y')

# The two horizontal accent rectangles around the clock are positioned
# relative to the screen centre.  Width is normally 700px; on narrow
# panels (rotated screens, vertical monitors, low-res VM sessions) we
# clamp to the screen width itself so RECT_X1 ≥ 0 — otherwise
# ImageMagick would render the bars off-canvas.
#
# Defensive: if GEOMETRY is malformed (resolve_geometry's regex check
# should already prevent this), force a sane fallback so $((H/2-90))
# below doesn't silently coerce a string to 0.
if ! [[ "$GEOMETRY" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]]; then
    GEOMETRY="1920x1080"
fi
W="${GEOMETRY%x*}"
H="${GEOMETRY#*x}"
RECT_W=700
(( RECT_W > W )) && RECT_W=$W
RECT_X1=$(( (W - RECT_W) / 2 ))     # always ≥ 0 since RECT_W ≤ W
RECT_X2=$(( RECT_X1 + RECT_W ))
RECT_Y=$((  H / 2 - 90 ))

# `set -e` is NOT in effect here (intentional — we want full control of
# error paths in a security-sensitive lockscreen).  Track convert's
# success explicitly so a render failure falls back to i3lock's
# built-in solid-colour mode rather than launching with an empty PNG —
# that would either crash i3lock or leave the screen unlocked.
convert_ok=1
if [[ ! -f "$WALLPAPER" ]]; then
    convert -size "$GEOMETRY" gradient:"#0a0a20-#00081a" "$LOCK_IMG" \
        2>/dev/null || convert_ok=0
else
    convert "$WALLPAPER" -resize "${GEOMETRY}^" -gravity center \
        -extent "$GEOMETRY" \
        -fill "#08081a" -colorize 75 \
        -fill "#000d1f" -colorize 20 \
        -fill "#00e5ff" \
        -draw "rectangle ${RECT_X1},${RECT_Y} ${RECT_X2},$((RECT_Y+2))" \
        -fill "#00e5ff22" \
        -draw "rectangle ${RECT_X1},$((RECT_Y-2)) ${RECT_X2},$((RECT_Y+4))" \
        -font "$FONT_BOLD" -pointsize 130 \
        -fill "#00e5ff" \
        -gravity Center -annotate +0-200 "$TIME" \
        -font "$FONT_BOLD" -pointsize 130 \
        -fill "#00e5ff15" \
        -gravity Center -annotate +3-197 "$TIME" \
        -font "$FONT_REG" -pointsize 28 \
        -fill "#4488bb" \
        -gravity Center -annotate +0-60 "$DATE" \
        "$LOCK_IMG" 2>/dev/null || convert_ok=0
fi

# An empty $LOCK_IMG would cause i3lock to error out — and the screen
# would NOT lock.  Fall back to i3lock's built-in solid-colour mode so
# the user is never left with an unlocked session because of a
# rendering glitch.  --color expects 6 hex digits without a `#`.
if (( convert_ok )) && [[ -s "$LOCK_IMG" ]]; then
    i3lock -i "$LOCK_IMG" --nofork
else
    i3lock --color 080810 --nofork
fi
# Cleanup is handled by the EXIT trap above (covers crashes / Ctrl-C too).
