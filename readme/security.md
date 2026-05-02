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
- Disk encryption is configured at OS install time (out of scope here).
- Multi-user shared boxes and servers are **not** the target — some
  defaults (broad sudo NOPASSWD during install) would be wrong there.

**Not in scope:**
- Hardening the kernel or systemd unit defaults.
- Container/sandbox isolation (Firejail, bubblewrap, etc.).
- USB device control / Yubikey enforcement.
- Browser fingerprint resistance.

---

## Hardening modes

The dotfiles have **two distinct security postures**:

| Mode      | When                          | sudo policy        | firewall | DNS        | auto-updates |
|-----------|-------------------------------|--------------------|----------|------------|--------------|
| Install   | While running `setup`         | NOPASSWD ALL       | none     | dhcpcd     | off          |
| Hardened  | After `./local_setup.sh harden` | Narrow Cmnd_Alias | ufw deny | Quad9 DoT | enabled      |

`setup` deliberately uses the permissive *install* mode so the
provisioning pipeline doesn't prompt for a password every five seconds.
You're meant to flip to *hardened* mode the first time everything works:

```bash
./local_setup.sh setup            # install (interactive)
./local_setup.sh harden           # tighten — once
```

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
- **No hardcoded password.** `vmPass@124` was removed from the source.
  The script tries SSH key auth first; only if `ssh -o BatchMode=yes …`
  fails does it fall back to `sshpass -e` reading from `$VM_PASS`.
- **No `sshpass -p`.** The `-p <password>` form leaks credentials into
  every running process's argv (`ps -ef`). We use `sshpass -e` (env-var
  mode) so the password lives only in the subprocess env block.
- **Pexpect logging is force-disabled.** `child.logfile = None` runs
  after every `_spawn_ssh()` so an accidental hook can't capture the
  bootstrap-time `su` password to disk.

To eliminate `$VM_PASS` entirely:
```bash
ssh-copy-id generic@172.22.220.59      # one-time
unset VM_PASS                          # done
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

### Apt-source modifications back themselves up
`enable_nonfree_repos` (called automatically when `--nvidia` is set)
copies each modified file to `<path>.bak.YYYYMMDD-HHMMSS` (mode 0600)
*before* the in-place edit. If `apt update` breaks afterwards,
`mv …bak.* path` is the rollback.

Backups older than 30 days are auto-pruned at the start of each
`enable_nonfree_repos` invocation — apt only reads `*.list` and
`*.sources` files so the stale `.bak.YYYY*` entries are inert, but
they accumulate without limit otherwise.

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

### 3. unattended-upgrades
- Installs `unattended-upgrades` + `apt-listchanges`.
- Drops `/etc/apt/apt.conf.d/20auto-upgrades` enabling the daily timer
  for `Debian-Security` packages only — feature releases still need
  manual `apt upgrade`.

### 4. systemd-resolved + Quad9 DoT
- Configures `/etc/systemd/resolved.conf.d/dnsovertls.conf` with:
  - **Primary:** Quad9 (`9.9.9.9`, `149.112.112.112`) over DNS-over-TLS,
    DNSSEC enforcement (`allow-downgrade`).
  - **Fallback:** Cloudflare (`1.1.1.1`).
- Symlinks `/etc/resolv.conf → /run/systemd/resolve/stub-resolv.conf`.
- Adds `nohook resolv.conf` to `dhcpcd.conf` so dhcpcd doesn't fight
  resolved on each lease renewal.

Why Quad9? Threat-blocks known-malicious domains, no commercial logging
in EU operations, supports DoT + DNSSEC. Swap to a different provider
by editing the `DNS=` line.

`unharden` reverses **all four** changes — sudoers back to broad
NOPASSWD, ufw disabled, unattended-upgrades off, DNS back to dhcpcd.

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
The dotfiles bind `Mod+b` to `firefox-esr` (Debian's Firefox). For privacy:
- Install [arkenfox-user.js](https://github.com/arkenfox/user.js/) into
  the profile dir. Disables telemetry, sets sane defaults, kills
  fingerprinting vectors.
- Or replace Firefox with [Mullvad Browser](https://mullvad.net/en/browser)
  — same engine, hardened, pairs with the Mullvad VPN you already
  installed. Just edit the i3 binding:
  `bindsym $mod+b exec mullvad-browser`.

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
The harden phase enables auto-security-updates but doesn't enable
auditd. If you want a forensic record of `sudo` invocations:
```bash
sudo apt install auditd
sudo auditctl -w /etc/sudoers -p wa -k sudoers
sudo auditctl -w /var/log/auth.log -p wa -k sudo-auth
```

### USB / device control
Out of scope. If you handle sensitive data, look at
[`usbguard`](https://github.com/USBGuard/usbguard).

---

## Verifying a hardened install

After `./local_setup.sh harden`, sanity-check each layer:

```bash
# 1. Sudoers — should show DOTFILES_* aliases, NOT "(ALL : ALL) NOPASSWD: ALL"
#    APT alias should NOT contain `install *` or `upgrade *`
sudo -l

# 2. ufw — should be active, default deny, ssh allowed
sudo ufw status verbose

# 3. unattended-upgrades — should be enabled and active
systemctl is-enabled unattended-upgrades.service
systemctl is-active  unattended-upgrades.service

# 4. DNS — should show Quad9, "+DNSOverTLS", "+DNSSEC"
resolvectl status | grep -E "DNS Servers|Protocols"

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
  `unattended-upgrades.service` disabled.
- `/etc/systemd/resolved.conf.d/dnsovertls.conf` removed; dhcpcd's
  `static domain_name_servers=1.1.1.1 8.8.8.8` line restored.

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
