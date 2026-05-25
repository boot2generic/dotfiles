# VSCodium profile

## Source

`settings.json` was extracted from this machine's installed Microsoft
VSCode (`~/.config/Code/User/settings.json`, 3 user preferences) and
augmented with a privacy-hardening block:

- `telemetry.telemetryLevel: "off"` + `enableCrashReporter: false` +
  `enableTelemetry: false` (also `redhat.telemetry.enabled: false`)
- `update.mode: "none"` + `extensions.autoUpdate: false` (apt manages)
- `workbench.enableExperiments: false`,
  `enableNaturalLanguageSearch: false`,
  `walkthroughs.openOnInstall: false`,
  `startupEditor: "none"`
- `security.workspace.trust.banner: "never"`,
  `startupPrompt: "never"`
- `git.autofetch: false`,
  `openRepositoryInParentFolders: "never"`

The user's three original prefs (`hidden` secondary side bar, Dracula
theme, vscode-icons) are preserved verbatim.

## Extensions

`extensions.txt` is the **Open VSX Registry-available subset** of the
user's MS VSCode extension list (24 → 7).  Microsoft-only extensions
(`ms-python.*`, `ms-toolsai.*`, `ms-vscode-remote.*`, `ms-vscode.*`,
`github.copilot-chat`) are NOT published to Open VSX by Microsoft and
intentionally omitted.

| Extension | Open VSX | MS marketplace |
|---|---|---|
| `charliermarsh.ruff` | ✓ | ✓ |
| `davidanson.vscode-markdownlint` | ✓ | ✓ |
| `dracula-theme.theme-dracula` | ✓ | ✓ |
| `github.vscode-github-actions` | ✓ | ✓ |
| `pkief.material-icon-theme` | ✓ | ✓ |
| `redhat.vscode-yaml` | ✓ | ✓ |
| `vscode-icons-team.vscode-icons` | ✓ | ✓ |
| `github.copilot-chat` | ✗ | ✓ (proprietary) |
| `ms-python.*` (5) | ✗ | ✓ (MS-licensed) |
| `ms-toolsai.*` (5) | ✗ | ✓ (MS-licensed) |
| `ms-vscode-remote.*` (3) | ✗ | ✓ (MS-licensed) |
| `ms-vscode.*` (3) | ✗ | ✓ (MS-licensed) |

## If you need the MS-only extensions

You have three options:

1. **Install MS VSCode alongside VSCodium**. The `code` entry in
   `apps.toml` ships disabled — flip `enabled = true` and re-run apps
   install. MS VSCode comes from `packages.microsoft.com` (signed apt
   repo). Same Electron app, MS-licensed marketplace, MS telemetry by
   default (the dotfiles still apply the no-telemetry settings.json).

2. **Use a community fork** of the MS-licensed extension where one
   exists. For example, Python tooling has `pyright-extended` and the
   `Pylyzer` extension on Open VSX. Coverage is partial.

3. **Use a local extension file**. Download the `.vsix` from the
   MS marketplace and `codium --install-extension <file>.vsix`. This
   accepts the EULA implicitly — read it first.

## Override (per-machine)

Drop a `~/.config/dotfiles-local/apps/vscodium/extensions.txt` to
extend or replace the shipped list. Mode `0644`, one extension per
line, `#` for comments.
