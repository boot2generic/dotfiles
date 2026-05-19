#!/usr/bin/env bash
# /usr/lib/systemd/system-sleep/cyberpunk-suspend.sh
#
# Suspend/resume hygiene hook for Plasma 6 / Wayland on the T14.
#
# WHY this exists (not "what it does"):
#
#   1. The T14 USB-C / Thunderbolt 3 dock occasionally fails to
#      re-enumerate after resume.  Symptoms: laptop wakes, external
#      monitors stay black, kscreen / kwin_wayland never receive a hotplug
#      event.  Manual workaround is `systemctl --user restart
#      plasma-kscreen.service`, which kicks KScreen into reading DRM
#      outputs again.  Doing it automatically saves the user the
#      "everything looks fine, why is my dock dead" diagnosis.
#
#   2. Even when the dock re-enumerates cleanly, there is no breadcrumb
#      in the journal showing what changed across suspend.  Snapshotting
#      outputs pre+post and logging the diff under a single tag
#      (`journalctl -t cyberpunk-suspend`) gives the user something to
#      grep when "the monitors did the thing again."
#
# systemd-sleep contract:
#   $1 = pre|post
#   $2 = suspend|hibernate|hybrid-sleep|suspend-then-hibernate
# Anything we write to stderr ends up in the systemd-sleep journal under
# the systemd-suspend.service unit; the explicit `logger -t
# cyberpunk-suspend` tag lets the user filter to just our breadcrumbs.
#
# Failure policy: this script runs WHILE THE KERNEL IS RESUMING.  An
# `errexit` here can stall userspace bring-up.  We `set -u` for typo
# safety but deliberately NOT `set -e`; every failure path is logged and
# swallowed.
set -u

TAG=cyberpunk-suspend
SNAPSHOT=/run/cyberpunk-suspend.json  # tmpfs — wiped on reboot

phase="${1:-?}"
action="${2:-?}"

_log()  { logger -t "$TAG" -- "$*"; }
_warn() { logger -t "$TAG" -p user.warning -- "$*"; }

# Capture currently-connected outputs as a sorted, deduped name list.
# Prefer kscreen-doctor (Plasma's source of truth under Wayland) and fall
# back to wlr-randr / xrandr ONLY for diagnostic completeness — on a
# Plasma Wayland session neither of those tools sees anything useful, but
# they're harmless if missing.
_snapshot_outputs() {
  if command -v kscreen-doctor >/dev/null 2>&1; then
    # `kscreen-doctor -j` requires a session bus.  In the pre-suspend
    # window we *are* still in the user's session (systemd-sleep runs as
    # root but DBUS is reachable via the user's runtime dir).  When
    # called from root with no bus, kscreen-doctor exits non-zero and
    # prints nothing — which we treat as an empty snapshot, intentionally.
    local active_uid runtime
    active_uid="$(_active_graphical_uid)"
    if [[ -n "$active_uid" ]]; then
      runtime="/run/user/${active_uid}"
      runuser -u "#${active_uid}" -- env \
        XDG_RUNTIME_DIR="$runtime" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime}/bus" \
        kscreen-doctor -j 2>/dev/null \
        | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
names = sorted({o.get("name","") for o in d.get("outputs",[]) if o.get("connected")})
print("\n".join(n for n in names if n))
' 2>/dev/null
      return 0
    fi
  fi
  # Fallback chain — empty on a clean Plasma Wayland box.
  if command -v wlr-randr >/dev/null 2>&1; then
    wlr-randr 2>/dev/null | awk '/^[^ ].* "/{print $1}' | sort -u
  elif command -v xrandr >/dev/null 2>&1; then
    DISPLAY=:0 xrandr 2>/dev/null | awk '/ connected /{print $1}' | sort -u
  fi
}

# Which UID owns the active graphical session?  Used both to run
# kscreen-doctor (DBUS reachability) and to restart the user-scoped
# kscreen unit on resume.  Returns empty if no graphical session.
_active_graphical_uid() {
  # `loginctl list-sessions --no-legend` columns: SESSION UID USER SEAT
  # TTY ...  We want a graphical seat (seat0) with an active state and a
  # non-system UID.  The first hit wins — multi-seat T14s don't exist.
  loginctl list-sessions --no-legend 2>/dev/null \
    | awk '$4 ~ /^seat/ && $2 >= 1000 {print $2; exit}'
}

case "$phase" in
  pre)
    _log "pre-${action}: snapshotting outputs to ${SNAPSHOT}"
    # Write atomically — the post hook MUST see either the previous
    # snapshot or the new one, never a half-written file.
    tmp="$(mktemp /run/cyberpunk-suspend.XXXX.json 2>/dev/null || mktemp)"
    {
      printf '{"ts":"%s","action":"%s","outputs":[' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$action"
      _snapshot_outputs | python3 -c '
import json, sys
print(",".join(json.dumps(line) for line in sys.stdin.read().splitlines() if line))
' 2>/dev/null
      printf ']}\n'
    } > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$SNAPSHOT" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    ;;

  post)
    _log "post-${action}: checking for lost outputs"
    if [[ ! -r "$SNAPSHOT" ]]; then
      _log "no pre-snapshot at ${SNAPSHOT} (boot-after-resume? first run?) — skipping diff"
      exit 0
    fi
    pre_outputs="$(python3 -c '
import json, sys
try:
    d = json.load(open("'"$SNAPSHOT"'"))
    print("\n".join(d.get("outputs",[])))
except Exception:
    pass
' 2>/dev/null)"
    post_outputs="$(_snapshot_outputs)"
    # Compute the set: pre - post.  Anything in pre but not in post is
    # an output that VANISHED across suspend — almost always the dock.
    lost="$(comm -23 \
      <(printf '%s\n' "$pre_outputs" | sort -u) \
      <(printf '%s\n' "$post_outputs" | sort -u) 2>/dev/null \
      | tr '\n' ' ')"
    if [[ -n "${lost// }" ]]; then
      _warn "outputs disappeared across ${action}: ${lost}— restarting plasma-kscreen.service"
      uid="$(_active_graphical_uid)"
      if [[ -n "$uid" ]]; then
        # systemctl --user needs DBUS_SESSION_BUS_ADDRESS and
        # XDG_RUNTIME_DIR for the target user.  Best-effort — if the
        # user isn't logged in (e.g. SDDM greeter on resume), there's no
        # user manager to talk to and that's fine.
        runuser -u "#${uid}" -- env \
          XDG_RUNTIME_DIR="/run/user/${uid}" \
          DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
          systemctl --user restart plasma-kscreen.service 2>/dev/null \
          && _log "plasma-kscreen.service restarted for uid=${uid}" \
          || _warn "plasma-kscreen.service restart failed (uid=${uid}) — manual:  systemctl --user restart plasma-kscreen.service"
      else
        _warn "no active graphical session — skipping kscreen restart"
      fi
    else
      _log "outputs match pre-snapshot (no recovery needed): ${post_outputs//$'\n'/ }"
    fi
    ;;

  *)
    _log "unknown phase '${phase}' action '${action}' — ignoring"
    ;;
esac

exit 0
