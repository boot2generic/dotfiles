#!/usr/bin/env python3
# config/plasma/kga_push.py
#
# Push every cyberpunk-dotfiles global-shortcut binding into the LIVE
# Plasma 6 session via a SINGLE D-Bus connection.  Replaces the
# 17-sequential-`dbus-send`-call block that previously lived in
# apply-theme.sh — each dbus-send fork was ~10ms (process spawn,
# connect, single method call, disconnect, exit), so the old loop
# burnt ~170 ms on every session start / re-deploy.  python-dbus
# opens one connection, drives 17+ calls down it, then exits — total
# wall-clock on the T14 is ~25-35 ms.
#
# Why we still talk to kglobalaccel over D-Bus at all (rather than
# editing ~/.config/kglobalshortcutsrc and asking the daemon to
# re-read it): on Plasma 6 Wayland kglobalaccel runs INSIDE
# kwin_wayland and does NOT re-read the file on change.  See the
# header of apply-theme.sh for the long rationale and the flag=4
# (NoAutoloading) reasoning.
#
# Run by config/plasma/apply-theme.sh — no direct user-facing CLI.
# Exits 0 on success, non-zero on any D-Bus call failure (callers
# should treat non-zero as a soft failure: the file-based binding
# still takes effect on the next login).
#
# Debian package: python3-dbus (added to DESKTOP_PLASMA_PACKAGES in
# local_setup.sh).  The dbus-python package is the long-supported
# reference binding for D-Bus on Linux and is maintained by the
# freedesktop project; it has zero non-stdlib runtime deps beyond
# libdbus-1 (already pulled in by the Plasma stack).

import sys

try:
    import dbus
except ImportError:
    print("[!]  python3-dbus not installed — add it to "
          "DESKTOP_PLASMA_PACKAGES and re-run local_setup.sh", file=sys.stderr)
    sys.exit(2)

# ── Qt::Key + Qt::KeyboardModifier values (qnamespace.h) ──────────
# Mirrored from the same constants apply-theme.sh used to compute
# inline.  Keep these in sync with Qt 6 if upstream ever renumbers
# (it has not since Qt 4).
QT_SHIFT       = 0x02000000
QT_CTRL        = 0x04000000
QT_ALT         = 0x08000000
QT_META        = 0x10000000

QT_KEY_RETURN  = 0x01000004
QT_KEY_F1      = 0x01000030   # F1..F4 = F1, F1+1, F1+2, F1+3
QT_KEY_LEFT    = 0x01000012
QT_KEY_RIGHT   = 0x01000014
QT_KEY_COMMA   = 0x2c
QT_KEY_PERIOD  = 0x2e
QT_KEY_SLASH   = 0x2f
QT_KEY_Q       = 0x51
# Digits 1..4 → 0x31..0x34

# Flag values (kglobalaccel/src/runtime/component.cpp):
#   0 = SetPresent      (default — refuses if already set)
#   4 = NoAutoloading   (override even if already set)  ← what we want
#   8 = IsDefault
KGA_NO_AUTOLOADING = 4


def build_bindings():
    """Assemble the (component, action, friendly_comp, friendly_action,
    keys[]) tuples.  Single source of truth for what apply-theme.sh
    pushes to kglobalaccel each session start.

    Mirrors the action-name strings used in
    config/plasma/kglobalshortcutsrc (and the kwriteconfig6 merge in
    local_setup.sh deploy_phase) verbatim — kglobalaccel matches by
    (component, name) tuple, so a typo here makes the binding silently
    no-op.
    """
    out = []

    # 1) Pre-empt Plasma's Meta+1..4 / Meta+Q / Meta+. defaults so the
    #    conflict resolver doesn't demote our kwin bindings.
    for n in range(1, 5):
        out.append(("plasmashell",
                    "activate task manager entry %d" % n,
                    "plasmashell",
                    "Activate Task Manager Entry %d" % n,
                    [0]))                                    # cleared
    out.append(("plasmashell", "manage activities",
                "plasmashell", "Show Activity Switcher", [0]))
    out.append(("org.kde.plasma.emojier.desktop", "_launch",
                "Emoji Selector", "Emoji Selector", [0]))

    # 2) Switch to Desktop N → Meta+N (primary), Ctrl+F[N] (secondary).
    for n in range(1, 5):
        primary   = QT_META | (0x30 + n)
        secondary = QT_CTRL | (QT_KEY_F1 - 1 + n)
        out.append(("kwin", "Switch to Desktop %d" % n,
                    "KWin", "Switch to Desktop %d" % n,
                    [primary, secondary]))

    # 3) Window to Desktop N → Meta+Shift+N (no secondary).
    for n in range(1, 5):
        primary = QT_META | QT_SHIFT | (0x30 + n)
        out.append(("kwin", "Window to Desktop %d" % n,
                    "KWin", "Window to Desktop %d" % n,
                    [primary]))

    # 4) Cycle desktops (i3 idiom: Meta+, / Meta+. ; arrow secondaries).
    out.append(("kwin", "Switch One Desktop to the Left",
                "KWin", "Switch One Desktop to the Left",
                [QT_META | QT_KEY_COMMA,
                 QT_META | QT_CTRL | QT_KEY_LEFT]))
    out.append(("kwin", "Switch One Desktop to the Right",
                "KWin", "Switch One Desktop to the Right",
                [QT_META | QT_KEY_PERIOD,
                 QT_META | QT_CTRL | QT_KEY_RIGHT]))

    # 5) Close window → Meta+Q (primary), Alt+F4 (secondary).
    out.append(("kwin", "Window Close",
                "KWin", "Close Window",
                [QT_META | QT_KEY_Q,
                 QT_ALT  | (QT_KEY_F1 + 3)]))

    # 6) Alacritty launcher → Meta+Return.
    out.append(("Alacritty.desktop", "_launch",
                "Alacritty", "Alacritty",
                [QT_META | QT_KEY_RETURN]))

    # 7) Cheatsheet popup → Meta+/.
    out.append(("cyberpunk-cheatsheet.desktop", "_launch",
                "Cyberpunk hotkey cheatsheet",
                "Cyberpunk hotkey cheatsheet",
                [QT_META | QT_KEY_SLASH]))

    return out


def main():
    bus = dbus.SessionBus()
    try:
        # Single proxy for the whole batch — no per-call lookup cost.
        proxy = bus.get_object("org.kde.kglobalaccel", "/kglobalaccel")
        kga = dbus.Interface(proxy, "org.kde.KGlobalAccel")
    except dbus.DBusException as e:
        print("[!]  could not reach org.kde.kglobalaccel: %s" % e,
              file=sys.stderr)
        return 1

    failed = 0
    pushed = 0
    for comp, action, friendly_comp, friendly_action, keys in build_bindings():
        # setShortcut signature:
        #     a(s)   actionId      — [component, action, friendly_comp, friendly_action]
        #     ai     keys          — Qt::Key | Qt::KeyboardModifier integers (0 to clear)
        #     u      flags         — KGlobalAccel::SetShortcutFlag bitmask
        action_id = dbus.Array(
            [dbus.String(comp), dbus.String(action),
             dbus.String(friendly_comp), dbus.String(friendly_action)],
            signature='s')
        keys_arr = dbus.Array([dbus.Int32(k) for k in keys], signature='i')
        try:
            kga.setShortcut(action_id, keys_arr,
                            dbus.UInt32(KGA_NO_AUTOLOADING))
            pushed += 1
        except dbus.DBusException as e:
            # Soft-fail: log + keep going, so a single typo'd action
            # name doesn't stop the rest of the batch.  This matches
            # the original dbus-send loop, which silently swallowed
            # individual failures (each call had >/dev/null 2>&1).
            print("[!]  setShortcut failed for %s/%s: %s"
                  % (comp, action, e), file=sys.stderr)
            failed += 1

    print("[ok] kga_push: %d bindings pushed, %d failed" % (pushed, failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
