#!/usr/bin/env bash
# scripts/vpn-exclude.sh
#
# Manage the set of applications that should bypass the Mullvad VPN
# tunnel via split-tunneling, with a one-file list + a shim-dir
# mechanism that's transparent at the shell.
#
# How it works:
#   1. List file (one app name per line) lives at:
#        config/vpn/exclude.list                           (repo default)
#        ~/.config/dotfiles-local/vpn-exclude.list         (per-machine)
#      The per-machine file, if present, REPLACES the repo default.
#   2. `apply` reads the list, resolves each name via `command -v`,
#      and writes a wrapper at ~/.local/bin/vpn-excluded/<name>:
#        #!/usr/bin/env bash
#        exec /usr/bin/mullvad-exclude "<real-binary>" "$@"
#   3. ~/.zshrc prepends ~/.local/bin/vpn-excluded/ to PATH, so the
#      shim is what's invoked when you type the app name.
#   4. Orphaned shims (apps removed from the list) are deleted on
#      every `apply`.
#
# Usage:
#     scripts/vpn-exclude.sh add <app>     — add to active list + apply
#     scripts/vpn-exclude.sh remove <app>  — drop from active list + apply
#     scripts/vpn-exclude.sh list          — effective set + shim status
#     scripts/vpn-exclude.sh apply         — regenerate shims (idempotent)
#     scripts/vpn-exclude.sh status        — mullvad daemon + shim dir health
#     scripts/vpn-exclude.sh --help
#
# Exit codes:
#     0  success
#     1  user error (bad name, app not found, etc.)
#     2  internal error (missing mullvad-exclude binary, etc.)

set -euo pipefail

# ============================================================
# Bootstrap — locate the repo, set up the helpers
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_LIST="${REPO_DIR}/config/vpn/exclude.list"
LOCAL_LIST="${HOME}/.config/dotfiles-local/vpn-exclude.list"
SHIM_DIR="${HOME}/.local/bin/vpn-excluded"
MULLVAD_EXCLUDE="/usr/bin/mullvad-exclude"

# Colourless [tag] logging — keeps output greppable + matches the rest
# of the scripts/ family.
log()  { printf '[vpn-exclude] %s\n' "$*" >&2; }
ok()   { printf '[vpn-exclude] OK %s\n' "$*" >&2; }
warn() { printf '[vpn-exclude] WARN %s\n' "$*" >&2; }
err()  { printf '[vpn-exclude] ERROR %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

print_help() {
  # Pull the leading block of '# …' comments after the shebang — same
  # docstring-extraction pattern as install-apps.sh + apps-cli.sh.
  sed -n '2,/^$/p' "$0"
}

# ============================================================
# Helpers
# ============================================================

# Which list file is active?  Per-machine wins if present (mirrors the
# dotfiles-local override pattern).  Echoes the path on stdout.
active_list() {
  if [[ -f "$LOCAL_LIST" ]]; then
    printf '%s\n' "$LOCAL_LIST"
  else
    printf '%s\n' "$DEFAULT_LIST"
  fi
}

# Validate an app name — same character class apps-validate.py enforces
# on manifest names, plus underscore (some binaries have one).  Stops
# shell metacharacters from sneaking through `add` into the shim.
NAME_RE='^[A-Za-z0-9._-]+$'
sane_name() {
  local n="$1"
  [[ -n "$n" ]] || return 1
  (( ${#n} <= 64 )) || return 1
  [[ "$n" =~ $NAME_RE ]] || return 1
  # Reject leading dot — a "hidden" shim is confusing; if the binary
  # name is legitimately `.something`, the shim approach breaks anyway.
  [[ "${n:0:1}" != "." ]] || return 1
  return 0
}

# Read a list file → emit one trimmed, non-empty, non-comment name per line.
# Sorts the output so two runs against the same input always produce
# the same shim set + order.
read_list() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  awk '
    {
      sub(/^[[:space:]]+/, "");
      sub(/[[:space:]]+$/, "");
      if ($0 == "" || $0 ~ /^#/) next;
      print
    }
  ' "$f" | sort -u
}

# Effective set of apps to exclude.  Just the active list right now;
# the function exists so future logic (intersections, host-filters)
# can layer in without changing call sites.
effective_set() {
  read_list "$(active_list)"
}

# Resolve a binary name to its current path.  Echoes the absolute path
# on stdout, or empty if not found.  We deliberately exclude $SHIM_DIR
# from PATH during the lookup so we don't recurse into our own shim.
resolve_binary() {
  local name="$1"
  local saved_path="$PATH"
  # Strip the shim dir from PATH for this lookup so `command -v` finds
  # the underlying real binary, not a previous shim.
  local clean_path
  clean_path="$(printf '%s\n' "$saved_path" | tr ':' '\n' \
    | grep -vFx "$SHIM_DIR" | tr '\n' ':' | sed 's/:$//')"
  PATH="$clean_path" command -v "$name" 2>/dev/null
}

# ============================================================
# Subcommand: list
# ============================================================
cmd_list() {
  local active
  active="$(active_list)"
  log "active list: $active"

  local apps
  apps="$(effective_set)"
  if [[ -z "$apps" ]]; then
    log "(empty — no apps configured for VPN exclusion)"
    return 0
  fi

  # Header + per-app status (FOUND/MISSING + shim ACTIVE/ABSENT).
  printf '%-24s %-40s %s\n' "APP" "REAL BINARY" "SHIM"
  printf '%-24s %-40s %s\n' "---" "-----------" "----"
  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    local bin="$(resolve_binary "$app")"
    local shim="${SHIM_DIR}/${app}"
    local bin_label="${bin:-(not on PATH)}"
    local shim_label
    if [[ -x "$shim" ]]; then
      shim_label="active"
    else
      shim_label="absent (run \`apply\`)"
    fi
    printf '%-24s %-40s %s\n' "$app" "$bin_label" "$shim_label"
  done <<<"$apps"
}

# ============================================================
# Subcommand: status
# ============================================================
cmd_status() {
  log "shim dir:           $SHIM_DIR"
  if [[ -d "$SHIM_DIR" ]]; then
    local n
    n="$(find "$SHIM_DIR" -maxdepth 1 -type f -executable 2>/dev/null | wc -l)"
    log "shims present:      $n"
  else
    log "shims present:      0 (dir does not exist)"
  fi

  log "mullvad-exclude:    $MULLVAD_EXCLUDE $([[ -x $MULLVAD_EXCLUDE ]] && echo '(found)' || echo '(MISSING — install mullvad-vpn)')"

  if command -v mullvad >/dev/null 2>&1; then
    local tun_state
    tun_state="$(mullvad status 2>/dev/null | head -1)"
    log "mullvad status:     ${tun_state:-(daemon not responding)}"
  else
    log "mullvad CLI:        (not installed)"
  fi

  # PATH sanity — is the shim dir actually in front of /usr/bin?
  local first
  first="$(printf '%s\n' "$PATH" | tr ':' '\n' | head -1)"
  if [[ "$first" == "$SHIM_DIR" ]] || printf '%s\n' "$PATH" | tr ':' '\n' \
        | awk -v dir="$SHIM_DIR" -v target="/usr/bin" '
            $0==dir   {seen_dir=NR}
            $0==target{seen_bin=NR}
            END {exit !(seen_dir && (!seen_bin || seen_dir<seen_bin))}
          '; then
    log "PATH precedence:    shim dir precedes /usr/bin"
  else
    warn "PATH precedence:    shim dir NOT before /usr/bin in current shell"
    warn "  → restart your shell after the next \`apply\`, or re-source ~/.zshrc"
  fi
}

# ============================================================
# Subcommand: add
# ============================================================
cmd_add() {
  local name="${1:-}"
  sane_name "$name" || die "add: invalid name '$name' (need ${NAME_RE}, ≤64 chars, no leading dot)"

  # Where to write — if the per-machine file exists, edit that.
  # Otherwise CREATE the per-machine file from the repo default
  # (preserving comments) so the next add lands there.
  if [[ ! -f "$LOCAL_LIST" ]]; then
    mkdir -p "$(dirname "$LOCAL_LIST")"
    if [[ -f "$DEFAULT_LIST" ]]; then
      cp "$DEFAULT_LIST" "$LOCAL_LIST"
      log "seeded per-machine list from repo default: $LOCAL_LIST"
    else
      printf '# vpn-exclude per-machine list (created by add)\n' > "$LOCAL_LIST"
    fi
  fi

  # Idempotent: skip the append if the name is already in the file
  # (uncommented).  awk is honest about ignoring whitespace + comments.
  if read_list "$LOCAL_LIST" | grep -Fxq "$name"; then
    log "$name already in $LOCAL_LIST"
  else
    printf '%s\n' "$name" >> "$LOCAL_LIST"
    ok "added $name → $LOCAL_LIST"
  fi
  cmd_apply
}

# ============================================================
# Subcommand: remove
# ============================================================
cmd_remove() {
  local name="${1:-}"
  sane_name "$name" || die "remove: invalid name '$name' (need ${NAME_RE}, ≤64 chars, no leading dot)"

  local active
  active="$(active_list)"
  if [[ ! -f "$active" ]]; then
    die "remove: no list file at $active — nothing to remove"
  fi

  if ! read_list "$active" | grep -Fxq "$name"; then
    log "$name not present in $active"
    cmd_apply
    return 0
  fi

  # Filter the file out-of-place, then atomic move back.  Preserves
  # comments + blank lines for everything except the line we're
  # removing.  awk pattern: skip lines whose trimmed value == name.
  local tmp
  tmp="$(mktemp -t vpn-exclude.XXXXXX.list)"
  # shellcheck disable=SC2064  # intentional early-binding of $tmp
  trap "rm -f '$tmp'" RETURN
  awk -v drop="$name" '
    {
      line = $0;
      trimmed = $0;
      sub(/^[[:space:]]+/, "", trimmed);
      sub(/[[:space:]]+$/, "", trimmed);
      if (trimmed == drop) next;
      print line;
    }
  ' "$active" > "$tmp"
  mv "$tmp" "$active"
  trap - RETURN
  ok "removed $name from $active"
  cmd_apply
}

# ============================================================
# Subcommand: apply
# ============================================================
# Build the shim set from scratch.  Two passes:
#   1. Generate a shim for every entry whose binary resolves.
#   2. Delete every shim whose name is NOT in the current set
#      (handles the "removed from list" case).
# Both passes leave SHIM_DIR mode 0755 + each shim 0755.
cmd_apply() {
  if [[ ! -x "$MULLVAD_EXCLUDE" ]]; then
    err "$MULLVAD_EXCLUDE not found — install the mullvad-vpn package first"
    return 2
  fi

  mkdir -p "$SHIM_DIR"
  chmod 0755 "$SHIM_DIR"

  local apps
  apps="$(effective_set)"

  # Track desired set so we can prune orphans later.
  local -A desired=()
  local created=0 missing=0 unchanged=0

  if [[ -n "$apps" ]]; then
    while IFS= read -r app; do
      [[ -z "$app" ]] && continue
      sane_name "$app" || { warn "skip $app: invalid name"; continue; }
      desired[$app]=1

      local bin
      bin="$(resolve_binary "$app")"
      if [[ -z "$bin" ]]; then
        warn "skip $app: binary not on PATH (install first, then re-run apply)"
        (( missing++ )) || true
        continue
      fi

      local shim="${SHIM_DIR}/${app}"
      local new_content
      new_content="$(printf '%s\n' \
        '#!/usr/bin/env bash' \
        '# Generated by scripts/vpn-exclude.sh — do not edit by hand.' \
        '# Re-run `scripts/vpn-exclude.sh apply` to refresh.' \
        "# Real binary: $bin" \
        "exec ${MULLVAD_EXCLUDE} \"${bin}\" \"\$@\"")"

      # Idempotent write: if the shim already matches byte-for-byte,
      # skip — avoids touching mtime on no-op applies.
      if [[ -r "$shim" ]] && [[ "$(cat "$shim")" == "$new_content" ]]; then
        (( unchanged++ )) || true
        continue
      fi
      printf '%s\n' "$new_content" > "$shim"
      chmod 0755 "$shim"
      ok "shim: $shim → mullvad-exclude $bin"
      (( created++ )) || true
    done <<<"$apps"
  fi

  # Prune orphan shims (apps removed from the list).
  local pruned=0
  if [[ -d "$SHIM_DIR" ]]; then
    while IFS= read -r -d '' shim; do
      local base
      base="$(basename "$shim")"
      if [[ -z "${desired[$base]:-}" ]]; then
        rm -f "$shim"
        ok "pruned: $shim (not in active list)"
        (( pruned++ )) || true
      fi
    done < <(find "$SHIM_DIR" -maxdepth 1 -type f -print0 2>/dev/null)
  fi

  log "summary: $created created, $unchanged unchanged, $missing missing, $pruned pruned"
  if (( missing > 0 )); then
    log "  → install the missing apps then re-run \`vpn-exclude.sh apply\`"
  fi
  return 0
}

# ============================================================
# Dispatch
# ============================================================
main() {
  local cmd="${1:-}"
  case "$cmd" in
    list)        shift; cmd_list "$@" ;;
    status)      shift; cmd_status "$@" ;;
    add)         shift; cmd_add "$@" ;;
    remove)      shift; cmd_remove "$@" ;;
    apply)       shift; cmd_apply "$@" ;;
    -h|--help|help|"") print_help; [[ -z "$cmd" ]] && exit 2 || exit 0 ;;
    *)           err "unknown subcommand: $cmd"; print_help; exit 2 ;;
  esac
}

main "$@"
