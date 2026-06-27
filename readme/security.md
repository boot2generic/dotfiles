# Security & Privacy

This guide covers the threat model the dotfiles assume, what's hardened
out-of-the-box, what's opt-in via the `harden` subcommand, and what's
left to the user.

---

## Threat model

These dotfiles target a **single-user development workstation** —
laptop or VM — running on Debian 12+. The model assumes:

- The user is the only human with shell access.
- Local processes running as the user are *not* fully trusted (browser
  exploits, malicious npm/pip packages, supply-chain attacks).
- Network adversaries can MITM unencrypted traffic.
- **Disk encryption (LUKS) is configured at OS install time.** See the
  next section — this is a hard prerequisite for the laptop, not an
  optional extra.
- Multi-user shared boxes and servers are **not** the target — some
  defaults (broad sudo NOPASSWD during install) would be wrong there.

**Not in scope:**
- Hardening the kernel or systemd unit defaults.
- Container/sandbox isolation (Firejail, bubblewrap, etc.).

**Partially in scope:**
- **Browser fingerprint resistance** — the apps subsystem ships
  **Mullvad Browser** (fingerprint-resistant Firefox fork) alongside
  Firefox ESR with a policies-driven privacy posture (telemetry off,
  six force-installed add-ons: uBlock Origin, KeePassXC-Browser,
  Privacy Badger, ClearURLs, LocalCDN, Multi-Account Containers).
  Full arkenfox-grade fingerprint surface reduction on Firefox is
  still on the user — see "Browser hardening" below.
- **USB device control / YubiKey enforcement** — `libpam-yubico` and
  `yubikey-manager` ship as tier-1 apt installs, but no PAM file is
  edited (the daemon-side install is a hygiene-tier opt-in that
  routes through a future `harden --yubikey` flow). `usbguard` is
  similarly opt-in via the same hygiene tier — not installed by
  default; see [`readme/apps.md`](apps.md) → tier 5.

---

## Prerequisite: full-disk encryption (LUKS)

**The laptop baseline is not safe without LUKS.** Several controls in
this repo (zsh history hardening, narrow sudoers, Mullvad config
permissions, WireGuard key-file modes) protect against malicious
*processes* on a running system. None of them protect a *powered-off*
or *suspended* machine from a thief who removes the disk and reads it
on another box. On a laptop — which is the threat model that
distinguishes a portable from a server — that is the dominant risk.

These are not problems the dotfiles can fix; LUKS is an installer-time
choice. To meet the threat model:

- **At Debian install time**, choose "Guided — use entire disk and
  set up encrypted LVM" (or the equivalent in the manual partitioner).
  Pick a passphrase you can memorise; use a hardware token for the
  recovery key if you have one.
- **Do not configure auto-unlock** at boot via TPM unless you have
  separately enabled measured boot — a TPM that releases the key to
  any kernel boot does not protect against evil-maid attacks.
- **Always lock the screen** before walking away (`Mod+Shift+x` or
  `Mod+Delete` per these dotfiles). LUKS only protects you while the
  machine is off; a logged-in unlocked session is fully exposed.
- **Hibernate, don't suspend**, when leaving the laptop unattended for
  long periods. Suspend keeps the LUKS key in RAM. (Hibernate has its
  own caveats — the swap partition must be on the encrypted LVM.)

The desktop workstation is generally a lower-risk environment
(physically controlled, no transit), so LUKS there is a judgement
call rather than a hard requirement — but the dotfiles' threat model
otherwise still applies.

---

## Hardening modes

The dotfiles have **two distinct security postures**:

| Mode      | When                          | sudo policy        | firewall | DNS                    | auto-updates |
|-----------|-------------------------------|--------------------|----------|------------------------|--------------|
| Install   | While running `setup`         | NOPASSWD ALL       | none     | NetworkManager / dhcpcd | off          |
| Hardened  | After `./local_setup.sh harden` | Narrow Cmnd_Alias | ufw deny | systemd-resolved opportunistic DoT (Cloudflare + Quad9; Google plain `8.8.8.8` fallback) | enabled |

`setup` deliberately uses the permissive *install* mode so the
provisioning pipeline doesn't prompt for a password every five seconds.
You're meant to flip to *hardened* mode the first time everything works:

```bash
./local_setup.sh setup            # install (interactive)
./local_setup.sh harden           # tighten — once
```

### Am I hardened right now?

A hardened system used to look identical to an unhardened one. Three
surfaces now make the posture obvious at a glance:

- **`./local_setup.sh status`** — a read-only dashboard: hardened-vs-install
  mode, disk encryption (LUKS), supply-chain pins, baseline drift, and
  recent security alerts, aggregated from `audit.sh` / `verify-pins.sh` /
  `seclog` so you run one command instead of six.
- **zsh login banner** — one line at session start: `✓ hardened …` or
  `⚠ INSTALL MODE — …`. Shown once per login session.
- **conky HEALTH panel** — the top two rows are `hardening` (green when
  hardened, yellow in install mode) and `disk crypto` (LUKS on `/`).

These read a world-readable marker `/etc/dotfiles-hardened` (written by
`harden`, removed by `unharden`) — necessary because the narrow sudoers
file itself is root-only, so an unprivileged shell can't infer the mode
from it. If you hardened before this marker existed, re-run `harden`
once to create it.

> **Tool exit codes** are unified across the suite for cron/scripting:
> `0` all clear · `1` warn/stale · `2` bad · `3` usage/tool-fault.
> (`audit.sh` previously used `1` for bad; it now uses `2`, matching
> `verify-pins.sh` and `dotfiles-doctor.sh`.)

If you ever need to re-run `setup` (after editing the dotfiles, say),
unharden first to give the install pipeline broad sudo:

```bash
./local_setup.sh unharden
./local_setup.sh setup
./local_setup.sh harden
```

---

## What's hardened out-of-the-box

These apply unconditionally — no opt-in needed.

### `vm_automation.py` SSH credentials
- **No hardcoded password.** Earlier revisions of this repo embedded a
  literal password constant; that has been removed. The script tries
  SSH key auth first; only if `ssh -o BatchMode=yes …` fails does it
  fall back to a 0600 password file (preferred) or the deprecated
  `$VM_PASS` env var (with a warning).
- **No `sshpass -p`.** The `-p <password>` form leaks credentials into
  every running process's argv (`ps -ef`). We use `sshpass -e` (env-var
  mode) so the password is read from `$SSHPASS` only inside the
  subprocess env block.
- **0600 password file preferred over `$VM_PASS`.** Env vars are
  visible in `/proc/<pid>/environ` to the same UID and tend to leak
  into shell history files and tmux scrollback. The script reads from
  `$XDG_CONFIG_HOME/dotfiles/vm_pass` if present and refuses any mode
  wider than 0600.
- **`VM_HOST` is not committed to git.** The script requires
  `VM_HOST=<ip-or-hostname>` in the environment — there is no default
  IP in the source, so a stale checkout cannot accidentally target a
  prior owner's VM.
- **Pexpect logging is force-disabled.** `child.logfile = None` runs
  after every `_spawn_ssh()` so an accidental hook can't capture the
  bootstrap-time `su` password to disk.

To eliminate the password file entirely once SSH key auth works:
```bash
export VM_HOST=<ip-or-hostname>
ssh-copy-id "${VM_USER:-generic}@${VM_HOST}"
shred -u ~/.config/dotfiles/vm_pass 2>/dev/null
unset VM_PASS
```

### Mullvad keyring fingerprint pinning
Both scripts download the Mullvad apt-repo signing key, then call
`gpg --show-keys --with-colons` and **assert** that:
1. the keyring contains exactly **one** public-key block
2. that key's fingerprint matches `MULLVAD_KEY_FINGERPRINT`

Either condition failing aborts the install with no apt source added.
The "exactly one" check defeats a transition-period attack where an
attacker prepends the expected key with a benign-looking key and
appends a malicious one — apt would have trusted both.

To override during a key rotation:
```bash
MULLVAD_KEY_FINGERPRINT=<new-fp> ./local_setup.sh setup
```

### No `curl | sh` for installers
- **oh-my-zsh:** plain `git clone --depth=1 …/ohmyzsh.git ~/.oh-my-zsh`.
  Skips the upstream `install.sh` entirely (its only other job is to
  write a default `~/.zshrc`, which we overwrite a moment later anyway).
- **starship:** downloads the architecture-matched tarball directly
  from the GitHub release page (`starship-x86_64-…tar.gz`), fetches the
  `.sha256` sidecar, runs `sha256sum -c`, only then extracts. A
  compromised CDN can't ship a backdoored binary without also
  compromising the GitHub release.
- **JetBrainsMono Nerd Font:** downloads `JetBrainsMono.zip` from the
  pinned `v3.3.0` release AND the same release's `SHA-256.txt`
  manifest, then `sha256sum -c` against the manifest line for our
  specific zip.  Manifest tampering is detected in lockstep with zip
  tampering since both files come from the same GitHub Release that
  the maintainer signs together.

### Plugin pinning (lazy.nvim)
Earlier revisions pinned the moving branches `branch = "0.1.x"`
(telescope) and `branch = "master"` (nvim-treesitter) — a maintainer
who could push to those branches could ship arbitrary code into the
next `:Lazy update`.  Both are now pinned to specific tags:
- `telescope.nvim` → `tag = "0.1.8"`
- `nvim-treesitter` → `tag = "v0.9.3"`

Other plugins were already tag-pinned (`mason.nvim v1.11.0`,
`mason-lspconfig.nvim v1.32.0`, `nvim-lspconfig v1.8.0`).  To upgrade,
edit the tag in `~/.config/nvim/init.lua` and `:Lazy sync`.

### File permissions
- `/etc/wireguard/`: `chmod 700` on the dir, `chmod 600` on `*.conf`,
  enforced by `deploy_phase`. WireGuard configs hold a private key in
  cleartext — `wg-quick` warns on permissive perms but the warning is
  easy to miss.
- `~/.zsh_history`: `chmod 600` enforced both at deploy time AND on
  every shell start (in `.zshrc`).  The shell-start chmod loop also
  covers `~/.fzf_history`, `~/.python_history`, `~/.lesshst`,
  `~/.sqlite_history`, `~/.mysql_history`, `~/.psql_history`,
  `~/.gdb_history`, and `~/.lua_history` — any of which can capture
  an accidentally-typed credential.
- `HISTORY_IGNORE` glob in `.zshrc` drops commands matching
  `*PASSWORD*`, `*TOKEN*`, `*SECRET*`, `mullvad account login*`,
  `wg set * private-key*`, `export *_KEY=*`, etc., before they hit
  history. Combined with `HIST_IGNORE_SPACE` you get two layers — the
  glob catches the obvious cases, the space-prefix lets you opt out
  ad-hoc.
- Lockscreen overlay PNG: `mktemp` + `chmod 600` + cleanup trap on
  `EXIT/INT/TERM`. The previous `/tmp/.lockscreen_$(id -u).png` was a
  predictable path readable by other users on a multi-user box.
- Conky state files: `$XDG_RUNTIME_DIR/conky/{netstat_bw,newprocs}` —
  `/run/user/$UID` is mode 0700 (per-user, wiped on logout).  Falls
  back to `~/.cache/conky/` on systems without logind.  Each file
  written via `os.open(... O_CREAT, 0o600)` so the perms hold even
  through user umask changes.  Previous `/tmp/.conky_*` paths leaked
  every active connection's destination + bytes-transferred to any
  other local user.

### Apt-source modifications are additive, not in-place (local_setup.sh)
`local_setup.sh` enables non-free apt access by writing a deb822
**drop-in** at `/etc/apt/sources.list.d/dotfiles-non-free.sources`.
It never modifies `/etc/apt/sources.list` or
`/etc/apt/sources.list.d/debian.sources` in place. To roll back, just
delete the drop-in:

```bash
sudo rm /etc/apt/sources.list.d/dotfiles-non-free.sources
sudo apt update
```

`vm_automation.py` is older and still uses an **in-place** edit for its
`enable_nonfree_repos()` (legacy path; called automatically when
`--nvidia` is set). It copies each modified file to
`<path>.bak.YYYYMMDD-HHMMSS` (mode 0600) before the edit so
`mv …bak.* path` is the rollback. Backups older than 30 days are
auto-pruned at the start of each invocation.

### sudoers content never appears on a command line
The `_install_sudoers` helper used to ship the new sudoers content as
a base64 blob inside `sudo bash -c '<script with embedded blob>'`.
That meant the full sudoers file (including the username and every
Cmnd_Alias) was visible in `ps -ef` for the brief window the command
ran AND in any audit log capturing argv (auditd, journald with
verbose levels).  The current implementation `scp`s the content to a
private temp file on the VM, then the remote script just reads from
disk — no sensitive content lands in argv.

---

## What `harden` does (opt-in)

### 1. Narrow sudo NOPASSWD
Replaces `/etc/sudoers.d/<user>` from `<user> ALL=(ALL) NOPASSWD: ALL`
with a `Cmnd_Alias` allowlist:

```
DOTFILES_VPN → wg-quick up/down *, wg show, systemctl wg-quick@*
               ls /etc/wireguard
DOTFILES_APT → apt-get update, apt-get clean, apt-get autoclean
DOTFILES_SVC → systemctl restart polybar / picom / lightdm
DOTFILES_NET → ss -nlp / -nip / -tl-nlp / -ul-nlp / -ta-nip / -ua-nip
               / -wa-nip
```

> **Important**: in earlier revisions the allowlist included
> `apt-get -y install *` and `apt-get -y upgrade *`.  Those have been
> removed because `sudo apt-get -y install ./malicious.deb` would have
> let any user-level process gain root via a `postinst` script — the
> wildcard in sudoers was a near-complete escape.  After the fix,
> `sudo apt install <package>` requires your password.
>
> If you need to re-run `setup` (which uses apt freely), `unharden`
> first and `harden` again afterwards.

After `harden`, **arbitrary `sudo`** (including `sudo bash`,
`sudo -i`, `sudo nano /etc/...`, `sudo apt install …`) prompts for your
password. The day-to-day commands the dotfiles need (VPN toggling,
running `apt update`, viewing socket info) stay passwordless.

The new sudoers file is validated with `visudo -c -f` *before*
installation — a syntactically broken sudoers file would lock you out
of root entirely.

### 2. ufw (firewall)
- `default deny incoming`, `default allow outgoing`
- `allow ssh` is added **before** `ufw enable` so the in-progress SSH
  session survives.
- That's it — no port allowlist for printers/cast/etc., add those
  yourself if you need them.

### 3. unattended-upgrades (security-only)
- Installs `unattended-upgrades` + `apt-listchanges`.
- Drops `/etc/apt/apt.conf.d/20auto-upgrades` to drive the daily timer.
- Drops a managed `/etc/apt/apt.conf.d/50unattended-upgrades` from
  `config/system/etc/apt/apt.conf.d/50unattended-upgrades` whose
  `Origins-Pattern` allowlist contains **only `Debian-Security`** labels.
  This deliberately avoids the standard Debian default of also including
  stable + stable-updates + backports + proposed-updates — that combination
  silently auto-bumps point releases under you, which is the historic
  footgun. CVEs install automatically; feature releases still need a
  manual `apt upgrade`.
- If `mailx` (`bsd-mailx` / `s-nail`) is installed, also drops a
  `51unattended-upgrades-mail` snippet that emails root on change.
  Without mailx the journal is the only audit trail
  (`journalctl -u unattended-upgrades.service`).

### 4. auditd rules (identity / sudoers / modules / mount)
- Installs `auditd` + `audispd-plugins`.
- Drops `config/system/etc/audit/rules.d/dotfiles.rules` into
  `/etc/audit/rules.d/dotfiles.rules` and loads it via
  `augenrules --load` (or `systemctl restart auditd` on very old hosts).
  Other `rules.d/` files are left untouched — `unharden` removes only
  our rule file.
- Logged surface:
  - `-w /etc/{passwd,group,shadow,gshadow} -p wa -k identity`
  - `-w /etc/sudoers* -p wa -k sudoers`
  - `init_module` / `finit_module` / `delete_module` on b64 *and* b32 (`-k modules`)
  - `mount` / `umount2` syscalls (`-k mount`)
  - `execve` of `sudo`/`su` is shipped **commented out** under
    `-k privesc`; uncomment if you want it (verbose on a desktop).

Query the resulting events:

```bash
sudo ausearch -k identity --start today
sudo ausearch -k sudoers  --start week-ago
sudo ausearch -k modules  --start today
sudo ausearch -k mount    --start today --interpret
sudo auditctl -l                                    # what's loaded now
```

The Debian-Level-2 / CIS "process accounting on every syscall" rules
are intentionally **not** shipped — on a single-user workstation they
flood logs without changing the threat picture. Add them by hand if
you're using these dotfiles on a multi-user box.

### 5. systemd-resolved + DNS-over-TLS (opportunistic)

`harden_dot()` (which **replaces** the older `harden_dns` /
`dhcpcd + static domain_name_servers=…` path entirely) installs
`systemd-resolved` if missing and drops two managed files:

- `/etc/systemd/resolved.conf.d/cyberpunk-dot.conf` from
  `config/system/etc/systemd/resolved.conf.d/cyberpunk-dot.conf`:
  - `DNSOverTLS=opportunistic` — try DoT first, fall back to plain
    DNS when TCP/853 is blocked or the cert doesn't validate.
  - `DNSSEC=allow-downgrade` — validate signatures when the upstream
    supports them, don't NXDOMAIN every lookup when it doesn't.
  - `DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com
    9.9.9.9#dns.quad9.net` — Cloudflare + Quad9 with the `#name`
    SNI/cert-CN hints resolved uses to authenticate the TLS
    connection. (Without `#name`, opportunistic mode has no
    expected-CN to compare and skips DoT entirely.)
  - `FallbackDNS=8.8.8.8 8.8.4.4` — Google as plain (no `#name`)
    last resort if every primary is unreachable. Liveness over
    privacy; remove the line if you'd rather hard-fail in that case.
- `/etc/NetworkManager/conf.d/cyberpunk-dns.conf` (`[main]
  dns=systemd-resolved`) — NM stops fighting `/etc/resolv.conf` on
  every connection event and pushes per-link DNS into resolved via
  D-Bus instead. This preserves per-link DNS for VPN / corporate
  resolvers under our global DoT policy.

Then atomically `ln -sf /run/systemd/resolve/stub-resolv.conf
/etc/resolv.conf` (defensive `chattr -i` first, in case an older
hardening guide pinned the file immutable), `systemctl reload
NetworkManager`, `systemctl restart systemd-resolved`.

#### The "opportunistic" trade-off

`opportunistic` is deliberately not `yes` (strict). The threat model
here is a **roaming laptop on untrusted wifi** — and strict mode is
unworkable on two real-world networks:

- **Captive portals** (hotels, airports, conferences) typically block
  TCP/853 outbound. A strict policy can't resolve
  `captive.portal.example` to even load the login page; the user is
  bricked.
- **Enterprise networks** sometimes MITM all TLS, including DoT, with
  an internal CA. Strict refuses to trust the cert and bricks the user
  identically.

Opportunistic mode degrades gracefully in both: encrypted when
the upstream supports it, plain DNS when it doesn't.

The cost is **RST-downgradability**: a hostile network can drop your
TCP/853 SYN with an RST and force you back to plain DNS, where they
can see (and potentially tamper with) every query. The conky `DoT`
row (`check_dot()` in `~/.config/conky/health.py`, see "Conky security
monitoring" below) tells you when this is happening:

| Conky `DoT` state | Meaning |
|---|---|
| `OK active on <iface>` | `+DNSOverTLS` on the default-route link — encrypted. |
| `WARN fallback (plain)` | `-DNSOverTLS` — resolved is configured but the upstream isn't honouring it. Treat DNS as visible; consider routing over Mullvad. |
| `DIM not configured` | systemd-resolved isn't running — you haven't `harden`ed, or `unharden` undid it. |

`unharden` reverses **all five** changes — sudoers back to broad
NOPASSWD, ufw disabled, unattended-upgrades off, auditd
`dotfiles.rules` removed (other rules.d/ entries left alone), and
`unharden_dot()` drops both `cyberpunk-*.conf` drop-ins, removes the
`/etc/resolv.conf` symlink **before** stopping resolved (so there's no
window of missing nameservers), reloads NM, kicks the active
connection if NM didn't rewrite `/etc/resolv.conf` on reload alone,
and disables `systemd-resolved`.

---

## What's still on you

These the dotfiles can't or shouldn't automate:

### Disk encryption
LUKS at OS install time. The dotfiles' `chmod 600` policies on
`~/.zsh_history`, `/etc/wireguard/*.conf`, etc. are mostly defence-in-
depth — they don't help if your disk is unencrypted and you lose the
laptop.

### Mullvad account number
The Mullvad daemon refuses to connect until you log in. The account
number IS the only credential — treat it like a password.

```bash
mullvad account login <16-digit-number>      # store ONLY in your password manager
mullvad account get                          # confirm
```

The `HISTORY_IGNORE` pattern catches `mullvad account login *` so it
won't end up in `~/.zsh_history`. Confirm with `tail ~/.zsh_history`
after running it.

### Browser hardening
The dotfiles install **two** browsers via the apps subsystem and bind
both in i3:

- `Mod+b` → `librewolf` (when present) or `firefox-esr` (the apt-backed
  baseline; ships with a policies.json that force-installs uBlock
  Origin, KeePassXC-Browser, Privacy Badger, ClearURLs, LocalCDN,
  Multi-Account Containers and locks telemetry off).
- `Mod+Shift+b` → `mullvad-browser` — [Mullvad
  Browser](https://mullvad.net/en/browser), fingerprint-resistant
  Firefox fork from Mullvad. Installed from Mullvad's signed apt repo
  (same key as the VPN). Ships a minimal extension set (uBlock +
  KeePassXC only) to preserve Mullvad's anonymity-set.

For a paranoid Firefox baseline, additionally install
[arkenfox-user.js](https://github.com/arkenfox/user.js/) into the
profile dir — kills fingerprinting vectors beyond what the policies
file can cover.

### SSH key passphrase
`ssh-copy-id` to the VM works for both passphrase-less and protected
keys. For a development laptop, a passphrase + ssh-agent is the right
posture. Yubikey-resident keys (`ssh-keygen -t ed25519-sk`) are even
better.

### Mullvad GUI telemetry
After login, in the GUI: Settings → "Beta program"  / "Help us improve"
should be reviewed. Mullvad's defaults are conservative but worth
double-checking each major release.

### Plugin commit pinning (lazy.nvim, oh-my-zsh, tpm)
We pin lazy.nvim plugins to **branches/tags**, not commits. A
compromised maintainer account can move tags. For a paranoid posture:

```lua
-- in init.lua
{ "telescope.nvim", commit = "abcd1234..." }
```

Look up each plugin's current SHA, paste it in. Trade-off: explicit
upgrades only (`:Lazy update`, manually re-paste SHAs).

### Sensitive command audit
`harden` now installs `auditd` and ships
`config/system/etc/audit/rules.d/dotfiles.rules` for identity files,
sudoers, kernel modules, and mount/umount syscalls (see "What `harden`
does" → §4 above). If you want a forensic record of every `sudo`
invocation specifically, uncomment the `execve(sudo)` / `execve(su)`
rule in `dotfiles.rules` (it's shipped commented under `-k privesc`)
and `sudo augenrules --load`. Verbose — only worth it if you're
actively chasing an incident.

### USB / device control
Hygiene-tier opt-in. `libpam-yubico` and `yubikey-manager` are
installed as tier-1 apt packages by the apps subsystem, but no PAM
file is edited — the daemon-side wiring is the user's call (see the
recommended steps under "Browser hardening" / "Sensitive command
audit" for the same pattern). For full USB lockdown look at
[`usbguard`](https://github.com/USBGuard/usbguard).

---

## Conky security monitoring (always-on, top-right of screen)

Conky's three security-oriented panels run continuously while you're
logged in. They're not a replacement for proper EDR — they're cheap
visual indicators that complement auditd's forensic log, and the same
checks are also available from the CLI via `scripts/audit.sh` and
`scripts/dotfiles-doctor.sh` (see [`readme/system.md`](system.md) →
"Drift monitoring" and "Security monitoring").

### HEALTH panel — `~/.config/conky/health.py`

Eighteen checks total, of which these four are the security stack:

| Check | What it tracks | Conky label |
|---|---|---|
| `check_critical_file_drift` | sha256 of `/etc/passwd`, `/etc/shadow`, `/etc/sudoers`, every file under `/etc/sudoers.d/`, `~/.ssh/authorized_keys`, systemd unit files, `/etc/cron.d/` against a stored baseline. Any change is BAD. | `critical files` |
| `check_recent_sudo_invocations` | Successful `sudo` invocations in the last 24 h (from auth.log / journal). Pure visibility — high count isn't BAD by itself, but a spike when you weren't sudo'ing is. Distinct from the existing `failed sudo 24h` counter (which tracks **failed** sudo attempts, the brute-force indicator). | `sudo ok 24h` |
| `check_suid_drift` | Full-rootfs SUID/SGID inventory. New SUID binary appearing between runs is BAD. Cached for 23 h to avoid re-`find /` every conky cycle (the scan is ~seconds even with hot cache). | `suid drift` |
| `check_parent_anomaly` | Walks the process tree looking for interactive shells whose parent is a long-running daemon (`sshd`, `cron`, `apache2`, etc.) — the canonical post-exploit reverse-shell pattern. | `parent anomaly` |

The baselines live next to the conky configs:
`~/.config/conky/baseline-{critical-files,suid,ports,modules}.txt`.
Refresh after a legitimate change (e.g. installing a new SUID
binary):

```bash
./scripts/audit.sh --refresh-baseline critical-files
./scripts/audit.sh --refresh-baseline suid
```

### Beacon detection — `~/.config/conky/netstat.py`

Persistent JSON state under `$XDG_RUNTIME_DIR/conky/` records every
*newly appearing* `(ip, port, proc)` triple's timestamp. When the same
triple has fired ≥4 times with mean interval ≥30 s and
coefficient-of-variation (`stdev/mean`) under 0.15 — i.e. "too regular
for a human-driven workload" — the row renders with a `⏱` marker
(yellow) and the header summary adds `<n> beaconing`.

The thresholds (`BEACON_MIN_EVENTS`, `BEACON_CV_THRESHOLD`,
`BEACON_MIN_MEAN_SECS`, `BEACON_HISTORY_TTL`) are tunable at the top
of `netstat.py`. Sub-30 s mean intervals are excluded on purpose —
that's where most DNS / NTP / metrics-scrape noise lives. Triples
quiet for over an hour age out (`BEACON_HISTORY_TTL`) so a long-dead
binary doesn't stay flagged forever.

### Listener tagging — `~/.config/conky/listenports.py`

Every listening port renders its bound binary's `exe` path. Path is
rendered in red (`${color5}`) when:

- the resolved path is **outside** `/usr/`, `/snap/`,
  `/var/lib/flatpak/`, and friends (i.e. a listener bound by a binary
  that wasn't packaged by apt / snap / flatpak), **or**
- the path ends in `(deleted)` — the kernel's marker for a process
  whose binary was unlinked after exec, a classic post-exploit trick
  (delete the dropper, keep the listener resident).

This is a visual prompt, not a verdict. A development build of a tool
you wrote yourself living under `~/code/` will read as red here — and
that's correct, the panel is asking "are you sure that's supposed to
be listening?".

### Audit trail tied to harden

The conky panel is the always-visible surface; auditd (`-k identity` /
`sudoers` / `modules` / `mount`, see §4 of "What `harden` does" above)
is the forensic surface — the conky check fires fast, the auditd log
tells you exactly what changed and which UID did it. Run them
together.

---

## Security event log

The conky HEALTH panel is *live*: it tells you THAT a security check is
red right now, but it keeps no history and its drift rows can't show
WHAT changed. The **security event log** is the persistent companion —
an append-only JSONL record that the security checks write to on every
OK→WARN/BAD transition, capturing the *why*: which file drifted (old→new
sha), which port/SUID/module appeared, which daemon spawned a shell,
which connection started beaconing, which pin failed verification.

Implemented in [`~/.config/conky/seclog.py`](../config/conky/seclog.py),
written by the same processes that drive the panel
(`health.py`, `netstat.py`, `listenports.py`).

### Quick glance

```bash
seclog            # path + size + recent alerts, FULLY expanded + colourised
seclog -n 100     # last 100 events
seclog --all      # every event (includes the .1 rollover)
seclogf           # same view, then live-follow new alerts as they arrive
seclog-raw        # verbatim JSONL dump (pipe to jq/grep)
```

The view is one line per alert — a simple, lightly-coloured display of
the log (dim timestamp, coloured severity, bold check) with the full
detail kept inline, so nothing is hidden and nothing is exploded into
tabbed blocks. `seclog-raw` is there for machine processing
(`seclog-raw | jq 'select(.sev=="bad")'`). Aliases in
[`config/zsh/.zshrc`](../config/zsh/.zshrc); all wrap
`python3 ~/.config/conky/seclog.py`. The viewer auto-targets whichever
log is active — see the two tiers below.

### Clearing alerts after you investigate

Once you've looked into a drift alert and decided the current state is
fine, accept it as the new baseline so the conky panel goes back to
clean:

```bash
seclog-clear              # re-baseline ALL drift checks (critfile/suid/ports/modules)
seclog-clear suid         # just one: critfile | suid | ports | modules
```

This deletes the relevant `~/.config/conky/baseline-*.txt` so the next
health cycle rebuilds it; the row then renders green and its transition
logic emits a `resolved` event. The clear itself is logged as a
`user_ack` event recording exactly what you accepted — so "I cleared
this on this date" is part of the audit trail. It **never** deletes the
event log (that's the history; view it with `seclog`).

Note which alerts this does and doesn't address:
- **Drift** (critfile / SUID / ports / modules) → cleared by `seclog-clear`.
- **Live anomalies** (parent-anomaly, suspicious-exe, hidden-PIDs,
  beacons, rogue listeners) → can't be "acked"; they clear themselves
  when the condition is gone (by design — you shouldn't be able to
  silence a live reverse shell).
- **Supply-chain staleness** → clear by refreshing the pin date
  (`scripts/refresh-pins.sh`); a *failed* pin needs the manifest fixed.
- **sudo counters** → 24 h rolling windows; they age out on their own.

### What gets logged

The **security subset** of the checks, on transition only (a persistent
BAD writes ONE event, not one every 30 s cycle): critical-file / SUID /
kernel-module / listening-port drift, daemon→shell parent anomalies,
suspicious / deleted exe paths, hidden PIDs, failed-sudo spikes,
successful-sudo spikes, supply-chain pin failures, netstat beacons,
rogue (non-packaged / `(deleted)`) listeners — plus `seclog_tamper`
events (always). Clearing a condition logs one `info` "resolved" event
so the log shows when it went green again.

**Redaction.** For the auth crown jewels (`/etc/shadow`, `/etc/passwd`,
`/etc/sudoers*`) the event records path + old→new sha only, never
content (`"redacted": true`). Other paths carry full sha-level detail.
The only place real textual diffs are stored is the tamper watcher (it
keeps a shadow copy of the log's own last-good bytes — see below) — and
that content is the already-redacted log, so no secrets land on disk.

**Size cap.** 256 KiB per file with one `.1` rollover (≈512 KiB worst
case per tier), so the log can never grow unbounded. Rotation is a
legitimate write that updates the integrity baseline in the same step,
so it never self-triggers a tamper alert.

### Tamper-watching (conky guards its own log)

The new HEALTH row **`seclog`** is the watcher. Each cycle it re-reads
the active log and compares it against an integrity sidecar
(`sha256` + `size` + `mtime` + a shadow copy of the last-good bytes):

| `seclog` row | Meaning |
|---|---|
| `guarded (N)` / `guarded+a (N)` | log matches the sidecar; N events. `+a` = Tier-2 append-only verified. |
| `mtime touched` (WARN) | content identical but the timestamp moved — someone `touch`ed/`utime`'d it. The mtime must move ONLY when the writer writes. |
| `TAMPERED +A -B` (BAD) | the log content diverged from the last-good snapshot. A **unified diff** of exactly what was altered is written into the log as a `seclog_tamper` event. |
| `baseline (N)` / `module missing` (DIM) | first sight of the log (trust established) / `seclog.py` not deployed. |

Detection is wired into **every append path**, not just the watcher row,
so a tamper can never be silently absorbed by a later legitimate append
— whichever process writes next catches it and records the diff. (If a
concurrent appender catches it first, the row may read green while
`seclog` shows the recorded `seclog_tamper` event.)

To re-baseline after you *legitimately* edit the log (rare), just delete
the sidecar — `rm ~/.local/state/dotfiles/.seclog.state.json` — and the
next cycle re-establishes trust silently.

### Two integrity tiers

| | Writer | Log path | Guarantee |
|---|---|---|---|
| **Tier 1** — always-on | `health.py` etc., as your user | `~/.local/state/dotfiles/security.log` (0700 dir, 0600 files) | tamper-**evident** |
| **Tier 2** — after `harden` | root helper via NOPASSWD sudo | `/var/log/dotfiles/security.log`, root-owned + `chattr +a` | tamper-**resistant** |

**The same-UID ceiling (be honest about it).** At Tier 1 the log, sidecar
and shadow are all owned by your user, so a malicious process running as
*you* can edit the log AND rewrite the sidecar to match — Tier 1 is
genuine tamper-*evidence* (it catches corruption, unsophisticated
tampering, and anything that strikes before it can rewrite the sidecar),
not tamper-*proof*. We deliberately do **not** HMAC-chain the records:
against a same-UID adversary the key is readable too, so it would add
audit cost without changing the guarantee. The real guarantee comes from
Tier 2.

**Tier 2 (what `harden` adds).** `local_setup.sh harden`:
- installs the append-only helper to `/usr/local/lib/dotfiles/seclog-append`
  (root-owned 0755 — **not** user-writable, so the grant below can't be
  repurposed);
- creates `/var/log/dotfiles/security.log` root-owned and `chattr +a`;
- adds a single narrow NOPASSWD rule (alongside the existing
  `DOTFILES_VPN`/`APT`/`SVC`/`NET` aliases):

  ```
  DOTFILES_SECLOG → /usr/local/lib/dotfiles/seclog-append
  ```

The helper takes **no arguments** (the log path is hard-coded), reads
**one** validated JSON record from **stdin** (mirroring the repo's
"no secrets in argv" rule), and appends it. Because the log is root-owned
and append-only, a non-root process — including one running as your UID —
cannot edit, truncate, or backdate it; the watcher additionally asserts
the file is still root-owned and still `+a` (losing either takes root, so
it's a high-signal event). `seclog.py` routes to Tier 2 only when BOTH
the root log and the helper exist, so `unharden` (which drops the
append-only attribute, removes the helper, and leaves the old root log as
a historical artifact) cleanly falls back to the Tier-1 user log.

### Relationship to the rest of the stack

The `seclog` log is the **detailed, persistent** layer; the conky HEALTH
panel is the **live** layer; `auditd` (Tier-2 `harden`) is the
**kernel-level forensic** layer that records the UID behind a change.
The seclog drift events answer "what did my own checks see change, and
when"; cross-reference a `critfile_drift` event's timestamp against
`sudo ausearch -k sudoers --start <time>` to get the UID that did it.

---

## File-integrity sentinels (decoy honeypot)

A set of **decoy** files holding fake credentials that no legitimate
application should ever read or modify — a honeypot. Any access is a
high-signal compromise indicator (malware or an intruder enumerating
`$HOME` for secrets). Implemented in
[`~/.config/conky/integrity.py`](../config/conky/integrity.py), polled by
health.py's `file integrity` HEALTH row.

> **Deliberately neutral naming.** Nothing on the *live* system reveals
> this is a honeypot: the module, the conky label, the aliases, the audit
> key, the security-log entries, the state files, and the decoys' own
> contents all read as ordinary **file-integrity monitoring** (a normal
> control) plus real-looking credentials. An attacker grepping the box,
> listing `~/.config`, reading `~/.zshrc`, or `cat`-ing a decoy gets no
> hint it's bait. This README (in the repo, not deployed) is the only
> place the true intent is named — keep that in mind if you treat a repo
> checkout on the host as itself sensitive.

Three decoys are created on first run (manifest-driven — edit to
add/relocate):

| Path | Looks like | Why it's safe |
|---|---|---|
| `~/.aws/credentials.bak` | AWS keys | aws-cli reads `credentials`, never `.bak` |
| `~/.ssh/id_rsa_old` | an old SSH key | ssh only uses keys it's configured to |
| `~/Documents/passwords.txt` | a password dump | nothing daemon-reads it |

Each holds plausible-but-fake secrets with a unique token embedded **as a
credential value** (no give-away comment) — grep logs / network captures
for it to spot exfiltration. State files (all bland):
`~/.config/conky/.integrity-paths` (manifest),
`baseline-integrity.txt`, `~/.config/conky/.integrity-id` (the token).

### Detection — two layers (fast alert + process attribution)

- **Always-on (unprivileged):** the `file integrity` HEALTH row checks
  each file every cycle. It catches **modify** (sha256) and **delete**
  reliably, and **reads** via an atime trick — each cycle it parks the
  file's access-time at the epoch, so on a normal `relatime` mount any
  read bumps atime and is caught (the check reads its own copy with
  `O_NOATIME` so it never trips itself). A trip turns the row red and
  writes a `seclog` event (per-file, so a persistent *modified* state
  logs once while distinct *reads* each log).
- **Process attribution (the "who"):**
  - *Any mode, best-effort:* on a trip it scans `/proc/*/fd` for a process
    holding the file open **right then** (catches editors, `tail -f`, a
    backup pass, an mmap) and records it as `open_now` in the event.
  - *Hardened, authoritative:* `harden` adds an auditd watch
    (`-w <file> -p rwa -k integrity`, generated from the manifest). On a
    trip the check runs `sudo -n ausearch -k integrity -f <file>` (a
    read-only query, allow-listed via the `DOTFILES_AUDITQ` sudoers rule)
    and embeds the most recent **comm / pid / uid** as `audit` in the
    event — reliable even for a one-shot `cat` and even on `noatime`.

A one-shot read in *install* mode (no auditd) may log the actor as
`unknown` — that's expected; harden for guaranteed attribution.

### Triage & reset

```bash
fim                                       # list monitored files + state
sudo ausearch -k integrity --start recent # who touched it (hardened)
fim-reset                                 # regenerate + re-baseline
```

`fim-reset` overwrites the files — **investigate first** (it discards
whatever an attacker left).

> **False-positive note.** A desktop file indexer (KDE **baloo** on the
> Plasma box) reads files in indexed folders, so the first index pass of
> `~/Documents/passwords.txt` can register as a *read*. When hardened the
> `audit` actor in the event shows `baloo_file_extr` so you can tell it
> from a real intrusion; otherwise exclude that folder from KDE search,
> or relocate the entry in the manifest.

---

## Application install supply chain

Every third-party app the dotfiles install — 27 entries as of this
writing — rides a formal supply-chain layer. All entries live in a
single TOML manifest at [`config/apps/apps.toml`](../config/apps/apps.toml);
the CLI dispatcher ([`scripts/apps-cli.sh`](../scripts/apps-cli.sh))
filters by machine profile and shells out to one of four method
adapters under `scripts/install-methods/`. The Mullvad keyring
fingerprint pinning + starship / JetBrainsMono Nerd Font sha256 + GPG
checks documented above ("What's hardened out-of-the-box") are now the
**baseline**, not bespoke per-script logic: they're three entries in
that one manifest (`mullvad-vpn`, `starship`, `jetbrains-mono-nerd`),
verified by the same `scripts/verify-pins.sh` everything else uses.

The subsystem documentation lives at [`readme/apps.md`](apps.md) (trust
ordering, schema overview, lifecycle commands, per-machine overrides);
this section covers the security-relevant pieces — what the trust
pillars actually verify, what the exit codes mean, and how the
in-repo audit surface fits together.

### The three trust pillars

Different install methods carry different trust models. The dispatcher
matches each app to one of three:

1. **apt repo signing** — for `apt-pinned-repo` apps (currently Mullvad
   VPN). The keyring file under
   `config/system/etc/apt/keyrings/<name>-keyring.asc` is verified at
   install time against the 40-hex `key_fingerprint` pinned in the
   manifest; the matching DEB822 sources file under
   `config/system/etc/apt/sources.list.d/<name>.sources` carries
   `Signed-By:` pointing at that keyring. Apt's own Release-file
   signature verification covers everything downstream. The keyring
   fingerprint is the trust anchor; rotation is single-app, interactive,
   and routes through `scripts/refresh-keys.sh` with an append-only
   audit log at `~/.cache/dotfiles/key-rotations.log`.

2. **SHA-256 pinning** — for `github-release` and `direct-deb` apps
   (currently starship, JetBrains Mono Nerd Font). The manifest carries
   a 64-hex `sha256` (or `sha256_x86_64` / `sha256_aarch64` for
   multi-arch GitHub releases) that the adapter verifies after download
   and before install. A compromised CDN cannot ship a backdoored
   tarball without also bumping the hash — and the manifest is in git,
   so the hash bump is a reviewable diff. `sha256_aarch64 = ""` is the
   convention for "x86_64-only" (do not omit the key; `verify-pins.sh`
   checks for its presence).

3. **Optional GPG signature verification** — for `github-release` apps
   when the upstream maintainer signs release artifacts. Set in the
   manifest as a 40-hex `gpg_fingerprint`; the adapter imports the key
   into an ephemeral homedir, verifies the detached signature, and
   requires a `VALIDSIG` line from gpg (i.e. signed AND by the pinned
   key, not just "signed by anyone in the local ring"). An empty
   `gpg_fingerprint = ""` disables this layer for upstreams that don't
   sign — sha256 alone is then the only guard.

### Pin verification (`scripts/verify-pins.sh`)

A single read-only tool checks every pin: keyring fingerprint matches
the manifest, sha256 matches the on-disk artifact (when present), and
`last_refreshed + refresh_after_days` hasn't passed. The exit code is
the contract — cron and conky branch on it without parsing stdout:

| Exit | Meaning |
|---|---|
| `0` | every pin fresh AND verified (or no manifests on disk) |
| `1` | at least one pin is STALE (date drift only) |
| `2` | at least one pin failed VERIFICATION (sha / GPG / keyring mismatch — a security event) |
| `3` | `--app NAME` was given but no manifest matched (typo / missing file — distinct from 2) |

"Bad" dominates "stale" on purpose: a fingerprint mismatch should alert
even when half the manifests also happen to be stale. `--strict-fresh`
promotes stale → exit 2 for crons that want stale dates treated as
hard failures. The same exit codes feed `scripts/audit.sh`'s `pins`
pseudo-baseline row, `scripts/dotfiles-doctor.sh`'s new SUPPLY CHAIN
section (between DRIFT and SYSTEM), and the conky HEALTH overlay's
`supply chain` row (`check_pins()` in
[`~/.config/conky/health.py`](../config/conky/health.py): green = all
fresh, yellow = N stale, red = N failed, dim when the script is missing
/ timed out — see "Conky security monitoring" below).

### Periodic refresh, no auto-commit

`scripts/refresh-pins.sh` is cron-driven and rewrites the TOMLs in
place — `last_refreshed` always, plus version + sha256 on a
`github-release` tag bump. It **never** commits. A real upstream
version bump should land as a reviewed `git diff` (release notes,
breaking-changes scan); the script intentionally stops at the TOML edit
so the human reviewing the diff is the one taking the trust step. Key
rotations are even stricter — they require `scripts/refresh-keys.sh
--app NAME`, interactive by default (`--yes` exists but is for
out-of-band-verified rotations only), single-app at a time. There is
no `--all` for key rotation by design: batching rotations would let a
typo or an MITM on one slip through under cover of the other.

### Bundle integrity vs per-pin verification

The two layers are independent:

- `INSTALL_SKIP_BUNDLE_CHECK=1` still works for the offline-bundle path
  (`scripts/install-shell.sh --offline`). That escape hatch covers
  `bundle/manifest.sha256` and the optional `manifest.sha256.asc`
  signature — see "Bundle tamper-evidence" in the top-level README.
- There is deliberately **no** equivalent per-pin "skip" env var. The
  per-app sha256 / GPG / keyring checks are non-bypassable; if upstream
  rotates a key or sha, the manifest must be updated by hand (the
  dispatcher refuses on `verify-pins.sh` exit 2). The keyring rotation
  is gated through `scripts/refresh-keys.sh`'s interactive prompt; the
  sha bumps land via `scripts/refresh-pins.sh` followed by a manual
  `git commit`.

### Manifest layout

| File | Role |
|---|---|
| `config/apps/apps.toml` | Primary manifest — every `[[apps]]` entry the repo installs (schema_version 2, array-of-tables). |
| `config/apps/schema.toml` | Authoritative field-by-field schema. |
| `config/apps/schema.example.toml` | Worked example exercising every install method. |
| `config/apps/<name>/` | Per-app source files referenced by `[apps.configs]` (policies.json, settings.json, ini files, …). |
| `config/apps/.locks/<name>.lock` | Lockfile sidecar — what was actually installed (TOML, one file per app, mode 0700 dir). |
| `config/apps/README.md` | Dev guide — add/remove an app, install-method semantics, machine profiles, file map. |
| `config/system/etc/apt/keyrings/<name>-keyring.{asc,gpg}` | Tracked source-of-truth keyring (apt-pinned-repo only). |
| `config/system/etc/apt/sources.list.d/<name>.sources` | DEB822 sources with `${distro_codename}` placeholder + `Signed-By:` pointer. |
| `scripts/apps-cli.sh` | Top-level lifecycle dispatcher (validate/install/freeze/unfreeze/refresh/verify/remove). |
| `scripts/install-methods/<method>.sh` | One adapter per install method (`apt`, `apt-pinned-repo`, `github-release`, `direct-deb`). |

See [`readme/apps.md`](apps.md) for the subsystem reference and
[`config/apps/README.md`](../config/apps/README.md) for the dev guide
+ the table of "files to modify when…".

---

## Verifying a hardened install

After `./local_setup.sh harden`, sanity-check each layer:

```bash
# 1. Sudoers — should show DOTFILES_* aliases, NOT "(ALL : ALL) NOPASSWD: ALL"
#    APT alias should NOT contain `install *` or `upgrade *`
sudo -l

# 2. ufw — should be active, default deny, ssh allowed
sudo ufw status verbose

# 3. unattended-upgrades — should be enabled and active,
#    and the Origins-Pattern should be Debian-Security ONLY
systemctl is-enabled unattended-upgrades.service
systemctl is-active  unattended-upgrades.service
grep -A20 'Origins-Pattern' /etc/apt/apt.conf.d/50unattended-upgrades \
    | grep -E 'Debian-Security|stable|backports|proposed'
# expected: only the Debian-Security line uncommented

# 3b. auditd — rules loaded, expected keys present
sudo auditctl -l | grep -E '\-k (identity|sudoers|modules|mount)'
sudo ausearch -k identity --start today --raw | head    # smoke-test

# 4. DNS — Cloudflare + Quad9 listed, per-link "+DNSOverTLS"/"+DNSSEC"
#    on the default-route iface (WARN on "-DNSOverTLS" — captive
#    portal or upstream RST-downgrade, see "opportunistic" trade-off).
resolvectl status | grep -E "DNS Servers|Protocols"
ls -la /etc/resolv.conf       # -> /run/systemd/resolve/stub-resolv.conf

# 5. Mullvad keyring PRIMARY fingerprint AND primary count
#    (subkeys are filtered out — `--show-keys` lists fpr for both
#    `pub:` (primary) and `sub:` (subkey) records).
fps=$(gpg --show-keys --with-colons /etc/apt/keyrings/mullvad-keyring.asc \
        | awk -F: '/^pub:/ {p=1; next} /^sub:/ {p=0} /^fpr:/ && p {print $10; p=0}')
echo "$fps" | wc -l   # expected: 1
echo "$fps"           # expected: A1198702FC3E0A09A9AE5B75D5A1D4F266DE8DDF

# 6. WireGuard config perms
sudo find /etc/wireguard -type f -name '*.conf' -exec ls -la {} \;
# expected:  -rw------- 1 root root  ...

# 7. Zsh + other tool history perms
for f in ~/.zsh_history ~/.fzf_history ~/.python_history ~/.lesshst \
         ~/.sqlite_history ~/.mysql_history ~/.psql_history \
         ~/.gdb_history ~/.lua_history; do
    [ -f "$f" ] && stat -c '%a %n' "$f"
done
# expected:  600 <path> for every existing file

# 8. Conky state files in /run/user/$UID, NOT /tmp
ls -la "${XDG_RUNTIME_DIR:-$HOME/.cache}/conky/"
# expected:  -rw------- on every entry

# 9. SSH key auth in use (if VM_PASS unset)
ssh -o BatchMode=yes generic@<vm-host> true && echo "key auth OK"

# 10. Plugin tag pinning (no rolling-branch refs in init.lua)
grep -E '"branch"\s*=\s*"(master|0\.1\.x)"' ~/.config/nvim/init.lua \
    && echo "WARNING: still on rolling branches" \
    || echo "tags only — good"
```

---

## Reverting

`./local_setup.sh unharden` (or `python3 vm_automation.py unharden`)
flips every step back. Specifically:

- `/etc/sudoers.d/<user>` → broad NOPASSWD ALL.
- `ufw --force disable`.
- `/etc/apt/apt.conf.d/20auto-upgrades` → both periodicities to "0",
  `/etc/apt/apt.conf.d/51unattended-upgrades-mail` removed,
  `unattended-upgrades.service` disabled.
- `/etc/audit/rules.d/dotfiles.rules` removed and `augenrules --load`
  re-applied. Other entries under `rules.d/` are deliberately left in
  place — if you added rules of your own, `unharden` won't strip them.
- `/etc/systemd/resolved.conf.d/cyberpunk-dot.conf` and
  `/etc/NetworkManager/conf.d/cyberpunk-dns.conf` removed; the
  `/etc/resolv.conf → stub-resolv.conf` symlink dropped *before*
  `systemd-resolved` is disabled (no window of missing nameservers);
  NetworkManager reloaded so it owns `/etc/resolv.conf` again, with a
  fall-back `nmcli connection up <active>` nudge if NM didn't rewrite
  on reload alone. (`unharden_dot()` — replaces the older
  `unharden_dns` path that touched `dhcpcd.conf`.)

### The chicken-and-egg with unharden

There's a built-in friction by design: after `harden`, the narrow
`sudoers.d/<user>` allowlist *blocks `sudo bash …`*.  `unharden` runs
its first step (rewriting the sudoers file) via `sudo bash`, so it
can't run unattended once you've hardened. This is the correct
behaviour — narrow NOPASSWD wouldn't be much of a guard if the script
that narrowed it could trivially un-narrow itself.

The workflow:

```bash
# 1. Re-broaden the sudoers file via su (asks for the ROOT password).
#    su's PATH is minimal so we use absolute paths.
su -c "cat > /etc/sudoers.d/$(whoami) <<EOF
$(whoami) ALL=(ALL) NOPASSWD: ALL
EOF
chmod 0440 /etc/sudoers.d/$(whoami) && /usr/sbin/visudo -c -f /etc/sudoers.d/$(whoami)"

# 2. Now unharden can run normally.
./local_setup.sh unharden          # local
python3 vm_automation.py unharden  # remote
```

If you don't have / don't know the root password (typical on Debian
where `root` is locked by default), you'll need to boot into rescue
mode or use a recovery image. **Don't lose your sudoers file.**

Alternative: keep the broad sudoers in place during major
re-provisioning windows (run `unharden`, then `setup`, then `harden`
again), and only narrow once your installation has stabilised.

Use `unharden` when you need to re-run `setup` (broad sudo makes the
install pipeline frictionless) and re-`harden` afterwards.

---

## Bug-bounty-style reporting

If you find a security issue in the dotfiles themselves (sudoers
allowlist too permissive, command-injection in a polybar helper,
predictable temp-file path, etc.), open a private discussion / DM
rather than a public issue. The threat model here doesn't include
"adversaries who already have your dotfiles" — but a CVE-grade bug in
the install scripts can affect anyone running them.
