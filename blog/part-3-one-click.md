# Part 3: One Click — From Five Terminal Commands to a Menu Bar App

*Continuing the series on building a low-latency screen mirror for the Daylight DC-1.*

---

At the end of Part 2, the streaming pipeline was solved — lossless, zero-GPU, sub-10ms latency, 4KB delta frames. But actually using it required this:

```bash
# Terminal 1: Start BetterDisplay, configure virtual display manually
# Terminal 2:
adb reverse tcp:8888 tcp:8888
swift build -c release
.build/release/daylight-mirror
# Terminal 3: (on the Daylight) open the Mirror app
```

Plus a $20 BetterDisplay license for virtual display creation. Plus Accessibility and Screen Recording permissions. Plus remembering the adb tunnel command every time.

The pipeline was fast. The experience was not.

## Killing BetterDisplay

BetterDisplay is excellent software. But we were using exactly one feature: "create a 1280x960 non-HiDPI virtual display." Paying $20 for a single function call felt wrong, especially when macOS has the API to do it natively.

The API is `CGVirtualDisplay` — an undocumented private framework that Apple uses internally for AirPlay, Sidecar, and display management. BetterDisplay uses it. So does DeskPad (the open-source virtual display tool). So does Chromium for headless rendering.

The header isn't in any SDK. You reverse-engineer it from class dumps:

```objc
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly) CGDirectDisplayID displayID;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (copy) NSString *name;
@property uint32_t maxPixelsWide;
@property uint32_t maxPixelsHigh;
// ...
@end
```

Bridged into Swift via a C module map, the entire virtual display setup is ~30 lines:

```swift
let descriptor = CGVirtualDisplayDescriptor()
descriptor.name = "Daylight DC-1"
descriptor.maxPixelsWide = 1280
descriptor.maxPixelsHigh = 960
descriptor.sizeInMillimeters = CGSize(width: 325, height: 244)

let virtualDisplay = CGVirtualDisplay(descriptor: descriptor)

let settings = CGVirtualDisplaySettings()
settings.hiDPI = 0  // Non-HiDPI: real pixels = logical pixels
settings.modes = [
    CGVirtualDisplayMode(width: 1280, height: 960, refreshRate: 60)
]
virtualDisplay.apply(settings)
```

That's it. macOS instantly registers a new display. The virtual display appears in System Settings, in ScreenCaptureKit's display list, everywhere a real display would. When the process exits, the display vanishes. No cleanup needed.

## Programmatic Mirroring

Creating the virtual display is half the job. The other half: telling macOS to mirror the built-in display onto it. This forces the Mac into 4:3 mode — the mouse is confined, windows tile to the virtual display's resolution, and ScreenCaptureKit captures exactly what the Daylight will show.

This part uses a public API:

```swift
var config: CGDisplayConfigRef?
CGBeginDisplayConfiguration(&config)
CGConfigureDisplayMirrorOfDisplay(config, builtInDisplayID, virtualDisplayID)
CGCompleteDisplayConfiguration(config, .forSession)
```

The `.forSession` flag is key — mirroring reverts automatically when the process exits. No risk of getting stuck in a broken display configuration. Kill the app, your Mac goes back to normal.

Combined: the virtual display and mirroring setup that previously required BetterDisplay now happens in code, with zero user interaction, and cleans up after itself.

## Display Controls

The Daylight DC-1 has two distinguishing hardware features: an amber backlight for warm-toned reading, and a reflective monochrome display. Both are controllable via Android system settings — but when you're using the DC-1 as a mirrored display, you can't reach the Android settings UI.

The solution: intercept Mac keyboard shortcuts and relay them to the device.

### The Key Interception Problem

macOS keyboard events come in two flavors:
- Regular `keyDown` events for normal keys
- `NX_SYSDEFINED` events for media keys (brightness, volume, mute)

On a MacBook, F1/F2 are brightness keys by default (not F1/F2 unless you hold `fn`). These don't generate `keyDown` — they generate a special system event with subtype 8, where the actual key identity is encoded in `data1`:

```swift
let data1 = nsEvent.data1
let keyCode = (data1 & 0xFFFF0000) >> 16  // 2=brightness_up, 3=brightness_down
let keyDown = ((data1 & 0xFF00) >> 8) == 0xA
```

A `CGEvent` tap intercepts both event types. With the Ctrl modifier, we repurpose the built-in function keys:

| Shortcut | Action |
|----------|--------|
| Ctrl+F1 | Daylight brightness down |
| Ctrl+F2 | Daylight brightness up |
| Ctrl+F10 | Toggle backlight on/off |
| Ctrl+F11 | Cooler (less amber) |
| Ctrl+F12 | Warmer (more amber) |

### Two Paths to the Device

Brightness goes over TCP. The binary protocol already has frame packets `[0xDA 0x7E]` — we added command packets `[0xDA 0x7F]`:

```
[0xDA 0x7F] [cmd:1B] [value:1B]
  cmd 0x01: brightness (value 0-255)
  cmd 0x02: warmth (value 0-255)
```

The Android app receives the brightness command via the same TCP socket it receives frames on, and applies it via `WindowManager.LayoutParams.screenBrightness` — a per-window override that needs no special permissions.

Warmth is different. The Daylight's amber backlight is controlled by a custom Android system setting (`screen_brightness_amber_rate`), and it's a protected setting that apps can't write to directly. The TCP command path fails. Even `Runtime.exec("settings put ...")` from the app itself fails.

What works: `adb shell settings put system screen_brightness_amber_rate <value>`. So warmth commands go over adb from the Mac, not over TCP. Slightly inelegant, but the latency is imperceptible for a slider adjustment.

## The Menu Bar App

The final step was wrapping everything in a macOS menu bar app. The motivation was simple: if I have to open a terminal to start mirroring, I'll eventually stop using it. A menu bar icon that's always there, one click to start — that's the difference between a tool and a hack.

### Extracting MirrorEngine

The original `main.swift` was ~800 lines of inline code. We refactored it into a `MirrorEngine` library that both the CLI and the menu bar app share:

```swift
public class MirrorEngine: ObservableObject {
    @Published public var status: MirrorStatus = .idle
    @Published public var fps: Double = 0
    @Published public var brightness: Int = 128
    @Published public var warmth: Int = 128
    // ...

    public func start() async { /* everything */ }
    public func stop() { /* clean teardown */ }
}
```

`start()` does the full sequence: detect adb device, set up reverse tunnel, create virtual display, configure mirroring, start TCP/WebSocket/HTTP servers, begin screen capture, initialize keyboard controls. `stop()` tears everything down in reverse — capture stops, servers close, virtual display deallocates, mirroring reverts, adb tunnel removed.

### SwiftUI MenuBarExtra

The app itself is ~200 lines of SwiftUI:

```swift
@main
struct DaylightMirrorApp: App {
    @StateObject private var engine = MirrorEngine()

    var body: some Scene {
        MenuBarExtra {
            MirrorMenuView(engine: engine)
        } label: {
            Image(systemName: "display")
        }
        .menuBarExtraStyle(.window)
    }
}
```

`MenuBarExtra` with `.window` style gives a popover with full SwiftUI layout. The engine's `@Published` properties drive everything reactively — FPS counter, bandwidth display, brightness and warmth sliders, backlight toggle, connection status.

No dock icon. No main window. Just an icon in the menu bar with a green dot when mirroring is active.

## Install UX

Where we started: five terminal commands, a paid app, and a mental model of display configuration.

Where we are now:

```bash
git clone https://github.com/welfvh/daylight-mirror
cd daylight-mirror
make install    # builds + installs Mac menu bar app
make deploy     # installs Android APK via adb
```

Then:
1. Open "Daylight Mirror" from Spotlight
2. Click "Start Mirror"
3. Open the Mirror app on the Daylight

That's it. The Mac switches to 4:3 mirroring, the Daylight shows your screen, brightness and warmth sliders are in the menu bar. When you click "Stop" or quit the app, your Mac goes back to normal.

### Prerequisites

- **macOS 14+** with Xcode Command Line Tools (`xcode-select --install`)
- **adb**: `brew install android-platform-tools`
- **Daylight DC-1** with USB debugging enabled
- **Permissions**: Accessibility (keyboard shortcuts) and Screen Recording (capture) — macOS prompts on first run

Building the Android APK from source additionally requires the Android SDK with NDK 26, but a pre-built APK works on any ARM64 Android 7+ device.

## Architecture: The Full Stack

```
┌──────────────── Mac ─────────────────────────┐
│                                              │
│  Menu Bar App (SwiftUI)                      │
│    │                                         │
│    ▼                                         │
│  MirrorEngine                                │
│    ├─ VirtualDisplayManager                  │
│    │   └─ CGVirtualDisplay (1280x960)        │
│    │   └─ CGConfigureDisplayMirrorOfDisplay  │
│    ├─ ScreenCapture                          │
│    │   └─ ScreenCaptureKit → vImage SIMD     │
│    │   └─ XOR delta → LZ4 compress           │
│    ├─ TCPServer (:8888)                      │
│    │   └─ Binary protocol [DA 7E/7F]         │
│    ├─ DisplayController                      │
│    │   └─ CGEvent tap (Ctrl+F1-F12)          │
│    │   └─ Brightness via TCP, warmth via adb │
│    └─ ADB Bridge                             │
│        └─ Device detection + reverse tunnel  │
│                                              │
└──────────┬───────────────────────────────────┘
           │ USB (adb reverse tcp:8888)
           │ ~0.1 MB/s avg
┌──────────┴───────── Daylight DC-1 ───────────┐
│                                              │
│  MirrorActivity.kt (entry + JNI bridge)      │
│    │                                         │
│    ▼                                         │
│  mirror_native.c (entire hot path in C)      │
│    ├─ TCP recv + protocol parse              │
│    ├─ LZ4 decompress                         │
│    ├─ NEON XOR delta apply                   │
│    ├─ NEON greyscale → RGBX expand           │
│    └─ ANativeWindow direct blit              │
│                                              │
│  Total: ~2ms per frame, zero GPU             │
│                                              │
└──────────────────────────────────────────────┘
```

## What Changed

| | Part 1 | Part 2 | Part 3 |
|---|---|---|---|
| Setup | 10+ manual steps | 5 terminal commands | `make install` + click |
| Display | BetterDisplay ($20) | BetterDisplay ($20) | CGVirtualDisplay (free) |
| Controls | None | None | Ctrl+F keys + sliders |
| Interface | Terminal | Terminal | Menu bar app |
| Start/stop | Ctrl+C | Ctrl+C | Click |
| Cleanup | Manual | Manual | Automatic |

The streaming pipeline hasn't changed since Part 2 — it didn't need to. What changed is everything around it. The fastest codec in the world doesn't matter if you can't be bothered to start it.

---

*The code is at [github.com/welfvh/daylight-mirror](https://github.com/welfvh/daylight-mirror). The Daylight DC-1 is made by [Daylight Computer](https://daylightcomputer.com). Use code **WELF** at checkout to save $50 on yours.*

---

**Previous:** [Part 2: Killing the GPU](part-2-killing-the-gpu.md) — zero-GPU pipeline, native Android renderer with ARM SIMD
