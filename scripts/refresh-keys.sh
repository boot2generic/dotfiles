#!/usr/bin/env bash
# scripts/refresh-keys.sh
#
# Manually rotate the GPG keyring file for ONE apt-pinned-repo app
# when upstream rolls its signing key.  Always interactive (unless
# --yes), single-app only (rotating multiple keyrings unattended is
# the wrong default — each rotation is a security event that wants
# its own out-of-band verification).
#
# Flow:
#   1. Read the app's manifest; bail unless install.method = apt-pinned-repo.
#   2. Download key_url to a mktemp dir; compute the new key's fingerprint.
#   3. Compare to the pinned key_fingerprint:
#        same   → "key unchanged" log + exit 0; nothing to do.
#        differ → print BOTH fingerprints + docs_url hint, ask y/N.
#   4. On accept:
#        • atomic swap of config/system/etc/apt/keyrings/<keyring_file>
#          (write to sibling .new, mv-rename).
#        • update install.apt_pinned_repo.key_fingerprint in the TOML.
#        • append to ~/.cache/dotfiles/key-rotations.log so we have an
#          audit trail across cron / interactive runs.
#   5. On decline: leave everything alone; exit 1.
#
# Why no --all: a rotation event should never be batched.  If two
# vendors rotated keys on the same day, the operator should review
# them one at a time so a typo or an MITM on one doesn't silently
# slip through under the cover of the other.
#
# Usage:
#   ./scripts/refresh-keys.sh --app NAME
#   ./scripts/refresh-keys.sh --app NAME --yes        # scripted (must be
#                                                       sure!) — bypasses prompt
#   ./scripts/refresh-keys.sh --help

set -euo pipefail

if [[ -t 1 ]]; then
    C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'
    C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
    C_OK= ; C_WARN= ; C_ERR= ; C_DIM= ; C_RST=
fi
log()  { echo "${C_DIM}[*]${C_RST} $*" >&2; }
ok()   { echo "${C_OK}[ok]${C_RST} $*" >&2; }
warn() { echo "${C_WARN}[!]${C_RST} $*" >&2; }
err()  { echo "${C_ERR}[!!]${C_RST} $*" >&2; }
die()  { err "$*"; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APPS_DIR="${REPO_DIR}/config/apps"
KEYRINGS_DIR="${REPO_DIR}/config/system/etc/apt/keyrings"
LOG_DIR="${HOME}/.cache/dotfiles"
LOG_FILE="${LOG_DIR}/key-rotations.log"

APP=""
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)     APP="${2:-}"; [[ -z "$APP" ]] && die "--app requires a name"; shift ;;
        --yes)     ASSUME_YES=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         die "Unknown flag: $1 (try --help)" ;;
    esac
    shift
done

[[ -n "$APP" ]] || die "--app NAME is required (see --help)"
command -v python3 >/dev/null 2>&1 || die "python3 missing"
command -v curl    >/dev/null 2>&1 || die "curl missing"
command -v gpg     >/dev/null 2>&1 || die "gpg missing"

TOML="${APPS_DIR}/${APP}.toml"
[[ -r "$TOML" ]] || die "manifest not found: ${TOML}"

# Extract just the fields we need.  Same shape as the other scripts —
# inline rather than sourcing a lib, so the script is standalone.
read_field() {
    python3 - "$TOML" "$1" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    d = tomllib.load(fh)
keys = sys.argv[2].split(".")
v = d
for k in keys:
    if not isinstance(v, dict) or k not in v:
        v = ""
        break
    v = v[k]
print(v if v is not None else "")
PY
}

INSTALL_METHOD="$(read_field install.method)"
KEY_URL="$(read_field install.apt_pinned_repo.key_url)"
KEY_FP_PINNED="$(read_field install.apt_pinned_repo.key_fingerprint)"
KEYRING_FILE="$(read_field install.apt_pinned_repo.keyring_file)"
DOCS_URL="$(read_field docs_url)"

if [[ "$INSTALL_METHOD" != "apt-pinned-repo" ]]; then
    die "${APP}: install.method is '${INSTALL_METHOD}', refresh-keys.sh only handles apt-pinned-repo"
fi
[[ -n "$KEY_URL" ]]      || die "${APP}: install.apt_pinned_repo.key_url unset"
[[ -n "$KEYRING_FILE" ]] || die "${APP}: install.apt_pinned_repo.keyring_file unset"
[[ -n "$KEY_FP_PINNED" ]] || warn "${APP}: no pinned fingerprint — first-run; any fetched key will be ACCEPTED if you confirm"

KEYRING_PATH="${KEYRINGS_DIR}/${KEYRING_FILE}"

TMPDIR_KEYS="$(mktemp -d -t refresh-keys.XXXXXX)"
trap 'rm -rf "$TMPDIR_KEYS"' EXIT

# Download the upstream key.  --fail makes curl exit non-zero on
# HTTP errors so we don't silently rotate to a 404 body.  -L follows
# redirects (some vendors put the key behind a CDN).
log "fetching ${KEY_URL}"
KEY_RAW="${TMPDIR_KEYS}/upstream.raw"
if ! curl -fsSL --max-time 30 -o "$KEY_RAW" "$KEY_URL"; then
    die "could not download ${KEY_URL}"
fi

# The upstream key may be ASCII-armored or binary; gpg --dearmor
# normalizes either form into a keyring file we can fingerprint.
KEY_NEW="${TMPDIR_KEYS}/upstream.gpg"
if ! gpg --dearmor --output "$KEY_NEW" --yes "$KEY_RAW" 2>/dev/null; then
    # Maybe it's already binary; try copying through.
    cp "$KEY_RAW" "$KEY_NEW"
fi

# Pull the primary key fingerprint via --with-colons (stable across
# gpg versions; the human-formatted output is not parseable).
fingerprint_of() {
    gpg --batch --no-default-keyring --keyring "$1" --with-colons --fingerprint 2>/dev/null \
        | awk -F: '$1=="fpr" {print $10; exit}'
}

NEW_FP=$(fingerprint_of "$KEY_NEW")
[[ -n "$NEW_FP" ]] || die "could not extract fingerprint from fetched key (is the URL a real GPG key?)"

if [[ -n "$KEY_FP_PINNED" && "${NEW_FP^^}" == "${KEY_FP_PINNED^^}" ]]; then
    ok "${APP}: key unchanged; no rotation needed (fingerprint ${NEW_FP})"
    exit 0
fi

# Rotation candidate.  This is the security-critical path; we print
# both fingerprints and force a Y/N (default N) unless --yes was
# given.  The user should verify NEW_FP out-of-band: vendor docs,
# signed announcement, multiple trusted sources.
cat >&2 <<EOF

${C_WARN}KEY ROTATION DETECTED${C_RST} for ${APP}
  old fingerprint: ${KEY_FP_PINNED:-<unset — first run>}
  new fingerprint: ${NEW_FP}
  source URL:      ${KEY_URL}
EOF
[[ -n "$DOCS_URL" ]] && printf '  vendor docs:     %s\n' "$DOCS_URL" >&2 || true
cat >&2 <<EOF

Verify the new fingerprint out-of-band (vendor docs, signed announcement,
multiple trusted sources) BEFORE accepting.  An MITM on the key_url alone
is enough to compromise every box this dotfiles repo installs.

EOF

if [[ $ASSUME_YES -eq 1 ]]; then
    warn "--yes given; skipping interactive confirmation"
    answer="y"
else
    if [[ ! -t 0 ]]; then
        die "stdin is not a TTY; refusing to rotate non-interactively without --yes"
    fi
    printf 'Accept rotation? [y/N] ' >&2
    read -r answer || answer="n"
fi

case "${answer,,}" in
    y|yes) ;;
    *)
        warn "rotation declined; leaving keyring and TOML untouched"
        exit 1
        ;;
esac

# ── Atomic swap.  Write to sibling .new in the SAME directory so the
# mv-rename is on one filesystem (otherwise mv falls back to a non-
# atomic copy+unlink and a power-loss midway leaves a half-written
# keyring).  We also create the keyrings dir if missing — first-run
# bootstrap may not have one yet.
mkdir -p "$KEYRINGS_DIR"
SIBLING="${KEYRING_PATH}.new.$$"
cp "$KEY_NEW" "$SIBLING"
chmod 0644 "$SIBLING"
mv -f "$SIBLING" "$KEYRING_PATH"
ok "keyring updated: ${KEYRING_PATH}"

# ── TOML write — only key_fingerprint.  Reuse the same targeted
# line-rewrite strategy as refresh-pins.sh (stay inside stdlib).
python3 - "$TOML" "install.apt_pinned_repo" "key_fingerprint" "$NEW_FP" <<'PY'
import sys, re, pathlib
path, section, key, newval = sys.argv[1:5]
text = pathlib.Path(path).read_text()
lines = text.splitlines(keepends=True)
want_header = f"[{section}]"
in_section = False
done = False
key_re = re.compile(r'^(\s*)(' + re.escape(key) + r')(\s*=\s*)([^\n#]*?)(\s*(#.*)?)$')
quoted = '"' + newval.replace('"', '\\"') + '"'
for i, line in enumerate(lines):
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        in_section = (stripped == want_header)
        continue
    if not in_section:
        continue
    m = key_re.match(line.rstrip("\n"))
    if m:
        indent, k, sep, _old, tail, _cmt = m.groups()
        nl = "\n" if line.endswith("\n") else ""
        lines[i] = f"{indent}{k}{sep}{quoted}{tail or ''}{nl}"
        done = True
        break
if not done:
    sys.stderr.write(f"could not locate [{section}].{key} in {path}\n")
    sys.exit(3)
pathlib.Path(path).write_text("".join(lines))
PY
ok "TOML updated: ${TOML}"

# ── Audit log.  Cheap append; persists across reboots.  We deliberately
# do NOT log key material itself — only the fingerprint and the user's
# explicit acceptance.  Tampering with this file does not weaken the
# repo's actual trust (the keyring is the truth), but it's evidence for
# "who accepted what, when".
mkdir -p "$LOG_DIR"
{
    printf '%s\tapp=%s\told_fp=%s\tnew_fp=%s\taccepted_by=%s\tassume_yes=%d\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$APP" \
        "${KEY_FP_PINNED:-<unset>}" \
        "$NEW_FP" \
        "${USER:-$(id -un)}" \
        "$ASSUME_YES"
} >>"$LOG_FILE"
ok "logged rotation to ${LOG_FILE}"

cat >&2 <<EOF

Next steps:
    $ git diff config/apps/${APP}.toml config/system/etc/apt/keyrings/${KEYRING_FILE}
    $ git add config/apps/${APP}.toml config/system/etc/apt/keyrings/${KEYRING_FILE}
    $ git commit -m "refresh-keys: rotate ${APP} signing key to ${NEW_FP}"
EOF
