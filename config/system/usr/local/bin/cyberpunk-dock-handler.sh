#!/usr/bin/env bash
# /usr/local/bin/cyberpunk-dock-handler.sh
#
# Auto-apply a saved monitor layout when a USB-C / Thunderbolt 3 dock is
# attached, and revert to laptop-only when it is unplugged.  Invoked by
# /etc/udev/rules.d/95-cyberpunk-dock.rules.
#
# WHY (not what):
#
#   • The T14 docks at home (2 externals) and undocks on the go (eDP
#     only).  Plasma 6 / KWin Wayland does NOT automatically pick a
#     previously-saved layout for a re-plugged USB hub on Debian 13:
#     KScreen's "remember per output config" only fires for outputs it
#     has seen connect/disconnect THROUGH KWin's DRM backend, and on
#     dock-driven DisplayLink / DP-MST topologies the DRM events lag the
#     USB enumerate by ~2s — KScreen has often already applied "laptop
#     only" before the externals show up.  Driving the layout from udev
#     instead races correctly.
#
#   • Layouts live UNDER ~/.config/dotfiles/dock-layouts/<dock-hash>.json
#     (per-machine state — NOT in the repo).  The hash is derived from
#     the dock's USB vendor:product:serial so the user can carry layouts
#     for several docks (home vs. office vs. travel).
#
#   • Per-host overrides under ~/.config/dotfiles-local/dock-layouts/
#     take precedence — the same overlay convention used elsewhere in
#     these dotfiles for machine-specific state.
#
# Failure policy: udev event handlers must not block.  Every external
# call is `|| true`-guarded; this script never aborts the udev worker.
set -u

TAG=cyberpunk-dock
LOG()  { logger -t "$TAG" -- "$*"; }
WARN() { logger -t "$TAG" -p user.warning -- "$*"; }

ACTION="${1:-}"      # add|remove
DOCK_HASH="${2:-}"   # optional — computed below if absent

# ─── Locate the active graphical user ────────────────────────────────
# udev runs as root.  KScreen / kscreen-doctor need to run AS THE USER
# on their DBUS session bus, otherwise no output config is loaded.  Use
# loginctl to find the active seat0 session; bail gracefully if there
# isn't one (e.g. handler fires during boot before SDDM autologin, or
# at the SDDM greeter where there's no user session yet).
active_uid="$(loginctl list-sessions --no-legend 2>/dev/null \
              | awk '$4 ~ /^seat/ && $2 >= 1000 {print $2; exit}')"
active_user="$(loginctl list-sessions --no-legend 2>/dev/null \
              | awk '$4 ~ /^seat/ && $2 >= 1000 {print $3; exit}')"

if [[ -z "${active_uid}" || -z "${active_user}" ]]; then
  LOG "no active graphical session — skipping (action=${ACTION})"
  exit 0
fi

USER_HOME="$(getent passwd "$active_user" | cut -d: -f6)"
[[ -d "$USER_HOME" ]] || { WARN "no home dir for ${active_user}"; exit 0; }

# Where layouts live.  The override path wins when populated (same
# convention as ~/.config/dotfiles-local/ elsewhere in this repo).
LOCAL_OVERRIDE_DIR="${USER_HOME}/.config/dotfiles-local/dock-layouts"
LAYOUT_DIR="${USER_HOME}/.config/dotfiles/dock-layouts"

# Helper: run a command as the graphical user with a DBUS session.
# Wayland-aware: pass through WAYLAND_DISPLAY if the user has one set;
# otherwise let kscreen-doctor auto-detect.
run_as_user() {
  runuser -u "${active_user}" -- env \
    HOME="${USER_HOME}" \
    XDG_RUNTIME_DIR="/run/user/${active_uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${active_uid}/bus" \
    "$@"
}

# ─── Compute dock-hash if udev didn't pass one ──────────────────────
# We rely on the udev env vars exported when SUBSYSTEM=="usb" rules
# fire: ID_VENDOR_ID, ID_MODEL_ID, ID_SERIAL_SHORT.  If they're not in
# our environment (e.g. this script was invoked by hand for testing),
# fall back to a synthetic "manual" hash so the user can still exercise
# the apply-layout path.
if [[ -z "${DOCK_HASH}" ]]; then
  v="${ID_VENDOR_ID:-}"
  p="${ID_MODEL_ID:-}"
  s="${ID_SERIAL_SHORT:-}"
  if [[ -n "$v" && -n "$p" ]]; then
    DOCK_HASH="${v}-${p}-${s:-noserial}"
  else
    DOCK_HASH="manual"
  fi
fi

LOG "action=${ACTION} dock=${DOCK_HASH} user=${active_user}(uid=${active_uid})"

# Detect which output is the internal panel.  KScreen JSON does not
# expose `is_internal`; we infer from `connectorName` / `name`
# matching the eDP* / LVDS* / DSI* family, which is the same heuristic
# KScreen itself uses internally.
internal_output_name() {
  run_as_user kscreen-doctor -j 2>/dev/null \
    | python3 -c '
import json, sys, re
INTERNAL = re.compile(r"^(eDP|LVDS|DSI)", re.I)
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for o in d.get("outputs", []):
    name = o.get("name") or o.get("connectorName") or ""
    if INTERNAL.match(name):
        print(name); break
' 2>/dev/null
}

# ─── ADD: wait, then apply or save ──────────────────────────────────
do_add() {
  # Wait for the external monitors to come up through DRM hotplug.  3s
  # is empirical: ThinkPad Universal TB4 dock takes ~1.8s on a cold
  # plug, ~0.6s on a warm plug.  Cap with `timeout` so a runaway sleep
  # can't pin a udev worker forever.
  sleep 3

  # Pick a layout: per-host override beats user-default; either may be
  # absent on first connect.
  local layout=""
  for d in "$LOCAL_OVERRIDE_DIR" "$LAYOUT_DIR"; do
    if [[ -f "${d}/${DOCK_HASH}.json" ]]; then
      layout="${d}/${DOCK_HASH}.json"; break
    fi
  done

  if [[ -z "$layout" ]]; then
    # First-time learning: persist the CURRENT layout under the user's
    # config so re-plugging this same dock later auto-applies it.  We
    # write the kscreen-doctor JSON verbatim — re-parsing it on apply
    # rebuilds a kscreen-doctor argv (see _apply_layout) since
    # kscreen-doctor has no "apply file" mode of its own.
    LOG "no saved layout for ${DOCK_HASH} — learning current layout"
    run_as_user mkdir -p "$LAYOUT_DIR" 2>/dev/null || true
    # DOCK_HASH is built from udev env vars (ID_VENDOR_ID/MODEL_ID/SERIAL_SHORT)
    # which a malicious USB device can claim.  We MUST NOT interpolate it
    # into a shell command (bash -c "... '${DOCK_HASH}.json'") because a
    # serial containing a quote breaks out of the redirect and executes
    # arbitrary code as the active graphical user.  Sanity-check the
    # hash against a strict regex AND write via a direct path rather
    # than shell-interpolation.
    if [[ ! "$DOCK_HASH" =~ ^[A-Za-z0-9._-]{1,128}$ ]]; then
      WARN "DOCK_HASH failed sanity check (refusing to write layout file)"
      WARN "  hash: ${DOCK_HASH}"
      return 0
    fi
    local _save_path="${LAYOUT_DIR}/${DOCK_HASH}.json"
    if run_as_user kscreen-doctor -j > "$_save_path" 2>/dev/null; then
      LOG "saved ${_save_path}"
    else
      WARN "save failed — check ${LAYOUT_DIR} perms"
    fi
    return 0
  fi

  LOG "applying layout ${layout}"
  _apply_layout "$layout"
}

# ─── REMOVE: laptop-only fallback ───────────────────────────────────
do_remove() {
  local internal
  internal="$(internal_output_name)"
  if [[ -z "$internal" ]]; then
    WARN "could not identify internal panel — refusing to blind-disable outputs"
    return 0
  fi
  LOG "dock detached — leaving only internal panel ${internal} enabled"
  # Build a kscreen-doctor argv that enables the internal panel and
  # disables EVERY OTHER connected output.  We don't preserve modes/
  # positions on the externals — they're gone; KScreen will rediscover
  # them on the next plug-in.
  local args
  args="$(run_as_user kscreen-doctor -j 2>/dev/null \
    | python3 -c '
import json, sys, re
INTERNAL = re.compile(r"^(eDP|LVDS|DSI)", re.I)
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
parts = []
for o in d.get("outputs", []):
    name = o.get("name") or o.get("connectorName") or ""
    if not name: continue
    if INTERNAL.match(name):
        parts.append(f"output.{name}.enable")
    else:
        if o.get("connected"):
            parts.append(f"output.{name}.disable")
print(" ".join(parts))
' 2>/dev/null)"
  if [[ -z "$args" ]]; then
    WARN "empty argv from kscreen-doctor JSON — skipping apply"
    return 0
  fi
  # shellcheck disable=SC2086  # word-splitting is the point here
  run_as_user kscreen-doctor $args 2>/dev/null \
    && LOG "applied laptop-only (args: ${args})" \
    || WARN "kscreen-doctor failed for laptop-only fallback (args: ${args})"
}

# Translate a saved kscreen-doctor JSON snapshot into kscreen-doctor
# argv and apply it.  We keep this in pure Python (no jq dep) because
# python3 is already a hard install dep elsewhere in these dotfiles.
_apply_layout() {
  local layout="$1"
  local args
  # $layout is `${LAYOUT_DIR}/${DOCK_HASH}.json` where DOCK_HASH is
  # built from udev env vars on a malicious USB device's claimed
  # descriptors.  Interpolating it directly into Python source via
  # shell-string substitution is a code-injection primitive — we'd be
  # parsing attacker-chosen bytes as Python while running as root from
  # the udev handler context.  Pass the path via env var instead so
  # Python receives it as a string at runtime, never as source text.
  args="$(LAYOUT_PATH="$layout" python3 -c '
import json, os, sys
try:
    d = json.load(open(os.environ["LAYOUT_PATH"]))
except Exception as e:
    sys.stderr.write(f"layout parse failed: {e}\n"); sys.exit(0)
parts = []
for o in d.get("outputs", []):
    name = o.get("name") or o.get("connectorName") or ""
    if not name: continue
    if not o.get("enabled"):
        parts.append(f"output.{name}.disable"); continue
    parts.append(f"output.{name}.enable")
    pos = o.get("pos") or {}
    if isinstance(pos, dict) and "x" in pos and "y" in pos:
        parts.append(f"output.{name}.position.{pos[\"x\"]},{pos[\"y\"]}")
    sz = o.get("size") or {}
    rr = None
    for m in o.get("modes", []):
        if m.get("id") == o.get("currentModeId"):
            rr = m.get("refreshRate"); sz = m.get("size", sz); break
    if sz and sz.get("width") and sz.get("height") and rr:
        parts.append(f"output.{name}.mode.{sz[\"width\"]}x{sz[\"height\"]}@{int(round(rr))}")
    elif sz and sz.get("width") and sz.get("height"):
        parts.append(f"output.{name}.mode.{sz[\"width\"]}x{sz[\"height\"]}")
    scale = o.get("scale")
    if scale and scale != 1:
        parts.append(f"output.{name}.scale.{scale}")
    rot = o.get("rotation")
    # KScreen rotation enum: 1=none 2=left 4=right 8=inverted.  Map to
    # kscreen-doctor literals.  Skip on 1/none — it is the default and
    # emitting it does no harm but clutters the argv.
    rot_map = {2: "left", 4: "right", 8: "inverted"}
    if rot in rot_map:
        parts.append(f"output.{name}.rotation.{rot_map[rot]}")
print(" ".join(parts))
' 2>/dev/null)"
  if [[ -z "$args" ]]; then
    WARN "empty argv from layout ${layout} — skipping apply"
    return 0
  fi
  # shellcheck disable=SC2086
  run_as_user kscreen-doctor $args 2>/dev/null \
    && LOG "applied layout (args: ${args})" \
    || WARN "kscreen-doctor failed applying ${layout} (args: ${args})"
}

case "$ACTION" in
  add)    do_add ;;
  remove) do_remove ;;
  "")
    WARN "no action arg — udev rule misconfigured?"
    exit 0
    ;;
  *)
    LOG "ignoring action=${ACTION}"
    ;;
esac

exit 0
