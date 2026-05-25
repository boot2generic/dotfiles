# Signal Desktop — privacy/hardening profile

Deployed to `${HOME}/.config/Signal/config.json` (mode `0600`,
`overlay = true` so a per-machine layer in
`~/.config/dotfiles-local/signal-desktop/config.json` takes
precedence).

The `0600` mode is load-bearing: Signal Desktop persists its
SQLCipher database key into this same `config.json` after first
launch. World-readable would let any local process running as a
different uid (or any user-scope package under `~/.local/`) read the
key off disk. The repo-tracked baseline starts at `0600` so the first
launch never has a window of `0644` exposure.

## What this profile sets

```json
{
  "disableHardwareAcceleration": true,
  "spellcheck": false,
  "alwaysRelayCalls": true
}
```

### `disableHardwareAcceleration: true`

Electron defaults to GPU-accelerated compositing, which on this hardware
profile (Mesa + Intel iGPU on T14, Nvidia proprietary on the desktop) leads
to two recurring problems:

1. Random black message-list rendering glitches when the GPU swap chain
   recovers (Nvidia DKMS reload, suspend/resume, fractional-scaling toggle).
2. The Electron renderer process holds a long-lived GBM handle, which keeps
   the discrete GPU spun up on the laptop — measurable battery drain.

Software rendering is fast enough for a text-heavy chat client; no UX loss.

### `spellcheck: false`

Signal Desktop's spellchecker uses Chromium's `hunspell`, which downloads
language dictionaries on demand from `redirector.gvt1.com` (Google's CDN)
on first use of each language.  That's:

- a passive fingerprinting signal ("which locales does this user write in?")
- a network call to a third party on every fresh install
- not gated by Signal's normal "we don't talk to Google" stance

Turning spellcheck off keeps the messaging surface free of Google network
contact.  Users who want spellcheck back: drop
`{"spellcheck": true}` into the per-machine overlay.

### `alwaysRelayCalls: true`

Default Signal voice/video calls try direct peer-to-peer ICE candidates
first.  That reveals your real IP to the call peer.  `alwaysRelayCalls`
forces every call through Signal's TURN relays — the call peer only ever
sees Signal's relay IPs.  Cost: ~50 ms extra latency on intra-continent
calls, ~150 ms cross-ocean.  Worth it for the privacy posture.

This matches Signal's own published recommendation under Privacy → "Always
Relay Calls" in the GUI; we just set it before first launch so the user
never has a window of unrelayed calls.

## What we explicitly do NOT set

- `mediaPermissions`, `mediaCameraPermissions` — these are managed by the
  in-app permission prompts; pre-seeding them would be surprising.
- `theme`, `notifications.draw`, etc. — UX prefs, not privacy.  Stay
  upstream defaults.
- `updatesEnabled` — apt manages this binary on Debian via the pinned-repo;
  the in-app updater simply never triggers because the .deb keeps moving
  forward.  No reason to disable it explicitly.

## How to override

- Per-machine: write a partial JSON object to
  `~/.config/dotfiles-local/signal-desktop/config.json`.  The deploy step
  merges it onto the repo copy when `overlay = true`.
- Disable the deploy entirely: edit `config/apps/apps.toml` and drop the
  signal-desktop entry under `[apps.configs]`.
- Reset to Signal's defaults: delete the file.  Signal recreates it on
  next launch with no privacy hardening.
