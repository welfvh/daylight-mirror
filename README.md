# Daylight Mirror

Turn your [Daylight DC-1](https://daylightcomputer.com) into a real-time external display for your Mac.

![Daylight DC-1 mirroring a MacBook — both displays showing the same content](docs/images/1-both-on.jpg)

Your Mac renders natively at the Daylight's 4:3 resolution. What you see on the Mac is exactly what appears on the Daylight — every pixel, every frame, with no perceptible delay.

**30 FPS. Under 10ms latency. Lossless. Zero artifacts.** This is as fast, as clean, and as efficient as a software display mirror can physically be.

## Download

### [Download Daylight Mirror — $15 suggested](https://buy.stripe.com/5kQ7sK1WGf64cFLbyq3Ru06)

Pay what you want ($5+). The `.dmg` includes both the Mac menu bar app and the Android APK for your Daylight.

After downloading, drag "Daylight Mirror" to Applications, then install the included APK on your Daylight:

```bash
adb install /Volumes/Daylight\ Mirror/DaylightMirror.apk
```

<details>
<summary>Other install options</summary>

### Homebrew

```bash
brew install --cask welfvh/tap/daylight-mirror
```

Then install the app on your Daylight (one time):

```bash
adb install /opt/homebrew/share/daylight-mirror/DaylightMirror.apk
```

### GitHub Releases

Grab the latest `.dmg` directly:

```
https://github.com/welfvh/daylight-mirror/releases/latest/download/DaylightMirror.dmg
```

Or browse all versions on the [Releases](https://github.com/welfvh/daylight-mirror/releases) page. Drag "Daylight Mirror" to Applications, then install the included APK:

```bash
adb install /Volumes/Daylight\ Mirror/DaylightMirror.apk
```

### Build from source

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

**On your Daylight DC-1** (one-time setup):
1. **Settings** > **About tablet** > tap **Build number** seven times
2. **Settings** > **Developer options** > enable **USB debugging**
3. Connect to your Mac via USB-C and tap **Allow** on the prompt

Verify with `adb devices` — you should see your device listed.

### First run — macOS permissions

On first launch, macOS needs two permissions. The app will guide you through this:

1. **Screen Recording** — required to capture your display. The app will open System Settings automatically. Toggle "Daylight Mirror" on, then quit and reopen the app.
2. **Accessibility** — required for keyboard shortcuts (`Ctrl+F8`, etc.). Same flow: toggle on in System Settings, then reopen.

## Usage

1. Open **Daylight Mirror** from Spotlight
2. Pick a resolution (Cozy, Comfortable, Balanced, or Sharp)
3. Click **Start Mirror** (or press `Ctrl+F8`)
4. On the Daylight, open the **Daylight Mirror** app

That's it. Your Mac switches to 4:3, and the Daylight lights up.

![Menu bar popover — live stats, brightness and warmth sliders, backlight toggle](docs/images/2-menu-bar.jpg)

### Resolution

Four 4:3 presets, selectable before or during mirroring:

| Preset | Resolution | Best for |
|--------|-----------|----------|
| Cozy | 800x600 HiDPI | Big UI, native sharpness (2x backing → 1600x1200 pixels) |
| Comfortable | 1024x768 | Larger UI, easy on the eyes |
| Balanced | 1280x960 | Good balance of size and sharpness |
| Sharp | 1600x1200 | Maximum sharpness, smallest UI |

### Keyboard shortcuts

All shortcuts use `Ctrl` + function keys:

| Shortcut | Action |
|----------|--------|
| `Ctrl+F8` | Start / stop mirroring |
| `Ctrl+F1` / `Ctrl+F2` | Brightness down / up |
| `Ctrl+F10` | Toggle backlight |
| `Ctrl+F11` / `Ctrl+F12` | Warmth down / up |

The menu bar also has brightness and warmth sliders, a backlight toggle, resolution picker, and live connection stats.

Click **Stop Mirror** or quit the app — your Mac reverts to normal instantly.

### CLI

Every feature in the menu bar app is available from the command line. The CLI talks to whatever engine is running (GUI app or CLI daemon) via Unix domain socket — one engine, two interfaces.

```bash
daylight-mirror start                # start mirroring (tells GUI app, or spawns daemon)
daylight-mirror stop                 # stop mirroring
daylight-mirror status               # current state (machine-readable)
daylight-mirror reconnect            # re-establish ADB tunnel

daylight-mirror brightness           # get current brightness
daylight-mirror brightness 200       # set brightness (0-255)
daylight-mirror warmth 128           # set warmth / amber rate (0-255)
daylight-mirror backlight toggle     # toggle backlight (on|off|toggle)
daylight-mirror resolution sharp     # set resolution (cozy|comfortable|balanced|sharp)
daylight-mirror sharpen 0.8          # set sharpening amount (0.0-1.5)
daylight-mirror restart              # full stop + start cycle
```

This means any script or tool (including AI agents) can control the Daylight programmatically.

## Fidelity

![Close-up of the Daylight displaying the GitHub README — pixel-perfect text](docs/images/3-fidelity.jpg)

What you see above is the Daylight rendering this README, mirrored from the Mac. Every character is pixel-identical to what the Mac displays. There's no JPEG compression, no dithering, no interpolation — just a direct greyscale conversion applied identically on both sides.

![The Daylight as a standalone display — Mac screen off, USB-C connected](docs/images/4-mac-off.jpg)

## How it works

This entire project was vibecoded in a single session with Claude Opus 4.6. Starting from "can I mirror my Mac to this tablet?", we iterated through VNC, Python scripts, browser-based streaming, and native rendering — each version dramatically faster than the last — until we hit the physical limits of what a software mirror can do. The result is 10x better than any existing solution for the DC-1: faster, sharper, lighter, and easier to use.

The blog series tells the full story:

- [Part 1: The Prototype](blog/part-1-from-vnc-to-raw-pixels.md) — from VNC to ScreenCaptureKit
- [Part 2: Killing the GPU](blog/part-2-killing-the-gpu.md) — zero-GPU pipeline, native Android renderer with ARM SIMD
- [Part 3: One Click](blog/part-3-one-click.md) — virtual display, display controls, menu bar app

## Get a Daylight DC-1

Don't have one yet? Use code **WELF** at [buy.daylightcomputer.com/WELF](https://buy.daylightcomputer.com/WELF).

## Support

If you find this useful, you can [support the project](https://buy.stripe.com/5kQ7sK1WGf64cFLbyq3Ru06).

## License

MIT

---

*The Daylight DC-1 is made by [Daylight Computer](https://daylightcomputer.com). This project is not affiliated with Daylight.*
