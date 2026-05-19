# Plasma 6 / Wayland desktop path

The cyberpunk dotfiles ship a second desktop stack — KDE Plasma 6 on Wayland — alongside the original i3 / X11 stack. Both paths share the same shell stack (alacritty, nvim, tmux, zsh + oh-my-zsh + starship), the same wallpaper PNG, and the same conky overlay. The only thing that changes is the WM/DM/compositor and a few audio/clipboard pieces.

## When to pick which

| Use the **i3 path** if… | Use the **plasma path** if… |
|---|---|
| Laptop, single monitor, integrated GPU | Desktop with discrete NVIDIA card |
| You want minimal RAM/CPU overhead | You have multiple monitors with mixed refresh rates (240 Hz + 144 Hz + 60 Hz) |
| You're happy driving everything from the keyboard | You want VRR / G-Sync / FreeSync working on Linux |
| You don't need fractional scaling | You want fractional scaling that actually works |
| You're hardening / scripting / debugging at the bar level | You want a polished SDDM greeter + krunner + kwallet + dolphin out of the box |

On NVIDIA + multi-monitor + high-refresh-rate hardware, X11 forces *every* monitor to the lowest common refresh rate for unsynced apps. Wayland doesn't. That alone is usually the deciding factor.

### Target compatibility

The plasma path is tested-against three target classes:

| Target | Status | Default session at first login | Notes |
|---|---|---|---|
| **NVIDIA desktop** (3080 Ti, multi-monitor, 240 Hz) | Headline target | **Plasma (Wayland)** | Full NVIDIA-Wayland kernel pieces apply (see below). VRR/Adaptive Sync configured per-output in System Settings. |
| **Intel iGPU laptop** (e.g. ThinkPad T14) | Supported | **Plasma (Wayland)** | Wayland on Intel iGPUs is the historical "easy mode" — works out of the box, no driver tweaks needed. TLP coexists with powerdevil (TLP handles CPU/disk/wifi power; powerdevil handles UI + screen blanking). |
| **VM** (Hyper-V Gen 2 / KVM virtio-gpu / VMware vmwgfx) | Supported with fallback | **Plasma (X11)** recommended on first login | Modern hypervisors with working KMS run Wayland fine; older configs (VirtualBox default VBoxVGA, Hyper-V Enhanced Session) need the X11 session. Both compositors are installed (`kwin-wayland` + `kwin-x11`); pick from the SDDM session dropdown. SDDM remembers the choice. |

The SDDM greeter itself runs in X11 mode (Debian default), so the greeter renders correctly on every backend including VMs without strong KMS. Once you've logged in once and picked the right session, SDDM remembers and the next boot logs you straight in.

## Install

```bash
# Fresh install with the plasma stack
./local_setup.sh setup --desktop=plasma

# Or, --plasma is shorthand
./local_setup.sh setup --plasma

# Switching an existing i3 install over to plasma (re-run on the same box)
./local_setup.sh setup --plasma --bypass
```

The plasma path is fully additive over the i3 path — none of the i3 configs are removed from the repo. You can switch back at any time:

```bash
./local_setup.sh setup --desktop=i3 --bypass
sudo systemctl disable sddm
sudo systemctl enable lightdm
sudo reboot
```

## What gets installed

**Common to both paths** (BASE_PACKAGES in local_setup.sh): terminal stack, fonts, network/audio backbone, hardware diagnostics, conky, wallpaper.

**Plasma-specific** (DESKTOP_PLASMA_PACKAGES):

| Layer | Package(s) | Replaces (i3 path) |
|---|---|---|
| Core desktop | `plasma-desktop`, `plasma-workspace`, `kwin-wayland`, `kwin-style-breeze` | i3, polybar, picom, rofi |
| Display manager | `sddm`, `sddm-theme-breeze` | lightdm |
| Wayland support | `xwayland`, `qt6-wayland` | (X11 stack) |
| Audio | `pipewire`, `pipewire-pulse`, `wireplumber`, `pavucontrol-qt` | pulseaudio + pavucontrol |
| Clipboard | `wl-clipboard` (`wl-copy` / `wl-paste`) | xclip |
| Screenshot | `kde-spectacle` | scrot |
| Native KDE | `konsole`, `dolphin`, `kwallet6`, `polkit-kde-agent-1`, `kde-cli-tools` | thunar |
| Lock screen | `kde-config-screenlocker` | i3lock |
| Theming | `breeze`, `breeze-cursor-theme`, `breeze-icon-theme`, `kf6-breeze-icon-theme` | – |
| System monitor | `plasma-systemmonitor` | polybar CPU/mem modules |
| Tray applets | `plasma-nm`, `plasma-pa` | nm-applet (X11 tray) |

`alacritty` stays the default terminal under both paths. Your nvim + tmux + zsh stack is identical.

## Theming — cyberpunk cyan

The Plasma path ships a `CyberpunkCyan` color scheme that mirrors the alacritty / polybar / conky palette exactly:

| Role | Hex | RGB |
|---|---|---|
| Background | `#0d0d1a` | 13, 13, 26 |
| Foreground | `#e2e2ff` | 226, 226, 255 |
| Accent (selection, focus, hover, link) | `#00e5ff` | 0, 229, 255 |
| Positive | `#00ff41` | 0, 255, 65 |
| Neutral | `#ffcc00` | 255, 204, 0 |
| Negative | `#ff0055` | 255, 0, 85 |
| Visited / secondary | `#ff00cc` | 255, 0, 204 |

The color scheme is the keystone — KWin window borders, krunner, knotifications, GTK apps (via `plasma-integration`), and the lock screen all inherit from it. The deploy phase calls `plasma-apply-colorscheme CyberpunkCyan` (which is idempotent, version-stable across Plasma 6.x). On first plasma login the `~/.config/autostart/cyberpunk-theme.desktop` entry re-runs `apply-theme.sh` to live-apply the wallpaper too.

Konsole gets its own matching profile + colorscheme — opening konsole from dolphin gives you the same colors as alacritty.

## NVIDIA on Wayland — extra install steps

On `--desktop=plasma + GPU=nvidia + physical`, `install_phase` runs four extra steps that are skipped on the i3 path:

| Step | Where | Why |
|---|---|---|
| `nvidia-drm.fbdev=1` | `add_nvidia_fbdev()` — GRUB cmdline | Clean fbcon under nvidia-drm. Without it, the tty→sddm→plasma handoff flashes / corrupts; on some monitors you get a black screen until VT switch. |
| Early-KMS modules | `add_nvidia_early_kms()` — `/etc/initramfs-tools/modules` | Load `nvidia nvidia_modeset nvidia_uvm nvidia_drm` in the initial ramdisk. Eliminates the early-boot flash and fixes an sddm-on-Wayland race where the greeter starts before nvidia-drm exposes its DRM connector. |
| `NVreg_PreserveVideoMemoryAllocations=1` | `add_nvidia_pm_options()` — `/etc/modprobe.d/nvidia-power-management.conf` | Preserves VRAM allocations across suspend/resume. Without this, Wayland sessions resume with corrupted textures or fail to repaint. |
| nvidia-suspend / -resume / -hibernate units | `add_nvidia_pm_options()` — systemd enable | Pair with the modprobe option above; do the actual VRAM save/restore via systemd-suspend hooks. |

All four are idempotent — re-running `setup --plasma` won't double-append cmdlines or duplicate module lists. Each writes a timestamped backup of the file it touches.

The validate phase reports `[FAIL]` for each missing piece, with a pointer to the install_phase helper that should have set it.

### Session env vars + explicit-sync (deploy-phase)

`deploy_phase` adds two more NVIDIA-only knobs on top of the four install-phase steps above. Both are no-ops on non-NVIDIA boxes (Intel iGPU T14 etc.):

| Step | Where | Why |
|---|---|---|
| `/etc/environment.d/95-nvidia-wayland.conf` | `deploy_nvidia_wayland_env()` — drops `config/system/etc/environment.d/95-nvidia-wayland.conf` | Sets `__GL_GSYNC_ALLOWED=1`, `__GL_VRR_ALLOWED=1`, `WLR_NO_HARDWARE_CURSORS=1`, `MOZ_ENABLE_WAYLAND=1`. Read by `pam_systemd` at graphical-session start (NOT by `/etc/environment`, which only login(1) / sshd-launched shells see), so the variables reach KWin, Firefox, and the rest of the user session uniformly. |
| `~/.config/kwinrc [Wayland] EnableExplicitSync=true` | `enable_plasma_explicit_sync()` — `kwriteconfig6` | Opt-in for KWin 6.1.x where the protocol is shipped OFF; a documented no-op on KWin 6.2+ where it's default-on with NVIDIA 555+. Always-write to keep one code path — version-detection in bash is the worse alternative. |

**Logout / login required for both.** `pam_systemd` only reads `environment.d/` at session start; KWin only re-checks `[Wayland]` keys on session start. A fresh shell inside an existing session won't pick either up. After re-running `deploy`, log out and back in to confirm — `printenv MOZ_ENABLE_WAYLAND` should print `1`, and `grep EnableExplicitSync ~/.config/kwinrc` should show `true`.

## Multi-monitor / high-refresh-rate notes

Per-output config (refresh rate, VRR, scale, position) lives in `~/.local/share/kscreen/` keyed by EDID hash. **This is not portable** between machines — different monitors, different EDIDs, different file. The repo deliberately does *not* ship these files; configure them once per machine via *System Settings → Display Configuration*.

**Default scale = 100% on every output.** Plasma's first-run heuristic sometimes picks 105–110 % on a high-DPI panel (the T14's 14" 1440p reports ~157 DPI). `apply-theme.sh` (autostart on first plasma login, also runs from deploy_phase) iterates every connected output via `kscreen-doctor` and forces `scale.1`. Override per-monitor afterwards in *System Settings → Display Configuration* — kscreen persists the new value to `~/.local/share/kscreen/` and `apply-theme.sh` won't touch it again unless you re-run with `DEFAULT_SCALE=…` exported.

What to enable in System Settings for a 3080 Ti + 240 Hz + multi-monitor box:

- **Display Configuration → Adaptive Sync → Automatic** on every output that supports it
- **Display Configuration → Refresh Rate → 240 Hz** on each monitor independently (Wayland handles mixed rates correctly)
- **Display Configuration → Scale → 100%** for 1440p (already enforced as default), **125–150%** for 4K (fractional scaling works under Wayland)
- **System Settings → Compositor → Tearing → Allow** (corresponds to `[Compositing] AllowTearing=true` in kwinrc; already set by the deployed kwinrc)

For fullscreen games, KWin's `AllowTearing` setting unlocks the immediate/mailbox present modes — closer to X11 unredirected fullscreen, helps frametime variance on 240 Hz.

### Per-monitor refresh + VRR baseline (`kscreen-baseline.py`)

Plasma's own `~/.local/share/kscreen/` cache is keyed by EDID hash, which works for the canonical case (this monitor on this DP port) but is fragile across driver bumps and not portable. The dotfiles ship `~/.config/plasma/kscreen-baseline.py` as a small driver on top of `kscreen-doctor`: capture the right per-output mode + VRR + HDR state once, replay it on every login via `apply-theme.sh`.

Two-phase workflow:

```bash
# 1. Configure once via System Settings → Display Configuration.
#    Set each monitor's refresh rate, scale, VRR (Adaptive Sync),
#    and HDR the way you want.

# 2. Snapshot the live state to ~/.config/dotfiles/kscreen-baseline.json
#    (per-machine state — NOT committed to the repo).
kscreen-baseline.py --snapshot

# Subsequent logins:  apply-theme.sh autostart calls
#   kscreen-baseline.py apply
# which re-asserts each output's saved mode/VRR/HDR.  Missing outputs
# (laptop undocked, monitor unplugged) are skipped with a per-output
# warning rather than aborting.
```

CLI:

| Invocation | What it does |
|---|---|
| `kscreen-baseline.py --snapshot` | Write current state (mode, scale, VRR policy, HDR, enabled) for every connected output to `~/.config/dotfiles/kscreen-baseline.json`. Refuses to write an empty baseline. Records `/etc/machine-id` for cross-machine detection (see D8 recovery below). |
| `kscreen-baseline.py` (or `apply`) | Default action — replay the saved baseline. Silent no-op when no baseline exists, so a fresh install doesn't break. |
| `kscreen-baseline.py --show` | Print the current baseline JSON. |
| `kscreen-baseline.py --reset` | Delete the baseline file. |
| `kscreen-baseline.py --enable-hdr <output>` | Probe capability, toggle HDR on, **persist the new state to the baseline** so the next `apply` re-asserts it. |
| `kscreen-baseline.py --disable-hdr <output>` | Same in reverse. |
| `kscreen-baseline.py -v` | Verbose — log per-output "already at baseline — no change" lines and the missing-output count. |

Notes on the kscreen-doctor surface this script drives:

- VRR is set via `output.<NAME>.vrrpolicy.{never|automatic|always}` — not via the older `vrr.enable` / `adaptiveSync.enable` keys, which kscreen-doctor on Plasma 6.2.x rejects.
- HDR capability is probed by parsing the **text** output of `kscreen-doctor -o` (looking for `HDR: incapable` vs `HDR: Disabled`/`Enabled`). The JSON output (`-j`) on Plasma 6.2.x omits the `hdrEnabled` key entirely when the panel doesn't support it, so JSON alone can't distinguish "no field" from "off".
- All per-output failures are warnings, never aborts. `apply-theme.sh` relies on this — one unplugged monitor must not stop scale enforcement, the color scheme apply, and everything downstream.

### HDR opt-in

HDR is strictly opt-in per output. The baseline records HDR=true for an output only when you explicitly turn it on via `--enable-hdr`; otherwise `apply` leaves the field alone (touching `output.<NAME>.hdr.*` on an incapable panel errors out, so the script refuses to "auto-disable" HDR it didn't author).

```bash
# Inspect what outputs you have, and which advertise HDR.
kscreen-doctor -o | grep -E '^Output:|HDR:'

# Turn HDR on for one monitor — capability is probed first; refused
# if the panel reports "HDR: incapable".
kscreen-baseline.py --enable-hdr DP-1

# Turn it back off.  Live state and baseline both updated.
kscreen-baseline.py --disable-hdr DP-1
```

A baseline copied from an HDR-capable box to an HDR-incapable one will warn on every `apply` rather than crash:

```
[!]  DP-1: HDR requested but monitor reports 'incapable' — skipping HDR step
```

### D8 — connected-output count recovery (multi-monitor)

After an `nvidia-dkms` rebuild + reboot, KWin occasionally initializes with only one of the 3080 Ti's three outputs visible because kernel modesetting handed it one connector by the time the compositor started polling. `apply-theme.sh` catches this:

1. Read the expected count from `~/.config/dotfiles/kscreen-baseline.json`.
2. Count currently-connected outputs (via `kscreen-doctor -j` + `jq`, or `kscreen-doctor -o | grep -c '^Output:'` as a sed-fallback).
3. If actual < expected **AND** `/etc/machine-id` matches the baseline's `machine_id` field, nudge with `qdbus6 org.kde.KWin /KWin reconfigure`. Re-count after 2 s.
4. If the count recovered, log `[ok] output count recovered after reconfigure`. If it didn't, log a `[!]` warning to stderr and `logger -t apply-theme` so the warning survives the closed terminal — the user-visible action is `sudo systemctl restart sddm` or reseat cables.

The reconfigure ping is the strongest non-destructive nudge available — KWin re-reads `kwinrc` and re-polls DRM connectors without killing windows. We deliberately do NOT restart `kwin_wayland`, which would close every open window in the session.

**Cross-machine safety (fail-open).** The recovery only fires when both `machine_id`s are present and equal. A baseline written before the `machine_id` field existed (or hand-edited to remove it), or one with a current-side machine-id we can't read, falls through to the recovery path — better to warn on an extra machine than to silently disable D8 for everyone whose baseline pre-dates that field. A baseline copied between machines via Syncthing simply doesn't trigger D8: the connector names will be different too, so any count delta is expected.

## Panel — thin + autohide + battery widget

The shipped panel is **28 px tall** with **autohide**, applied by `apply-theme.sh` via plasma's JS scripting D-Bus interface (`qdbus6 org.kde.plasmashell /PlasmaShell evaluateScript`). On top of geometry, `apply-theme.sh` also adds a top-level **battery widget** (`org.kde.plasma.battery`) to the panel — separate from the systray's auto-hidden battery icon, so power state is always one mouse-bottom-flick away (the polybar wlan/battery-pill equivalent for the i3 path). The battery widget is the *only* applet `apply-theme.sh` adds; everything else (kickoff, pager, icontasks, systray, clock, show-desktop) is the plasma factory layout.

Tunable without editing the script — export at install time:

```bash
PANEL_HEIGHT=24 PANEL_HIDING=none ./config/plasma/apply-theme.sh
```

Valid `PANEL_HIDING` values: `autohide` (default), `none` (always visible), `dodgewindows` (hide only when windows would overlap), `windowsbelow` (windows pass under the panel).

Re-running `apply-theme.sh` is idempotent for the battery widget too — the script iterates `panel.widgetIds` and skips the add if a `org.kde.plasma.battery` is already present.

On a no-battery box (the 3-monitor desktop), the battery widget falls back to showing the AC-adapter icon — useful UX (lights up if power is unstable / on a UPS), not a wasted slot.

We can't ship `~/.config/plasma-org.kde.plasma.desktop-appletsrc` directly because that file embeds runtime UUIDs and per-machine plasmoid version pins; the JS-scripting route is the supported, version-stable surface across Plasma 6.x point releases.

## i3-style hotkeys + virtual desktops

The plasma path ships `~/.config/kglobalshortcutsrc` with the key bindings i3 users miss:

| Hotkey | Action | i3 equivalent |
|---|---|---|
| `Meta+Return` | Launch Alacritty | `bindsym $mod+Return exec alacritty` |
| `Meta+1`…`Meta+4` | Switch to virtual desktop 1–4 | `bindsym $mod+1..4 workspace 1..4` |
| `Meta+Shift+1`…`Meta+Shift+4` | Move active window to desktop 1–4 | `bindsym $mod+Shift+1..4 move container to workspace 1..4` |
| `Meta+period` / `Meta+comma` | Cycle desktop right / left | `bindsym $mod+period/comma` |
| `Meta+Tab` / `Meta+W` | Overview (present-windows) | `bindsym $mod+s scratchpad` |
| `Meta+Q` | Close focused window | `bindsym $mod+Shift+q kill` (minus the Shift) |
| `Alt+F4` | Close focused window (secondary) | – |
| `Meta+Ctrl+Left` / `Meta+Ctrl+Right` | Cycle desktops (alternate) | – |
| `Ctrl+F1`…`Ctrl+F4` | Switch to desktop (Plasma factory; kept as secondary) | – |
| `Meta+/` | Show the hotkey cheatsheet popup | `bindsym $mod+slash` |

`Meta+/` (the i3 idiom for a help overlay) launches `config/plasma/cheatsheet.sh`, which **re-renders the table above from `~/.config/kglobalshortcutsrc` on every invocation**. There's no second hand-maintained list to drift — add or rename a binding in our `kglobalshortcutsrc` whitelist (`kwin_actions` / `svc_actions` in `cheatsheet.sh`) and the popup updates itself the next time you press the key. Display target chain: `kdialog --msgbox` (preferred, in `DESKTOP_PLASMA_PACKAGES`) → `zenity` → `yad` → plain stdout, so the script still works from a TTY or on a Plasma install missing kdialog.

`config/plasma/kwinrc` sets `[Desktops] Number=4 Rows=1` so all four desktops actually exist (Plasma defaults to one). Re-run `./local_setup.sh setup --plasma --bypass` to redeploy if you want the defaults restored after editing in *System Settings → Workspace → Shortcuts*.

### Why some bindings ship `none,none` (Plasma's conflict resolver)

Three Plasma-factory bindings collide directly with the i3 keymap above, and kglobalaccel does **not** politely merge — it picks one owner per key and silently demotes the other. The shipped `kglobalshortcutsrc` therefore clears the loser explicitly:

- **`[plasmashell] activate task manager entry 1..4 = none,none`** — Plasma ships these on `Meta+1..4` (focus the Nth taskbar entry). Without the clear, plasmashell wins the resolver and our `Switch to Desktop N` stays dead.
- **`[plasmashell] manage activities = none,none`** — Plasma ships Activity Switcher on `Meta+Q`. Cleared so our `Window Close` wins.
- **`[services][org.kde.plasma.emojier.desktop] _launch = none,none,Emoji Selector`** — Plasma 6 ships the Emoji Selector on `Meta+.`, which collides with `Switch One Desktop to the Right`. kglobalaccel's resolver refuses to reassign a key already owned by a service `_launch`, so the clear is mandatory; demoting emojier to a secondary slot also fails (the resolver may promote it back).

### Why apply-theme.sh pushes shortcuts via D-Bus, not `kquitapp6 kglobalaccel`

On Plasma 6 Wayland there is no standalone `kglobalacceld` process — kglobalaccel runs **inside `kwin_wayland`** and owns the `org.kde.kglobalaccel` D-Bus name there. Restarting kglobalaccel means restarting KWin, which closes every window in the session. kglobalaccel also caches bindings at KWin startup and does **not** re-read `~/.config/kglobalshortcutsrc` when the file changes, so edits otherwise only take effect on the next login.

`apply-theme.sh` works around both by calling `org.kde.KGlobalAccel.setShortcut` directly with flag `4` (`NoAutoloading` — overrides even if already set). New bindings fire immediately, no logout, no window kill. The script also pre-clears the three plasmashell/emojier conflicts above via the same path so the resolver doesn't claw the keys back at next reconfigure.

The actual `setShortcut` calls go through `config/plasma/kga_push.py`, a small `python3-dbus` helper that opens **one** session-bus connection and drives every binding down it. The original implementation forked `dbus-send` 17 times per session start (one per binding) which cost ~170 ms of process-spawn overhead on the T14; the Python batch is ~25–35 ms. If `python3-dbus` is missing — e.g. a partial install — `apply-theme.sh` falls back to the legacy `dbus-send` loop, so a fresh deploy without internet access still bootstraps a working session.

### Tiling (Polonium / Bismuth) — intentionally NOT shipped

The cyberpunk dotfiles do **not** install Polonium, Bismuth, Krohnkite, or any other KWin tiling script. Two reasons:

- **No apt package on Debian Trixie.** Polonium is the actively-maintained tiling KWin script for Plasma 6, but it is not in the trixie archive (`apt-cache search ^polonium` is empty). Bismuth was dropped during the Plasma 5→6 transition. Installing from KDE Store / GitHub means no signed-package update path and per-machine drift — not the bar these dotfiles target.
- **Hotkey collision.** Polonium's defaults claim `Meta+H`, `Meta+V`, `Meta+F`, `Meta+M`, and a few others. The kglobalaccel conflict resolver would either re-fight our `Meta+1..4` / `Meta+Q` / `Meta+Return` / `Meta+.` bindings every session or silently demote one set. Mapping around those collisions cleanly needs more design than "drop in upstream defaults".

The four-virtual-desktop + Meta-prefix workflow above already gives i3-style window placement at the desktop granularity; floating window placement is the one remaining behavioural gap. If a future Debian release ships Polonium (or you install it manually), add `polonium` to `DESKTOP_PLASMA_PACKAGES` and document its Meta-binding claims here before re-running deploy.

## Conky — yes, it still works

Conky is X11-only. Under plasma it runs via XWayland with two adjustments handled automatically by the deploy phase:

1. `patch_conky_window_type` swaps `own_window_type='override'` to `'normal'` in the deployed `~/.config/conky/conky.conf`. **Both `'override'` and `'desktop'` get mapped by KWin's XWayland bridge into a stacking layer below plasmashell's desktop wallpaper layer** — the conky process keeps running (you see it in `ps`) but the window is buried, looking like a crash. A managed `'normal'` window with a kwin rule pinning it below is the only combination that actually renders on Plasma + Wayland.
2. `~/.config/kwinrulesrc` ships a window rule matching `WM_CLASS=Conky` that forces below + skip-taskbar / skip-switcher / skip-pager + no-border + no-focus + all-desktops. This is what keeps the now-managed window from stealing focus, showing in the taskbar, or floating above other apps.
3. `~/.config/autostart/conky.desktop` (XDG autostart, `OnlyShowIn=KDE`) launches conky on every plasma login.

Same `conky.conf` file is used by both desktops; only the deployed copy is patched. The repo source stays at `'override'` so the i3 path keeps working unchanged.

## Lock screen

Plasma uses `kscreenlocker_greet` (from `kde-config-screenlocker`); i3 uses i3lock with a custom ImageMagick neon overlay. They're not interchangeable. The plasma path:

- Reads the same `~/.config/wallpaper/wallpaper.png` for the lock background (via templated `kscreenlockerrc`).
- Inherits the `CyberpunkCyan` color scheme for the clock + unlock prompt — cyan accent matches the rest of the desktop.
- Locks on suspend/resume (`LockOnResume=true`) and after 10 minutes idle (`Timeout=10`).

If you want the *exact* i3lock neon-overlay look reproduced on Plasma, kscreenlocker supports custom QML lock screens — substantially more work, deferred to a future revision. The `config/lockscreen/` directory (with the i3lock helpers) stays in the repo and stays deployed; it's just not the active locker under Plasma.

## Switching back to i3 (or between)

Both stacks coexist on disk after either install runs. Switching is a flag + DM swap:

```bash
# i3 → plasma
./local_setup.sh setup --plasma --bypass

# plasma → i3
./local_setup.sh setup --i3 --bypass
sudo systemctl disable sddm
sudo systemctl enable lightdm
sudo reboot
```

(`--bypass` skips the per-stage prompts; the underlying install/deploy/validate logic is the same either way.)

## VM-specific notes

If you're running the plasma path inside a hypervisor:

- **VirtualBox**: change *Settings → Display → Graphics Controller* to **VMSVGA** (not the default VBoxVGA / VBoxSVGA). VBoxVGA has no KMS, so neither Wayland sessions nor the kwin-wayland binary will start. With VMSVGA you get working KMS and both sessions become usable.
- **Hyper-V Gen 2**: disable *Enhanced Session* on the VM connection (the toolbar icon at top of the Hyper-V Connect window). Enhanced Session forces an RDP-style channel that the synthetic Hyper-V framebuffer doesn't handle well under Wayland. With Enhanced Session off, KWin Wayland comes up; with it on, pick Plasma (X11) at the SDDM greeter.
- **KVM/QEMU**: use **virtio-gpu** (`-vga virtio` on the QEMU CLI, or *Video → Model → Virtio* in virt-manager) for the smoothest Wayland experience. The default `qxl` works too but has worse latency.
- **VMware Workstation / ESXi**: vmwgfx provides KMS; both sessions work.

In all VM cases, the `--desktop=plasma` install ships both compositors (`kwin-wayland` + `kwin-x11`), so even if Wayland fails to start you can still log in with Plasma (X11) and have a working desktop.

## Window decorations — terminal title bar with cyan accent

Alacritty ships with `decorations = "full"`, requesting server-side decorations (SSD) over the `xdg-decoration` Wayland protocol. KWin draws the title bar via the Breeze decoration plugin. The cyberpunk look is composed from three files:

| File | Key | Effect |
|---|---|---|
| `config/plasma/kdeglobals` | `[WM] activeBackground=13,13,26` | Title-bar bg matches alacritty's `#0d0d1a` exactly — the bar visually melts into the focused terminal window |
| `config/plasma/kdeglobals` | `[WM] activeBlend=0,229,255` | Cyan `#00e5ff` accent line drawn around the active window perimeter |
| `config/plasma/breezerc` | `[Common] BorderSize=Normal` | 2 px outline (Tiny=1 px / Normal=2 px / Large=4 px / …) — controls how visible the cyan accent is |
| `config/plasma/breezerc` | `[Style] DrawBackgroundGradient=false` | Flat dark bar instead of Breeze's default glassy gradient — fits the rest of the cyberpunk palette |

**Real alpha-transparent title bars** require a third-party decoration theme (Klassy, BreezeEnhanced, BreezeBlurred). None are packaged on Debian Trixie at time of writing; this stock-Breeze recipe gets visually as close as the bundled tools allow. If you want true alpha later, add the upstream repo for one of those themes and switch `library` in `kdeglobals [org.kde.kdecoration2]`.

## ThinkPad T14 (Intel iGPU laptop) notes

- The T14's iGPU (UHD / Iris Xe) ships with `intel-media-va-driver`, `i965-va-driver`, and `firmware-misc-nonfree` from the standard `--nvidia=false` path. No NVIDIA-Wayland kernel tweaks apply.
- Brightness keys work via `brightnessctl` + the existing `trigger_backlight_udev` rule in `install_phase`. Plasma's `powerdevil` also drives backlight via DBus — both routes coexist.
- TLP stays installed alongside `powerdevil`. They handle different layers (TLP: CPU governor / disk APM / wifi power-save; powerdevil: screen blanking, lid action, battery widget). If you see *Power Profile* notifications fighting with TLP, disable powerdevil's CPU/disk policies in *System Settings → Power Management → Energy Saving → uncheck CPU governor*.
- Lid close: configure in *System Settings → Power Management → On Battery / On AC → Lid open / closed actions*. Default is suspend on battery, do-nothing on AC.
- High-DPI on the T14's 1440p panel: *System Settings → Display → Scale → 150%* (fractional scaling under Wayland actually works on Intel iGPUs).
- Backlight on suspend/resume: works natively; no nvidia-pm-options needed.

## Troubleshooting

- **Black screen after reboot on the 3080 Ti** — `nvidia-drm.fbdev=1` and / or the early-KMS modules didn't make it onto the cmdline. Run `cat /proc/cmdline` and `lsinitramfs /boot/initrd.img-$(uname -r) | grep nvidia`. Re-run `./local_setup.sh install --plasma --nvidia` and reboot.
- **Resume from suspend leaves garbled textures** — `NVreg_PreserveVideoMemoryAllocations=1` isn't in effect. Check `cat /etc/modprobe.d/nvidia-power-management.conf` and `lsmod | grep nvidia`. Re-run `add_nvidia_pm_options` via `./local_setup.sh install --plasma`.
- **SDDM doesn't appear at boot — text console only** — lightdm and sddm both enabled. `sudo systemctl disable lightdm`, then `sudo systemctl enable sddm`, reboot. The deploy phase does this, but if it raced you may need to manually fix once.
- **Conky window invisible under plasma (process running per `ps`)** — the window-type patch didn't run, or didn't run with the new value. `grep own_window_type ~/.config/conky/conky.conf` should show `'normal'`. If it still shows `'override'` or `'desktop'`, re-run `./local_setup.sh deploy --plasma` and then `~/.config/conky/launch.sh` to relaunch. Verify the kwin rule is loaded: `grep -A1 conky-desktop-pin ~/.config/kwinrulesrc` should show `below=true belowrule=2`.
- **Plasma network applet doesn't show wifi networks / current connection** — almost always means a *standalone* `wpa_supplicant.service` is still running and holding the wifi device, leaving NetworkManager's view of it as `unavailable`. Diagnose with `nmcli device status` (look for `wifi unavailable`) and `systemctl is-active wpa_supplicant`. Fix: `./scripts/take-over-wifi.sh` (interactive — backs up `/etc/network/interfaces`, stops + disables wpa_supplicant, drops a NM `conf.d` snippet, restarts NM, prompts for SSID + PSK). The installer auto-runs this at the end of `setup` when creds are recoverable from `/etc/network/interfaces`; manual run is required when they aren't (e.g. fresh Debian install with wifi configured by `nmtui` only). After the takeover the plasma-nm tray icon populates correctly within seconds.
- **Hotkeys (Meta+Return / Meta+1..4 / Meta+Q / Meta+. / Meta+,) not working** — kglobalaccel didn't pick up the new shortcuts. On Plasma 6 Wayland kglobalaccel runs inside `kwin_wayland`, so `kquitapp6 kglobalaccel` does NOT work (there's no separate daemon). Either log out / back in, or live-reload by re-running `~/.config/plasma/apply-theme.sh` — the dbus-send loop at the bottom of the script pushes every binding via `org.kde.KGlobalAccel.setShortcut` with flag=4 (NoAutoloading). If only Meta+1..4 or Meta+Q is broken specifically, plasmashell's `activate task manager entry N` / `manage activities` bindings clawed back the key — re-running `apply-theme.sh` clears them again. If Meta+. is broken, the Emoji Selector `_launch` re-took the key for the same reason.
- **Panel didn't shrink / autohide** — `qdbus6` missing or `apply-theme.sh` couldn't reach plasmashell. `dpkg -s qdbus-qt6` should show `Status: install ok installed`; if not, `sudo apt install qdbus-qt6` then `~/.config/plasma/apply-theme.sh`.
- **Battery widget says "no batteries detected" / lid close does nothing / screen never blanks** — `upower` isn't installed and powerdevil can't query the system power state. Diagnose with `journalctl --user -u plasma-powerdevil -n 20` (look for `"org.freedesktop.UPower was not provided by any .service files"`) and `dpkg -s upower`. Fix: `sudo apt install upower && systemctl --user restart plasma-powerdevil`. The installer adds `upower` to `DESKTOP_PLASMA_PACKAGES` — running `./local_setup.sh install --plasma` will pull it in. powerdevil itself doesn't `Recommends: upower` (it Recommends: `power-profiles-daemon`, which conflicts with TLP — we explicitly don't want that), so the package has to be listed by name; `--no-install-recommends` doesn't help here.
- **Audio missing under plasma** — pulseaudio didn't get swapped to pipewire. `systemctl --user status pipewire pipewire-pulse wireplumber`. If pulseaudio.socket is still active, `systemctl --user mask pulseaudio.socket pulseaudio.service` and log out / back in.
- **240 Hz not showing in display settings** — DisplayPort cable issue, or EDID hash hasn't been written yet. Plug both monitors into the GPU's DP outputs (not HDMI for 240 Hz), open System Settings → Display Configuration, click *Apply*. After one successful apply, `~/.local/share/kscreen/` caches the choice.
