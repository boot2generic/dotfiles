# Microsoft VSCode profile (OPT-IN)

## Status

This entry ships **disabled by default** (`enabled = false` in
`config/apps/apps.toml`). The dotfiles primary editor is VSCodium —
this `code` entry exists because the user's actual workflow uses
Microsoft-marketplace-only extensions that VSCodium can't install from
Open VSX.

## To enable

1. Edit `config/apps/apps.toml`. Find the entry with `name = "code"`.
   Change `enabled = false` → `enabled = true`.
2. `./scripts/apps-cli.sh install --app code`

After that, `apps install` will pick it up on subsequent runs.

## Telemetry posture

Microsoft VSCode is proprietary and telemeters by default. The shipped
`settings.json` sets:

- `telemetry.telemetryLevel: "off"`
- `telemetry.enableCrashReporter: false`
- `telemetry.enableTelemetry: false`
- `redhat.telemetry.enabled: false`

These cover the documented opt-out channels. There may be residual
network traffic from extensions or the auto-update probe (which is
also disabled via `update.mode: "none"`). If a stronger guarantee is
required, run VSCode under firejail or strace it once and inspect
outbound connections.

The binary is signed via the Microsoft Release signing key
(`BC528686B50D79E339D3721CEB3E94ADBE1229CF`); the dotfiles pin that
fingerprint in `apps.toml`.

## Extensions

`extensions.txt` is the full extension set extracted from the user's
existing MS VSCode install (`code --list-extensions`) on 2026-05-24.
24 extensions across:

- Python tooling (5): debugpy, isort, python, pylance, python-envs
- Jupyter (5)
- Remote dev (4): containers, ssh, ssh-edit, remote-explorer
- C/C++ (2)
- GitHub workflow (2): copilot-chat, vscode-github-actions
- Linting (2): ruff, markdownlint
- YAML
- Themes (3): dracula, material-icon-theme, vscode-icons

## Coexistence with VSCodium

Both can be installed simultaneously. They use separate config dirs:

- VSCodium: `~/.config/VSCodium/User/`
- MS VSCode: `~/.config/Code/User/`

Settings/extensions are independent. The dotfiles ship the same
`settings.json` content to both (different deploy destinations).
