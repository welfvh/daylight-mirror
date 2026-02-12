# 60fps Investigation — PR #29 Testing on Daylight DC-1

**Date**: 2026-02-12
**PR**: #29 (`feat/latency-optimizations` by @05bmckay)
**Claims**: 57+ FPS, 27% lower RTT via CGDisplayStream, GL shaders, NEON

## TL;DR

PR #29's Mac-side capture works. The bottleneck is the **Daylight DC-1 running at 30Hz** by default. Forcing 60Hz via system settings proves the full pipeline can work — blit drops from 28ms to 5.8ms. But the Android app doesn't force the display mode, so out of the box you get 30fps with TCP buffer bloat causing 5+ second latency.

## Live Test Results

### Before fix (DC-1 at 30Hz — default)

```
Active display mode: id=6, 30Hz
VSYNC period: 33333333 ns (30Hz)

FPS: 29.6 | recv: 0.0ms | lz4: 2.1ms | delta: 3.5ms | blit: 28.1ms | 7KB delta
FPS: 29.6 | recv: 0.0ms | lz4: 2.1ms | delta: 3.5ms | blit: 28.1ms | 7KB delta
```

- `blit: 28ms` = `eglSwapBuffers` waiting for 30Hz vsync
- `recv: 0.0ms` = frames already queued in TCP buffer (Mac outruns Android)
- User-perceived latency: **~5 seconds** (TCP buffer bloat)

### During heavy activity (scrolling, typing)

```
FPS: 27.5 | recv: 18.3ms | lz4: 8.0ms | delta: 4.2ms | blit: 5.9ms | 1231KB delta
FPS: 21.7 | recv: 25.1ms | lz4: 10.4ms | delta: 4.4ms | blit: 6.2ms | 1663KB delta
FPS: 18.3 | recv: 32.5ms | lz4: 11.1ms | delta: 4.5ms | blit: 6.5ms | 1485KB delta
```

- Delta sizes spike to 1-1.6MB (full screen changes)
- LZ4 decompression jumps to 8-11ms
- FPS drops to 18-21

### After forcing 60Hz (`adb shell settings put system min_refresh_rate 60.0`)

```
Active display mode: id=1, 60Hz
VSYNC period: 16666667 ns (60Hz)

FPS: 29.4 | recv: 22.1ms | lz4: 2.7ms | delta: 3.4ms | blit: 5.9ms | 7KB delta
FPS: 29.2 | recv: 22.2ms | lz4: 2.9ms | delta: 3.4ms | blit: 5.8ms | 9KB delta
```

- `blit: 5.8ms` — Android CAN render at 60fps (12ms total decode pipeline)
- `recv: 22ms` — now Mac is the bottleneck (backpressure limiting to ~30fps)
- FPS stuck at ~29 because Mac adaptive backpressure caps in-flight frames

## DC-1 Display Capabilities

```
DisplayDeviceInfo{"Built-in Screen": 1200x1600, modeId 6 (active), defaultModeId 1
  supportedModes:
    id=1  60.0Hz    (default)
    id=2  120.0Hz
    id=3  90.0Hz
    id=4  72.0Hz
    id=5  45.0Hz
    id=6  30.0Hz    ← ACTIVE (power saving!)
    id=7  24.0Hz
    id=8  15.0Hz
    id=9  10.0Hz
    id=10 6.0Hz
  mDisplayModeSpecs: primaryRefreshRateRange=[24 120] appRequestRefreshRateRange=[0 120]
```

**Note**: display is portrait-native (1200x1600), `installOrientation=2`.

## Root Causes

### 1. DC-1 defaults to 30Hz for this app

The code calls `surface.setFrameRate(60.0f, FRAME_RATE_COMPATIBILITY_DEFAULT)` in MirrorActivity.kt:106, but this is just a **hint** — Android's power management overrides it. The Daylight's e-ink-optimized firmware likely prefers low refresh for battery life.

**Fix**: Use `WindowManager.LayoutParams.preferredDisplayModeId` to force mode 1 (60Hz). This is mandatory, not a hint.

```kotlin
// In MirrorActivity.onCreate() or surfaceCreated()
val display = windowManager.defaultDisplay
val mode60 = display.supportedModes.firstOrNull { it.refreshRate >= 59.0f }
if (mode60 != null) {
    window.attributes = window.attributes.apply {
        preferredDisplayModeId = mode60.modeId
    }
}
```

### 2. TCP buffer bloat (the 5-second delay)

When Mac sends 60fps but Android renders 30fps, excess frames pile up:
- Android TCP receive buffer: max 8MB, default 3.4MB
- At 300KB/frame × 30 excess fps = ~9MB/s queuing
- Buffer fills in <1 second, then TCP flow control slows the Mac
- But by then there's 3-8 seconds of stale frames queued

`recv: 0.0ms` confirms Android never waits for network — it's always reading from a full buffer of old frames.

### 3. Mac backpressure too conservative for USB tunnel

```swift
func adaptiveBackpressureThreshold(rttMs: Double) -> Int {
    max(2, min(6, Int(120.0 / max(rttMs, 1.0))))
}
```

At USB RTT (~1-5ms), threshold = 6. At 60fps that's 100ms of buffering — reasonable. But after the 60Hz fix, recv: 22ms suggests the Mac is only delivering ~45fps even though Android can handle 60fps. The backpressure + ACK round-trip timing is the remaining bottleneck.

### 4. Early ACK hides render problems

Android sends ACK after decompression, BEFORE rendering (line 858 in mirror_native.c):
```c
send_ack(sock, seq);        // ACK first
publish_frame(g_current_frame, seq);  // render later
```

Mac thinks frame is "done" but it hasn't been rendered yet. If the double-buffer overwrites it, Mac never knows.

## Android Render Pipeline Budget (per frame at 60fps = 16.67ms)

| Step | Time | Thread |
|------|------|--------|
| recv (network read) | 0-22ms (waiting) | decode |
| LZ4 decompress | 2-3ms | decode |
| Delta XOR (NEON) | 3-4ms | decode |
| publish (memcpy to double-buffer) | <1ms | decode |
| memcpy to render_local | 1-2ms | render |
| glTexSubImage2D + glDrawArrays | 1-2ms | render |
| eglSwapBuffers (vsync) | 5-6ms @ 60Hz | render |

**Total decode**: ~6ms. **Total render**: ~8ms. These are parallel.
**Android CAN do 60fps** — 8ms render << 16.67ms budget.

## Recommended Fixes (priority order)

### Fix 1: Force 60Hz display mode in Android app [HIGH — single biggest win]

Add `preferredDisplayModeId` in MirrorActivity. This alone eliminates the 28ms→5.8ms blit regression and prevents TCP buffer bloat. Should also check if 120Hz is viable (8.3ms vsync budget, Android pipeline is 8ms — tight but possible).

### Fix 2: Reduce TCP socket buffer on Android [MEDIUM — prevents bloat]

Set `SO_RCVBUF` to something small (64KB-256KB) on the TCP socket. This limits how many stale frames can queue, making the system self-correcting even if refresh rate negotiation fails.

```c
int bufsize = 65536;
setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &bufsize, sizeof(bufsize));
```

### Fix 3: Tune Mac backpressure for USB tunnel [LOW — diminishing returns]

Current formula caps at 6 in-flight. At USB speeds with 60Hz Android, could safely allow 8-10. But this is secondary to fixes 1 and 2.

### Fix 4: Move ACK to post-render [LOW — correctness]

Send ACK after `eglSwapBuffers` completes, not after decompress. Gives Mac accurate RTT for backpressure calculation. Tradeoff: slightly higher measured RTT, but more honest flow control.

## Verification Commands

```bash
# Check current display mode
adb shell dumpsys display | grep mActiveModeId

# Check VSYNC period
adb shell dumpsys SurfaceFlinger | grep "VSYNC period"

# Force 60Hz (temporary, resets on reboot)
adb shell settings put system peak_refresh_rate 60.0
adb shell settings put system min_refresh_rate 60.0

# Watch Android FPS
adb logcat --pid=$(adb shell pidof com.daylight.mirror) | grep "FPS:"

# Reset to default
adb shell settings delete system peak_refresh_rate
adb shell settings delete system min_refresh_rate
```
