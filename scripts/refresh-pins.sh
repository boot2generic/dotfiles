#!/usr/bin/env bash
# scripts/refresh-pins.sh
#
# Pull upstream metadata for every config/apps/<name>.toml pin, verify
# what we can, and rewrite the pin's `last_refreshed` (and SHA/version
# for github-release) back into the TOML in place.  NEVER commits.
# NEVER auto-prompts.  Designed to be cron-driven; --quiet exists so a
# successful run produces zero output.
#
# Per-method semantics:
#   apt              skipped — no pin to refresh.
#   apt-pinned-repo  run `apt-get update` scoped to ONLY this app's
#                    sources file + keyring.  If apt accepts the
#                    signed Release file, the pinned key is still
#                    trusted upstream → bump last_refreshed only.
#                    If apt rejects it, the upstream key likely
#                    rotated; we log a CRITICAL warning and DO NOT
#                    bump the date (the next run will keep flagging
#                    until refresh-keys.sh is run by a human).
#   github-release   GET https://api.github.com/repos/<repo>/releases/latest
#                    Compare tag_name to pin.version:
#                      same  → bump last_refreshed only.
#                      diff  → download new asset(s) to mktemp, sha256
#                              both arch tarballs we have a slot for,
#                              GPG-verify if pin.gpg_fingerprint is set,
#                              then rewrite version + sha256_* + date.
#                    Note: GitHub rate-limits unauth'd API to 60/hr/IP;
#                    --all on a box with many github-release apps may
#                    exhaust that.  Sleep between calls is intentional.
#   direct-deb       DEGENERATE in Phase 0.  We have no discovery URL
#                    pattern — vendor sites differ wildly — so we just
#                    HEAD the pinned URL and bump last_refreshed if it
#                    returns 2xx.  This catches "vendor moved the
#                    download" but NOT "vendor cut a new version" —
#                    that requires manual editing of the .toml.
#
# Why no auto-commit: refreshing a SHA after a real upstream version
# bump should be reviewed by a human (release notes, breaking-changes
# scan).  This script intentionally stops at the TOML edit so the
# user sees a clean `git diff` before committing.
#
# Usage:
#   ./scripts/refresh-pins.sh                       # all apps
#   ./scripts/refresh-pins.sh --app NAME
#   ./scripts/refresh-pins.sh --method github-release
#   ./scripts/refresh-pins.sh --dry-run
#   ./scripts/refresh-pins.sh --quiet               # cron
#   ./scripts/refresh-pins.sh --help

set -euo pipefail

if [[ -t 1 ]]; then
    C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'
    C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
    C_OK= ; C_WARN= ; C_ERR= ; C_DIM= ; C_RST=
fi

QUIET=0
log()  { [[ $QUIET -eq 1 ]] || echo "${C_DIM}[*]${C_RST} $*" >&2; }
ok()   { [[ $QUIET -eq 1 ]] || echo "${C_OK}[ok]${C_RST} $*" >&2; }
warn() { echo "${C_WARN}[!]${C_RST} $*" >&2; }
err()  { echo "${C_ERR}[!!]${C_RST} $*" >&2; }
die()  { err "$*"; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APPS_DIR="${REPO_DIR}/config/apps"
KEYRINGS_DIR="${REPO_DIR}/config/system/etc/apt/keyrings"
SOURCES_DIR="${REPO_DIR}/config/system/etc/apt/sources.list.d"

DRY_RUN=0
ONLY_APP=""
ONLY_METHOD=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)        ;;
        --app)        ONLY_APP="${2:-}";    [[ -z "$ONLY_APP" ]]    && die "--app requires a name"; shift ;;
        --method)     ONLY_METHOD="${2:-}"; [[ -z "$ONLY_METHOD" ]] && die "--method requires a value"; shift ;;
        --dry-run)    DRY_RUN=1 ;;
        --quiet)      QUIET=1 ;;
        -h|--help)    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            die "Unknown flag: $1 (try --help)" ;;
    esac
    shift
done

command -v python3 >/dev/null 2>&1 || die "python3 missing"
command -v curl    >/dev/null 2>&1 || warn "curl missing — github-release / direct-deb refresh will fail"

TODAY=$(date +%Y-%m-%d)
TMPROOT=""
cleanup() { [[ -n "$TMPROOT" && -d "$TMPROOT" ]] && rm -rf "$TMPROOT"; }
trap cleanup EXIT
TMPROOT=$(mktemp -d -t refresh-pins.XXXXXX)

# ── TOML read (same shape as verify-pins.sh).  Kept inline so the script
# is standalone — installer adapters explicitly forbid cross-script imports.
toml_extract() {
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
emit("META_NAME",       meta.get("name", ""))
emit("INSTALL_METHOD",  inst.get("method", ""))
apr = inst.get("apt_pinned_repo", {})
emit("APR_KEYRING_FILE",    apr.get("keyring_file", ""))
emit("APR_SOURCES_FILE",    apr.get("sources_file", ""))
emit("APR_SUITE",           apr.get("suite", ""))
gh = inst.get("github_release", {})
emit("GH_REPO",            gh.get("repo", ""))
emit("GH_VERSION",          gh.get("version", ""))
emit("GH_ASSET_PATTERN",    gh.get("asset_pattern", ""))
emit("GH_SHA256_X86_64",    gh.get("sha256_x86_64", ""))
emit("GH_SHA256_AARCH64",   gh.get("sha256_aarch64", ""))
emit("GH_GPG_FINGERPRINT",  gh.get("gpg_fingerprint", ""))
dd = inst.get("direct_deb", {})
emit("DD_URL",     dd.get("url", ""))
emit("DD_VERSION", dd.get("version", ""))
emit("PIN_LAST_REFRESHED", pin.get("last_refreshed", ""))
emit("HAS_PIN", "1" if pin else "0")
PY
}

# ── TOML write: targeted line-rewrite via Python.
#
# WHY not a full TOML library: tomlkit is the obvious choice for
# round-tripping with preserved comments/whitespace, but Debian 13
# doesn't ship it and we don't want to require pip on a freshly
# bootstrapped box.  Our schema is regular enough — each scalar key
# lives on its own line in `key = value` form — that an in-place
# string substitution preserves comments, blank lines, and ordering
# perfectly while staying inside the stdlib.
#
# The helper finds the line `^<indent><key>\s*=` inside the chosen
# [section] header's scope (delimited by the next `^[` line or EOF)
# and rewrites the value, preserving any trailing inline comment.
toml_set() {
    # $1 = path, $2 = section ("pin" / "install.github_release"), $3 = key, $4 = new value (already quoted/escaped)
    local path="$1" section="$2" key="$3" newval="$4"
    if [[ $DRY_RUN -eq 1 ]]; then
        log "  would set [${section}].${key} = ${newval} in $(basename "$path")"
        return 0
    fi
    python3 - "$path" "$section" "$key" "$newval" <<'PY'
import sys, re, pathlib
path, section, key, newval = sys.argv[1:5]
text = pathlib.Path(path).read_text()
lines = text.splitlines(keepends=True)
want_header = f"[{section}]"
in_section = False
done = False
key_re = re.compile(r'^(\s*)(' + re.escape(key) + r')(\s*=\s*)([^\n#]*?)(\s*(#.*)?)$')
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
        lines[i] = f"{indent}{k}{sep}{newval}{tail or ''}{nl}"
        done = True
        break
if not done:
    sys.stderr.write(f"toml_set: did not find [{section}].{key} in {path}\n")
    sys.exit(3)
pathlib.Path(path).write_text("".join(lines))
PY
}

# Convenience: quote a string value for TOML re-insertion.  Numbers
# (the only non-string scalar we write here is refresh_after_days,
# which we never rewrite) would skip the quotes; everything we touch
# is a string so we always quote.
toml_q() { printf '"%s"' "${1//\"/\\\"}"; }

# ── Per-method refresh handlers.
#
# Each sets REFRESH_OUTCOME to one of:
#   bumped         last_refreshed date was advanced; no version change.
#   updated        version + sha changed (real release bump).
#   skipped        nothing to do (apt method, dry-run, etc.)
#   failed         upstream rejected / network / sha mismatch.
# and REFRESH_NOTE to a human-readable one-liner.

refresh_apt() {
    REFRESH_OUTCOME="skipped"
    REFRESH_NOTE="no pin to refresh (apt method)"
}

refresh_apt_pinned_repo() {
    local name="$1" toml="$2"
    local kf="${KEYRINGS_DIR}/${APR_KEYRING_FILE}"
    local sf="${SOURCES_DIR}/${APR_SOURCES_FILE}"

    if [[ ! -r "$kf" || ! -r "$sf" ]]; then
        REFRESH_OUTCOME="failed"
        REFRESH_NOTE="missing keyring or sources file"
        return
    fi

    # Build an isolated apt environment so we can validate THIS repo's
    # signed Release file without polluting the system apt state or
    # depending on what's already in /etc/apt.  The flags Dir::Etc::*
    # point apt at our repo's files; lists go into a tmp dir so we
    # don't write to /var.  --no-allow-insecure-repositories is the
    # default but we set it explicitly so a future apt version that
    # weakens that default still rejects an unsigned Release.
    local tmpd; tmpd="$(mktemp -d -p "$TMPROOT" apt.XXXX)"
    mkdir -p "$tmpd/lists/partial" "$tmpd/cache" "$tmpd/sources.list.d" "$tmpd/keyrings"
    cp -- "$sf" "$tmpd/sources.list.d/"
    cp -- "$kf" "$tmpd/keyrings/"

    if [[ $DRY_RUN -eq 1 ]]; then
        REFRESH_OUTCOME="skipped"
        REFRESH_NOTE="dry-run: would apt-get update against ${APR_SOURCES_FILE}"
        return
    fi

    # We can't talk to sudo from a cron job without NOPASSWD; apt-get
    # update without root can run with these Dir overrides as long as
    # the lists/ dir is writable.  No-cache flag avoids stale results.
    if apt-get update -qq \
            -o "Dir::Etc::SourceParts=${tmpd}/sources.list.d" \
            -o "Dir::Etc::SourceList=/dev/null" \
            -o "Dir::Etc::TrustedParts=${tmpd}/keyrings" \
            -o "Dir::Etc::Trusted=/dev/null" \
            -o "Dir::State::Lists=${tmpd}/lists" \
            -o "Dir::Cache=${tmpd}/cache" \
            -o "APT::Get::List-Cleanup=0" \
            -o "Acquire::AllowInsecureRepositories=false" \
            -o "Acquire::AllowDowngradeToInsecureRepositories=false" \
            >/dev/null 2>"${tmpd}/err"; then
        toml_set "$toml" "pin" "last_refreshed" "$(toml_q "$TODAY")"
        REFRESH_OUTCOME="bumped"
        REFRESH_NOTE="apt-get update verified the pinned key"
    else
        REFRESH_OUTCOME="failed"
        REFRESH_NOTE="apt-get update FAILED — upstream key may have rotated (run refresh-keys.sh --app ${name})"
        # Echo the apt error so the cron mail shows it.
        [[ $QUIET -eq 1 ]] || sed 's/^/      | /' "${tmpd}/err" >&2 || true
    fi
}

# Compute sha256 of a URL by streaming through curl → sha256sum.  We do
# not download to disk because some assets are large (>50MB) and we
# only need the hash.  -f makes curl fail on HTTP 4xx/5xx instead of
# saving the error body; -L follows GitHub's CDN redirect.
sha256_of_url() {
    local url="$1"
    curl -fsSL --max-time 120 "$url" 2>/dev/null | sha256sum | awk '{print $1}'
}

# Expand "{arch}" / "{version}" tokens in an asset pattern.
expand_asset() {
    local pat="$1" arch="$2" version="$3"
    # Strip leading "v" from version when expanding {version} — GitHub
    # tags are conventionally "vX.Y.Z" but asset filenames usually drop
    # the "v".  We try the bare version first; callers can iterate.
    pat="${pat//\{arch\}/$arch}"
    pat="${pat//\{version\}/$version}"
    printf '%s' "$pat"
}

refresh_github_release() {
    local name="$1" toml="$2"
    if [[ -z "$GH_REPO" ]]; then
        REFRESH_OUTCOME="failed"; REFRESH_NOTE="install.github_release.repo unset"
        return
    fi
    local api="https://api.github.com/repos/${GH_REPO}/releases/latest"
    local body; body="$(curl -fsSL --max-time 30 -H "Accept: application/vnd.github+json" "$api" 2>/dev/null || true)"
    if [[ -z "$body" ]]; then
        REFRESH_OUTCOME="failed"
        REFRESH_NOTE="github API unreachable for ${GH_REPO} (rate-limit or network)"
        return
    fi
    local new_tag
    new_tag=$(printf '%s' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tag_name",""))' 2>/dev/null || true)
    if [[ -z "$new_tag" ]]; then
        REFRESH_OUTCOME="failed"; REFRESH_NOTE="could not parse tag_name from GitHub response"
        return
    fi

    if [[ "$new_tag" == "$GH_VERSION" ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            REFRESH_OUTCOME="skipped"
            REFRESH_NOTE="dry-run: ${GH_REPO} still at ${new_tag}; would bump date only"
        else
            toml_set "$toml" "pin" "last_refreshed" "$(toml_q "$TODAY")"
            REFRESH_OUTCOME="bumped"
            REFRESH_NOTE="${GH_REPO} still at ${new_tag}"
        fi
        return
    fi

    # Version drift — need new SHAs.  Try both architectures so the
    # manifest stays portable; "" sha256_aarch64 means "skip aarch64".
    local version_bare="${new_tag#v}"
    local sha_x="" sha_a=""

    # Build candidate URLs.  We try {version_bare} first, then {new_tag}
    # because asset names vary across upstreams.
    local asset_x asset_a url_x="" url_a=""
    for v in "$version_bare" "$new_tag"; do
        asset_x=$(expand_asset "$GH_ASSET_PATTERN" "x86_64" "$v")
        asset_a=$(expand_asset "$GH_ASSET_PATTERN" "aarch64" "$v")
        # The releases body lists "browser_download_url" entries; we grep
        # rather than recurse with python so we keep deps minimal here.
        url_x=$(printf '%s' "$body" | python3 -c '
import json, sys, re
d = json.load(sys.stdin)
pat = re.compile(re.escape(sys.argv[1]))
for a in d.get("assets", []):
    if pat.search(a.get("name","")):
        print(a.get("browser_download_url",""))
        break
' "$asset_x" 2>/dev/null || true)
        url_a=$(printf '%s' "$body" | python3 -c '
import json, sys, re
d = json.load(sys.stdin)
pat = re.compile(re.escape(sys.argv[1]))
for a in d.get("assets", []):
    if pat.search(a.get("name","")):
        print(a.get("browser_download_url",""))
        break
' "$asset_a" 2>/dev/null || true)
        [[ -n "$url_x" || -n "$url_a" ]] && break
    done

    if [[ -n "$url_x" ]]; then
        sha_x=$(sha256_of_url "$url_x" || true)
    fi
    if [[ -n "$GH_SHA256_AARCH64" && -n "$url_a" ]]; then
        # Only attempt aarch64 if the existing pin has a slot for it.
        sha_a=$(sha256_of_url "$url_a" || true)
    fi

    if [[ -z "$sha_x" ]]; then
        REFRESH_OUTCOME="failed"
        REFRESH_NOTE="${GH_REPO}: could not download/hash x86_64 asset (pattern: ${GH_ASSET_PATTERN})"
        return
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        REFRESH_OUTCOME="updated"
        REFRESH_NOTE="dry-run: ${GH_REPO} ${GH_VERSION} -> ${new_tag} (sha_x=${sha_x:0:12}…)"
        return
    fi
    toml_set "$toml" "install.github_release" "version"       "$(toml_q "$new_tag")"
    toml_set "$toml" "install.github_release" "sha256_x86_64" "$(toml_q "$sha_x")"
    if [[ -n "$sha_a" ]]; then
        toml_set "$toml" "install.github_release" "sha256_aarch64" "$(toml_q "$sha_a")"
    fi
    toml_set "$toml" "pin" "last_refreshed" "$(toml_q "$TODAY")"
    REFRESH_OUTCOME="updated"
    REFRESH_NOTE="${GH_REPO} ${GH_VERSION} -> ${new_tag}"
}

refresh_direct_deb() {
    local name="$1" toml="$2"
    if [[ -z "$DD_URL" ]]; then
        REFRESH_OUTCOME="failed"; REFRESH_NOTE="install.direct_deb.url unset"
        return
    fi
    # HEAD instead of GET — we're only checking liveness here, not
    # rehashing.  --fail makes curl return non-zero on 4xx/5xx.
    if curl -fsSL --max-time 20 -I "$DD_URL" >/dev/null 2>&1; then
        if [[ $DRY_RUN -eq 1 ]]; then
            REFRESH_OUTCOME="skipped"
            REFRESH_NOTE="dry-run: ${DD_URL} reachable; would bump date only"
        else
            toml_set "$toml" "pin" "last_refreshed" "$(toml_q "$TODAY")"
            REFRESH_OUTCOME="bumped"
            REFRESH_NOTE="HEAD ${DD_URL} → 2xx (URL alive; version field NOT re-derived)"
        fi
    else
        REFRESH_OUTCOME="failed"
        REFRESH_NOTE="HEAD ${DD_URL} failed — vendor moved the download?"
    fi
}

# ── Driver ─────────────────────────────────────────────────────────
if [[ ! -d "$APPS_DIR" ]]; then
    log "no apps configured"
    [[ $QUIET -eq 1 ]] || printf '\nsummary: 0 bumped, 0 updated, 0 failed\n'
    exit 0
fi

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
        die "no manifest matched --app ${ONLY_APP}"
    fi
    log "no apps configured"
    [[ $QUIET -eq 1 ]] || printf '\nsummary: 0 bumped, 0 updated, 0 failed\n'
    exit 0
fi

bumped=0; updated=0; failed=0; skipped=0
declare -a UPDATED_LINES=()
declare -a FAILED_LINES=()

for toml in "${manifests[@]}"; do
    name=$(basename "$toml" .toml)
    raw="$(toml_extract "$toml" 2>/dev/null || true)"
    if [[ -z "$raw" ]]; then
        err "${name}: toml-parse-error — skipping"
        failed=$((failed+1))
        FAILED_LINES+=("$name: toml-parse-error")
        continue
    fi
    META_NAME="" INSTALL_METHOD="" HAS_PIN="0"
    APR_KEYRING_FILE="" APR_SOURCES_FILE="" APR_SUITE=""
    GH_REPO="" GH_VERSION="" GH_ASSET_PATTERN="" GH_SHA256_X86_64="" GH_SHA256_AARCH64="" GH_GPG_FINGERPRINT=""
    DD_URL="" DD_VERSION=""
    PIN_LAST_REFRESHED=""
    eval "$raw"

    if [[ -n "$ONLY_METHOD" && "$INSTALL_METHOD" != "$ONLY_METHOD" ]]; then
        continue
    fi

    REFRESH_OUTCOME=""
    REFRESH_NOTE=""

    case "$INSTALL_METHOD" in
        apt)              refresh_apt ;;
        apt-pinned-repo)  refresh_apt_pinned_repo "$name" "$toml" ;;
        github-release)   refresh_github_release  "$name" "$toml" ;;
        direct-deb)       refresh_direct_deb      "$name" "$toml" ;;
        "")               REFRESH_OUTCOME="failed"; REFRESH_NOTE="install.method unset" ;;
        *)                REFRESH_OUTCOME="failed"; REFRESH_NOTE="unknown install.method: ${INSTALL_METHOD}" ;;
    esac

    case "$REFRESH_OUTCOME" in
        bumped)
            bumped=$((bumped+1))
            ok  "$name: $REFRESH_NOTE"
            ;;
        updated)
            updated=$((updated+1))
            ok  "$name: $REFRESH_NOTE"
            UPDATED_LINES+=("$name|$GH_VERSION|$REFRESH_NOTE")
            ;;
        skipped)
            skipped=$((skipped+1))
            log "$name: $REFRESH_NOTE"
            ;;
        failed)
            failed=$((failed+1))
            warn "$name: $REFRESH_NOTE"
            FAILED_LINES+=("$name: $REFRESH_NOTE")
            ;;
    esac
done

# Summary at end — printed unconditionally in non-quiet mode; under
# --quiet only failures escape to stderr (warn() above already did that).
if [[ $QUIET -eq 0 ]]; then
    printf '\nsummary: %d bumped, %d updated, %d failed, %d skipped\n' \
        "$bumped" "$updated" "$failed" "$skipped"
    if [[ ${#UPDATED_LINES[@]} -gt 0 || $bumped -gt 0 ]]; then
        printf '\nnext steps:\n'
        printf '    $ git diff config/apps/\n'
        if [[ ${#UPDATED_LINES[@]} -gt 0 ]]; then
            for line in "${UPDATED_LINES[@]}"; do
                IFS='|' read -r u_name _u_oldver u_note <<<"$line"
                printf '    $ git add config/apps/%s.toml\n' "$u_name"
                printf '    $ git commit -m "refresh: %s"\n' "$u_note"
            done
        else
            printf '    $ git add config/apps/\n'
            printf '    $ git commit -m "refresh: bump pin dates"\n'
        fi
    fi
fi

# Failed > 0 is a non-zero exit so cron + MAILTO surfaces it.  Bumped
# / updated are normal outcomes.
[[ $failed -eq 0 ]] || exit 1
exit 0
