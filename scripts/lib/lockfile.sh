# scripts/lib/lockfile.sh
#
# Sourced bash library — do NOT execute directly.  Reads and writes
# per-app lockfiles at  config/apps/.locks/<name>.lock  (one file per
# installed app, committed to git so "what was installed when" stays
# auditable).
#
# Schema (TOML):
#     schema_version = 1
#
#     [lock]
#     name              = "starship"
#     install_method    = "github-release"
#     installed_at      = "2026-05-23T14:30:00Z"
#     installed_version = "v1.25.1"
#     installed_sha256  = "<hex>"
#     install_path      = "/usr/local/bin/starship"
#     verified_by       = "sha256"
#     manifest_pin_mode = "frozen"
#
# Optional-per-method fields (sha256, install_path, verified_by,
# pin_mode) appear as empty strings rather than being omitted — keeps
# the schema uniform for any downstream parser.
#
# Public API (all prefixed `lockfile_`):
#     lockfile_write   --path ... --name ... --method ... --version ...
#                      --sha256 ... --install-path ... --verified-by ...
#                      --pin-mode ...
#     lockfile_read    PATH
#     lockfile_exists  REPO_DIR NAME
#     lockfile_path    REPO_DIR NAME
#     lockfile_delete  PATH
#
# All progress / error output goes to stderr; lockfile_read prints
# KEY=VAL pairs on stdout (shell-eval-safe via single-quoted values).

# Guard against double-sourcing.
if [[ -n "${_DOTFILES_LOCKFILE_SH:-}" ]]; then
    return 0
fi
_DOTFILES_LOCKFILE_SH=1

# ── Module-private constants ───────────────────────────────────────
# Methods the validator accepts.  Mirrored here so lockfile_write can
# refuse a clearly-bogus --method early (defense in depth: the validator
# has already vetted apps.toml, but a buggy adapter could pass garbage).
_LOCKFILE_VALID_METHODS=("apt" "apt-pinned-repo" "github-release" "direct-deb")
_LOCKFILE_VALID_PIN_MODES=("track-latest" "frozen")

# ── Tiny logger — stderr only, prefixed for grep ───────────────────
_lockfile_log()  { printf '[lockfile] %s\n' "$*" >&2; }
_lockfile_warn() { printf '[lockfile] WARN: %s\n' "$*" >&2; }
_lockfile_err()  { printf '[lockfile] ERROR: %s\n' "$*" >&2; }

# Current time in UTC ISO 8601 ("Z" suffix), matches setup-state.sh.
_lockfile_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Is $1 in the remaining args ($2..)?
_lockfile_in_set() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# Escape a string for use inside a TOML basic string (the "..." form).
# Per TOML spec we MUST escape backslash and double-quote; control
# characters are also illegal raw inside basic strings.  All inputs we
# accept (version tags, sha hex, file paths, fingerprint identifiers)
# are well-formed in practice, but escaping defensively keeps the file
# valid even if a caller hands us something gnarly.
#
# Prints the escaped contents on stdout (no surrounding quotes).
_lockfile_toml_escape() {
    local s="$1"
    # Backslash first so we don't double-escape the escapes we add next.
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    # Bare CR/LF would break the single-line "..." form; escape them.
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Atomic same-filesystem write.  Stages content in a tempfile in the
# destination's directory, chmods it 0644, then mv -f's it into place —
# rename(2) is the actual atomicity primitive.  Returns 1 on any error.
#
# Args: <destination> <content>
_lockfile_write_atomic() {
    local dest="$1"
    local content="$2"
    local dir tmp
    dir="$(dirname -- "$dest")"

    if [[ ! -d "$dir" ]]; then
        if ! mkdir -p -- "$dir"; then
            _lockfile_err "could not create parent dir: $dir"
            return 1
        fi
    fi

    if ! tmp="$(mktemp -p "$dir" .lockfile.XXXXXX.tmp 2>/dev/null)"; then
        _lockfile_err "could not create tempfile in $dir"
        return 1
    fi
    # Make sure we don't leak the tempfile on early-return.  Sub-shell-
    # safe because we trap on RETURN, which fires when the function frame
    # unwinds (success or failure).
    # shellcheck disable=SC2064  # intentional early-binding of $tmp
    trap "rm -f -- '$tmp'" RETURN

    if ! printf '%s' "$content" > "$tmp"; then
        _lockfile_err "could not write tempfile: $tmp"
        return 1
    fi
    if ! chmod 0644 "$tmp"; then
        _lockfile_err "could not chmod tempfile: $tmp"
        return 1
    fi
    if ! mv -f -- "$tmp" "$dest"; then
        _lockfile_err "could not move tempfile into place: $dest"
        return 1
    fi
}

# ============================================================
# Public API
# ============================================================

# Resolve config/apps/.locks/<name>.lock under REPO_DIR.  Does not check
# existence — purely a path-builder so callers can pass it to write/read/
# delete without re-deriving the layout.
#
# Args: <repo_dir> <name>
# Prints: absolute path on stdout.
lockfile_path() {
    local repo_dir="${1:-}"
    local name="${2:-}"
    if [[ -z "$repo_dir" || -z "$name" ]]; then
        _lockfile_err "lockfile_path: REPO_DIR and NAME required"
        return 1
    fi
    printf '%s/config/apps/.locks/%s.lock\n' "$repo_dir" "$name"
}

# Returns 0 if the lockfile for NAME exists under REPO_DIR, 1 otherwise.
# Convenience for `apps-cli.sh status` / `verify` etc.
#
# Args: <repo_dir> <name>
lockfile_exists() {
    local repo_dir="${1:-}"
    local name="${2:-}"
    if [[ -z "$repo_dir" || -z "$name" ]]; then
        _lockfile_err "lockfile_exists: REPO_DIR and NAME required"
        return 1
    fi
    [[ -f "$repo_dir/config/apps/.locks/$name.lock" ]]
}

# Delete a lockfile at the given path.  No-op (but logs) if it's not
# there — callers (apps-cli.sh remove) treat "already gone" as success.
# Returns 1 only on a genuine rm failure (e.g. permission denied).
#
# Args: <path>
lockfile_delete() {
    local path="${1:-}"
    if [[ -z "$path" ]]; then
        _lockfile_err "lockfile_delete: PATH required"
        return 1
    fi
    if [[ ! -e "$path" ]]; then
        _lockfile_log "lockfile already absent: $path"
        return 0
    fi
    if ! rm -f -- "$path"; then
        _lockfile_err "could not remove lockfile: $path"
        return 1
    fi
    _lockfile_log "removed lockfile: $path"
}

# Write a lockfile atomically.
#
# Required (all non-empty unless noted):
#     --path PATH               destination absolute path
#     --name NAME               app name (matches apps.toml entry)
#     --method METHOD           one of: apt apt-pinned-repo github-release direct-deb
#     --version VERSION         installed version string
#
# Method-dependent (MAY be empty strings):
#     --sha256 SHA              hex digest, "" for apt/apt-pinned-repo
#     --install-path PATH       "" for apt/apt-pinned-repo/direct-deb
#     --verified-by TAG         "" only when truly N/A — every method
#                               in the matrix above sets a value, but
#                               accepting "" lets oddball cases through
#     --pin-mode MODE           one of: track-latest frozen; "" only
#                               when truly N/A (same caveat as above)
#
# Returns 0 on success, 1 on any error (missing required arg, unknown
# method/pin-mode, write failure).  Prints a clear stderr message
# describing what went wrong.
lockfile_write() {
    # Default everything to UNSET so we can distinguish "not passed" from
    # "passed as empty string" (the latter is valid for optional fields).
    local -A args=()
    local key val
    while (( $# )); do
        case "$1" in
            --path|--name|--method|--version|--sha256|\
            --install-path|--verified-by|--pin-mode)
                key="$1"
                if (( $# < 2 )); then
                    _lockfile_err "lockfile_write: $key requires a value"
                    return 1
                fi
                val="$2"
                args["$key"]="$val"
                shift 2
                ;;
            *)
                _lockfile_err "lockfile_write: unknown arg: $1"
                return 1
                ;;
        esac
    done

    # Required flags must be present AND have a non-empty value.
    # --install-path is allowed empty because apt-managed methods have
    # no application-controlled install path.
    local required_nonempty=(--path --name --method --version)
    for key in "${required_nonempty[@]}"; do
        if [[ -z "${args[$key]+set}" ]]; then
            _lockfile_err "lockfile_write: missing required flag $key"
            return 1
        fi
        if [[ -z "${args[$key]}" ]]; then
            _lockfile_err "lockfile_write: $key must be non-empty"
            return 1
        fi
    done

    # These four MAY be empty but the flag itself must still be passed
    # — keeps the call sites explicit so future maintainers can see at
    # a glance which fields were considered N/A.
    local required_present=(--sha256 --install-path --verified-by --pin-mode)
    for key in "${required_present[@]}"; do
        if [[ -z "${args[$key]+set}" ]]; then
            _lockfile_err "lockfile_write: missing required flag $key (pass \"\" if N/A)"
            return 1
        fi
    done

    local path="${args[--path]}"
    local name="${args[--name]}"
    local method="${args[--method]}"
    local version="${args[--version]}"
    local sha="${args[--sha256]}"
    local install_path="${args[--install-path]}"
    local verified_by="${args[--verified-by]}"
    local pin_mode="${args[--pin-mode]}"

    if ! _lockfile_in_set "$method" "${_LOCKFILE_VALID_METHODS[@]}"; then
        _lockfile_err "lockfile_write: --method must be one of: ${_LOCKFILE_VALID_METHODS[*]} (got: $method)"
        return 1
    fi

    # pin-mode is optional in the schema (can be ""), but if a value is
    # supplied it must be one of the known set.  Catches typos like
    # "frozen-track" rather than letting them land in the lockfile.
    if [[ -n "$pin_mode" ]]; then
        if ! _lockfile_in_set "$pin_mode" "${_LOCKFILE_VALID_PIN_MODES[@]}"; then
            _lockfile_err "lockfile_write: --pin-mode must be one of: ${_LOCKFILE_VALID_PIN_MODES[*]} (got: $pin_mode)"
            return 1
        fi
    fi

    local now
    now="$(_lockfile_now)" || { _lockfile_err "could not read current time"; return 1; }

    # Escape every string field once up front so the body below stays
    # readable.  All fields are TOML basic strings ("..." form) — empty
    # is allowed and renders as "".
    local e_name e_method e_now e_version e_sha e_install_path e_verified_by e_pin_mode
    e_name="$(_lockfile_toml_escape "$name")"
    e_method="$(_lockfile_toml_escape "$method")"
    e_now="$(_lockfile_toml_escape "$now")"
    e_version="$(_lockfile_toml_escape "$version")"
    e_sha="$(_lockfile_toml_escape "$sha")"
    e_install_path="$(_lockfile_toml_escape "$install_path")"
    e_verified_by="$(_lockfile_toml_escape "$verified_by")"
    e_pin_mode="$(_lockfile_toml_escape "$pin_mode")"

    # Hand-rolled TOML emit — single [lock] table, all keys are simple
    # strings, no nested tables.  Aligned `=` columns mirror the human-
    # readable example in the design doc.
    local content
    printf -v content '%s\n' \
        "schema_version = 1" \
        "" \
        "[lock]" \
        "name              = \"$e_name\"" \
        "install_method    = \"$e_method\"" \
        "installed_at      = \"$e_now\"" \
        "installed_version = \"$e_version\"" \
        "installed_sha256  = \"$e_sha\"" \
        "install_path      = \"$e_install_path\"" \
        "verified_by       = \"$e_verified_by\"" \
        "manifest_pin_mode = \"$e_pin_mode\""

    # umask 022 in a subshell so we don't perturb the caller's umask.
    # The atomic-write helper additionally chmods 0644, but setting
    # umask first means the tempfile starts at the right perms — no
    # window where it's group/world-writable.
    (
        umask 022
        _lockfile_write_atomic "$path" "$content"
    ) || return 1

    _lockfile_log "wrote lockfile: $path"
    return 0
}

# Read a lockfile and print its fields as KEY=VAL lines on stdout.
# Keys printed:
#     SCHEMA_VERSION
#     NAME INSTALL_METHOD INSTALLED_AT INSTALLED_VERSION
#     INSTALLED_SHA256 INSTALL_PATH VERIFIED_BY MANIFEST_PIN_MODE
#
# Values are single-quoted with embedded single-quotes escaped via the
# standard `'\''` pattern, so callers can `eval` the output safely:
#     eval "$(lockfile_read /path/to/x.lock)"
#
# Empty stdout (and return 0) if the file is absent — callers should
# pre-check with lockfile_exists when they need to distinguish absent
# from empty.  Returns 1 only on parse failure.
#
# Args: <path>
lockfile_read() {
    local path="${1:-}"
    if [[ -z "$path" ]]; then
        _lockfile_err "lockfile_read: PATH required"
        return 1
    fi
    if [[ ! -f "$path" ]]; then
        return 0
    fi

    LOCKFILE_PATH_ARG="$path" python3 - <<'PY' || return 1
import os, sys, tomllib

path = os.environ["LOCKFILE_PATH_ARG"]
try:
    with open(path, "rb") as f:
        data = tomllib.loads(f.read().decode("utf-8"))
except Exception as e:
    print(f"[lockfile] ERROR: could not parse {path}: {e}", file=sys.stderr)
    sys.exit(1)

sv   = data.get("schema_version", "")
lock = data.get("lock", {}) or {}

def sq(v):
    # Shell single-quote: close-quote, escaped-quote, re-open.  Safe
    # against arbitrary string content — the only special inside '...'
    # is the single quote itself.
    s = "" if v is None else str(v)
    return "'" + s.replace("'", "'\\''") + "'"

fields = [
    ("SCHEMA_VERSION",    sv),
    ("NAME",              lock.get("name",              "")),
    ("INSTALL_METHOD",    lock.get("install_method",    "")),
    ("INSTALLED_AT",      lock.get("installed_at",      "")),
    ("INSTALLED_VERSION", lock.get("installed_version", "")),
    ("INSTALLED_SHA256",  lock.get("installed_sha256",  "")),
    ("INSTALL_PATH",      lock.get("install_path",      "")),
    ("VERIFIED_BY",       lock.get("verified_by",       "")),
    ("MANIFEST_PIN_MODE", lock.get("manifest_pin_mode", "")),
]
for k, v in fields:
    print(f"{k}={sq(v)}")
PY
}
