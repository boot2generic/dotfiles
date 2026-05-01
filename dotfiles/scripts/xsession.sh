#!/usr/bin/env bash
# ~/.xsession — X session startup
# Used by: lightdm (local login), xrdp (remote desktop), startx

export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"

export GTK_THEME=Adwaita:dark
export QT_QPA_PLATFORMTHEME=gtk2
export QT_AUTO_SCREEN_SCALE_FACTOR=0

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

export EDITOR=nvim
export VISUAL=nvim

# Local binaries (starship, fd, bat symlinks installed here)
export PATH="$HOME/.local/bin:$PATH"

# Starship prompt config
export STARSHIP_CONFIG="$HOME/.config/starship/starship.toml"

# Merge X resources (font AA, DPI, cursor theme)
[ -f "$HOME/.Xresources" ] && xrdb -merge "$HOME/.Xresources"

# Set DPI (adjust for HiDPI; 96 = standard)
xrandr --dpi 96 2>/dev/null || true

# Start PulseAudio if not already running (needed for polybar volume module
# and system audio in both lightdm and xrdp sessions)
if command -v pulseaudio >/dev/null 2>&1; then
    pulseaudio --check 2>/dev/null || pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1
fi

# Start the window manager
exec i3
