# Daylight Mirror

Turn your [Daylight DC-1](https://daylightcomputer.com) into a real-time external display for your Mac.

![Daylight DC-1 mirroring a MacBook — both displays showing the same content](images/1-both-on.jpg)

Your Mac renders natively at the Daylight's resolution. The mouse stays inside the 4:3 frame, windows tile to fit, and what you see on the Mac is exactly what appears on the Daylight — every pixel, every frame, with no perceptible delay.

The mirror runs at **30 frames per second** with **under 10 milliseconds of latency** and uses **less than 0.1 MB/s of bandwidth** over a single USB-C cable. It's lossless — no compression artifacts, no quality loss. Your Mac's GPU stays completely idle the entire time, so there's zero fan noise. This is as fast, as clean, and as efficient as a software display mirror can physically be.

## Install

### Homebrew (recommended)

```bash
brew install --cask welfvh/tap/daylight-mirror
```

Then install the app on your Daylight (one time):

```bash
adb install /opt/homebrew/share/daylight-mirror/DaylightMirror.apk
```

<details>
<summary>Other install options</summary>

**Download:** Grab the `.dmg` from [Releases](https://github.com/welfvh/daylight-mirror/releases). Drag "Daylight Mirror" to Applications, then install the included APK:

```bash
adb install /Volumes/Daylight\ Mirror/DaylightMirror.apk
```

**Build from source:**

```bash
git clone https://github.com/welfvh/daylight-mirror
cd daylight-mirror
make install    # Mac menu bar app → ~/Applications
make deploy     # Android APK → Daylight (requires Android SDK)
```

</details>

### Prerequisites

**On your Mac:**
- macOS 14 or later
- `adb`: `brew install android-platform-tools`
- macOS will prompt for Accessibility and Screen Recording permissions on first run

**On your Daylight DC-1** (one-time setup):
1. **Settings** > **About tablet** > tap **Build number** seven times
2. **Settings** > **Developer options** > enable **USB debugging**
3. Connect to your Mac via USB-C and tap **Allow** on the prompt

Verify with `adb devices` — you should see your device listed.

## Usage

1. Open **Daylight Mirror** from Spotlight
2. Click **Start Mirror**
3. On the Daylight, open the **Daylight Mirror** app

That's it. Your Mac switches to 4:3, and the Daylight lights up.

![Menu bar popover — live stats, brightness and warmth sliders, backlight toggle](images/2-menu-bar.jpg)

The menu bar gives you brightness and warmth sliders, a backlight toggle, and live connection stats. Keyboard shortcuts work too: **Ctrl+F1/F2** for brightness, **Ctrl+F11/F12** for warmth, **Ctrl+F10** to toggle the backlight.

Click **Stop Mirror** or quit the app — your Mac reverts to normal instantly.

## Fidelity

![Close-up of the Daylight displaying the GitHub README — pixel-perfect text](images/3-fidelity.jpg)

What you see above is the Daylight rendering this README, mirrored from the Mac. Every character is pixel-identical to what the Mac displays. There's no JPEG compression, no dithering, no interpolation — just a direct greyscale conversion applied identically on both sides.

![The Daylight as a standalone display — Mac screen off, USB-C connected](images/4-mac-off.jpg)

## How it works

The technical deep-dive is in the blog series:

- [Part 1: The Prototype](blog/) — from VNC to ScreenCaptureKit
- [Part 2: Killing the GPU](blog/part-2-killing-the-gpu.md) — zero-GPU pipeline, native Android renderer with ARM SIMD
- [Part 3: One Click](blog/part-3-one-click.md) — virtual display, display controls, menu bar app

The short version: the Mac captures its own screen, converts to greyscale using CPU vector instructions, compresses the difference between consecutive frames, and sends ~4KB per frame over USB. The Daylight runs a native C renderer that decompresses and paints pixels directly to the display hardware. No browser, no GPU, no Java in the hot path. The entire round trip — capture, encode, transmit, decode, render — takes about 5 milliseconds.

## License

MIT

---

*The Daylight DC-1 is made by [Daylight Computer](https://daylightcomputer.com). This project is not affiliated with Daylight.*
