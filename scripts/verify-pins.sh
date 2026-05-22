#!/usr/bin/env bash
# scripts/verify-pins.sh
#
# Read-only verification of every config/apps/<name>.toml pin block.
# Called by install-apps.sh (pre-flight), audit.sh (drift sweep),
# dotfiles-doctor.sh (health), and conky's check_pins() panel.  The
# exit code is the contract — callers branch on it without parsing
# stdout (so the JSON format can evolve freely without breaking them):
#
#   0  every pin fresh AND verified (or no app manifests exist at all)
#   1  at least one pin is STALE (last_refreshed + refresh_after_days
#      < today) but no signature/hash mismatches
#   2  at least one pin failed VERIFICATION (sig/sha mismatch,
#      keyring fingerprint drift, missing required file, etc.)
#   3  --app NAME was given but no manifest matched (typo / missing
#      file).  Distinct from 2 so callers can tell "verify says BAD"
#      apart from "you spelled the app wrong".
#
# Why "bad" dominates "stale": a fingerprint mismatch is a security
# event; a stale date is just a reminder.  Callers want the stronger
# signal to take precedence so a cron run that finds a key rotation
# alerts even if half the manifests also happen to be stale.
#
# Verification per install.method:
#   apt              nothing to verify (OS archive signing covers it).
#                    If a [pin] block exists we still check freshness.
#   apt-pinned-repo  • keyring file exists under config/system/.../keyrings/
#                    • keyring file's gpg fingerprint == pin.key_fingerprint
#                    • sources file exists under config/system/.../sources.list.d/
#   github-release   • sha256 present for current arch (dpkg --print-architecture)
#                    • if the artifact is already on disk at install_to,
#                      its sha256 matches the pinned value
#   direct-deb       • if the package is installed at the pinned version,
#                      report ok (we cannot re-verify on-disk vs upstream
#                      URL — the .deb is dropped after dpkg -i)
#
# Usage:
#   ./scripts/verify-pins.sh                     # all apps, human output
#   ./scripts/verify-pins.sh --app NAME          # single app
#   ./scripts/verify-pins.sh --json              # one JSON obj/line/app
#   ./scripts/verify-pins.sh --strict-fresh      # stale → exit 2 (cron)
#   ./scripts/verify-pins.sh --help

set -euo pipefail

# ── Colour helpers (copy of build-bundle.sh:59-68; deliberate to keep
# the script standalone — see schema.toml note "no cross-script imports").
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
SOURCES_DIR="${REPO_DIR}/config/system/etc/apt/sources.list.d"

MODE_JSON=0
STRICT_FRESH=0
ONLY_APP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)          ;;
        --app)          ONLY_APP="${2:-}"; [[ -z "$ONLY_APP" ]] && die "--app requires a name"; shift ;;
        --json)         MODE_JSON=1 ;;
        --strict-fresh) STRICT_FRESH=1 ;;
        -h|--help)      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              die "Unknown flag: $1 (try --help)" ;;
    esac
    shift
done

command -v python3 >/dev/null 2>&1 || die "python3 missing"
command -v gpg     >/dev/null 2>&1 || warn "gpg missing — apt-pinned-repo fingerprint checks will fail"

# Current arch in the same vocabulary the schema uses.  dpkg reports
# "amd64" / "arm64"; the schema uses "x86_64" / "aarch64" because that's
# what github-release asset names use.  Map once, reuse below.
case "$(dpkg --print-architecture 2>/dev/null || echo unknown)" in
    amd64) ARCH_KEY="sha256_x86_64" ;;
    arm64) ARCH_KEY="sha256_aarch64" ;;
    *)     ARCH_KEY="sha256_x86_64" ;;  # best-effort fallback
esac

# ── TOML loader.  tomllib is stdlib on Debian 13's Python 3.11+.  We
# emit a flat shell-quotable line of KEY=VAL pairs the caller can `eval`
# into local vars — simpler than threading jq through every call site,
# and keeps the dependency surface to just python3.
toml_extract() {
    # $1 = path to .toml ; stdout = `key=value` lines (shell-quoted).
    python3 - "$1" <<'PY'
import sys, tomllib, shlex
p = sys.argv[1]
with open(p, "rb") as fh:
    d = tomllib.load(fh)
def emit(k, v):
    if v is None: v = ""
    if isinstance(v, list): v = ",".join(str(x) for x in v)
    print(f"{k}={shlex.quote(str(v))}")
meta = d.get("meta", {})
inst = d.get("install", {})
pin  = d.get("pin", {})
emit("META_NAME",   meta.get("name", ""))
emit("INSTALL_METHOD", inst.get("method", ""))
apr = inst.get("apt_pinned_repo", {})
emit("APR_PACKAGE",         apr.get("package", ""))
emit("APR_KEY_FINGERPRINT", apr.get("key_fingerprint", ""))
emit("APR_KEYRING_FILE",    apr.get("keyring_file", ""))
emit("APR_SOURCES_FILE",    apr.get("sources_file", ""))
gh = inst.get("github_release", {})
emit("GH_REPO",            gh.get("repo", ""))
emit("GH_VERSION",          gh.get("version", ""))
emit("GH_INSTALL_TO",       gh.get("install_to", ""))
emit("GH_SHA256_X86_64",    gh.get("sha256_x86_64", ""))
emit("GH_SHA256_AARCH64",   gh.get("sha256_aarch64", ""))
emit("GH_GPG_FINGERPRINT",  gh.get("gpg_fingerprint", ""))
dd = inst.get("direct_deb", {})
emit("DD_URL",     dd.get("url", ""))
emit("DD_SHA256",  dd.get("sha256", ""))
emit("DD_VERSION", dd.get("version", ""))
emit("PIN_LAST_REFRESHED",     pin.get("last_refreshed", ""))
emit("PIN_REFRESH_AFTER_DAYS", pin.get("refresh_after_days", ""))
emit("HAS_PIN", "1" if pin else "0")
PY
}

# Days between $1 (YYYY-MM-DD) and today.  GNU date handles ISO dates
# directly; we treat parse failure as "very old" so a malformed pin
# trips the staleness check instead of silently passing.
days_since() {
    local d="$1"
    local t_then t_now
    if ! t_then=$(date -d "$d" +%s 2>/dev/null); then
        echo 99999
        return
    fi
    t_now=$(date +%s)
    echo $(( (t_now - t_then) / 86400 ))
}

# Extract a single fingerprint from a keyring file via gpg --with-colons.
# Two file shapes are supported:
#   • binary keyring   (.gpg / .kbx) — fed via --keyring directly.
#   • ASCII-armored    (.asc / armored .gpg) — must be dearmored first;
#                      gpg --keyring rejects armored input silently.
# We detect armor by the first line ("-----BEGIN PGP …") and route
# accordingly.  The first fpr: line is the primary key (any subkeys
# follow); for vendor repo keys we pin against the primary.
fingerprint_of() {
    local kf="$1"
    local tmp=""
    local first
    first=$(head -c 64 "$kf" 2>/dev/null || true)
    if [[ "$first" == "-----BEGIN PGP"* ]]; then
        tmp=$(mktemp -t fp.XXXXXX)
        if ! gpg --dearmor --output "$tmp" --yes "$kf" 2>/dev/null; then
            rm -f "$tmp"; return 1
        fi
        kf="$tmp"
    fi
    gpg --batch --no-default-keyring --keyring "$kf" --with-colons --fingerprint 2>/dev/null \
        | awk -F: '$1=="fpr" {print $10; exit}'
    [[ -n "$tmp" ]] && rm -f "$tmp"
    return 0
}

# Per-app verifier.  Sets RESULT_STATUS / RESULT_REASON via globals
# (bash has no struct return; this keeps the call-site readable).
verify_app() {
    local toml="$1"
    local raw
    if ! raw=$(toml_extract "$toml" 2>/dev/null); then
        RESULT_STATUS="bad"
        RESULT_REASON="toml-parse-error"
        RESULT_METHOD=""
        RESULT_LAST_REFRESHED=""
        RESULT_DAYS_OLD=0
        return
    fi
    # Subshell-safe: eval into local vars only (declared in caller scope below).
    local META_NAME="" INSTALL_METHOD="" HAS_PIN="0"
    local APR_PACKAGE="" APR_KEY_FINGERPRINT="" APR_KEYRING_FILE="" APR_SOURCES_FILE=""
    local GH_REPO="" GH_VERSION="" GH_INSTALL_TO="" GH_SHA256_X86_64="" GH_SHA256_AARCH64="" GH_GPG_FINGERPRINT=""
    local DD_URL="" DD_SHA256="" DD_VERSION=""
    local PIN_LAST_REFRESHED="" PIN_REFRESH_AFTER_DAYS=""
    eval "$raw"

    RESULT_METHOD="$INSTALL_METHOD"
    RESULT_LAST_REFRESHED="$PIN_LAST_REFRESHED"
    RESULT_DAYS_OLD=0
    RESULT_STATUS="ok"
    RESULT_REASON=""

    # ── 1. Verification (security) first; staleness only matters if
    #      everything else verifies.  A bad pin should never read "ok".
    case "$INSTALL_METHOD" in
        apt)
            : # nothing to verify
            ;;
        apt-pinned-repo)
            local kf="${KEYRINGS_DIR}/${APR_KEYRING_FILE}"
            local sf="${SOURCES_DIR}/${APR_SOURCES_FILE}"
            if [[ -z "$APR_KEYRING_FILE" ]]; then
                RESULT_STATUS="bad"; RESULT_REASON="keyring_file unset"
            elif [[ ! -r "$kf" ]]; then
                RESULT_STATUS="bad"; RESULT_REASON="keyring missing: ${APR_KEYRING_FILE}"
            elif [[ -z "$APR_KEY_FINGERPRINT" ]]; then
                RESULT_STATUS="bad"; RESULT_REASON="key_fingerprint unset"
            else
                local got
                got=$(fingerprint_of "$kf" || true)
                if [[ -z "$got" ]]; then
                    RESULT_STATUS="bad"; RESULT_REASON="cannot read fingerprint from ${APR_KEYRING_FILE}"
                elif [[ "${got^^}" != "${APR_KEY_FINGERPRINT^^}" ]]; then
                    RESULT_STATUS="bad"; RESULT_REASON="key_fingerprint mismatch (got ${got})"
                fi
            fi
            if [[ "$RESULT_STATUS" == "ok" ]]; then
                if [[ -z "$APR_SOURCES_FILE" ]]; then
                    RESULT_STATUS="bad"; RESULT_REASON="sources_file unset"
                elif [[ ! -r "$sf" ]]; then
                    RESULT_STATUS="bad"; RESULT_REASON="sources missing: ${APR_SOURCES_FILE}"
                fi
            fi
            ;;
        github-release)
            # Arch-relevant SHA must be present.  An "x86_64-only" app
            # signals that by leaving sha256_aarch64 empty AND vice versa.
            local need_sha=""
            case "$ARCH_KEY" in
                sha256_x86_64)  need_sha="$GH_SHA256_X86_64"  ;;
                sha256_aarch64) need_sha="$GH_SHA256_AARCH64" ;;
            esac
            if [[ -z "$need_sha" ]]; then
                RESULT_STATUS="bad"; RESULT_REASON="missing ${ARCH_KEY} for this arch"
            elif [[ ${#need_sha} -ne 64 ]]; then
                RESULT_STATUS="bad"; RESULT_REASON="${ARCH_KEY} is not 64 hex chars"
            elif [[ -n "$GH_INSTALL_TO" && -f "$GH_INSTALL_TO" ]]; then
                local got
                got=$(sha256sum "$GH_INSTALL_TO" 2>/dev/null | awk '{print $1}')
                if [[ -n "$got" && "${got,,}" != "${need_sha,,}" ]]; then
                    RESULT_STATUS="bad"; RESULT_REASON="on-disk sha mismatch at ${GH_INSTALL_TO}"
                fi
            fi
            ;;
        direct-deb)
            # We can't re-hash the .deb (it's removed after dpkg -i), so the
            # best evidence we have is "installed package version matches
            # the pinned version".  An installed-but-wrong-version state is
            # treated as ok with reason "version-drift" — not bad, because
            # the user may have intentionally apt-pinned a newer build; the
            # refresh workflow catches this honestly.
            local pkg="$DD_VERSION"  # reuse var name; actual lookup uses meta.name
            if [[ -n "$META_NAME" ]]; then
                local inst_ver
                inst_ver=$(dpkg-query -W -f='${Version}' "$META_NAME" 2>/dev/null || true)
                if [[ -z "$inst_ver" ]]; then
                    RESULT_REASON="not-installed"
                elif [[ "$inst_ver" == "$DD_VERSION" ]]; then
                    RESULT_REASON="version-matches"
                else
                    RESULT_REASON="version-drift (installed=${inst_ver}, pinned=${DD_VERSION})"
                fi
            fi
            ;;
        "")
            RESULT_STATUS="bad"; RESULT_REASON="install.method unset"
            ;;
        *)
            RESULT_STATUS="bad"; RESULT_REASON="unknown install.method: ${INSTALL_METHOD}"
            ;;
    esac

    # ── 2. Freshness — only relevant if [pin] is present AND we haven't
    #      already marked the app bad.  Per-method note: plain `apt` may
    #      legitimately omit [pin]; in that case freshness is moot.
    if [[ "$HAS_PIN" == "1" && -n "$PIN_LAST_REFRESHED" && -n "$PIN_REFRESH_AFTER_DAYS" ]]; then
        local d
        d=$(days_since "$PIN_LAST_REFRESHED")
        RESULT_DAYS_OLD="$d"
        if [[ "$RESULT_STATUS" == "ok" && "$d" -gt "$PIN_REFRESH_AFTER_DAYS" ]]; then
            RESULT_STATUS="stale"
            RESULT_REASON="${d}d old (threshold ${PIN_REFRESH_AFTER_DAYS}d)"
        fi
    fi
}

# ── Driver ─────────────────────────────────────────────────────────
if [[ ! -d "$APPS_DIR" ]]; then
    log "no apps configured (${APPS_DIR} missing)"
    exit 0
fi

# Filter out schema.toml / underscore-prefixed names per dispatcher convention.
shopt -s nullglob
manifests=()
for f in "$APPS_DIR"/*.toml; do
    base=$(basename "$f")
    [[ "$base" == schema*.toml || "$base" == _*.toml ]] && continue
    if [[ -n "$ONLY_APP" ]]; then
        [[ "$base" == "${ONLY_APP}.toml" ]] && manifests+=("$f")
    else
        manifests+=("$f")
    fi
done
shopt -u nullglob

if [[ ${#manifests[@]} -eq 0 ]]; then
    if [[ -n "$ONLY_APP" ]]; then
        # Distinct exit code 3 — "not found" is not a signature mismatch.
        # Callers (install-apps.sh dispatcher) branch on this to surface
        # "typo" vs "verify says BAD" cleanly.
        err "no manifest matched --app ${ONLY_APP}"
        exit 3
    fi
    log "no apps configured"
    exit 0
fi

worst=0   # 0 ok, 1 stale, 2 bad — monotonic; only ever increases.
first_json=1
[[ $MODE_JSON -eq 0 ]] || printf '['

for toml in "${manifests[@]}"; do
    verify_app "$toml"
    name=$(basename "$toml" .toml)

    case "$RESULT_STATUS" in
        ok)    ;; # monotonic: ok never decreases worst
        stale) (( worst < 1 )) && worst=1 ;;
        bad)   worst=2 ;;
    esac

    if [[ $MODE_JSON -eq 1 ]]; then
        # JSON encode the reason via python so we never have to think
        # about quoting inside bash (reasons may contain quotes/paths).
        [[ $first_json -eq 1 ]] || printf ','
        first_json=0
        python3 -c '
import json, sys
print(json.dumps({
    "name": sys.argv[1],
    "method": sys.argv[2],
    "status": sys.argv[3],
    "reason": sys.argv[4],
    "last_refreshed": sys.argv[5],
    "days_old": int(sys.argv[6] or 0),
}))' "$name" "$RESULT_METHOD" "$RESULT_STATUS" "$RESULT_REASON" \
   "$RESULT_LAST_REFRESHED" "$RESULT_DAYS_OLD"
    else
        # Fixed-width column layout — name 20, days 4, method 18, reason free-form.
        case "$RESULT_STATUS" in
            ok)    tag="${C_OK}[ok]${C_RST}   " ;;
            stale) tag="${C_WARN}[stale]${C_RST}" ;;
            bad)   tag="${C_ERR}[bad]${C_RST}  " ;;
            *)     tag="[?]   " ;;
        esac
        printf '%b %-20s %3sd %-18s %s\n' \
            "$tag" "$name" "$RESULT_DAYS_OLD" "$RESULT_METHOD" "$RESULT_REASON"
    fi
done

[[ $MODE_JSON -eq 0 ]] || printf ']\n'

# Strict-fresh: stale promotes to bad for cron use.  Default mode keeps
# the distinction so interactive users see "stale but verified" clearly.
if [[ $STRICT_FRESH -eq 1 && $worst -eq 1 ]]; then
    worst=2
fi
exit "$worst"
