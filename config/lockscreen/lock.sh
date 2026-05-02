#!/usr/bin/env bash
# ~/.config/lockscreen/lock.sh — Cyberpunk Neon lock screen
#
# Layout (1920x1080, y=540 is centre):
#   y≈270  large neon clock      (gravity Center, offset -200)
#   y≈390  date subtitle         (gravity Center, offset  -80)
#   y≈540  [i3lock circle here — centre of screen]
#
# The text is in the upper half so the i3lock indicator circle
# (always drawn at the screen centre) appears below the text.

WALLPAPER="${XDG_CONFIG_HOME:-$HOME/.config}/wallpaper/wallpaper.png"

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

if [[ ! -f "$WALLPAPER" ]]; then
    convert -size 1920x1080 gradient:"#0a0a20-#00081a" "$LOCK_IMG" 2>/dev/null
else
    convert "$WALLPAPER" -resize 1920x1080! \
        -fill "#08081a" -colorize 75 \
        -fill "#000d1f" -colorize 20 \
        -fill "#00e5ff" \
        -draw "rectangle 610,450 1310,452" \
        -fill "#00e5ff22" \
        -draw "rectangle 610,448 1310,454" \
        -font "$FONT_BOLD" -pointsize 130 \
        -fill "#00e5ff" \
        -gravity Center -annotate +0-200 "$TIME" \
        -font "$FONT_BOLD" -pointsize 130 \
        -fill "#00e5ff15" \
        -gravity Center -annotate +3-197 "$TIME" \
        -font "$FONT_REG" -pointsize 28 \
        -fill "#4488bb" \
        -gravity Center -annotate +0-60 "$DATE" \
        "$LOCK_IMG" 2>/dev/null
fi

i3lock -i "$LOCK_IMG" --nofork
# Cleanup is handled by the EXIT trap above (covers crashes / Ctrl-C too).
