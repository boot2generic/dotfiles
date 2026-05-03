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

After `install` finishes, **reboot** before launching anything that
talks to the GPU. The `validate` phase reports `[FAIL] nvidia kernel
module not loaded (reboot required)` when this hasn't happened yet.

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

## Further reading

- `man pactl`, `man pavucontrol`, `man brightnessctl`
- `man scrot`, `man xclip`
- `man xrandr`, `man arandr`
- `man nmcli`
- [`~/.config/i3/config`](../config/i3/config) — for the bindings shipped here
