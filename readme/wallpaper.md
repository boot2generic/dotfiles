# Wallpaper — Cyberpunk 2077 Night City Skyline

The default desktop wallpaper is a **4K Cyberpunk 2077 in-game
screenshot** of Night City — neon-saturated, vertical Asian-script
mega-billboards, classic CP77 mood.  Hosted on
[Wallhaven](https://wallhaven.cc/w/728lye); the image is © CD Projekt
RED and distributed for personal-desktop use.  Don't republish the
bitstream in unrelated commercial work.

The deploy step downloads at the original 3840x2160 resolution
(~6.6 MiB lossless PNG), SHA-256 verifies, and writes to
`~/.config/wallpaper/wallpaper.png`.  feh's `--bg-fill` mode crops the
4K image to whatever your monitor is, so this looks sharp on 1080p,
1440p, and ultrawide displays without manual sizing.

If the download fails (offline install, Wallhaven down, hash mismatch)
the procedural Pillow generator runs as a fallback and produces a
synthetic cyberpunk city scene instead — either way the file lands at
the same path so feh, lockscreen, etc. don't care.

**Online wallpaper:** `~/.config/wallpaper/download_wallpaper.sh`
- source: <https://wallhaven.cc/w/728lye>
- direct: `https://w.wallhaven.cc/full/72/wallhaven-728lye.png`
- format: 3840x2160 PNG, ~6.6 MiB
- SHA-256: `33d3ad8efd2529604149c47ce79da63c1addddce526eddc3a23b0a471e8b3270`

**Procedural fallback:** `~/.config/wallpaper/generate_wallpaper.py`

**Output (both):** `~/.config/wallpaper/wallpaper.png`

**Setter (i3 autostart):** `feh --bg-fill ~/.config/wallpaper/wallpaper.png`

---

## Refresh the wallpaper

```bash
# Re-download the canonical hacker wallpaper:
~/.config/wallpaper/download_wallpaper.sh

# Apply it now (no logout):
feh --bg-fill ~/.config/wallpaper/wallpaper.png
```

### Override the source

The script honours these env vars (set inline or in `.zshenv`):

| Var              | Default                                                     | Effect |
|------------------|-------------------------------------------------------------|---|
| `WP_URL`         | the Wallhaven image URL                                     | Use a different image |
| `WP_SHA256`      | matches the default URL's bytes                             | Different expected hash |
| `WP_SHA256_SKIP` | unset                                                       | `=1` to skip the hash check |
| `WP_DEST`        | `~/.config/wallpaper/wallpaper.png`                         | Where to write |

```bash
# Use a different image (any feh-compatible format), no hash check
WP_URL=https://example.com/my-wallpaper.png \
WP_SHA256_SKIP=1 \
~/.config/wallpaper/download_wallpaper.sh
```

If Wallhaven ever re-encodes the source and our pinned SHA-256 stops
matching, the script aborts with a clear error pointing at the override.

---

## Procedural fallback

If you've no network or you'd rather not pull from the internet, the
original procedural wallpaper generator still ships:

```bash
python3 ~/.config/wallpaper/generate_wallpaper.py
# or with a custom resolution:
python3 ~/.config/wallpaper/generate_wallpaper.py \
    --width 2560 --height 1440 \
    --output ~/.config/wallpaper/wide.png
```

It paints a cyberpunk city: starfield sky, skyline silhouette, neon
reflections, perspective grid, scanlines, film grain.  Each call is
randomised — re-run for a different scene.

---

## How it's wired up

1. The install script generates `wallpaper.png` once at deploy time.
2. i3's config has an autostart line:
   ```
   exec --no-startup-id feh --bg-fill ~/.config/wallpaper/wallpaper.png
   ```
3. The lockscreen script (`~/.config/lockscreen/lock.sh`) re-uses the same
   PNG, dimming and overlaying the time on top.

---

## Replacing with your own image

If you'd rather use a static photo:

```bash
cp ~/Pictures/my-photo.jpg ~/.config/wallpaper/wallpaper.png
feh --bg-fill ~/.config/wallpaper/wallpaper.png
```

(Yes, the file extension says `.png` but feh handles JPEG fine — or just
update the i3 line to point at the JPEG.)

---

## Customising the generator

Edit `~/.config/wallpaper/generate_wallpaper.py`. Look for the palette
constants at the top:

```python
CYAN     = (0, 229, 255)
MAGENTA  = (255,  0, 200)
SKY_TOP  = (8, 8, 22)
GROUND   = (3, 3, 10)
```

Other knobs (search the file): number of buildings, star density, scanline
opacity, fog level, window-light density.

---

## Multi-monitor

`feh --bg-fill` expands the same image across all monitors. For a per-monitor
image, generate two images and call:

```bash
feh --bg-fill ~/.config/wallpaper/left.png ~/.config/wallpaper/right.png
```

(One path per monitor, in xrandr order.)

---

## Further reading

- [`~/.config/wallpaper/generate_wallpaper.py`](../config/wallpaper/generate_wallpaper.py) — heavily commented Python
- `man feh`
- [Pillow docs](https://pillow.readthedocs.io/) — for editing the generator
