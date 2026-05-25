#!/usr/bin/env bash
# scripts/verify-pins.sh
#
# Read-only verification of every pin block under config/apps/.  In the
# schema-v2 layout, manifests are TOML array-of-tables: any .toml file
# (other than schema*.toml, _*.toml, .*.toml) containing a top-level
# [[apps]] list is loaded and every entry verified.  Files that parse
# cleanly but lack [[apps]] are silently skipped (room for future
# tier-split files such as core.toml / desktop.toml).
#
# Called by install-apps.sh (pre-flight), audit.sh (drift sweep),
# dotfiles-doctor.sh (health), and conky's check_pins() panel.  The
# exit code is the contract — callers branch on it without parsing
# stdout (so the JSON format can evolve freely without breaking them):
#
#   0  every pin fresh AND verified (or no apps configured at all)
#   1  at least one pin is STALE (last_refreshed + refresh_after_days
#      < today) but no signature/hash mismatches
#   2  at least one pin failed VERIFICATION (sig/sha mismatch,
#      keyring fingerprint drift, missing required file, etc.)
#   3  --app NAME was given but no [[apps]] entry matched (typo /
#      missing entry).  Distinct from 2 so callers can tell "verify
#      says BAD" apart from "you spelled the app wrong".
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
#                    • keyring file's gpg fingerprint == key_fingerprint
#                    • sources file exists under config/system/.../sources.list.d/
#   github-release   • sha256 present for current arch (frozen mode only)
#                    • if the artifact is already on disk at install_to,
#                      its sha256 matches the pinned value (frozen mode)
#                    • if gpg_fingerprint is set, signature is verified
#   direct-deb       • frozen-only by contract; sha + version + url
#                    present.  Cannot re-verify URL post-install (the
#                    .deb is dropped after dpkg -i) so we check the
#                    installed package version when the name resolves.
#
# pin.mode behaviour:
#   "track-latest"   waives per-version verification (no pinned
#                    version/sha to verify against).  Only on-disk
#                    integrity is checked (keyring fingerprint,
#                    sources file existence).  Freshness still
#                    matters: pin.last_refreshed is treated as
#                    "we last audited this".
#   "frozen"         full verification of pinned values.  Required
#                    for direct-deb; default for github-release.
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

VALIDATOR="${SCRIPT_DIR}/apps-validate.py"

MODE_JSON=0
STRICT_FRESH=0
ONLY_APP=""
NO_VALIDATE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)          ;;
        --app)          ONLY_APP="${2:-}"; [[ -z "$ONLY_APP" ]] && die "--app requires a name"; shift ;;
        --json)         MODE_JSON=1 ;;
        --strict-fresh) STRICT_FRESH=1 ;;
        --no-validate)  NO_VALIDATE=1 ;;
        -h|--help)      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              die "Unknown flag: $1 (try --help)" ;;
    esac
    shift
done

command -v python3 >/dev/null 2>&1 || die "python3 missing"
command -v gpg     >/dev/null 2>&1 || warn "gpg missing — apt-pinned-repo fingerprint checks will fail"

# ── Pre-flight validator gate ──────────────────────────────────────
# Mirrors install-apps.sh; refuse to verify a manifest the schema
# validator rejects.  See scripts/lib/validator-gate.sh for the contract.
# shellcheck source=lib/validator-gate.sh
source "${SCRIPT_DIR}/lib/validator-gate.sh"
if ! run_apps_validator "$VALIDATOR" "$REPO_DIR" "$NO_VALIDATE"; then
    exit 1
fi

# Current arch in the same vocabulary the schema uses.  dpkg reports
# "amd64" / "arm64"; the schema uses "x86_64" / "aarch64" because that's
# what github-release asset names use.  Map once, reuse below.
case "$(dpkg --print-architecture 2>/dev/null || echo unknown)" in
    amd64) ARCH_KEY="sha256_x86_64" ;;
    arm64) ARCH_KEY="sha256_aarch64" ;;
    *)     ARCH_KEY="sha256_x86_64" ;;  # best-effort fallback
esac

# ── Schema-v2 manifest discovery
#
# Walk every config/apps/*.toml that ISN'T schema*.toml, _*.toml, or a
# dotfile, parse it, and emit a flat TSV stream of one [[apps]] entry
# per line:
#     <source_file>\t<entry_index>\t<entry_json>
#
# entry_index is 0-based within its source file (used in error messages
# so a hand-edit catches "second entry" vs "fifth entry" without rummaging
# through the source).  entry_json is a compact one-line JSON encoding
# of the [[apps]] entry — verify_entry() pulls fields out of it via
# json_get below.
#
# Files that parse cleanly but lack a top-level [[apps]] array are
# silently skipped — that's where the three legacy per-file manifests
# still live during the schema-v1 → schema-v2 transition.  Files that
# fail to parse emit a WARN but do not abort discovery (the validator
# gate elsewhere in the dispatcher chain is the authoritative schema
# check; we just want to not crash on a weird sibling).
load_entries() {
    [[ -d "$APPS_DIR" ]] || return 0
    local f base
    local files=""
    for f in "$APPS_DIR"/*.toml; do
        [[ -e "$f" ]] || continue
        base="$(basename "$f")"
        case "$base" in
            schema*.toml) continue ;;
            _*.toml)      continue ;;
            .*)           continue ;;
        esac
        files+="$f"$'\n'
    done
    [[ -n "$files" ]] || return 0
    # Pass the file list via env var rather than stdin — combining a
    # heredoc (<<'PY') with a here-string (<<<"$files") on the same
    # stream silently loses the heredoc.  Same pattern install-apps.sh
    # uses in its load_entries().
    APPS_FILES="$files" python3 - <<'PY'
import json
import os
import sys
import tomllib
from pathlib import Path

paths = [Path(line) for line in os.environ.get("APPS_FILES", "").splitlines() if line.strip()]
for p in paths:
    try:
        with open(p, "rb") as fh:
            data = tomllib.load(fh)
    except (tomllib.TOMLDecodeError, OSError, UnicodeDecodeError) as exc:
        # Skip-and-warn rather than abort — mirrors install-apps.sh's
        # discovery contract.  A truly broken apps.toml would have been
        # caught by the validator gate upstream.
        print(f"# WARN unparseable {p}: {exc}", file=sys.stderr)
        continue
    apps = data.get("apps")
    # Silent-skip files without [[apps]] — that's where the legacy
    # per-file manifests live during the transition.
    if not isinstance(apps, list):
        continue
    for idx, entry in enumerate(apps):
        if not isinstance(entry, dict):
            continue
        sys.stdout.write(
            f"{p}\t{idx}\t{json.dumps(entry, separators=(',', ':'))}\n"
        )
PY
}

# Extract a JSON value via Python — keeps the script jq-free.
# Usage: json_get '<json>' '<dotted.path>'  → prints value or empty.
# Lists are space-joined.  Booleans render as "true"/"false".
json_get() {
    local json="$1" path="$2"
    python3 -c '
import json, sys
data = json.loads(sys.argv[1])
for key in sys.argv[2].split("."):
    if isinstance(data, dict) and key in data:
        data = data[key]
    else:
        sys.exit(0)
if isinstance(data, (list, tuple)):
    print(" ".join(str(x) for x in data))
elif isinstance(data, bool):
    print("true" if data else "false")
else:
    print(data if data is not None else "")
' "$json" "$path"
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

# fingerprint_of() is shared with refresh-pins.sh via lib/gpg-helpers.sh
# so both scripts apply the same armor-detection / primary-key picking
# logic when checking on-disk keyrings against manifest pins.
# shellcheck source=lib/gpg-helpers.sh
source "${SCRIPT_DIR}/lib/gpg-helpers.sh"

# gpg_verify_pinned() lives in scripts/lib/gpg-helpers.sh so the
# github-release install adapter can reuse it.  The `source` line above
# pulls in both fingerprint_of and gpg_verify_pinned; see the library
# file for the trust model and rationale.

# Per-entry verifier.  Sets RESULT_STATUS / RESULT_REASON / etc. via
# globals (bash has no struct return; this keeps the call-site readable).
# $1 = compact JSON for one [[apps]] entry.
verify_entry() {
    local entry_json="$1"

    # Pull fields out of the JSON entry.  The schema-v2 layout puts
    # name/machines at the TOP of the entry (not under meta.*).
    local name method
    name="$(json_get "$entry_json" 'name')"
    method="$(json_get "$entry_json" 'install.method')"

    # Pin mode + freshness fields.
    local pin_mode pin_last pin_refresh_days
    pin_mode="$(json_get "$entry_json" 'pin.mode')"
    pin_last="$(json_get "$entry_json" 'pin.last_refreshed')"
    pin_refresh_days="$(json_get "$entry_json" 'pin.refresh_after_days')"

    # Method-specific sub-tables.
    local apr_pkg apr_kfp apr_kf apr_sf
    apr_pkg="$(json_get "$entry_json" 'install.apt_pinned_repo.package')"
    apr_kfp="$(json_get "$entry_json" 'install.apt_pinned_repo.key_fingerprint')"
    apr_kf="$( json_get "$entry_json" 'install.apt_pinned_repo.keyring_file')"
    apr_sf="$( json_get "$entry_json" 'install.apt_pinned_repo.sources_file')"

    local gh_repo gh_version gh_install_to gh_sha_x gh_sha_a gh_gpg_fp
    gh_repo="$(      json_get "$entry_json" 'install.github_release.repo')"
    gh_version="$(   json_get "$entry_json" 'install.github_release.version')"
    gh_install_to="$(json_get "$entry_json" 'install.github_release.install_to')"
    gh_sha_x="$(     json_get "$entry_json" 'install.github_release.sha256_x86_64')"
    gh_sha_a="$(     json_get "$entry_json" 'install.github_release.sha256_aarch64')"
    gh_gpg_fp="$(    json_get "$entry_json" 'install.github_release.gpg_fingerprint')"

    local dd_url dd_sha dd_version
    dd_url="$(    json_get "$entry_json" 'install.direct_deb.url')"
    dd_sha="$(    json_get "$entry_json" 'install.direct_deb.sha256')"
    dd_version="$(json_get "$entry_json" 'install.direct_deb.version')"

    RESULT_NAME="$name"
    RESULT_METHOD="$method"
    RESULT_LAST_REFRESHED="$pin_last"
    RESULT_DAYS_OLD=0
    RESULT_STATUS="ok"
    RESULT_REASON=""
    RESULT_PIN_MODE="$pin_mode"

    # ── 1. Verification (security) first; staleness only matters if
    #      everything else verifies.  A bad pin should never read "ok".
    case "$method" in
        apt)
            : # nothing to verify
            ;;
        apt-pinned-repo)
            local kf="${KEYRINGS_DIR}/${apr_kf}"
            local sf="${SOURCES_DIR}/${apr_sf}"
            if [[ -z "$apr_kf" ]]; then
                RESULT_STATUS="bad"; RESULT_REASON="keyring_file unset"
            elif [[ ! -r "$kf" ]]; then
                RESULT_STATUS="bad"; RESULT_REASON="keyring missing: ${apr_kf}"
            elif [[ -z "$apr_kfp" ]]; then
                RESULT_STATUS="bad"; RESULT_REASON="key_fingerprint unset"
            else
                local got
                got=$(fingerprint_of "$kf" || true)
                if [[ -z "$got" ]]; then
                    RESULT_STATUS="bad"; RESULT_REASON="cannot read fingerprint from ${apr_kf}"
                elif [[ "${got^^}" != "${apr_kfp^^}" ]]; then
                    RESULT_STATUS="bad"; RESULT_REASON="key_fingerprint mismatch (got ${got})"
                fi
            fi
            if [[ "$RESULT_STATUS" == "ok" ]]; then
                if [[ -z "$apr_sf" ]]; then
                    RESULT_STATUS="bad"; RESULT_REASON="sources_file unset"
                elif [[ ! -r "$sf" ]]; then
                    RESULT_STATUS="bad"; RESULT_REASON="sources missing: ${apr_sf}"
                fi
            fi
            # track-latest mode: file-on-disk integrity is the whole
            # check.  apt manages versions upstream so there's no
            # per-version pin to verify.  Frozen mode would normally
            # add per-version checks here too, but for apt-pinned-repo
            # the version still lives in apt's package metadata (not
            # the manifest), so frozen on this method is purely a
            # "we audited the key on this date" annotation — same
            # disk-side check.
            ;;
        github-release)
            # In track-latest mode there is no pinned version/sha by
            # design (validator forbids them).  Skip per-version
            # verification; freshness check below still applies.
            if [[ "$pin_mode" == "track-latest" ]]; then
                : # waive per-version checks
            else
                # frozen (or unspecified) mode — full check.
                # Arch-relevant SHA must be present.  An "x86_64-only"
                # app signals that by leaving sha256_aarch64 empty AND
                # vice versa.
                local need_sha=""
                case "$ARCH_KEY" in
                    sha256_x86_64)  need_sha="$gh_sha_x" ;;
                    sha256_aarch64) need_sha="$gh_sha_a" ;;
                esac
                if [[ -z "$need_sha" ]]; then
                    RESULT_STATUS="bad"; RESULT_REASON="missing ${ARCH_KEY} for this arch"
                elif [[ ${#need_sha} -ne 64 ]]; then
                    RESULT_STATUS="bad"; RESULT_REASON="${ARCH_KEY} is not 64 hex chars"
                elif [[ -n "$gh_install_to" && -f "$gh_install_to" ]]; then
                    local got
                    got=$(sha256sum "$gh_install_to" 2>/dev/null | awk '{print $1}')
                    if [[ -n "$got" && "${got,,}" != "${need_sha,,}" ]]; then
                        RESULT_STATUS="bad"; RESULT_REASON="on-disk sha mismatch at ${gh_install_to}"
                    fi
                fi
                # Signature check — only meaningful in frozen mode AND
                # when the upstream actually signs releases.  Empty
                # fingerprint = "no signature check" by convention.
                # We can only verify when both the install_to artifact
                # and a *.sig / *.asc sibling are present; otherwise
                # this is informational.
                if [[ "$RESULT_STATUS" == "ok" && -n "$gh_gpg_fp" \
                      && -n "$gh_install_to" && -f "$gh_install_to" ]]; then
                    local sig=""
                    for ext in .sig .asc; do
                        if [[ -f "${gh_install_to}${ext}" ]]; then
                            sig="${gh_install_to}${ext}"; break
                        fi
                    done
                    if [[ -n "$sig" ]]; then
                        # gpg_verify_pinned isolates the keyring to
                        # /dev/null so the user's default keyring can't
                        # smuggle in a trusted-but-wrong-fpr key.  It
                        # returns a short status string on stdout AND
                        # an exit code; we surface the status as the
                        # reason on failure.  See the helper's
                        # function-level comment for the trust model.
                        local sig_status sig_rc=0
                        sig_status="$(gpg_verify_pinned "$sig" "$gh_install_to" "$gh_gpg_fp")" || sig_rc=$?
                        if (( sig_rc != 0 )); then
                            RESULT_STATUS="bad"
                            RESULT_REASON="signature verification failed: ${sig_status}"
                        fi
                    fi
                fi
            fi
            ;;
        direct-deb)
            # direct-deb is frozen by contract (validator-enforced).
            # We can't re-hash the .deb (it's removed after dpkg -i),
            # so the best evidence we have is "url + sha + version are
            # all present" plus a best-effort installed-version probe.
            # An installed-but-wrong-version state is treated as ok
            # with reason "version-drift" — not bad, because the user
            # may have intentionally apt-pinned a newer build; the
            # refresh workflow catches this honestly.
            if [[ -z "$dd_url" ]]; then
                RESULT_STATUS="bad"; RESULT_REASON="direct_deb.url unset"
            elif [[ -z "$dd_sha" ]]; then
                RESULT_STATUS="bad"; RESULT_REASON="direct_deb.sha256 unset"
            elif [[ ${#dd_sha} -ne 64 ]]; then
                RESULT_STATUS="bad"; RESULT_REASON="direct_deb.sha256 is not 64 hex chars"
            elif [[ -z "$dd_version" ]]; then
                RESULT_STATUS="bad"; RESULT_REASON="direct_deb.version unset"
            elif [[ -n "$name" ]]; then
                local inst_ver
                inst_ver=$(dpkg-query -W -f='${Version}' "$name" 2>/dev/null || true)
                if [[ -z "$inst_ver" ]]; then
                    RESULT_REASON="not-installed"
                elif [[ "$inst_ver" == "$dd_version" ]]; then
                    RESULT_REASON="version-matches"
                else
                    RESULT_REASON="version-drift (installed=${inst_ver}, pinned=${dd_version})"
                fi
            fi
            ;;
        "")
            RESULT_STATUS="bad"; RESULT_REASON="install.method unset"
            ;;
        *)
            RESULT_STATUS="bad"; RESULT_REASON="unknown install.method: ${method}"
            ;;
    esac

    # ── 2. Freshness — only relevant if last_refreshed + refresh_after_days
    #      are present AND we haven't already marked the entry bad.
    #      In track-latest mode the date is purely informational ("we
    #      last audited") so the same staleness threshold applies.
    if [[ -n "$pin_last" && -n "$pin_refresh_days" ]]; then
        local d
        d=$(days_since "$pin_last")
        RESULT_DAYS_OLD="$d"
        if [[ "$RESULT_STATUS" == "ok" && "$d" -gt "$pin_refresh_days" ]]; then
            RESULT_STATUS="stale"
            RESULT_REASON="${d}d old (threshold ${pin_refresh_days}d)"
        fi
    fi
}

# ── Driver ─────────────────────────────────────────────────────────
if [[ ! -d "$APPS_DIR" ]]; then
    log "no apps configured (${APPS_DIR} missing)"
    exit 0
fi

ENTRIES="$(load_entries)"
if [[ -z "$ENTRIES" ]]; then
    if [[ -n "$ONLY_APP" ]]; then
        err "no [[apps]] entry matched --app ${ONLY_APP}"
        exit 3
    fi
    log "no apps configured"
    exit 0
fi

# If --app was passed, filter the TSV stream by the schema-v2 `name`
# field BEFORE invoking the verifier (so a missing name shows as exit
# 3, not exit 0 with empty output).
if [[ -n "$ONLY_APP" ]]; then
    FILTERED=""
    while IFS=$'\t' read -r _src _idx entry_json; do
        [[ -n "$entry_json" ]] || continue
        probe_name="$(json_get "$entry_json" 'name')"
        if [[ "$probe_name" == "$ONLY_APP" ]]; then
            FILTERED+="${_src}"$'\t'"${_idx}"$'\t'"${entry_json}"$'\n'
        fi
    done <<<"$ENTRIES"
    if [[ -z "$FILTERED" ]]; then
        err "no [[apps]] entry matched --app ${ONLY_APP}"
        exit 3
    fi
    ENTRIES="$FILTERED"
fi

worst=0   # 0 ok, 1 stale, 2 bad — monotonic; only ever increases.
first_json=1
[[ $MODE_JSON -eq 0 ]] || printf '['

while IFS=$'\t' read -r src_file _entry_idx entry_json; do
    [[ -n "$entry_json" ]] || continue
    verify_entry "$entry_json"

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
    "pin_mode": sys.argv[7],
}))' "$RESULT_NAME" "$RESULT_METHOD" "$RESULT_STATUS" "$RESULT_REASON" \
   "$RESULT_LAST_REFRESHED" "$RESULT_DAYS_OLD" "$RESULT_PIN_MODE"
    else
        # Fixed-width column layout — name 20, days 4, method 18, reason free-form.
        case "$RESULT_STATUS" in
            ok)    tag="${C_OK}[ok]${C_RST}   " ;;
            stale) tag="${C_WARN}[stale]${C_RST}" ;;
            bad)   tag="${C_ERR}[bad]${C_RST}  " ;;
            *)     tag="[?]   " ;;
        esac
        printf '%b %-20s %3sd %-18s %s\n' \
            "$tag" "$RESULT_NAME" "$RESULT_DAYS_OLD" "$RESULT_METHOD" "$RESULT_REASON"
    fi
done <<<"$ENTRIES"

[[ $MODE_JSON -eq 0 ]] || printf ']\n'

# Strict-fresh: stale promotes to bad for cron use.  Default mode keeps
# the distinction so interactive users see "stale but verified" clearly.
if [[ $STRICT_FRESH -eq 1 && $worst -eq 1 ]]; then
    worst=2
fi
exit "$worst"
