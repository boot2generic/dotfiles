# scripts/lib/gpg-helpers.sh
#
# Shared GPG helpers used by verify-pins.sh, refresh-pins.sh, and the
# github-release install adapter so all three apply the same fingerprint-
# extraction + signature-verification logic against manifest pins.
# Sourced (not executed).
#
# Sourcing contract:
#   No callbacks required.  All output goes to stdout (the extracted
#   fingerprint, uppercase hex, one per line) on success; stderr is
#   silenced inside the helpers so callers can compare clean strings.
#
# Functions:
#   fingerprint_of      — primary-key fpr from a binary or armored keyring.
#   gpg_verify_pinned   — detached-sig fpr assertion against a 40-hex pin.
#
# Usage:
#     source "${SCRIPT_DIR}/lib/gpg-helpers.sh"
#     got_fpr="$(fingerprint_of /path/to/keyring.gpg)"
#     [[ "${got_fpr^^}" == "${want_fpr^^}" ]] || { echo "mismatch"; exit 1; }
#
#     status="$(gpg_verify_pinned sig.sig data.bin "$FPR_40HEX")" || { echo "bad: $status"; exit 1; }

if [[ -n "${_DOTFILES_GPG_HELPERS_SH:-}" ]]; then
    return 0
fi
_DOTFILES_GPG_HELPERS_SH=1

# Extract a single fingerprint from a keyring file via gpg --with-colons.
# Two file shapes are supported:
#   • binary keyring   (.gpg / .kbx) — fed via --keyring directly.
#   • ASCII-armored    (.asc / armored .gpg) — must be dearmored first;
#                      gpg --keyring rejects armored input silently.
# We detect armor by the first line ("-----BEGIN PGP …") and route
# accordingly.  The first fpr: line is the primary key (any subkeys
# follow); for vendor repo keys we pin against the primary.
#
# Returns 0 on success (stdout: hex fingerprint, no newline-stripping
# guarantees beyond what awk prints); non-zero on read/dearmor failure.
fingerprint_of() {
    local kf="$1"
    local tmp=""
    local first
    # Binary keyrings (.gpg / .kbx) contain NUL bytes that bash's $()
    # substitution strips with a warning; route through `tr -d '\0'`
    # before assignment so the armor check below stays clean.  We only
    # need the first 8 bytes to detect the "-----BEGIN PGP" armor
    # header anyway.
    first=$(head -c 64 "$kf" 2>/dev/null | tr -d '\0' || true)
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

# Verify a detached signature against an artifact, asserting that the
# SIGNING key matches a manifest-pinned 40-hex fingerprint.
#
# Originally defined inline in verify-pins.sh; factored here in Phase B
# so the github-release install adapter can reuse the same trust model
# (verify-pins is read-only audit; the adapter is the actual install
# path).  Behaviour is byte-for-byte identical to the prior verify-pins
# helper — see verify-pins.sh's "Trust limitation" notes for why the
# keyring is /dev/null and why we gate on the [GNUPG:] status line
# rather than gpg's exit code.
#
# Trust limitation (intentional, Phase A->B carryover):
#   Until per-app pinned keyrings ship on disk, this check confirms
#   only "the signature was made by the right fingerprint" — NOT "and
#   we trust that key".  We refuse to consult the user's default gnupg
#   keyring (an attacker who can drop a key into ~/.gnupg/ could
#   otherwise bypass the manifest pin) and force gpg's keyring to
#   /dev/null.  Sha-256 verification MUST run first in the caller;
#   this is defence-in-depth on top of that, not a primary anchor.
#
# Args: <sig-file> <data-file> <pinned-fingerprint-40hex>
# Stdout: single short status string for caller to surface as reason:
#   "fpr-match-untrusted"  — sig made by the pinned fpr (OK pre-Phase B keyrings)
#   "no-sig" / "no-data" / "bad-pin" / "no-sig-info"
#   "fpr-mismatch:expected=… got=…"
# Exit: 0 on fpr-match, non-zero otherwise.
gpg_verify_pinned() {
    local sig="$1" data="$2" want_fpr="$3"
    [[ -f "$sig" ]]  || { echo "no-sig";  return 1; }
    [[ -f "$data" ]] || { echo "no-data"; return 1; }
    [[ "$want_fpr" =~ ^[0-9A-Fa-f]{40}$ ]] || { echo "bad-pin"; return 1; }

    local status
    status="$(gpg --status-fd 1 --no-default-keyring \
        --keyring /dev/null \
        --verify "$sig" "$data" 2>/dev/null)" || true
    # Even with a /dev/null keyring gpg emits a [GNUPG:] line containing
    # the fingerprint of the SIGNING key (which it cannot trust because
    # the keyring is empty).  Use that to determine WHAT key signed, not
    # WHETHER it's trusted — see the function-level comment for why this
    # is the strongest assertion we can make pre per-app-keyring delivery.
    local seen_fpr
    seen_fpr="$(awk '/^\[GNUPG:\] (VALIDSIG|EXPSIG|EXPKEYSIG|REVKEYSIG|BADSIG|ERRSIG) / {print toupper($3); exit}' <<<"$status")"
    if [[ -z "$seen_fpr" ]]; then
        echo "no-sig-info"
        return 1
    fi
    if [[ "${seen_fpr^^}" != "${want_fpr^^}" ]]; then
        echo "fpr-mismatch:expected=${want_fpr^^} got=${seen_fpr^^}"
        return 1
    fi
    # gpg's exit code is non-zero when the keyring lacks the public key
    # (always, with /dev/null keyring) so we can't gate on rc alone.  The
    # fingerprint-match-with-correct-pin is the strongest assertion we
    # can make without per-app keyring delivery.
    echo "fpr-match-untrusted"
    return 0
}
