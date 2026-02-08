# Daylight Mirror

Use your [Daylight DC-1](https://daylightcomputer.com) as a real-time external display for your Mac. Lossless, zero-GPU, sub-10ms latency.

The Mac renders at 4:3 natively (mouse confined, windows tiling to 1280x960), and the Daylight shows exactly what you see — pixel-perfect greyscale, 30 FPS, ~0.1 MB/s over USB.

![Daylight DC-1 mirroring a MacBook — both displays showing the same content](images/1-both-on.jpg)

## Install

### Option A: Homebrew (recommended)

```bash
brew install --cask welfvh/tap/daylight-mirror
```

This installs the Mac menu bar app to `/Applications` and the Android APK to `/opt/homebrew/share/daylight-mirror/`.

Then install the APK on your Daylight:

```bash
adb install /opt/homebrew/share/daylight-mirror/DaylightMirror.apk
```

### Option B: Download

Grab the latest `.dmg` from [Releases](https://github.com/welfvh/daylight-mirror/releases). Open it, drag "Daylight Mirror" to Applications, and install the included APK:

```bash
adb install /Volumes/Daylight\ Mirror/DaylightMirror.apk
```

### Option C: Build from source

```bash
git clone https://github.com/welfvh/daylight-mirror
cd daylight-mirror
make install    # builds Mac app → ~/Applications
make deploy     # builds + installs APK (requires Android SDK + NDK)
```

## Prerequisites

### On your Mac

- **macOS 14+**
- **adb** (Android Debug Bridge): `brew install android-platform-tools`
- On first run, macOS will ask for **Accessibility** (keyboard shortcuts) and **Screen Recording** (capture) permissions

### On your Daylight DC-1

Enable USB debugging (one-time setup):

1. Open **Settings** > **About tablet**
2. Tap **Build number** seven times (you'll see "You are now a developer!")
3. Go back to **Settings** > **Developer options**
4. Toggle on **USB debugging**
5. Connect the DC-1 to your Mac via USB-C
6. On the DC-1, tap **Allow** on the "Allow USB debugging?" prompt

Verify the connection:

```bash
adb devices
# Should show your device, e.g.: R5CTA1XXXXX    device
```

## Usage

1. Open **Daylight Mirror** from Spotlight or the menu bar
2. Click **Start Mirror**
3. On the Daylight, open the **Daylight Mirror** app

Your Mac switches to 4:3 mirrored mode. The Daylight shows your screen in real-time.

### Controls

![Menu bar popover — FPS stats, brightness and warmth sliders, backlight toggle](images/2-menu-bar.jpg)

From the menu bar popover:
- **Brightness** and **warmth** sliders
- **Backlight** toggle
- **Stop Mirror** button (Mac reverts to normal)

Keyboard shortcuts (while mirroring):

| Shortcut | Action |
|----------|--------|
| Ctrl + F1 | Brightness down |
| Ctrl + F2 | Brightness up |
| Ctrl + F10 | Toggle backlight |
| Ctrl + F11 | Cooler (less amber) |
| Ctrl + F12 | Warmer (more amber) |

### Stopping

Click **Stop Mirror** in the menu bar, or quit the app. Your Mac display reverts to its normal resolution automatically.

## Fidelity

![Close-up of the Daylight displaying the GitHub README — pixel-perfect text rendering](images/3-fidelity.jpg)

The mirror is lossless. Every pixel on the Mac is reproduced exactly on the Daylight via a deterministic BT.601 greyscale conversion. No JPEG artifacts, no dithering, no interpolation.

![The Daylight as a standalone display — Mac screen off, USB-C connected](images/4-mac-off.jpg)

## How it works

```
Mac                              Daylight DC-1
─────────────────────            ─────────────────────
ScreenCaptureKit (BGRA)          TCP recv
        │                                │
        ▼                                ▼
vImage SIMD greyscale (0.2ms)    LZ4 decompress (0.3ms)
        │                                │
        ▼                                ▼
XOR delta (0.1ms)                NEON XOR delta (0.1ms)
        │                                │
        ▼                                ▼
LZ4 compress (0.3ms → ~4KB)     NEON grey→RGBX (1.0ms)
        │                                │
        ▼                                ▼
Raw TCP ──── USB (adb) ────────► ANativeWindow blit
```

- **Zero GPU** on both sides — Mac GPU is completely idle, no fan noise
- **Lossless** — deterministic BT.601 greyscale, no JPEG compression
- **~4KB per frame** (delta), ~80KB keyframes once per second
- **~0.1 MB/s** average bandwidth over USB

The Mac side creates a virtual display using `CGVirtualDisplay` (private API) and mirrors the built-in display to it. The virtual display is captured by ScreenCaptureKit, converted to greyscale via vImage SIMD, delta-encoded against the previous frame, LZ4 compressed, and sent over raw TCP.

The Android side is a native NDK app — the entire hot path (TCP recv, LZ4 decompress, NEON delta apply, NEON pixel expansion, ANativeWindow blit) is C with zero JNI calls in the frame loop.

## Blog

- [Part 1: The Prototype](blog/)
- [Part 2: Killing the GPU](blog/part-2-killing-the-gpu.md)
- [Part 3: One Click](blog/part-3-one-click.md)

## License

MIT

---

*The Daylight DC-1 is made by [Daylight Computer](https://daylightcomputer.com). This project is not affiliated with Daylight.*
