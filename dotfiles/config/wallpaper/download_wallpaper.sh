#!/usr/bin/env bash
# ~/.config/wallpaper/download_wallpaper.sh
#
# Fetch the canonical desktop wallpaper — a 4K Cyberpunk 2077 Night
# City skyline screenshot, hosted on Wallhaven — and write it to
# ~/.config/wallpaper/wallpaper.png.
#
#   Source : https://wallhaven.cc/w/728lye
#   Direct : https://w.wallhaven.cc/full/72/wallhaven-728lye.png
#   Format : PNG, 3840x2160, ~6.6 MiB (lossless, max bitrate)
#   Genre  : in-game screenshot, "Cyberpunk 2077", "city lights" tags
#
# Note on rights: Wallhaven hosts user-uploaded content; the underlying
# imagery is © CD Projekt RED, distributed for personal use as a
# desktop wallpaper.  Don't republish the bitstream as part of an
# unrelated commercial product.
#
# The default URL+SHA are pinned to a specific image so the byte
# stream is reproducible across installs.  Wallhaven serves the file
# directly (no on-the-fly re-encoding), so the SHA stays stable as
# long as the upload itself isn't taken down.
#
# Override knobs (env vars):
#   WP_URL         alternate image URL (any imagemagick-readable format)
#   WP_SHA256      expected SHA-256 of the downloaded file
#   WP_SHA256_SKIP =1 to skip the hash check
#   WP_DEST        output path (default ~/.config/wallpaper/wallpaper.png)
#
set -euo pipefail

# 4K Cyberpunk 2077 in-game screenshot ("Night City lights", uploader
# valkabg16).  Update both URL and SHA in lockstep when picking a
# different image.
DEFAULT_URL="https://w.wallhaven.cc/full/72/wallhaven-728lye.png"
DEFAULT_SHA="33d3ad8efd2529604149c47ce79da63c1addddce526eddc3a23b0a471e8b3270"

URL="${WP_URL:-$DEFAULT_URL}"
EXPECTED_SHA="${WP_SHA256:-$DEFAULT_SHA}"
DEST="${WP_DEST:-${HOME}/.config/wallpaper/wallpaper.png}"

# Prerequisites
command -v curl    >/dev/null 2>&1 || { echo "curl missing"          >&2; exit 1; }
command -v convert >/dev/null 2>&1 || { echo "imagemagick missing"   >&2; exit 1; }

mkdir -p "$(dirname "$DEST")"

# .img tempfile (extension-agnostic; convert sniffs the format).
tmp="$(mktemp --tmpdir wallpaper-dl.XXXXXX.img)"
trap 'rm -f "$tmp"' EXIT INT TERM

# Wallhaven's CDN occasionally rate-limits or blocks default User-Agents,
# so set a vanilla browser UA.  --max-time bounded so the install pipeline
# can't hang on a stuck CDN connection.
if ! curl -fsSL --max-time 60 \
        -H "User-Agent: Mozilla/5.0 dotfiles-installer" \
        "$URL" -o "$tmp"; then
    echo "wallpaper download failed (URL=$URL)" >&2
    exit 1
fi

# Sanity-check the file is actually a renderable image, not e.g. an
# error page or a 0-byte response.  `convert -ping` reads only the
# header so it's cheap.
if ! convert -ping "$tmp" -format '%wx%h' info: >/dev/null 2>&1; then
    echo "wallpaper download produced a non-image (URL=$URL)" >&2
    exit 1
fi

# SHA-256 pin (override with WP_SHA256_SKIP=1 if the upstream image
# has been re-encoded and you trust the new bitstream).
if [[ -n "$EXPECTED_SHA" && -z "${WP_SHA256_SKIP:-}" ]]; then
    actual="$(sha256sum < "$tmp" | awk '{print $1}')"
    if [[ "$actual" != "$EXPECTED_SHA" ]]; then
        echo "wallpaper SHA-256 mismatch:" >&2
        echo "  expected: $EXPECTED_SHA" >&2
        echo "  got:      $actual" >&2
        echo "If Wallhaven re-encoded the source, set WP_SHA256_SKIP=1" >&2
        echo "or update DEFAULT_SHA in this script."                    >&2
        exit 1
    fi
fi

# When the download is already a PNG (Wallhaven preserves the source
# format), a plain `install` keeps the bitstream byte-for-byte stable
# — important if the user wants to re-verify the SHA on disk.
# `convert` only runs for non-PNG inputs (e.g., a custom WP_URL
# pointing at a JPEG / WEBP / AVIF — feh handles all of these but the
# downstream lockscreen.sh has historically expected PNG).
if file -b "$tmp" 2>/dev/null | grep -q '^PNG image'; then
    install -m 644 "$tmp" "$DEST"
else
    convert "$tmp" "$DEST"
    chmod 644 "$DEST"
fi
echo "wallpaper updated → $DEST  ($(stat -c '%s' "$DEST") bytes, $(identify -format '%wx%h' "$DEST"))"
