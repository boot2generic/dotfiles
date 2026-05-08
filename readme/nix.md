# Nix package manager (alongside apt)

`local_setup.sh setup` installs the Nix package manager in **multi-user
(daemon) mode** alongside apt. The model: apt is the system package
manager (drivers, services, system tools); Nix is for **per-project
reproducible dev shells** via flakes + direnv.

Skip the install with `./local_setup.sh setup --no-nix` if you don't
want Nix.

---

## What you get

| Capability | Command |
|---|---|
| One-off tool, no install | `nix run nixpkgs#cowsay -- "hello"` |
| Drop into a subshell with tools temporarily | `nix shell nixpkgs#yt-dlp nixpkgs#ffmpeg-full` |
| Per-project pinned dev environment | `nix develop` (auto via direnv when `.envrc` says `use flake`) |
| Permanently install a user tool | `nix profile install nixpkgs#yt-dlp` (sparingly — see below) |

---

## The default workflow: flakes + direnv

Each project gets a `flake.nix` (defines tooling) and an `.envrc`
containing `use flake`. After `direnv allow` once, **`cd` into the
project auto-loads its dev shell** and `cd` out tears it down. No
manual activation, no global state.

Starter flakes live in [`<repo>/templates/`](../templates/):

- `python/` — Python 3.12 + uv + ruff
- `python-cuda/` — Python 3.11 + PyTorch (CUDA) + numpy/scipy/jupyter — for ML/LLM research
- `node/` — Node.js 20 + pnpm + TypeScript
- `rust/` — Rust stable (rustc, cargo, rust-analyzer, clippy)

```bash
# Start a Python ML project:
mkdir my-experiment && cd my-experiment
cp -r ~/dotfiles/templates/python-cuda/. .
direnv allow              # one-time, this dir
# cd back in to trigger:
cd .
which python              # /nix/store/...-python.../bin/python
python -c 'import torch; print(torch.cuda.is_available())'
```

When the project's needs change, edit `flake.nix` and `direnv reload`.
`flake.lock` gets created on first build and pins every input down to
a git SHA — commit it.

---

## When to reach for `nix profile install`

Use `nix profile install nixpkgs#FOO` only when:

1. The tool isn't in apt at all (e.g., `eza`).
2. apt's version is meaningfully outdated (e.g., `yt-dlp` — YouTube
   API changes break apt's version every few months).

Otherwise, leave it on apt. Reaching for `nix profile install` on a
tool that's already in apt creates "which `git` is this?" PATH
confusion. The point of the apt-default + Nix-opt-in model is to
keep that confusion at zero.

To inspect what's permanently installed via Nix:

```bash
nix profile list                          # what's installed
nix profile remove <name>                 # uninstall
```

---

## CUDA from cache (skip multi-hour builds)

The first time you `nix develop` into the `python-cuda` template, CUDA
might rebuild from source if the binary cache is missing. To use the
community-maintained CUDA cache instead, add this **system-wide** (one
time, requires root):

```bash
sudo tee -a /etc/nix/nix.conf > /dev/null <<'EOF'

# CUDA prebuilt-binary cache (community-maintained).  Keys verified
# at https://app.cachix.org/cache/cuda-maintainers.
extra-substituters = https://cuda-maintainers.cachix.org
extra-trusted-public-keys = cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E=
EOF

sudo systemctl restart nix-daemon
```

After that, the CUDA toolkit pulls as a binary (~minutes, not hours).

---

## Disk hygiene

Nix's content-addressed `/nix/store` grows over time as projects pull
in different versions of things. Old generations stay around so you
can roll back; reclaim them periodically:

```bash
# Drop store paths older than 30 days (safe — only orphaned ones go).
nix-collect-garbage --delete-older-than 30d

# More aggressive: drop everything not currently referenced.
nix-collect-garbage -d
```

Set a monthly reminder. On a workstation with several CUDA flakes,
this can reclaim 20–50 GB.

---

## Uninstalling Nix entirely

If you change your mind, the official installer has an uninstall
mode (Determinate Systems' installer is even cleaner). Your project
flakes remain readable as documentation of what tools the project
needed; they're not bound to any particular machine's Nix install.

```bash
# Multi-user uninstall on Debian:
sudo systemctl stop nix-daemon.socket nix-daemon.service
sudo systemctl disable nix-daemon.socket nix-daemon.service
sudo rm -rf /etc/nix /nix /var/root/.nix-* /var/root/.cache/nix
sudo userdel -r nixbld1 ... nixbld32 2>/dev/null   # 32 build users
sudo groupdel nixbld
# Remove the profile.d hook + any user-level state:
sudo rm /etc/profile.d/nix.sh
rm -rf ~/.nix-* ~/.cache/nix ~/.config/nix
```

After this, `apt` is the only PM again. `~/.config/direnv/direnvrc`
will silently fail to source the now-missing `nix-direnv` direnvrc —
remove that line if it bothers you.

---

## When Nix doesn't help

- **System packages** (drivers, kernel, services): apt.
- **GUI desktop apps** (firefox-esr, OBS, Discord): apt or Flatpak.
- **Tools that bundle prebuilt binaries assuming FHS** (DaVinci
  Resolve, some game launchers): apt or run them via `nix-ld` /
  `steam-run` if you really must.

Nix is for the development side of your workflow. The desktop side
stays on Debian.
