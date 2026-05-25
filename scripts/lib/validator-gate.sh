# scripts/lib/validator-gate.sh
#
# Shared pre-flight gate that wraps scripts/apps-validate.py.  Sourced
# (not executed) by install-apps.sh, verify-pins.sh, and refresh-pins.sh
# so the three entry points enforce identical schema-validation policy.
#
# The gate's exit-code contract mirrors apps-validate.py itself:
#     0 — clean.  Proceed silently.
#     1 — errors.  Refuse to proceed; surface to caller as exit 1.
#     2 — warnings only.  Log a notice and continue (return 0).
# Any other validator exit (missing interpreter, IO error, ...) is
# treated as fatal so a silent misconfig never reaches per-entry work.
#
# Sourcing contract:
#   The caller MUST define:
#     • err()  — error log helper writing to stderr.
#     • log()  — progress log helper writing to stderr.
#     • warn() — warning log helper writing to stderr.
#   (install-apps.sh, verify-pins.sh, refresh-pins.sh all do.)
#   The library prints via those callbacks so each script's logging
#   style (colour codes, prefixes) stays consistent with its own output.
#
# The --no-validate co-signature gate:
#   --no-validate is a debug-only override.  Even when the caller passes
#   it, we refuse to bypass validation unless DOTFILES_ALLOW_UNVALIDATED=1
#   is ALSO set in the environment.  Two signals so a stray TTY flag /
#   shell-history typo doesn't accidentally unsafe-mode the install.
#
# Usage from a caller script:
#     source "${SCRIPT_DIR}/lib/validator-gate.sh"
#     ...arg parsing sets NO_VALIDATE=0|1...
#     if ! run_apps_validator "$VALIDATOR" "$REPO_DIR" "$NO_VALIDATE"; then
#         exit 1
#     fi

# Guard against double-sourcing.  Multiple scripts in the same shell
# session would otherwise redefine the function; harmless for now but a
# guard keeps things tidy.
if [[ -n "${_DOTFILES_VALIDATOR_GATE_SH:-}" ]]; then
    return 0
fi
_DOTFILES_VALIDATOR_GATE_SH=1

# run_apps_validator <validator-path> <repo-dir> <no-validate-flag>
#
# Returns 0 if the dispatch can continue (clean validate, warnings-only
# validate, or --no-validate with the env co-signature).  Returns 1
# otherwise.  All progress/errors are emitted via the caller's
# err/log/warn helpers so the look-and-feel matches the host script.
run_apps_validator() {
    local validator="$1"
    local repo_dir="$2"
    local no_validate="${3:-0}"

    if (( no_validate )); then
        # Require an explicit env-var co-signature to actually skip the
        # gate.  Stops accidental TTY reuse / shell-history typos from
        # bypassing validation; debugging workflows just export the var
        # once at the start of the session.
        if [[ "${DOTFILES_ALLOW_UNVALIDATED:-0}" != "1" ]]; then
            err "--no-validate refused without DOTFILES_ALLOW_UNVALIDATED=1"
            err "set the env var explicitly if you really mean it (UNSAFE)"
            return 1
        fi
        warn "validator skipped via --no-validate + DOTFILES_ALLOW_UNVALIDATED (UNSAFE)"
        return 0
    fi

    if [[ ! -x "$validator" && ! -r "$validator" ]]; then
        err "validator missing: $validator"
        return 1
    fi

    local rc=0
    if [[ -x "$validator" ]]; then
        "$validator" --root "$repo_dir" || rc=$?
    else
        python3 "$validator" --root "$repo_dir" || rc=$?
    fi
    case "$rc" in
        0) return 0 ;;
        1) err "validator reported errors — refusing to proceed (pass --no-validate to override, UNSAFE)"
           return 1 ;;
        2) log "validator returned warnings — continuing"
           return 0 ;;
        *) err "validator exited with unexpected code $rc"
           return 1 ;;
    esac
}
