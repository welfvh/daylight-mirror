# Turning a Daylight DC-1 Into a Mac External Display: From VNC to Raw Pixels

*Part 1 of a series on building a low-latency screen mirror from scratch.*

---

The Daylight DC-1 is an Android tablet with an amber, paper-like display — designed for reading and writing without the blue light assault of a normal screen. I wanted to use it as an external display for my Mac. Not through some official integration (there isn't one), but as a real-time mirror of a Mac display, streamed over USB.

What started as "just pipe VNC over adb" became a deep dive into display pipelines, pixel formats, compression tradeoffs, and the boundary between what USB can carry and what a screen can render.

## Attempt 1: VNC Over USB

The most obvious approach. macOS has built-in Screen Sharing (VNC server), the DC-1 runs Android, and AVNC is a solid VNC client. Connect via USB, set up `adb reverse tcp:5900 tcp:5900`, point AVNC at localhost.

**Result:** Unusable. The Mac was streaming its full 5K Studio Display resolution through VNC's encoding pipeline. Latency was measured in seconds, not milliseconds. Even after pointing it at just the 14" built-in Retina display (3024x1964), VNC's RFB protocol couldn't keep up over USB. The encoding overhead alone was catastrophic.

**Lesson:** VNC was designed for remote desktop over networks, not low-latency local mirroring. The protocol negotiation, rectangle-based updates, and encoding flexibility all add overhead we don't need.

## Attempt 2: Python screencapture + HTTP Streaming

Strip everything down. Capture the screen to JPEG, serve it over HTTP, display in Chrome on the Daylight. No VNC protocol, no encoding negotiation — just frames.

```python
# The core loop (simplified)
while True:
    subprocess.run(["screencapture", "-C", "-x", "-D", "1", "-t", "jpg", path])
    with open(path, "rb") as f:
        frame = f.read()
    # Serve to connected client
```

This worked. Sort of. We added instrumentation:

```
screencapture: 103ms avg, 199ms p95
Read: 0.1ms, Serve: 0.1ms
Capture FPS: 9.7, Serve FPS: 7.5
```

**103 milliseconds per capture.** The `screencapture` command spawns a process, captures the compositor, writes to disk, and exits — for every single frame. The actual image encode and disk write were negligible; the process spawn overhead was the bottleneck.

At 9.7 FPS, it was usable for writing prose but painful for anything dynamic. Cursor movement felt like swimming through honey.

**Lesson:** Process-per-frame architectures have a hard floor around 100ms. The OS overhead of fork/exec/cleanup dominates everything else.

## The Aspect Ratio Problem

Even with frames flowing, there was a bigger issue: the Daylight is 4:3 (1200x1600 portrait, 1600x1200 landscape). The Mac's built-in display is 16:10. Chrome's toolbar ate another chunk. We were effectively mirroring a 16:10 rectangle onto a 4:3 screen with ~25% wasted to letterboxing and browser chrome.

We tried cropping the Mac capture to 4:3, but this produced a "zoomed in center" effect that was disorienting — you'd see a portion of your desktop pulled wide.

**The solution: a virtual display.**

## BetterDisplay and the Virtual Display Trick

[BetterDisplay](https://github.com/wahlquisty/BetterDisplay) can create virtual displays on macOS with arbitrary resolutions. We created one at 1280x960 — a 4:3 resolution that maps cleanly to the Daylight.

```bash
betterdisplaycli create --type=VirtualScreen --width=1280 --height=960
```

But macOS immediately made it a HiDPI display (2560x1920 backing), defeating the purpose. Fix:

```bash
betterdisplaycli set --name="Daylight" --hiDPI=off
```

Then the breakthrough: **mirror mode**. Instead of treating the virtual display as a separate screen (which requires dragging windows to it), we set the Mac's built-in display to *mirror* the virtual display:

```bash
betterdisplaycli set --name="Daylight" --mirror=on --targetName="Built-in Display"
```

Now the Mac's built-in panel shows 4:3 content letterboxed on its 16:10 panel. The virtual display is the "source of truth" at 1280x960. Everything the user sees on their Mac is already in the right aspect ratio and resolution. The capture just grabs those pixels — no scaling, no cropping.

**Lesson:** Don't fight the display pipeline. Make it produce what you need natively, then capture is trivial.

## Attempt 3: ScreenCaptureKit + WebSocket (Swift)

The Python approach topped out at ~10 FPS because of process spawning. Apple's ScreenCaptureKit API, introduced in macOS 12.3, offers continuous frame capture via a callback — no process spawn, no disk I/O, frames delivered directly as pixel buffers.

We rewrote the server in Swift:

```swift
// ScreenCaptureKit delivers frames via delegate callback
func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType) {
    guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    guard let jpegData = ciContext.jpegRepresentation(
        of: ciImage,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        options: [kCGImageDestinationLossyCompressionQuality: 0.8]
    ) else { return }

    wsServer.broadcast(jpegData)
}
```

The JPEG encoding uses `CIContext` which leverages the GPU. The WebSocket server uses Apple's Network framework (`NWListener` with `NWProtocolWebSocket`), so zero external dependencies.

The client is a single HTML page served over a separate HTTP port:

```javascript
const ws = new WebSocket('ws://localhost:8888');
ws.binaryType = 'arraybuffer';
ws.onmessage = async (e) => {
    const blob = new Blob([e.data], {type: 'image/jpeg'});
    const bmp = await createImageBitmap(blob);
    ctx.drawImage(bmp, 0, 0, canvas.width, canvas.height);
    bmp.close();
};
```

`createImageBitmap` decodes the JPEG off the main thread. The whole thing connects over USB via `adb reverse tcp:8888 tcp:8888`.

**Result:** 29.4 FPS, ~4ms encode time. The jump from 10 FPS to 30 FPS was visceral — the display went from "slideshow" to "this is actually a monitor."

## Greyscale: Compression for Free

The Daylight DC-1 has an amber monochrome display. Every pixel of color data we send is wasted — the display can only show luminance. JPEG internally uses YCbCr color space, where Y is luminance and Cb/Cr are chrominance. If the image is greyscale, Cb and Cr are flat (constant), which means they compress to nearly nothing.

One line of code:

```swift
let grayImage = ciImage.applyingFilter("CIColorControls",
    parameters: [kCIInputSaturationKey: 0.0])
```

This desaturates on the GPU before JPEG encoding. Frame sizes dropped from ~500KB (color) to ~200KB (greyscale) at the same quality — a 2.5x bandwidth reduction for free.

## The Raw Pixels Experiment (and Why It Failed)

If the display is greyscale and compression adds latency, why compress at all? Send raw luminance: 1 byte per pixel, 1280x960 = 1,228,800 bytes per frame.

We extracted greyscale directly from the BGRA pixel buffer:

```swift
// BT.601 luminance from BGRA
let r = UInt16(px[2])
let g = UInt16(px[1])
let b = UInt16(px[0])
out[i] = UInt8((77 &* r &+ 150 &* g &+ 29 &* b) >> 8)
```

CPU-only, no GPU, ~2ms conversion time. The client expanded each byte back to RGBA:

```javascript
// Uint32Array writes 4 bytes per iteration (ABGR in little-endian)
const u32 = new Uint32Array(imgData.data.buffer);
for (let i = 0; i < gray.length; i++) {
    const v = gray[i];
    u32[i] = 0xFF000000 | (v << 16) | (v << 8) | v;
}
ctx.putImageData(imgData, 0, 0);
```

**Result:** 5 seconds of latency, frames buffering, required touch input to render.

1.2MB/frame x 30fps = 36MB/s. USB 2.0 through adb reverse tops out around 30-35MB/s real throughput. We were saturating the pipe, frames queued faster than they could transmit, and Chrome on Android throttled canvas updates when not actively interacted with.

**Lesson:** Bandwidth constraints are real even over USB. The "obvious" optimization (skip compression entirely) can backfire when the transport can't keep up. Greyscale JPEG at ~200KB was 7x less data for a ~3ms encode cost — a trade worth making.

## Frame Dropping: The Final Piece

The original client rendered every frame it received. If frames arrived faster than Chrome could paint, they queued up, creating a growing latency buffer. The fix was a `requestAnimationFrame` loop that only renders the most recent frame:

```javascript
let latestFrame = null;
let pending = false;

ws.onmessage = async (e) => {
    const bmp = await createImageBitmap(blob);
    if (latestFrame) latestFrame.close();  // Drop old frame
    latestFrame = bmp;
    if (!pending) { pending = true; requestAnimationFrame(render); }
};

function render() {
    if (latestFrame) {
        ctx.drawImage(latestFrame, 0, 0, canvas.width, canvas.height);
        latestFrame.close();
        latestFrame = null;
    }
    pending = false;
}
```

This guarantees the displayed frame is always the most recent one. Stale frames are discarded. The display shows what the Mac shows *now*, not what it showed 200ms ago.

## Where We Are

The current pipeline:

```
ScreenCaptureKit (BGRA, 30fps)
  → CIColorControls desaturate (GPU, ~1ms)
  → CIContext JPEG encode (GPU, ~3ms)
  → NWListener WebSocket broadcast (~200KB binary frame)
  → adb reverse USB tunnel (~5-10ms transit)
  → Chrome createImageBitmap (off-thread decode, ~5ms)
  → requestAnimationFrame → canvas drawImage
```

**Total latency: ~20-35ms.** At 30 FPS, it feels like a real monitor.

| Metric | Python screencapture | ScreenCaptureKit JPEG | Greyscale JPEG |
|--------|---------------------|-----------------------|----------------|
| FPS | 9.7 | 29.4 | 29.4 |
| Encode time | 103ms | 4.2ms | 3.0ms |
| Frame size | ~150KB | ~500KB | ~200KB |
| Bandwidth | ~1.5MB/s | ~15MB/s | ~6MB/s |
| GPU | None | Yes | Yes |
| Dependencies | Python | None | None |

The entire server is a single Swift file, ~300 lines, zero dependencies. It compiles with `swift build -c release` and runs as a standalone binary.

## What's Next (Part 2)

The remaining latency bottleneck is Chrome. The browser's rendering pipeline — JavaScript event loop, blob creation, off-thread decode, compositor scheduling — adds 10-15ms we could eliminate with a native Android app.

The plan: an Android NDK app using `ANativeWindow` for direct surface access, `libjpeg-turbo` for SIMD-accelerated decode, and raw TCP instead of WebSocket. If we can get from "bytes arrive on socket" to "pixels in surface buffer" in under 5ms, total latency drops to ~15-20ms.

But that's Part 2.

---

*The code is at [github.com/welfvh/daylight-mirror](https://github.com/welfvh/daylight-mirror). The Daylight DC-1 is made by [Daylight Computer](https://daylightcomputer.com).*
