# scripts/lib/xdg-defaults.sh
#
# Sourced bash library — do NOT execute directly.  Applies XDG-MIME
# default-application associations declared in config/apps/apps.toml.
#
# Public function:
#     xdg_defaults_apply [PATH]
#         PATH defaults to <REPO_DIR>/config/apps/apps.toml when set,
#         otherwise to the path resolved relative to this file's own
#         location.  Reads the top-level [xdg_defaults] table:
#
#             [xdg_defaults]
#             "application/pdf" = "org.mozilla.firefox-esr.desktop"
#             "x-scheme-handler/https" = "org.mozilla.firefox-esr.desktop"
#
#         For every key/value pair, runs
#             xdg-mime default <APP.desktop> <MIME>
#         as the install user (NOT root) so the binding lands in
#         $XDG_CONFIG_HOME/mimeapps.list, not /etc.
#
# `apps.toml` does not currently declare an [xdg_defaults] table, so
# the call is a no-op on a stock checkout.  Add the table when you
# want xdg-mime defaults applied; the library will pick it up
# automatically.

# ── Module-local logger ────────────────────────────────────────────
_xdg_defaults_log()  { printf '[xdg-defaults] %s\n' "$*" >&2; }
_xdg_defaults_warn() { printf '[xdg-defaults] WARN: %s\n' "$*" >&2; }

# ── Resolve default apps.toml path ─────────────────────────────────
# When the caller doesn't pass an explicit path, fall back to the
# repo-relative location.  BASH_SOURCE[0] points at this file even
# when sourced, so the repo root resolves the same way as in the
# top-level scripts.
_xdg_defaults_default_path() {
  local lib_dir repo_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_dir="$(cd "${lib_dir}/../.." && pwd)"
  printf '%s\n' "${repo_dir}/config/apps/apps.toml"
}

# ── Public: apply [xdg_defaults] from apps.toml ────────────────────
# Returns 0 in all happy paths (including the silent no-op when the
# file or table is absent).  Returns non-zero only when xdg-mime
# itself is missing AND we have pairs to apply — that's a real
# inconsistency the caller should know about.
xdg_defaults_apply() {
  local apps_toml="${1:-}"
  if [[ -z "$apps_toml" ]]; then
    apps_toml="$(_xdg_defaults_default_path)"
  fi

  if [[ ! -f "$apps_toml" ]]; then
    # Manifest absent — silent no-op.
    return 0
  fi

  # Extract pairs as TAB-separated "mime<TAB>app" lines.  No table or
  # an empty one prints nothing — silent no-op by design.
  local pairs
  if ! pairs="$(python3 - "$apps_toml" <<'PY'
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as f:
        data = tomllib.loads(f.read().decode("utf-8"))
except Exception as e:
    print(f"[xdg-defaults] WARN: parse failed: {e}", file=sys.stderr)
    sys.exit(0)
table = data.get("xdg_defaults", {})
if not isinstance(table, dict):
    sys.exit(0)
for mime, app in table.items():
    if not isinstance(mime, str) or not isinstance(app, str):
        continue
    if not mime or not app:
        continue
    print(f"{mime}\t{app}")
PY
  )"; then
    _xdg_defaults_warn "could not parse $apps_toml"
    return 0
  fi

  if [[ -z "$pairs" ]]; then
    # No [xdg_defaults] table or empty table — silent no-op.
    return 0
  fi

  if ! command -v xdg-mime >/dev/null 2>&1; then
    _xdg_defaults_warn "xdg-mime not on PATH — skipping ${apps_toml##*/} defaults"
    return 1
  fi

  # Refuse to run as root — the bindings must land in the user's
  # mimeapps.list, not /root/.config/mimeapps.list.
  if [[ $EUID -eq 0 ]]; then
    _xdg_defaults_warn "refusing to set xdg defaults as root — re-run as the install user"
    return 1
  fi

  local mime app rc=0
  while IFS=$'\t' read -r mime app; do
    [[ -n "$mime" && -n "$app" ]] || continue
    if xdg-mime default "$app" "$mime" >/dev/null 2>&1; then
      _xdg_defaults_log "${mime} -> ${app}"
    else
      _xdg_defaults_warn "xdg-mime default '${app}' '${mime}' failed"
      rc=1
    fi
  done <<<"$pairs"

  return "$rc"
}
