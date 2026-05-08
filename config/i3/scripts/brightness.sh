#!/usr/bin/env bash
# ~/.config/i3/scripts/brightness.sh
#
# Backlight-brightness helper invoked from i3 XF86MonBrightness*
# bindings.  Wraps `brightnessctl` with three pieces of logic that
# i3's command parser can't easily express inline:
#
#   1. /sys/class/backlight/ presence check — emits a "no backlight"
#      toast on a desktop instead of brightnessctl silently no-opping.
#
#   2. Device picking — `brightnessctl set` without `-d` defaults to
#      the first backlight device enumerated by udev, which on some
#      ThinkPad T14 + Intel iGPU configurations is `acpi_video0`.
#      `acpi_video0` exists on most laptops but doesn't actually drive
#      the panel on modern Intel/AMD iGPUs (the panel is wired up via
#      `intel_backlight` / `amdgpu_bl0` instead).  When you "set" via
#      acpi_video0, sysfs accepts the write and reports the new value
#      but the panel doesn't change — exactly the "no error, no
#      brightness change" symptom.  We pick the panel device explicitly
#      with intel_backlight > amdgpu_bl* > nv_backlight > anything
#      that ISN'T acpi_video* > acpi_video* (last resort).
#
#   3. Permission diagnosis — brightnessctl ships a udev rule giving
#      `video`-group write access to /sys/class/backlight/*/brightness.
#      Users not in `video` get silent no-ops (sysfs returns EACCES,
#      brightnessctl prints to stderr but i3 doesn't surface that).
#      We catch this case and emit a toast with the fix command.
#
# Why this lives in a separate script instead of inline in
# ~/.config/i3/config: i3's command parser does NOT recognise single
# quotes as a quoting form, so an inline `sh -c '...'` arg whose body
# contains a `[` (e.g. `if [ -n ... ]; then`) is parsed by i3 as the
# start of a criteria block and rejected with "Expected one of these
# tokens: ... '['".  A separate script avoids that AND matches the
# existing convention (volume.sh / media.sh).
#
# Usage: brightness.sh up | down | <brightnessctl-set-arg>
#
# `up`/`down` are aliases for ±5 %; anything else passes through
# unchanged so a custom binding can do `brightness.sh 50%` etc.
set -euo pipefail

ARG="${1:-}"
case "$ARG" in
    up)   ARG="+5%" ;;
    down) ARG="5%-" ;;
    "")   echo "usage: $(basename "$0") {up|down|<brightnessctl-set-arg>}" >&2
          exit 2 ;;
esac

# notify-send fails harmlessly with `|| true` when DBus / dunst aren't
# up yet — we never want to propagate a non-zero exit back to i3.
toast() {
    notify-send -t "${1}" "Brightness" "${2}" 2>/dev/null || true
}

# Step 1: any backlight device at all?
if [[ ! -d /sys/class/backlight ]] \
   || [[ -z "$(ls -A /sys/class/backlight 2>/dev/null)" ]]; then
    toast 1500 "no backlight on this hardware"
    exit 0
fi

# Step 2: pick the device that actually drives the panel.  Iterate
# preferred names first; fall through to "anything that isn't
# acpi_video*"; last-resort accept acpi_video* if that's truly all we
# have (some old hardware needs it).
pick_device() {
    local prefer name
    for prefer in intel_backlight amdgpu_bl0 amdgpu_bl1 \
                  radeon_bl0 nv_backlight nvidia_0; do
        if [[ -d "/sys/class/backlight/${prefer}" ]]; then
            printf '%s\n' "$prefer"
            return 0
        fi
    done
    for d in /sys/class/backlight/*/; do
        name="$(basename "$d")"
        case "$name" in
            acpi_video*) continue ;;
            *) printf '%s\n' "$name"; return 0 ;;
        esac
    done
    for d in /sys/class/backlight/*/; do
        printf '%s\n' "$(basename "$d")"
        return 0
    done
}
DEVICE="$(pick_device)"

# Step 3: make sure we can actually write to the device.  EACCES from
# the kernel turns into a silent no-op as far as i3's binding is
# concerned, which is exactly the "no error, nothing changes" symptom
# everyone reports.  Diagnose it explicitly.
BRIGHT_FILE="/sys/class/backlight/${DEVICE}/brightness"
if [[ ! -w "$BRIGHT_FILE" ]]; then
    if ! id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx 'video'; then
        toast 4000 "user '$USER' not in 'video' group — run: sudo usermod -aG video $USER && reboot"
    else
        # In `video` but file still not writable — udev rule didn't
        # fire (rare; happens if brightnessctl was reinstalled or the
        # rule was clobbered).  Surface the one-line fix so the user
        # doesn't have to dig through docs.
        toast 6000 "no g+w on $BRIGHT_FILE — fix: sudo chgrp video $BRIGHT_FILE && sudo chmod g+w $BRIGHT_FILE"
    fi
    exit 1
fi

brightnessctl -d "$DEVICE" set "$ARG"
