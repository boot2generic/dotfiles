# scripts/lib/setup-report.sh
#
# Sourced bash library — do NOT execute directly.  Accumulates a
# human-readable end-of-setup summary in memory, then renders it at
# the end of `local_setup.sh` (or any caller that calls report_render).
#
# Functions:
#     report_init
#     report_apps_installed   NAME TIER
#     report_service_enabled  NAME SCOPE      # SCOPE = system | user
#     report_xdg_default      MIME APP
#     report_needs_action     MSG
#     report_render
#
# The "NEEDS YOUR HAND" section is hardcoded with the manual-identity
# checklist (SSH key, git identity, GPG key, VPN account login, mail
# account setup, Signal phone link, Syncthing pairing, KeePassXC
# database) plus anything caller added via report_needs_action.
# Colour is applied only when stdout is a TTY.
#
# A plain-text copy of the report is also saved to
#     ~/.config/dotfiles-state/last-setup-report.txt
# so the user can re-read it after the terminal scrolls away.

# ── In-memory state ────────────────────────────────────────────────
# Bash arrays — declared up front so `set -u` doesn't trip on first
# access from a fresh sourcing.  report_init resets them.
REPORT_APPS_INSTALLED=()
REPORT_SERVICES_ENABLED=()
REPORT_XDG_DEFAULTS=()
REPORT_NEEDS_ACTION=()

# Default save path; callers may override before report_render runs.
REPORT_SAVE_PATH="${REPORT_SAVE_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles-state/last-setup-report.txt}"

# ── Tiny logger (stderr; lib-local) ────────────────────────────────
_report_warn() { printf '[setup-report] WARN: %s\n' "$*" >&2; }

# ── Public: clear state ────────────────────────────────────────────
report_init() {
  REPORT_APPS_INSTALLED=()
  REPORT_SERVICES_ENABLED=()
  REPORT_XDG_DEFAULTS=()
  REPORT_NEEDS_ACTION=()
}

# ── Public: record an installed app (NAME, TIER) ───────────────────
# TIER is free-form (e.g. "1", "core", "optional") — preserved as
# given so callers can adopt their own taxonomy.
report_apps_installed() {
  local name="${1:-}" tier="${2:-}"
  if [[ -z "$name" ]]; then
    _report_warn "report_apps_installed: NAME required"
    return 1
  fi
  REPORT_APPS_INSTALLED+=("${name}|${tier}")
}

# ── Public: record an enabled service (NAME, SCOPE) ────────────────
# SCOPE = "system" | "user" (no validation — caller's responsibility).
report_service_enabled() {
  local name="${1:-}" scope="${2:-}"
  if [[ -z "$name" ]]; then
    _report_warn "report_service_enabled: NAME required"
    return 1
  fi
  REPORT_SERVICES_ENABLED+=("${name}|${scope}")
}

# ── Public: record an xdg-mime default mapping ─────────────────────
report_xdg_default() {
  local mime="${1:-}" app="${2:-}"
  if [[ -z "$mime" || -z "$app" ]]; then
    _report_warn "report_xdg_default: MIME and APP required"
    return 1
  fi
  REPORT_XDG_DEFAULTS+=("${mime}|${app}")
}

# ── Public: add a free-form action item ────────────────────────────
report_needs_action() {
  local msg="$*"
  if [[ -z "$msg" ]]; then
    _report_warn "report_needs_action: MSG required"
    return 1
  fi
  REPORT_NEEDS_ACTION+=("$msg")
}

# ── Internal: hardcoded manual-identity checklist ─────────────────
# Kept in one place so the order is stable across renders.  Lines are
# emitted verbatim — caller's "needs_action" additions appear after.
_report_manual_checklist() {
  cat <<'EOF'
[ ] SSH keys           ssh-keygen -t ed25519 -C "<your-comment>"
[ ] git identity       git config --global user.name "..."; git config --global user.email "..."
[ ] GPG key            gpg --full-generate-key   (if you use one)
[ ] Mullvad VPN        mullvad account login    (account number prompt)
[ ] Thunderbird        configure mail account on first launch
[ ] Signal Desktop     link your phone on first launch
[ ] Syncthing          accept device pairing in web UI (http://localhost:8384)
[ ] KeePassXC          create or open your password database
EOF
}

# ── Internal: section header ──────────────────────────────────────
# When colour="1", wraps the title in dim/bold-ish ANSI; otherwise
# emits plain text.  Lines are pre-padded to 60 chars for the rule.
_report_header() {
  local title="$1" colour="$2"
  local rule
  rule="$(printf '%.0s=' {1..60})"
  if (( colour )); then
    printf '\n\033[1m%s\033[0m\n%s\n' "$title" "$rule"
  else
    printf '\n%s\n%s\n' "$title" "$rule"
  fi
}

# ── Public: render the full report ────────────────────────────────
# Writes to stdout AND to REPORT_SAVE_PATH (plain, no colour).
# Returns 0 even when the save fails — render is the load-bearing
# side; persistence is nice-to-have.
report_render() {
  # TTY detection — colour only when stdout is a terminal.  Mirrors
  # the local_setup.sh / install-common.sh convention.
  local colour=0
  [[ -t 1 ]] && colour=1

  # Build the full report into a variable so we can emit identical
  # bytes to stdout and to the save file (with colour stripped).
  local body=""
  local line item name tier scope mime app

  body+="$(_report_header "DOTFILES SETUP — RUN SUMMARY" "$colour")"$'\n'

  # ── Apps installed ──────────────────────────────────────────────
  body+="$(_report_header "Apps installed" "$colour")"$'\n'
  if (( ${#REPORT_APPS_INSTALLED[@]} == 0 )); then
    body+="  (none)"$'\n'
  else
    for item in "${REPORT_APPS_INSTALLED[@]}"; do
      name="${item%%|*}"
      tier="${item#*|}"
      if [[ -n "$tier" ]]; then
        body+="$(printf '  - %-30s tier=%s' "$name" "$tier")"$'\n'
      else
        body+="$(printf '  - %s' "$name")"$'\n'
      fi
    done
  fi

  # ── Services enabled ────────────────────────────────────────────
  body+="$(_report_header "Services enabled" "$colour")"$'\n'
  if (( ${#REPORT_SERVICES_ENABLED[@]} == 0 )); then
    body+="  (none)"$'\n'
  else
    for item in "${REPORT_SERVICES_ENABLED[@]}"; do
      name="${item%%|*}"
      scope="${item#*|}"
      if [[ -n "$scope" ]]; then
        body+="$(printf '  - %-30s scope=%s' "$name" "$scope")"$'\n'
      else
        body+="$(printf '  - %s' "$name")"$'\n'
      fi
    done
  fi

  # ── XDG defaults ────────────────────────────────────────────────
  body+="$(_report_header "XDG defaults" "$colour")"$'\n'
  if (( ${#REPORT_XDG_DEFAULTS[@]} == 0 )); then
    body+="  (none)"$'\n'
  else
    for item in "${REPORT_XDG_DEFAULTS[@]}"; do
      mime="${item%%|*}"
      app="${item#*|}"
      body+="$(printf '  - %-40s -> %s' "$mime" "$app")"$'\n'
    done
  fi

  # ── NEEDS YOUR HAND ─────────────────────────────────────────────
  body+="$(_report_header "NEEDS YOUR HAND" "$colour")"$'\n'
  while IFS= read -r line; do
    body+="  $line"$'\n'
  done < <(_report_manual_checklist)
  if (( ${#REPORT_NEEDS_ACTION[@]} > 0 )); then
    for item in "${REPORT_NEEDS_ACTION[@]}"; do
      body+="  [ ] $item"$'\n'
    done
  fi

  body+=$'\n'

  # Emit to stdout.
  printf '%s' "$body"

  # Persist a plain-text copy (no colour).  Strip ANSI escapes with a
  # small Python helper — `sed` would also work but Python is already
  # a hard dep elsewhere in the dotfiles, and avoids the BSD/GNU sed
  # regex split.
  local save_dir
  save_dir="$(dirname "$REPORT_SAVE_PATH")"
  if ! mkdir -p "$save_dir" 2>/dev/null; then
    _report_warn "could not create $save_dir — skipping report save"
    return 0
  fi
  if ! printf '%s' "$body" \
       | python3 -c 'import re,sys; sys.stdout.write(re.sub(r"\x1b\[[0-9;]*m","",sys.stdin.read()))' \
       >"$REPORT_SAVE_PATH" 2>/dev/null; then
    _report_warn "could not write $REPORT_SAVE_PATH"
    return 0
  fi
}
