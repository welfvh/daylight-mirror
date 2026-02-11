# Part 2: Killing the GPU — From JPEG to LZ4 Delta at 4KB per Frame

*Continuing the series on building a low-latency screen mirror for the Daylight DC-1.*

---

At the end of Part 1, we had a working pipeline: ScreenCaptureKit → GPU greyscale → JPEG → WebSocket → Chrome. 30 FPS, ~200KB per frame, ~6MB/s bandwidth. It worked. But there was a problem I couldn't ignore.

The GPU was spinning.

## The Noise Problem

I'm HSP — highly sensitive to sensory input. The M4 Pro MacBook is essentially silent under normal load. But the moment you engage the GPU continuously — even for something as light as CIContext JPEG encoding — there's a high-frequency whine from the power delivery. Most people wouldn't notice. I can't not notice.

The pipeline was: `CIColorControls` (GPU desaturate) → `CIContext.jpegRepresentation` (GPU encode). Both operations kept the GPU active at all times. I'd literally considered buying a Mac Mini to put in a box in another room just to avoid the noise.

So the goal shifted: **zero GPU usage.** Not "low GPU." Zero.

## Step 1: CPU Greyscale with vImage (0.2ms)

Apple's Accelerate framework includes vImage — SIMD-optimized image processing that runs entirely on CPU. For BGRA-to-greyscale, there's a single function that does exactly what we need:

```swift
// BT.601 luminance from BGRA channel order: [B=29, G=150, R=77, A=0] / 256
var matrix: [Int16] = [29, 150, 77, 0]
let divisor: Int32 = 256

vImageMatrixMultiply_ARGB8888ToPlanar8(
    &srcBuffer, &dstBuffer,
    &matrix, divisor,
    &preBias, 0,
    vImage_Flags(kvImageNoFlags)
)
```

This produces a flat array of greyscale bytes. On an M4 Pro, it converts 1,228,800 pixels (1280×960) in **0.2ms**. The SIMD instructions process 16 pixels per cycle. No GPU touched.

But now we have 1.2MB of raw pixels per frame. At 30fps, that's 36MB/s — and we already knew from Part 1 that USB 2.0 via adb reverse tops out around 30-35MB/s. We'd saturate the pipe again.

## Step 2: LZ4 Compression (~0.3ms)

LZ4 is a lossless compression algorithm designed for speed over ratio. It was created by Yann Collet at Facebook for real-time data processing. The key property: on modern CPUs, LZ4 decompression is faster than memcpy for most data patterns, because the decompressed data is smaller than the compressed data that needs to traverse the memory bus.

For our greyscale frames, LZ4 compresses a typical desktop screenshot from 1.2MB down to ~80KB. That's a 15:1 ratio, entirely lossless, in 0.3ms.

```swift
let compressedSize = LZ4_compress_default(
    grayPixels, compressedBuffer,
    Int32(pixelCount), maxCompressed
)
```

But we can do much better. Most frames are nearly identical to the previous one — the cursor moved a few pixels, a text insertion point blinked. Why send 80KB of mostly-unchanged data?

## Step 3: XOR Delta Encoding (~0.1ms)

Delta encoding: XOR the current frame with the previous frame. Identical pixels become 0x00. Changed pixels become non-zero.

```swift
for i in 0..<pixelCount {
    deltaBuffer[i] = currentGray[i] ^ previousGray[i]
}
```

For a static desktop with only a cursor blinking, the delta is 99.99% zeros. LZ4 compresses runs of zeros extraordinarily well. The result: **~4KB per delta frame.** Down from 1.2MB raw, 80KB LZ4-only.

The server sends a full keyframe every 30 frames (once per second) for client resync, and XOR deltas for everything in between. A simple binary protocol tags which is which:

```
[0xDA 0x7E] [flags:1B] [length:4B LE] [LZ4 payload]
  flags bit 0: 1=keyframe, 0=delta
```

**Bandwidth: ~0.1MB/s.** That's 60x less than the greyscale JPEG path, and it's lossless.

## Step 4: Raw TCP (Killing WebSocket)

WebSocket adds framing overhead, masking, and upgrade negotiation. For a dedicated native client, there's no reason for it. We replaced WebSocket with raw TCP using Apple's Network framework:

```swift
let params = NWParameters.tcp
let tcpOptions = params.defaultProtocolStack.transportProtocol as! NWProtocolTCP.Options
tcpOptions.noDelay = true  // Disable Nagle's for minimum latency
listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: 8888)!)
```

`TCP_NODELAY` is critical — without it, Nagle's algorithm buffers small writes (our 4KB deltas) waiting for more data before sending. With our frame sizes, that could add 40ms of latency per frame. One flag eliminates it.

## The Android Native App

Chrome was the other half of the GPU problem. Even with `requestAnimationFrame` frame dropping, Chrome's rendering pipeline involves JavaScript execution, blob creation, image decode, compositing — all touching the GPU. Replacing it with a native NDK app eliminates every layer.

### Architecture: Zero Java in the Hot Path

The Android app has exactly two files:
- `MirrorActivity.kt` (~50 lines): creates a SurfaceView, hands its Surface to JNI, enters immersive mode
- `mirror_native.c` (~300 lines): the entire receive + decode + render pipeline in C

The Kotlin code runs once at startup and never again. Every frame is processed entirely in C:

```
TCP recv → LZ4 decompress → XOR delta apply → ANativeWindow blit
```

No JNI callbacks. No Java GC. No GPU.

### NEON SIMD: Delta Apply in Hardware

ARM NEON processes 16 bytes per instruction. The XOR delta apply:

```c
static void apply_delta_neon(uint8_t *frame, const uint8_t *delta, int count) {
    int i = 0;
    for (; i + 16 <= count; i += 16) {
        uint8x16_t f = vld1q_u8(frame + i);
        uint8x16_t d = vld1q_u8(delta + i);
        vst1q_u8(frame + i, veorq_u8(f, d));
    }
    for (; i < count; i++) {
        frame[i] ^= delta[i];
    }
}
```

1,228,800 bytes XOR'd in ~0.1ms. The NEON path handles 76,800 iterations (16 bytes each) while the scalar tail handles the remaining bytes.

### NEON SIMD: Greyscale to RGBX Expansion

ANativeWindow uses RGBX_8888 format — 4 bytes per pixel. We need to expand each greyscale byte to [G, G, G, 0xFF]. NEON's `vst4q_u8` interleaves four 16-byte vectors into a 64-byte output:

```c
uint8x16_t g = vld1q_u8(src + x);       // 16 grey pixels
uint8x16_t ff = vdupq_n_u8(0xFF);       // alpha channel
uint8x16x4_t rgbx = { g, g, g, ff };    // broadcast grey to RGB
vst4q_u8(row + x * 4, rgbx);            // write 64 bytes (16 pixels)
```

16 pixels expanded in a single instruction. The entire 1280×960 frame blits in ~1ms.

### ANativeWindow: Direct Surface Access

The Android rendering path bypasses every abstraction:

```c
ANativeWindow_setBuffersGeometry(window, 1280, 960,
    AHARDWAREBUFFER_FORMAT_R8G8B8X8_UNORM);

ANativeWindow_Buffer buffer;
ANativeWindow_lock(window, &buffer, NULL);
// Write pixels directly to buffer.bits
ANativeWindow_unlockAndPost(window);
```

No Canvas. No Bitmap. No OpenGL. No Vulkan. The native window buffer is a memory-mapped region shared with SurfaceFlinger. We write pixels; SurfaceFlinger composites them to the display. One copy, one composite, done.

### Instant Reconnect

When the Android app switches away and comes back, the Surface is destroyed and recreated. The original implementation required a full reconnect + wait for the next keyframe (~1-2 seconds of black screen).

Fix: the server caches the last keyframe and sends it immediately to any new TCP connection:

```swift
listener.newConnectionHandler = { conn in
    // ...
    if let kf = self.lastKeyframeData {
        conn.send(content: kf, completion: .contentProcessed { _ in })
    }
}
```

The client gets pixels on the first TCP packet. No black flash.

## The Numbers

Per-frame timing from Android logcat (averaged over 5-second windows):

| Stage | Time |
|-------|------|
| TCP recv (7-byte header + ~4KB payload) | ~0.5ms |
| LZ4 decompress | ~0.3ms |
| XOR delta apply (NEON) | ~0.1ms |
| Greyscale → RGBX blit (NEON) | ~1.0ms |
| **Total per frame** | **~2ms** |

And the full pipeline comparison:

| Metric | Part 1: JPEG+Chrome | Part 2: LZ4+Native |
|--------|---------------------|---------------------|
| Server encode | ~4ms (GPU) | ~0.6ms (CPU) |
| Frame size | ~200KB | ~4KB (delta) |
| Bandwidth | ~6MB/s | ~0.1MB/s |
| Client decode+render | ~10-15ms | ~2ms |
| **End-to-end latency** | ~25-35ms | ~5-10ms |
| GPU usage | Continuous | **Zero** |
| FPS | 29.4 | 29.4 |
| Lossless | No (JPEG) | **Yes** |

The pipeline went from lossy, GPU-bound, and bandwidth-heavy to lossless, CPU-only, and barely sipping the USB pipe. The Mac's GPU is completely idle. The fan noise is gone.

## Pixel-Perfect Verification

The obvious question: is the lossless claim real? We captured a screenshot on the Mac, pushed it to the Daylight as a PNG, and opened it side-by-side with the mirror output.

Identical. Every pixel. The only transform is the deterministic BT.601 greyscale conversion, applied identically on both sides. What the Mac shows in greyscale is exactly what the Daylight renders.

## Architecture Diagram

```
┌─────────────────── Mac ───────────────────┐
│                                           │
│  ScreenCaptureKit (BGRA, 30fps)           │
│         │                                 │
│         ▼                                 │
│  vImage SIMD greyscale (0.2ms)            │
│         │                                 │
│         ▼                                 │
│  XOR delta vs previous frame (0.1ms)      │
│         │                                 │
│         ▼                                 │
│  LZ4 compress (0.3ms → ~4KB)             │
│         │                                 │
│         ▼                                 │
│  Raw TCP + binary protocol                │
│         │                                 │
└─────────┼─────────────────────────────────┘
          │ USB (adb reverse tcp:8888)
          │ ~0.1MB/s
┌─────────┼──────── Daylight DC-1 ──────────┐
│         ▼                                 │
│  TCP recv + protocol parse                │
│         │                                 │
│         ▼                                 │
│  LZ4 decompress (0.3ms)                  │
│         │                                 │
│         ▼                                 │
│  NEON XOR delta apply (0.1ms)             │
│         │                                 │
│         ▼                                 │
│  NEON greyscale→RGBX expand (1.0ms)       │
│         │                                 │
│         ▼                                 │
│  ANativeWindow direct blit                │
│                                           │
└───────────────────────────────────────────┘
```

## What's Left

The software works. The display pipeline is essentially solved — sub-10ms latency, zero GPU, lossless, 30fps. What remains is the setup experience: virtual display creation, mirror configuration, adb tunneling, and server launch. Right now that's a series of manual steps. Part 3 will explore whether we can collapse all of it into a single command.

---

*The code is at [github.com/welfvh/daylight-mirror](https://github.com/welfvh/daylight-mirror). The Daylight DC-1 is made by [Daylight Computer](https://daylightcomputer.com). Use code **WELF** at checkout to save $50 on yours.*

---

**Previous:** [Part 1: The Prototype](part-1-from-vnc-to-raw-pixels.md) — from VNC to ScreenCaptureKit | **Next:** [Part 3: One Click](part-3-one-click.md) — virtual display, display controls, menu bar app
