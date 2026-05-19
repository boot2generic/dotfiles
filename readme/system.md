# System — Audio, Brightness, Clipboard, Network, Screenshots

Catch-all for the desktop-integration utilities the dotfiles install but
don't have a custom config for. They mostly Just Work; this page documents
the commands and the keybinds wired into them.

---

## Audio (PulseAudio + pavucontrol + playerctl)

PulseAudio is the audio server; `pavucontrol` is its GUI mixer;
`playerctl` is the MPRIS bridge that lets a single key control whatever
player is active (Spotify, mpv, Firefox HTML5 audio, VLC, …).

| Action                  | How                                                |
|-------------------------|----------------------------------------------------|
| Open the mixer          | Click the volume icon in polybar (or run `pavucontrol`) |
| Adjust volume           | Scroll on the polybar volume module                |
| Mute / unmute           | Click the polybar volume module                    |
| Pick a different output | pavucontrol → Output Devices                       |
| Per-app volume          | pavucontrol → Playback                             |

### Media keys (already wired in i3)

The dotfiles bind both XF86 media keys (laptops, headsets) and a Mod+F-row
fallback. Each press emits a dunst notification.

| Keys                                  | Action                                |
|---------------------------------------|---------------------------------------|
| `XF86AudioRaiseVolume` / `Mod+F12`    | Volume up 5%                          |
| `XF86AudioLowerVolume` / `Mod+F11`    | Volume down 5%                        |
| `XF86AudioMute` / `Mod+m`             | Toggle mute                           |
| `XF86AudioMicMute`                    | Toggle microphone mute                |
| `XF86AudioPlay` / `Mod+F9`            | Play / pause toggle                   |
| `XF86AudioPause`                      | Play / pause toggle                   |
| `XF86AudioNext` / `Mod+F10`           | Next track                            |
| `XF86AudioPrev` / `Mod+F8`            | Previous track                        |
| `XF86AudioStop`                       | Stop                                  |

The bindings call helper scripts that wrap the underlying commands and
add notifications:

| Script                              | Wraps         | Subcommands                              |
|-------------------------------------|---------------|------------------------------------------|
| `~/.config/i3/scripts/volume.sh`    | `pactl`       | `up`, `down`, `mute`, `mute-mic`, `get`  |
| `~/.config/i3/scripts/media.sh`     | `playerctl`   | `playpause`, `play`, `pause`, `next`, `prev`, `stop` |

You can call them directly from a shell:

```bash
~/.config/i3/scripts/volume.sh up
~/.config/i3/scripts/media.sh next
```

### CLI reference (raw commands)

```bash
# Volume
pactl set-sink-volume @DEFAULT_SINK@   +5%
pactl set-sink-volume @DEFAULT_SINK@   -5%
pactl set-sink-mute   @DEFAULT_SINK@   toggle
pactl set-source-mute @DEFAULT_SOURCE@ toggle      # microphone
pactl get-sink-volume @DEFAULT_SINK@
pactl list short sinks                              # list available outputs

# Playback (MPRIS)
playerctl status
playerctl metadata --format '{{ artist }} — {{ title }}'
playerctl play-pause
playerctl next
playerctl previous
playerctl --player=spotify play          # restrict to a specific player
playerctl --list-all                     # list active MPRIS players
```

If you're on a desktop without media keys and want a different layout,
edit the relevant `bindsym` lines in `~/.config/i3/config` (search for
"Media keys") and reload (`Mod+Shift+c`).

---

## Screen brightness (brightnessctl)

`XF86MonBrightnessUp` / `XF86MonBrightnessDown` (Fn+F5/F6 on most ThinkPads)
adjust brightness in 5% steps. The keybinds are wired in i3 — no extra
config needed if your laptop has brightness keys.

```bash
brightnessctl                  # show current
brightnessctl set 50%
brightnessctl set +10%
brightnessctl set 10%-
brightnessctl set 0
```

To remap step size or bind brightness to non-`XF86` keys, edit the
`Brightness keys` block in `~/.config/i3/config`.

---

## Clipboard (xclip)

Selection vs clipboard:
- **PRIMARY** (X selection) — middle-click to paste; auto-filled by selection
- **CLIPBOARD** — `Ctrl+C` / `Ctrl+V` style; explicit copy

```bash
echo "hello" | xclip -selection clipboard -i      # → CLIPBOARD
xclip -selection clipboard -o                     # paste CLIPBOARD
xclip -i file.txt                                 # → PRIMARY
xclip -o                                          # paste PRIMARY
```

Already integrated:
- tmux copy-mode `y` copies to CLIPBOARD via xclip
- `fcp` zsh helper copies a path to CLIPBOARD
- nvim `"+y` and `"+p` use CLIPBOARD

---

## Screenshots (scrot)

`scrot` is the screenshot tool. Defaults are bound in i3:

| Keys              | What it captures                              | Saved to                          |
|-------------------|-----------------------------------------------|-----------------------------------|
| `Print`           | Full screen                                   | `~/Pictures/screenshot-<ts>.png` |
| `Mod+Print`       | Region (drag to select)                       | `~/Pictures/screenshot-<ts>.png` |

CLI:
```bash
scrot                              # full screen, saved to cwd
scrot -d 5                         # 5-second countdown
scrot -s                           # interactive: drag to select region
scrot -u                           # currently focused window
scrot ~/Pictures/shot.png          # specific file path
scrot -e 'xclip -selection clipboard -t image/png -i $f'  # copy to clipboard
```

---

## Display layout (xrandr / arandr)

`arandr` is a GUI for `xrandr`. Use it to drag-arrange multiple monitors:

```bash
arandr        # GUI — drag monitors, click apply, save layout
xrandr        # CLI: list outputs and their modes
```

CLI tweaks:
```bash
xrandr --output HDMI-1 --auto --right-of eDP-1
xrandr --output HDMI-1 --rotate left
xrandr --output eDP-1 --primary
xrandr --dpi 144                    # HiDPI scaling
```

After changing layout via xrandr, re-run polybar so a bar appears on the new
monitor:
```bash
~/.config/polybar/launch.sh
```

---

## VPN (Mullvad + WireGuard)

Both Mullvad VPN and the WireGuard userland are installed and wired into
polybar. See **[`vpn.md`](vpn.md)** for the full guide — install,
activation, polybar bindings, dropping in WireGuard configs, and the
kill-switch comparison.

Quick reference:

```bash
mullvad status                # connection state
mullvad connect               # connect to last/default relay
mullvad disconnect
mullvad relay list | less     # browse relays

sudo wg-quick up <name>       # bring up /etc/wireguard/<name>.conf
sudo wg-quick down <name>
sudo wg                       # tunnel status / handshakes
```

---

## Network (NetworkManager + polybar wlan/eth)

NetworkManager is the connection manager. Three independent UIs all talk
to the same daemon — pick whichever fits the moment:

| UI                      | How                                       | When to use                       |
|-------------------------|-------------------------------------------|-----------------------------------|
| `nm-applet` (tray)      | Click the network icon in polybar's tray  | Quick connect to a known SSID     |
| `nm-connection-editor`  | `Mod+Shift+w`                             | Editing creds, certs, VPN profiles |
| `nmtui` (TUI)           | `Mod+n` (opens in alacritty)              | SSH session, no GUI, recovery     |
| `nmcli` (CLI)           | Any shell                                 | Scripts, automation, one-liners   |

The polybar `wlan` module on the right side of the bar shows signal
strength + SSID. Click it for the same `nm-connection-editor`; right-click
for `nmtui`; middle-click toggles the radio via `rfkill`. The `eth`
module beside it lights up only when a wired link is active — a laptop
running on wifi sees no "ethernet offline" pill cluttering the bar.

| Keys                     | Action                                       |
|--------------------------|----------------------------------------------|
| `Mod+Shift+w`            | Open `nm-connection-editor` (full GUI)       |
| `Mod+n`                  | Open `nmtui` in alacritty (TUI fallback)     |
| `XF86WLAN` (Fn+F8 ThinkPad) | Toggle wifi radio (`rfkill toggle wifi`)  |

CLI:
```bash
nmcli device                    # list interfaces
nmcli connection show           # list saved connections
nmcli device wifi list          # scan for SSIDs
nmcli device wifi connect "SSID" password "secret"
nmcli connection up <name>      # bring connection up
nmcli connection down <name>
nmcli networking off            # quick airplane-mode

# Low-level wifi (iw): signal, bitrate, raw 802.11 detail
iw dev                          # which wireless interfaces exist
iw dev wlan0 link               # signal level, SSID, bitrate
iw dev wlan0 scan | less        # raw scan results (BSSIDs, channels)
iw dev wlan0 station dump       # peer association info

# Radio kill-switch
rfkill list                     # which radios exist + state
rfkill block wifi               # disable; `unblock` re-enables
rfkill toggle wifi              # what XF86WLAN runs
```

For VPN, OpenVPN configs go in `/etc/NetworkManager/system-connections/`.

### WiFi shows "unmanaged" — NM takeover (automatic + manual)

Symptom: `nmcli device status` reports `wlp...:wifi:unmanaged`, the
polybar wlan pill shows "off" forever, `wifi-menu.sh` opens but
neither lists nor connects to networks. Cause: another backend (most
commonly **iwd** on Intel cards, sometimes wpa_supplicant launched
from `/etc/network/interfaces`, occasionally systemd-networkd) is
holding the device. Debian's NetworkManager defers to those by default
via `[ifupdown] managed=false`.

**Do not blindly force NM to take over while you're online over wifi**
without a saved profile to fall back on — flipping the device to
`managed` instantly drops the active connection. The takeover script
solves this by **pre-importing** the SSID/PSK that ifupdown was
already using as a NetworkManager profile *before* stopping the old
backend. When NM takes over, it already knows what to connect to and
reconnects automatically. If creds aren't recoverable from
`/etc/network/interfaces`, plug ethernet in first or be ready to type
your SSID + password into nmtui.

**Automatic path:** `local_setup.sh setup` runs the takeover for you
at the very end (after `validate`), but only when:

- the machine is physical (no point on a VM),
- the wifi device is currently `unmanaged` / `unavailable`,
- credentials are recoverable from `/etc/network/interfaces`, and
- you didn't pass `--no-wifi-takeover`.

If creds aren't extractable, the auto step deliberately does nothing
and prints a hint pointing at the manual takeover script — forcing a
takeover with no saved profile is exactly the failure mode we want to
avoid. The takeover invocation is non-interactive (`--yes`); if the
pre-import fails at runtime, the script exits with a clear error
rather than blocking on a `read` prompt nobody can answer.

**Manual / on-demand path:** the dotfiles ship the same guarded
takeover script standalone:

```bash
~/dotfiles/scripts/take-over-wifi.sh        # interactive
~/dotfiles/scripts/take-over-wifi.sh --yes  # skip confirmation (used by auto_wifi_takeover)
```

Run it any time after install, or whenever wifi flips back to
`unmanaged` (some package upgrades reset NM's defaults). It detects
the wifi iface, refuses to run if NM is already managing it, warns
when no ethernet is up, **pre-imports SSID/PSK from
`/etc/network/interfaces` as an NM profile** with `autoconnect=yes`,
comments out wifi blocks in `/etc/network/interfaces` (with timestamped
backup), stops `iwd`/`wpa_supplicant`/`systemd-networkd` if active,
drops the NM conf.d snippet (`/etc/NetworkManager/conf.d/10-globally-managed-devices.conf`,
`[ifupdown] managed=true`), restarts NM, and waits up to 15 s for
auto-reconnect via the imported profile. Only if all of that fails
(e.g., no creds were recoverable) does it fall back to an interactive
SSID+password prompt.

**Manual path** (if the script doesn't fit your case):

Once safely on a wired connection (or with the SSID/password
memorised), find which backend is currently driving the wifi:

```bash
systemctl is-active iwd                       # most common on Intel cards
systemctl is-active wpa_supplicant
systemctl is-active systemd-networkd
grep -nE 'iface\s+wl' /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null
```

Then disable it and tell NM to manage the device:

```bash
# If iwd is the standalone backend:
sudo systemctl disable --now iwd

# If wpa_supplicant was launched from /etc/network/interfaces:
sudo nvim /etc/network/interfaces       # comment out the `iface wlp...` block
sudo systemctl disable --now wpa_supplicant 2>/dev/null

# If systemd-networkd had a .network file for it:
sudo rm /etc/systemd/network/<file-that-matched-the-iface>.network
sudo systemctl restart systemd-networkd

# Now make NM the global owner:
sudo install -d -m 0755 /etc/NetworkManager/conf.d
sudo tee /etc/NetworkManager/conf.d/10-globally-managed-devices.conf >/dev/null <<'EOF'
[ifupdown]
managed=true
EOF
sudo systemctl restart NetworkManager
sleep 3

# Confirm and connect:
nmcli device status                     # wlp... should be "disconnected"
nmcli device wifi connect "YOUR_SSID" password "YOUR_PASSWORD"
```

After this, the polybar wlan pill renders correctly and `wifi-menu.sh`
works as designed. The setup script's `ensure_nm_managed` step in
`install_phase` is **diagnostic-only** — it warns when an interface is
unmanaged but won't change anything, because mid-install is the worst
time to drop the network. The actual handover lives in
`auto_wifi_takeover` (see "Automatic path" above), which fires AFTER
the four install stages have completed and only when it's safe (creds
recoverable so reconnect is guaranteed).

If you ever want to revert (give the device back to iwd / etc.), the
takeover script ships a `--revert` flag that does the right thing
automatically — restores the most recent
`/etc/network/interfaces.bak.<TS>` it took during the original
takeover, removes the NM `conf.d` snippet
(`/etc/NetworkManager/conf.d/10-globally-managed-devices.conf`), and
re-enables whichever backend (wpa_supplicant / iwd / ifupdown) was
running before (heuristic: wpa_supplicant > iwd > ifupdown). If no
backup is found it exits 0 with a clear message — safe to run on a
clean box.

```bash
./scripts/take-over-wifi.sh --revert
```

The manual equivalent (when the script doesn't fit your case):

```bash
sudo rm /etc/NetworkManager/conf.d/10-globally-managed-devices.conf
sudo systemctl restart NetworkManager
sudo systemctl enable --now iwd        # or whichever backend was original
```

---

## Power management (TLP + acpi + thermald + powertop)

The setup script enables a small power-management stack on physical
laptops. Nothing to configure for typical use — defaults are tuned for
battery life and thermal headroom. On VMs / desktops these are skipped.

| Tool       | What it does                                        | Auto-enabled? |
|------------|-----------------------------------------------------|---------------|
| `tlp`      | Daemon: laptop power-saving (CPU, PCIe ASPM, USB autosuspend, wifi power-save, SATA ALPM). 20–40% idle-power win on a typical ThinkPad. | yes (physical) |
| `thermald` | Intel-only thermal daemon — proactive throttle so the SoC doesn't hit emergency thermal trips. | yes (Intel + physical) |
| `acpi`     | One-shot CLI: battery state, charge level, time remaining. Used by the polybar fallback and shell scripts. | n/a (binary) |
| `powertop` | Diagnostic tool — `sudo powertop` shows what's keeping the CPU awake and where energy is going. Run on demand. | no (manual) |

The polybar `battery` module to the right of the volume control shows
charge level (Font Awesome battery glyph + percentage), with a charging
animation when the AC adapter is plugged in. Glyph colour goes from green
(>80%) → yellow → orange → red (<20%) so a low-battery state is hard to
miss. Click for `xfce4-power-manager-settings` if installed, or `acpi -V`
in a terminal.

```bash
# Status / quick checks
tlp-stat -s                    # TLP version + mode (AC vs battery)
tlp-stat -b                    # battery health, full-charge %, cycle count
tlp-stat -p                    # active CPU governor + EPP
tlp-stat -t                    # temperatures (CPU + drives)
acpi -V                        # battery + thermal + AC summary
acpi -b                        # battery only

# Manual mode override (rare — TLP auto-detects AC)
sudo tlp ac                    # force "AC" profile
sudo tlp bat                   # force "battery" profile
sudo tlp start                 # re-apply current profile

# Diagnostic — what's wasting power right now?
sudo powertop                  # interactive TUI
sudo powertop --html=power.html --time=60   # 60-sec HTML report

# Thermal — is the SoC throttling?
systemctl status thermald
journalctl -u thermald -n 50 --no-pager
```

To tune TLP, edit `/etc/tlp.conf` (the defaults file is
`/usr/share/tlp/defaults.conf` — copy a section into `/etc/tlp.conf` to
override). After editing: `sudo systemctl restart tlp`. Common tweaks:

```ini
# /etc/tlp.conf
CPU_SCALING_GOVERNOR_ON_AC=performance         # responsiveness on AC
CPU_SCALING_GOVERNOR_ON_BAT=powersave          # battery
CPU_BOOST_ON_AC=1                              # turbo enabled on AC
CPU_BOOST_ON_BAT=0                             # turbo disabled on battery
WIFI_PWR_ON_BAT=on                             # wifi power-save on bat
START_CHARGE_THRESH_BAT0=75                    # ThinkPad-specific (see note):
STOP_CHARGE_THRESH_BAT0=80                     # cap charging at 80%
                                               # for long battery health
```

**`BAT0` may be `BAT1` on your hardware.** Most ThinkPads expose the
single internal cell as `BAT0`, but dual-battery models (X1 Carbon Gen
* with the optional second cell, P-series with secondary, …) and some
recent T-series revisions use `BAT1`. Check `ls /sys/class/power_supply/`
and edit the `BAT*` suffix in the lines above to match. The polybar
battery module auto-detects either name; the TLP keys do not.

The charge-threshold settings need `tlp-rdw` (already installed) plus
the `acpi-call` kernel module (DKMS) on most ThinkPads — run
`sudo apt install acpi-call-dkms` if you want to use them.

To **disable** TLP (e.g. switching to GNOME's `power-profiles-daemon`):
```bash
sudo systemctl disable --now tlp
sudo apt install power-profiles-daemon       # mutually exclusive with TLP
```

---

## Laptop hygiene (T14)

`deploy_phase` lays down two root-owned hooks on machines whose DMI
chassis is 8 (portable) / 9 (laptop) / 10 (notebook) / 14
(sub-notebook). Desktops and VMs read chassis 3/4/6/etc. and skip both
deploys silently — there's no "force-laptop" flag.

### Suspend / resume hygiene

`/usr/lib/systemd/system-sleep/cyberpunk-suspend.sh` is invoked by
`systemd-suspend.service` with `pre|post` + the sleep action. The script
runs at root with the user's session bus reachable; it snapshots
connected outputs (via `kscreen-doctor -j` under the active graphical
user, with `wlr-randr` / `xrandr` fallbacks for completeness) into
`/run/cyberpunk-suspend.json` on the pre-suspend hook, then on resume:

1. Reads the pre-suspend snapshot.
2. Re-counts current outputs.
3. If anything *vanished* across suspend, runs
   `systemctl --user restart plasma-kscreen.service` against the
   active graphical UID — this is the manual workaround for the
   Wayland-on-T14 dock-doesn't-re-enumerate failure mode, automated.
4. If outputs match, logs `outputs match pre-snapshot (no recovery
   needed)` and exits.

Everything is best-effort and logged with `logger -t cyberpunk-suspend`,
which keeps the script from blocking userspace resume on a transient
fault. To read what happened across a recent suspend:

```bash
journalctl -t cyberpunk-suspend -n 50 --no-pager
# Filter to one boot:
journalctl -t cyberpunk-suspend -b
```

Disable cleanly (the file is a system drop-in, not a unit, so there's
no `systemctl disable` knob):

```bash
sudo rm /usr/lib/systemd/system-sleep/cyberpunk-suspend.sh
```

It re-deploys on the next `./local_setup.sh deploy`.

### Thunderbolt / USB-C dock auto-layout

`/usr/local/bin/cyberpunk-dock-handler.sh` is fired by
`/etc/udev/rules.d/95-cyberpunk-dock.rules`. By default the only
narrow match in the rule is the **Lenovo ThinkPad Universal
Thunderbolt 4 Dock (Gen 1)** (`USB ID 17ef:3082`); the file ships
commented templates for other Lenovo docks (`3083`, `3070`, `a052`)
and a broad-USB-hub escape hatch which is **disabled by default**.

The udev rule wraps the handler in `systemd-run --no-block --collect`
— udev's `RUN+=` runs synchronously inside the worker with a 180 s
timeout and blocks other queued events; our `sleep 3 + kscreen-doctor
over D-Bus` is exactly the workload udev tells you not to do directly.
The transient unit untethers the work and lets udev return immediately
(logs under `journalctl -u cyberpunk-dock-*`).

The handler runs under `runuser -u <graphical-user>` so `kscreen-doctor`
talks to the user's DBUS bus.

- **On first connect** with no saved layout for this dock's
  vendor-product-serial hash, the handler writes the *current*
  `kscreen-doctor -j` JSON to
  `~/.config/dotfiles/dock-layouts/<dock-hash>.json` — so once you've
  arranged the monitors how you like, leave them and the next plug-in
  applies that layout automatically.
- **On subsequent connects**, the handler reads the saved JSON,
  rebuilds a `kscreen-doctor` argv (`output.<NAME>.mode.<WxH@RR>`,
  `.position.X,Y`, `.scale.N`, `.rotation.left|right|inverted`), and
  applies it.
- **On unplug**, the handler identifies the internal panel via the
  `eDP*`/`LVDS*`/`DSI*` connector name regex (the same heuristic
  KScreen itself uses internally), enables it, and disables every
  other currently-connected output. Modes / positions on the externals
  are not preserved — they're gone; KScreen will rediscover them on
  next plug-in.

```bash
# Tail the handler's logs as you plug / unplug the dock.
journalctl -t cyberpunk-dock -f

# What layouts are saved?
ls -la ~/.config/dotfiles/dock-layouts/

# Reset the layout for a specific dock — the next plug-in re-learns
# whatever's currently on the screens.
rm ~/.config/dotfiles/dock-layouts/<dock-hash>.json

# Per-host override (e.g. travel-machine forces single-monitor):
# ~/.config/dotfiles-local/dock-layouts/<dock-hash>.json wins over
# the path above.
```

**Adding a non-Lenovo dock** to the udev rule (read the scope comment
at the top of the file first — broadening to all USB hubs will fire
the handler on internal root hubs, USB keyboards with built-in hubs,
etc., which saturates udev workers):

```bash
# 1. Plug the dock in.  Find its USB IDs:
lsusb                                              # idVendor:idProduct
# Or, for the verbose path:
udevadm monitor --environment --subsystem-match=usb &
# (re-plug the dock to see the env vars)

# 2. Add a SUBSYSTEM=="usb" / ATTR{idVendor}=... / ATTR{idProduct}=...
#    rule by copying one of the commented templates in
#    /etc/udev/rules.d/95-cyberpunk-dock.rules.

# 3. Reload + retrigger:
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=usb --action=add
```

If the dock genuinely doesn't expose a dock-identifying VID:PID
(some CalDigit / OWC / Anker docks present only a generic VIA /
Genesys hub chip), the broad-USB-hub escape hatch at the bottom of
the rules file is the last resort — uncomment it knowing that it'll
also fire for the internal keyboard hub.

---

## File manager (Thunar)

Mod+e opens Thunar. Default file manager — supports tabs (Ctrl+T), bookmarks
(drag a folder onto the side panel), and custom actions (Edit → Configure
custom actions…).

CLI helper for trash: `gio trash file.txt` (or just `rm` if you don't want
trash semantics).

---

## Display manager (lightdm)

Lightdm is what you log into from the boot screen. Themed in cyberpunk via
`config/lightdm/lightdm-gtk-greeter.conf.in` — a **template** with `@HOME@`
placeholders for the user's home directory (e.g. background image path).
At deploy time, both `local_setup.sh` and `vm_automation.py` substitute
`@HOME@` with the actual `$HOME` (resolved on the target machine, no
literal `/home/<user>` in the repo) and write the result to
`/etc/lightdm/lightdm-gtk-greeter.conf`.

To customise the greeter:

```bash
sudo nvim /etc/lightdm/lightdm-gtk-greeter.conf
sudo systemctl restart lightdm    # WARNING: kills your X session
```

(Better: edit the template `config/lightdm/lightdm-gtk-greeter.conf.in`
in the dotfiles repo — keep the `@HOME@` placeholder anywhere a path
that depends on the user's home would otherwise appear — then redeploy
with `local_setup.sh deploy` and reboot.)

---

## NVIDIA GPU — gaming + workstation

For a desktop with a discrete NVIDIA card, `local_setup.sh install` (when
GPU is detected as `nvidia` and virt is `physical`) installs:

- **Kernel module** — `nvidia-open-kernel-dkms` for Turing+ (RTX 20-series
  / GTX 16-series and newer), or the legacy proprietary `nvidia-driver`
  kernel module for Maxwell / Pascal / Volta. Selected automatically by
  PCI device ID; fall-through to proprietary if the open package is
  missing in apt's index.
- **Native userland** — `nvidia-driver-libs`, `nvidia-settings`,
  `firmware-misc-nonfree`, the Vulkan loader (`libvulkan1`), Vulkan
  software-fallback drivers (`mesa-vulkan-drivers`), and diagnostics
  (`vulkan-tools` — provides `vulkaninfo`, `vkcube`).
- **32-bit gaming userland** — `nvidia-driver-libs:i386`, `libvulkan1:i386`,
  `mesa-vulkan-drivers:i386`, `libgl1-mesa-dri:i386`. **Required for
  Steam, Proton, Wine, DXVK/VKD3D, and any 32-bit Linux-native game.**
  Installed only after `dpkg --add-architecture i386`, which the script
  does for you.
- **Hardware video decode** — `nvidia-vaapi-driver`. NVDEC → VA-API shim
  so Firefox / Chromium / mpv hardware-decode H.264 / HEVC / AV1 on the
  GPU instead of saturating the CPU. Cuts CPU usage on YouTube to 1-2%.
- **Kernel cmdline** — `nvidia-drm.modeset=1` is appended to
  `GRUB_CMDLINE_LINUX_DEFAULT` (with a timestamped backup of
  `/etc/default/grub`). Required for Wayland, fixes most tearing on X11,
  and fixes "blank screen on resume from suspend" on most cards.

### Additional NVIDIA pieces on `--desktop=plasma` (Wayland)

On `--desktop=plasma + GPU=nvidia + physical`, four extra steps run that
are **not** part of the i3 path (each is a separate function in
`local_setup.sh`, all idempotent, each writes a timestamped backup of
the file it touches):

- **`nvidia-drm.fbdev=1`** (`add_nvidia_fbdev`) — appended to the same
  `GRUB_CMDLINE_LINUX_DEFAULT`. Required for clean fbcon under nvidia-drm:
  without it, the tty→sddm→plasma handoff flashes / corrupts; on some
  monitors you get a black screen until VT switch.
- **Early-KMS modules** (`add_nvidia_early_kms`) — adds `nvidia`,
  `nvidia_modeset`, `nvidia_uvm`, `nvidia_drm` to
  `/etc/initramfs-tools/modules` so they load in the initial ramdisk.
  Eliminates the early-boot flash and fixes an sddm-on-Wayland race
  where the greeter starts before nvidia-drm exposes its DRM connector.
  Runs `update-initramfs -u` after.
- **`NVreg_PreserveVideoMemoryAllocations=1`** (`add_nvidia_pm_options`)
  — written to `/etc/modprobe.d/nvidia-power-management.conf`. Preserves
  VRAM allocations across suspend/resume. Without this, Wayland
  sessions resume with corrupted textures or fail to repaint.
- **nvidia-suspend / -resume / -hibernate units** (also
  `add_nvidia_pm_options`) — `systemctl enable`d. Pair with the
  modprobe option above; do the actual VRAM save/restore via
  systemd-suspend hooks. Debian's `nvidia-driver` package ships these
  units but doesn't enable them by default.

After `install` finishes, **reboot** before launching anything that
talks to the GPU. The `validate` phase reports `[FAIL] nvidia kernel
module not loaded (reboot required)` when this hasn't happened yet,
plus the four Wayland-specific failures (`fbdev=1 missing`, `Preserve…
missing`, `early-KMS missing`, `nvidia-suspend not enabled`) when the
plasma path's extras haven't taken effect.

### Verifying

```bash
nvidia-smi                     # driver + module loaded, GPU visible
glxinfo | grep -i 'opengl renderer'   # should say NVIDIA, not llvmpipe
vulkaninfo --summary | grep -i nvidia # Vulkan ICD wired up
cat /proc/cmdline              # contains nvidia-drm.modeset=1
```

The validate phase covers most of these for you (kernel module
loaded, `nvidia-smi` returns a GPU, `nvidia-drm.modeset=1` on the
running cmdline, i386 multiarch enabled, `vulkaninfo` sees an NVIDIA
device, 32-bit `libGL.so.1` present). It does **not** run `glxinfo`
explicitly — run that one by hand if you want to confirm direct
rendering at the GLX layer.

```bash
./local_setup.sh validate
```

### Optional add-ons (opt in at install time)

- **CUDA toolkit** (~3 GB): for ML, Blender Cycles, DaVinci Resolve,
  ffmpeg `-c:v h264_nvenc`, local LLM inference (llama.cpp, vLLM, etc.):
  ```bash
  ./local_setup.sh install --cuda
  ```
  Pulls `nvidia-cuda-toolkit` from non-free.

- **Steam (Debian package)**: a thin bootstrap that downloads the real
  Steam from Valve on first launch. Pulls in 32-bit deps automatically:
  ```bash
  ./local_setup.sh install --steam
  ```
  Or use the Flatpak Steam (`flatpak install flathub com.valvesoftware.Steam`)
  if you prefer a sandboxed runtime — both work; pick one.

- **Both at once**:
  ```bash
  ./local_setup.sh install --cuda --steam
  ```

### Troubleshooting

- **`nvidia-smi: command not found`** — the metapackage didn't install.
  Check `apt-get install nvidia-driver` worked and that non-free is
  enabled (`grep -r non-free /etc/apt/sources.list.d/`). The installer
  drops a `dotfiles-non-free.sources` deb822 file.
- **Steam: "OpenGL GLX context is not using direct rendering"** —
  i386 multiarch isn't on, or `nvidia-driver-libs:i386` is missing.
  `dpkg --print-foreign-architectures` should list `i386`.
- **Black screen after upgrade** — DKMS hasn't rebuilt against the new
  kernel. Check `sudo dkms status`; rebuild with
  `sudo dkms autoinstall` and reboot.
- **Tearing on X11** — confirm `nvidia-drm.modeset=1` is on the running
  cmdline (`cat /proc/cmdline`). Without it, the X driver falls back
  to UMS.
- **YouTube CPU usage still high** — `nvidia-vaapi-driver` needs the
  `MOZ_DISABLE_RDD_SANDBOX=1` env var on Firefox, plus
  `media.ffmpeg.vaapi.enabled = true` in `about:config`. Verify with
  `vainfo` (install `vainfo` ad-hoc).

---

## Hardening extras (unattended-upgrades + auditd + DoT)

`./local_setup.sh harden` ships three layers on top of the older
sudoers / ufw triplet documented in [`readme/security.md`](security.md).
All are reversed by `./local_setup.sh unharden`.

### unattended-upgrades — security-only

`harden_uu()` installs `unattended-upgrades` + `apt-listchanges` and
drops `config/system/etc/apt/apt.conf.d/50unattended-upgrades` into
`/etc/apt/apt.conf.d/`. The shipped origins-pattern allowlists **only
`Debian-Security`** labels — by design. The vanilla Debian
`50unattended-upgrades` file enables stable + stable-updates +
backports + proposed-updates, which silently auto-bumps point releases
and is the historic footgun. Ours covers CVEs only; feature updates
stay manual (`sudo apt update && sudo apt upgrade`).

`harden_uu()` also writes `/etc/apt/apt.conf.d/20auto-upgrades` to
drive the daily timer, and (only when `mailx`/`bsd-mailx`/`s-nail` is
installed) a `51unattended-upgrades-mail` file that emails root on
change. Without mailx the journal is the only audit trail:

```bash
systemctl status unattended-upgrades.service
journalctl -u unattended-upgrades.service -n 100 --no-pager
```

To revert just the auto-upgrades layer (without dropping the rest of
the harden posture):

```bash
sudo rm /etc/apt/apt.conf.d/20auto-upgrades \
        /etc/apt/apt.conf.d/51unattended-upgrades-mail
sudo apt-get install --reinstall unattended-upgrades   # restore distro default 50-file
sudo systemctl disable --now unattended-upgrades.service
```

`./local_setup.sh unharden` does the same automatically.

### auditd — identity / sudoers / modules / mount / privesc

`harden_auditd()` installs `auditd` + `audispd-plugins` and drops
`config/system/etc/audit/rules.d/dotfiles.rules` into
`/etc/audit/rules.d/`. `augenrules --load` is preferred (atomic concat
+ swap of `/etc/audit/audit.rules`); on systems without `augenrules`
it falls back to `systemctl restart auditd`. Existing rules under
`/etc/audit/rules.d/` are left in place — `unharden_auditd()` removes
only our `dotfiles.rules` and re-applies.

What gets logged, and how to query each rule set:

| `ausearch -k <key>` | Watches |
|---|---|
| `identity` | writes to `/etc/{passwd,group,shadow,gshadow}` (catches `useradd`/`usermod`/`passwd`/hand-edits) |
| `sudoers` | writes to `/etc/sudoers` and `/etc/sudoers.d/` |
| `modules` | `init_module` / `finit_module` / `delete_module` syscalls on b64 *and* b32 (multi-arch hosts can hit the compat-mode syscall too) |
| `mount` | `mount` / `umount2` syscalls — USB-mass-storage attacks, `mount -o bind` exfil tricks |
| `privesc` | `execve` of `sudo`/`su` — **commented out by default**; uncomment in the rules file if you want this. Drops verbose, mostly noise on a desktop |

Examples:

```bash
sudo ausearch -k identity --start today
sudo ausearch -k sudoers  --start week-ago
sudo ausearch -k modules  --start today                 # any module load this session?
sudo ausearch -k mount    --start today --interpret     # decode raw syscall args
sudo auditctl -l                                        # what's loaded right now
```

The deliberate scope is Debian-friendly minimum (identity files,
sudoers, modules, mounts). CIS Level 2 adds dozens of process-tracing
rules that flood logs on a desktop — those are omitted on purpose.

### DNS-over-TLS via systemd-resolved

`harden_dot()` is the current encrypted-DNS path; it **replaces** the
older `harden_dns` (`dhcpcd` + `static domain_name_servers=…`) entirely.
The sequence is laid out so a Ctrl-C anywhere mid-run leaves a
recoverable system:

1. Install `systemd-resolved` if missing (logs to
   `${LOG_DIR}/apt_resolved.log`; failures abort the function before
   anything else is touched).
2. Pick the source file: per-host overlay
   `~/.config/dotfiles-local/etc/systemd/resolved.conf.d/cyberpunk-dot.conf`
   wins over the repo's
   `config/system/etc/systemd/resolved.conf.d/cyberpunk-dot.conf`
   (`DNSOverTLS=opportunistic`, `DNSSEC=allow-downgrade`, Cloudflare
   `1.1.1.1#cloudflare-dns.com` + `1.0.0.1#cloudflare-dns.com` + Quad9
   `9.9.9.9#dns.quad9.net`, plain Google `8.8.8.8`/`8.8.4.4` as
   `FallbackDNS=`).
3. Drop `config/system/etc/NetworkManager/conf.d/cyberpunk-dns.conf`
   (`[main] dns=systemd-resolved`) so NM pushes DNS into resolved via
   D-Bus instead of fighting `/etc/resolv.conf` on every connection
   event.
4. `systemctl enable --now systemd-resolved` so the stub at
   `127.0.0.53` is listening *before* the symlink swap.
5. Defensive `chattr -i /etc/resolv.conf` (handles the
   `Lynis`/CIS-recipe case where a previous hardening guide pinned
   the file immutable), then atomically `ln -sf
   /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf`.
6. `systemctl reload NetworkManager` (NOT restart — restart drops the
   current connection mid-run) and `systemctl restart
   systemd-resolved` so the new drop-in is live for verification.

The opportunistic policy means resolved tries DoT first and falls back
to plain DNS when TCP/853 is blocked (captive portals, corporate
middleboxes). The trade-off is RST-downgrade — a hostile network *can*
push you back to plain DNS — which the conky `DoT` row surfaces (see
`check_dot()` in `~/.config/conky/health.py` and "Security monitoring"
below).

Verify:

```bash
resolvectl status                # global block + per-link Protocols:
resolvectl status <iface>        # zoom to one interface
                                 # +DNSOverTLS = encrypted; -DNSOverTLS = fallback
systemctl is-active systemd-resolved
ls -la /etc/resolv.conf          # -> /run/systemd/resolve/stub-resolv.conf
```

`unharden_dot()` is the exact inverse — removes both drop-ins, drops
the resolv.conf symlink **before** stopping resolved (so no window of
missing nameservers), reloads NM, nudges the active connection with
`nmcli connection up <name>` if NM didn't rewrite resolv.conf on
reload alone, and finally `systemctl disable --now systemd-resolved`.

---

## Per-host overrides (`~/.config/dotfiles-local/`)

`deploy_phase` runs an extra step *after* writing the repo configs:
anything found under `~/.config/dotfiles-local/<thing>/…` is rsync'd
OVER the deployed files. The rsync runs **without `--delete`**, so
overrides only add or replace files — they never strip repo defaults.

```
~/.config/dotfiles-local/
├── README                          # auto-written on first install
├── alacritty/alacritty.toml        # ↑ this overrides ~/.config/alacritty/alacritty.toml
├── polybar/modules.ini             # ↑ this is added next to the repo's config.ini
└── conky/local.lua                 # ↑ extra file the repo doesn't ship
```

Inspect what's currently in effect without deploying:

```bash
./local_setup.sh --show-overrides
```

Each row is tagged `[add]` (override file the repo doesn't have),
`[override]` (file present in both, override wins), `[same]` (override
identical to repo — safe to delete from the overlay), or `[extra]`
(file in `dotfiles-local/` with no matching repo path).

Skip the overlay for a single run (useful when you suspect an override
is causing a problem):

```bash
DOTFILES_NO_LOCAL=1 ./local_setup.sh deploy
```

Repo defaults remain the source of truth — the overlay is local-only,
never committed.

---

## Drift monitoring (audit.sh + dotfiles-doctor.sh)

Two CLI scripts ship for the question "what changed since I last
looked?". Both are cron-friendly (clean exit codes, `--brief` /
`--json` modes).

- **`scripts/audit.sh`** — diffs current state against the baselines
  under `~/.config/conky/baseline-*.txt`. Four baselines today:
  `ports` (listening sockets via `ss -tln`), `modules` (loaded kernel
  modules via `lsmod`), `critical-files` (sha256 of
  `/etc/{passwd,shadow,sudoers,…}`), `suid` (sha256-keyed SUID/SGID
  inventory across the rootfs). Drift semantics intentionally mirror
  `~/.config/conky/health.py`'s `check_*_drift` checks — same diff,
  no second source of truth.

  ```bash
  ./scripts/audit.sh                            # human-readable summary
  ./scripts/audit.sh --json                     # machine-parseable
  ./scripts/audit.sh --refresh-baseline ports   # accept current as new baseline
  ```

  Exit 0 = every baseline OK or WARN; exit 1 = at least one BAD
  (`MAILTO=` in crontab catches this); exit 2 = usage error.

- **`scripts/dotfiles-doctor.sh`** — one-page report covering DRIFT
  (shells out to `audit.sh`), SYSTEM (disk, memory, OOM, kernel taint,
  NTP, pending firmware, pending reboot), NETWORK (listening ports,
  default route, DNS, Mullvad), and DEPLOY (is `~/.config/{plasma,i3}/`
  in sync with the repo?). Standalone counterpart to the conky HEALTH
  panel — what you want over SSH or when pasting a snapshot into a bug
  report.

  ```bash
  ./scripts/dotfiles-doctor.sh                # full report, every row
  ./scripts/dotfiles-doctor.sh --brief        # only non-OK rows
  ./scripts/dotfiles-doctor.sh --no-color     # strip ANSI on a tty
  ```

  Exit codes are Nagios-style: 0 OK, 1 WARN, 2 BAD.

A workable cron pair:

```cron
# daily morning drift snapshot to root mail
0 7  * * *  /home/<you>/dotfiles/scripts/audit.sh --json >>/var/log/dotfiles-audit.log 2>&1
# weekly full doctor report, brief mode (only firing rows)
0 8  * * 1  /home/<you>/dotfiles/scripts/dotfiles-doctor.sh --brief --no-color
```

---

## Security monitoring (conky overlay)

The conky panel runs a small security-monitoring stack alongside the
hardware modules. Three pieces:

- **HEALTH checks (`~/.config/conky/health.py`)** — adds `check_critical_file_drift`
  (sha256 of `/etc/passwd`, `/etc/shadow`, `/etc/sudoers`, `/etc/sudoers.d/`,
  `~/.ssh/authorized_keys`, systemd unit files, `/etc/cron.d/`),
  `check_recent_sudo_invocations` (label `sudo ok 24h` — distinct from the
  existing `failed sudo 24h`), `check_suid_drift` (full-rootfs SUID/SGID
  inventory; 23 h cached so it doesn't re-`find /` every conky cycle),
  `check_parent_anomaly` (catches the daemon → interactive-shell parentage
  that follows a post-exploit drop), and `check_dot` (label `DoT` — parses
  `resolvectl status <iface>` for `+DNSOverTLS`/`-DNSOverTLS` on the link
  carrying the default route; OK when encrypted, WARN on plain-DNS fallback,
  DIM when systemd-resolved isn't running — see "Hardening extras → DNS-over-TLS"
  above).
- **Beacon detection (`~/.config/conky/netstat.py`)** — keeps a small JSON
  history of `(ip, port, proc)` triples in `$XDG_RUNTIME_DIR/conky/`.
  When a triple has re-opened ≥4 times with mean interval ≥30 s and
  coefficient-of-variation under 0.15 (i.e. "too regular for a
  human-driven workload"), the row gets a `⏱` marker (yellow), and the
  header summary adds `<n> beaconing`.
- **Listener tagging (`~/.config/conky/listenports.py`)** — every
  listening port now shows the bound binary's `exe` path. Listeners
  whose path is **outside** `/usr/`, `/snap/`, `/var/lib/flatpak/`,
  etc., or whose `exe` ends in `(deleted)` (the kernel's marker for a
  process whose binary was unlinked after exec — classic post-exploit
  trick) are rendered in red.

The CLI-side counterparts (`scripts/audit.sh`,
`scripts/dotfiles-doctor.sh`) cover the same ground for SSH / cron use —
see "Drift monitoring" above. `audit.sh`'s drift checks deliberately
match `health.py`'s same-named checks line-for-line, so a conky alert
and a cron-mail bad row are talking about the same diff.

---

## Further reading

- `man pactl`, `man pavucontrol`, `man brightnessctl`
- `man scrot`, `man xclip`
- `man xrandr`, `man arandr`
- `man nmcli`
- [`~/.config/i3/config`](../config/i3/config) — for the bindings shipped here
