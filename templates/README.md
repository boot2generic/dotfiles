# Nix flake starter templates

Copy any of these into a new project, run `direnv allow` once, and `cd`
into the directory will auto-activate a Nix dev shell with the listed
tooling. **No global state** — leave the directory and the tools are
gone from your PATH.

| Template | Stack | When |
|---|---|---|
| [`python/`](python/)             | Python 3.12 + uv + venv tooling                         | scripts, web apps, anything Python |
| [`python-cuda/`](python-cuda/)   | Python 3.11 + PyTorch (CUDA) + numpy + cudaPackages     | ML research, LLM inference, training |
| [`node/`](node/)                 | Node.js 20 + pnpm + TypeScript                          | TS/JS web work |
| [`rust/`](rust/)                 | Rust stable (rustc, cargo, rust-analyzer, clippy)       | systems / CLI / games |

## How to use one

```bash
# Once per project: copy the template into the project root.
cp -r ~/dotfiles/templates/python/. /path/to/your-project/
cd /path/to/your-project

# Once per project: tell direnv it's OK to load this .envrc.
direnv allow

# That's it.  cd in → tools available; cd out → tools gone.
which python                      # /nix/store/...-python.../bin/python
python -c 'import sys; print(sys.version)'
```

## Editing a flake

To pin a different Python version, swap the package name in `flake.nix`:

```nix
# python 3.12 → python 3.13
packages = with pkgs; [ python313 python313Packages.uv ];
```

The first time you change the flake, direnv will re-evaluate (slower).
After that, `flake.lock` caches the resolution; `cd` in is fast.

## Updating pinned versions

```bash
cd your-project
nix flake update          # pulls newest nixpkgs revision
direnv reload             # rebuild the shell with new versions
```

## Nuking a project's nix state

```bash
direnv revoke             # stop auto-loading
rm flake.lock .envrc      # remove pin + hook
# `flake.nix` itself is documentation; you can keep or delete it.
```

The on-disk `/nix/store` paths the project pulled in stay until the
next `nix-collect-garbage --delete-older-than 30d` runs (or use
`--delete-old`).

## Why the `legacyPackages` thing in some flakes

`nixpkgs.legacyPackages.${system}` is the standard recommended pattern
for accessing nixpkgs from a flake — the name is unfortunate but it's
not deprecated.  See nixpkgs docs.

## Where flakes shine

- **Per-paper reproducibility** — pin nixpkgs to a specific git SHA;
  three years from now `nix develop` rebuilds the same env.
- **Different Python/CUDA/Node versions per project** — no `pyenv`,
  no `nvm`, no `rustup override`.
- **Onboarding** — new collaborator clones repo, runs `direnv allow`,
  has the exact dev env in seconds.

## Where flakes don't help

- **System packages** — drivers, services, system fonts, etc. stay on apt.
- **GUI desktop apps** — install via apt (`firefox-esr`, `obs-studio`).
- **Tools you want everywhere always** — leave on apt unless apt is
  badly stale (e.g., `yt-dlp`).
