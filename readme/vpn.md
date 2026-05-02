# VPN — Mullvad + WireGuard

The dotfiles install **Mullvad VPN** (with the official GUI + CLI) and the
**WireGuard** userland (`wg`, `wg-quick`) — both are wired into polybar so
you can toggle, reconfigure, and watch status from the bar without opening
a terminal or the Mullvad GUI.

---

## What's installed

| Tool                | What it does                                                  |
|---------------------|---------------------------------------------------------------|
| `mullvad-vpn`       | Mullvad GUI app + system tray icon + `mullvad-vpn` launcher   |
| `mullvad` (CLI)     | Same daemon, scriptable from a terminal                       |
| `mullvad-daemon`    | systemd service — talks to relays, manages routes             |
| `wireguard-tools`   | `wg`, `wg-quick`, `wg-genkey`, `wg-pubkey`                    |
| WireGuard kernel module | Ships with modern Debian kernels — no extra DKMS install  |

Mullvad is installed from its **official apt repo** (set up automatically by
the install scripts), so `apt upgrade` keeps it current alongside everything
else.

---

## First-time Mullvad activation

The CLI / GUI need an account number before they can connect:

```bash
mullvad account login <16-digit-account-number>
mullvad account get                       # confirm registration
```

Don't have an account? `mullvad account create` makes one (and you'll get a
new account number — write it down). Or buy a premium account at
[mullvad.net](https://mullvad.net/).

Useful one-time settings to run after login:

```bash
mullvad lan set allow                              # let printers/cast through
mullvad relay set tunnel-protocol wireguard        # WireGuard, not OpenVPN
mullvad auto-connect set on                        # connect on every boot
mullvad lockdown-mode set on                       # kill switch (block while disconnected)
```

(Settings persist in `~/.config/Mullvad VPN/`.)

---

## Polybar — Mullvad module

Look for the   icon to the right of the network indicator. State is
shown as text after the icon:

| Display                    | Meaning                                          |
|----------------------------|--------------------------------------------------|
|   `gb-lon-wg-001`          | Connected to that relay (cyan)                   |
|   `connecting…`            | Establishing tunnel (yellow)                     |
|   `blocked`                | Daemon refused to route (yellow)                 |
|   `off`                    | Disconnected (dim)                               |
|   `not installed`          | `mullvad` CLI missing                            |

Click bindings:

| Mouse              | Action                                                 |
|--------------------|--------------------------------------------------------|
| Left-click         | Toggle: connect ↔ disconnect                           |
| Right-click        | rofi menu: connect / disconnect / pick relay / settings|

Right-click menu structure:

```
Mullvad
├──   Connect                  → mullvad connect
├──   Disconnect               → mullvad disconnect
├──   Reconnect                → mullvad reconnect
├──   Pick relay               → flat list of every relay; pick → set + reconnect
├──   Settings                 → submenu (tunnel/LAN/kill switch/auto-connect)
├──   Account / Status         → notification with current relay + account info
└──   Open Mullvad GUI         → launches the native GUI
```

The relay picker presents all ~600 relays in one rofi window — type to
filter (e.g., `lon` → all London servers).

---

## Mullvad CLI — common operations

```bash
mullvad status                              # one-line connection status
mullvad status verbose                      # full state including IP routes

mullvad connect                             # connect to last relay (or auto-pick)
mullvad disconnect
mullvad reconnect                           # disconnect + reconnect

# Pick a server.  Three styles:
mullvad relay set location se                       # any server in Sweden
mullvad relay set location se sto                   # any in Stockholm
mullvad relay set location se sto se-sto-wg-001     # specific server

mullvad relay list | less                   # browse all relays / cities

# Tunnel + protocol
mullvad relay set tunnel-protocol wireguard         # or openvpn

# Settings
mullvad lan set allow                       # let LAN traffic through (printers!)
mullvad lockdown-mode set on                # kill switch
mullvad auto-connect set on                 # connect at boot
mullvad split-tunnel pid add <pid>          # exclude a process from VPN
```

Full reference: `mullvad --help`, `man mullvad`.

---

## WireGuard — drop-in configs

If you already have WireGuard `.conf` files (e.g., from Mullvad's
"Generate WireGuard config" page, or any other provider), the dotfiles let
you use them directly without going through the Mullvad GUI.

### Install a config

```bash
sudo install -m 600 ~/Downloads/my-vpn.conf /etc/wireguard/my-vpn.conf
```

Naming matters: the filename without `.conf` becomes the interface name
(`wg-quick up my-vpn` ⇒ creates a `my-vpn` netdev).

### Bring it up / down

From the polybar **WireGuard** module (left-click) — pick the config from
the menu.

Or from the CLI:

```bash
sudo wg-quick up   my-vpn
sudo wg-quick down my-vpn
```

### Auto-start at boot

```bash
sudo systemctl enable wg-quick@my-vpn.service
```

### Status

The polybar shows `󰦝 my-vpn → 1.2.3.4:51820` while a tunnel is up; the
module is hidden when nothing is up.

CLI:

```bash
sudo wg                                 # short summary, all interfaces
sudo wg show my-vpn                     # full info for an interface
sudo wg show my-vpn endpoints           # peer endpoints
sudo wg show my-vpn transfer            # bytes rx/tx per peer
sudo wg show my-vpn latest-handshakes   # last successful handshake
ip route                                # routing table (see what's tunneled)
```

---

## Mullvad-style WireGuard (use Mullvad relays without the daemon)

You can sidestep the Mullvad daemon entirely and treat Mullvad as a generic
WireGuard provider:

1. Generate a key pair: `wg genkey | tee privkey | wg pubkey > pubkey`.
2. Register the public key in your Mullvad account at
   [mullvad.net/account/wireguard-config](https://mullvad.net/en/account/wireguard-config/).
3. Generate a config there for the city of your choice, download the `.conf`.
4. Drop it in `/etc/wireguard/` and bring it up with `wg-quick`.

The polybar WireGuard module then reflects the tunnel — same UX as any
other WireGuard config.

---

## Generating your own keys (any provider)

```bash
umask 077
wg genkey | tee privkey | wg pubkey > pubkey
# privkey   → put in `[Interface] PrivateKey = …` of the .conf
# pubkey    → upload to whichever VPN provider's dashboard
# Set permissions
chmod 600 privkey
```

---

## Polybar — WireGuard module

Hidden when no `wg-quick` interface is up. When one is up:

```
󰦝 my-vpn → 1.2.3.4:51820
```

| Mouse        | Action                                                       |
|--------------|--------------------------------------------------------------|
| Left-click   | rofi menu listing every `/etc/wireguard/*.conf`              |

Menu actions:
- Click an inactive config → `wg-quick up <name>`
- Click an active one (marked "(up — click to bring down)") → `wg-quick down <name>`
- "Show status" → notification with full `wg show` output
- "Bring all down" → `wg-quick down` for every active interface

---

## Kill switch comparison

| Layer            | Tool             | What it blocks when "off"                                  |
|------------------|------------------|-----------------------------------------------------------|
| Mullvad daemon   | `mullvad lockdown-mode set on` | All traffic when daemon isn't connected   |
| WireGuard config | `PostDown = iptables ...`      | Routes added by `wg-quick` are torn down — but if you want a true kill switch via WG, add `iptables -I OUTPUT -m mark ! --mark $(wg show wg0 fwmark) -m addrtype ! --dst-type LOCAL -j REJECT` to the PostUp section |
| Mullvad GUI      | Settings → "Always require VPN" | Same as `lockdown-mode` but exposed in the GUI       |

Pick **one** layer — combining them tends to deadlock connections during
reconnect handshakes.

---

## Troubleshooting

| Symptom                                      | Likely cause / fix                                              |
|----------------------------------------------|-----------------------------------------------------------------|
| Polybar shows `  not installed`              | `sudo apt install mullvad-vpn` (or re-run `local_setup.sh setup`) |
| Polybar shows `  off` and click does nothing | Daemon not running: `sudo systemctl start mullvad-daemon`       |
| `mullvad status` says "Daemon offline"       | `sudo systemctl restart mullvad-daemon`                         |
| `wg-quick up X`: `RTNETLINK answers: Operation not supported` | Kernel module missing — `sudo modprobe wireguard` |
| WG module never appears in polybar           | No interface up — `sudo wg-quick up <conf>`                     |
| WG endpoint not shown, only iface name       | sudo isn't passwordless — `sudo wg show` would prompt           |
| Mullvad relay picker is empty                | Daemon hasn't refreshed relay list yet — `mullvad relay update` |
| Polybar status not updating                  | `~/.config/polybar/launch.sh` (relaunches the bar)              |

---

## Further reading

- [Mullvad CLI docs](https://mullvad.net/en/help/install-mullvad-app-linux)
- [WireGuard quickstart](https://www.wireguard.com/quickstart/)
- `man wg`, `man wg-quick`, `man mullvad`
- [`config/polybar/scripts/`](../config/polybar/scripts/) — all five helper scripts
