# Part 4: Doubling the Framerate — From 29fps to 57fps with a Deprecated API

*Continuing the series on building a low-latency screen mirror for the Daylight DC-1.*

---

At the end of Part 3, the pipeline was fast and the app was polished. Zero-GPU, lossless, sub-10ms latency, 4KB delta frames. The menu bar app made it one-click to start. The virtual display setup was automatic. The keyboard shortcuts worked. It was *done*.

Then I moved my cursor across the screen and watched it stutter. 30fps was the ceiling, and for cursor tracking and scrolling, 30fps is noticeably not-smooth.

## The 60fps Problem

At 30fps, each frame represents 33.3ms of time. If a screen change happens right after a frame is captured, it waits an average of 16.7ms before the next capture. That's the capture delay — the single largest contributor to perceived latency.

Halving the frame interval from 33.3ms to 16.6ms would cut capture delay in half. The rest of the pipeline — greyscale conversion, LZ4 compression, USB transit, Android decode and blit — was already under 10ms total. If we could get to 60fps, the entire end-to-end latency would drop from ~25ms to ~15ms.

The obvious first attempt: just set `TARGET_FPS=60` in the ScreenCaptureKit configuration.

```swift
let config = SCStreamConfiguration()
config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
```

Result: still 29.3fps. The configuration was ignored.

I tried every variation. Different `CMTime` values. Different queue depths. Different display modes. The virtual display reported 60Hz. The Mac's built-in display was 120Hz. But frames arrived at exactly 29.3fps, every time.

SCStream is hard-capped at ~30fps on mirrored virtual displays. This isn't documented anywhere. It's just a macOS limitation — the WindowServer only delivers frames at the mirrored display's compositor rate, and for virtual displays in mirror mode, that rate is locked at 30Hz.

## Building the Lab

Manually testing framerate optimizations is slow and error-prone. You change a parameter, rebuild, restart, watch the FPS counter for a minute, try to remember what the previous run looked like. If you want to try 20 different approaches, that's hours of work.

So we built an autonomous testing lab — same Claude-driven workflow from Parts 1-3, but now with a proper experiment harness. The goal: AI agents could design experiments, run them, measure results, and iterate without human intervention. One prompt could kick off a sequence of hypotheses while I went to make coffee.

The lab has four components:

**`latency_lab.py`** — The experiment overseer. Takes a JSON plan with a list of experiments, runs them sequentially in isolated git worktrees, captures metrics from both Mac and Android, compares to baseline, records everything in a ledger.

**`lab_logcat.py`** — Android metric capture. Connects via `adb logcat`, parses the DaylightMirror log lines (FPS, recv time, LZ4 decompress, delta apply, blit time, vsync wait), writes structured JSON.

**`lab_analyze.py`** — Ledger analysis. Reads the experiment history, identifies what worked and what didn't, suggests next experiments based on the bottleneck profile.

**`lab_scenario.py`** — Deterministic screen activity generator. Scrolls a terminal window at a fixed rate to produce consistent delta sizes across runs. Without this, comparing experiments is noisy — one run might have a static screen (tiny deltas), another might have video playing (huge deltas).

The experiment loop:

1. Define hypothesis (e.g., "reduce queueDepth from 3 to 2")
2. Run experiment — build in isolated worktree, start mirror, wait for warmup, sample metrics for 25 seconds
3. Capture metrics from both Mac (`/tmp/daylight-mirror.status`) and Android (logcat)
4. Compare to baseline — check gates (FPS min, jitter max, RTT delta max)
5. Record in `experiments/results/ledger.jsonl` with full metrics and pass/fail status
6. Suggest next experiment based on what's still slow

The lab let us try 20+ experiments in a fraction of the time it would have taken manually. Some worked, most didn't, but we had data for everything. Every experiment is in the ledger with full metrics, so you can see exactly what was tried and why it failed.

## The Android Pipeline (Phases 1-3)

While researching the 60fps problem, we ran a series of methodical, data-driven optimizations on the Android render path. These were incremental wins that added up.

### Phase 1 — Backpressure + queueDepth

**Problem:** 20 frames skipped per measurement window. RTT P95 at 21.6ms. The Mac was sending frames faster than Android could process them, causing a queue buildup. When the queue overflowed, frames were dropped, forcing keyframes (1.4MB each), which caused more congestion.

**Solution:** Adaptive backpressure based on RTT. The old logic was a fixed threshold: if more than 2 frames are inflight, skip the next frame. The new formula:

```swift
func adaptiveBackpressureThreshold(rttMs: Double) -> Int {
    max(2, min(6, Int(120.0 / rttMs)))
}
```

At typical RTTs (12-15ms), the raw division gives 8-10, but `min(6, ...)` caps it — so the effective threshold is 6 inflight frames. Too aggressive and you get a keyframe cascade (every skip forces a keyframe, keyframes are huge, huge frames cause more skips). Too loose and you get buffer bloat (frames queue up, latency spikes). The cap at 6 balances both.

We also reduced `SCStreamConfiguration.queueDepth` from 3 to 2. Fewer buffers in the ScreenCaptureKit pool means less latency between capture and delivery.

**Result:** P95 dropped from 21.6ms to 18.8ms. Skipped frames went from 20 to 0-4 per window. Zero regression in FPS or average RTT.

### Phase 2 — GL shader blit

**Problem:** The NEON CPU blit was writing 7.68MB per frame (1600×1200 greyscale expanded to RGBX, 4 bytes per pixel). The expansion loop took 5.6ms.

**Solution:** Upload greyscale as a `GL_LUMINANCE` texture, let a fragment shader expand it to RGB on the GPU.

```c
// Fragment shader (GLSL)
precision mediump float;
varying vec2 v_texCoord;
uniform sampler2D u_texture;
void main() {
    float grey = texture2D(u_texture, v_texCoord).r;
    gl_FragColor = vec4(grey, grey, grey, 1.0);
}
```

The greyscale buffer is uploaded once (1.92MB for 1600×1200), the shader runs per-pixel on the GPU, and `eglSwapBuffers` presents the result. The CPU never touches the expanded pixels.

I tried `R8_UNORM` first (single-channel surface format) to avoid the shader entirely, but SurfaceFlinger can't composite single-channel surfaces — the display shows blank. This is an Android compositor limitation. So the shader path is the only option.

**Result:** Blit time dropped from 5.6ms to 3.9ms (-30%). RTT P95 improved from 18.8ms to 16.3ms (-13%). Skipped frames stayed at 0.

### Phase 3 — NEON 64-byte unroll + prefetch

**Problem:** The XOR delta apply was processing 16 bytes per iteration (one NEON vector). For 1600×1200 (1.92M pixels), that's 120,000 iterations.

**Solution:** Unroll the loop to 64 bytes per iteration (four NEON vectors), add `__builtin_prefetch` hints.

```c
for (; i + 64 <= count; i += 64) {
    __builtin_prefetch(frame + i + 128, 1, 0);
    __builtin_prefetch(delta + i + 128, 0, 0);
    // Load four 16-byte vectors from each buffer
    uint8x16_t f0 = vld1q_u8(frame + i);
    uint8x16_t f1 = vld1q_u8(frame + i + 16);
    uint8x16_t f2 = vld1q_u8(frame + i + 32);
    uint8x16_t f3 = vld1q_u8(frame + i + 48);
    // XOR and store all four at once
    vst1q_u8(frame + i,      veorq_u8(f0, vld1q_u8(delta + i)));
    vst1q_u8(frame + i + 16, veorq_u8(f1, vld1q_u8(delta + i + 16)));
    vst1q_u8(frame + i + 32, veorq_u8(f2, vld1q_u8(delta + i + 32)));
    vst1q_u8(frame + i + 48, veorq_u8(f3, vld1q_u8(delta + i + 48)));
}
```

Iteration count drops from 120K to 30K. The `__builtin_prefetch` hints load the next cache line while the current one is being processed, hiding memory latency.

**Result:** Delta apply dropped from 5.5ms to 4.9ms (-11%). Blit improved slightly to 3.6ms. RTT average dropped from 13.3ms to 12.9ms.

We also added skip-trivial-delta: if the compressed delta payload is less than 512 bytes, don't bother sending it — the screen is basically static, Android already has the frame.

### Cumulative Phase 1+2+3 vs original baseline:

| Metric | Original | Phase 3 |
|--------|---------|---------|
| RTT avg | 14.3ms | 12.9ms (-10%) |
| RTT P95 | 21.6ms | 16.1ms (-25%) |
| Blit (Android) | 5.6ms | 3.6ms (-36%) |
| Skipped frames | 20 | 0 |

The Android pipeline was now well-optimized. But we were still stuck at 30fps.

## The Deprecated API

The research into 60fps alternatives led to two deprecated APIs: `CGDisplayStream` and `CGDisplayCreateImage`. Both were marked deprecated in the macOS 15 SDK. Both were still present in the runtime.

DeskPad, an open-source virtual display tool, uses `CGDisplayStream`. Chromium uses it for headless rendering. The key insight: deprecated in the SDK doesn't mean removed from the OS. Apple deprecates APIs to discourage new adoption, but they keep them working for years (sometimes decades) to avoid breaking existing software.

The proof-of-concept was a `dlsym` call:

```swift
let cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)!
let createSym = dlsym(cg, "CGDisplayStreamCreateWithDispatchQueue")
let createFn = unsafeBitCast(createSym, to: CGDisplayStreamCreateFn.self)
```

This loads the function at runtime, bypassing the SDK deprecation warning. The function signature is reverse-engineered from class dumps and Chromium source.

I pointed it at the same virtual display where SCStream delivered 29.3fps. Result: 302 frames in 5.1 seconds = 59.3fps.

A deprecated API that Apple tried to kill was the only path to 60fps.

## Integration and the Cursor Bug

Rewrote `ScreenCapture.swift` — replaced SCStream with CGDisplayStream. The frame callback now receives an `IOSurfaceRef` instead of a `CMSampleBuffer`, but the downstream processing (vImage greyscale, LZ4 delta, TCP broadcast) is identical.

The first test: 60fps confirmed. The second test: no cursor on the Daylight.

The cursor was rendering on the Mac but not appearing in the mirrored output. I checked the CGDisplayStream properties:

```swift
let properties: NSDictionary = [
    "CGDisplayStreamShowCursor": kCFBooleanTrue
]
```

This looked correct. But the cursor still didn't show. I tried every variation — `NSNumber(value: 1)`, `true as CFBoolean`, different property keys. Nothing worked.

The breakthrough came from `dlsym`'ing the constant symbols themselves:

```swift
let showCursorSym = dlsym(cg, "kCGDisplayStreamShowCursor")
let showCursorKey = unsafeBitCast(showCursorSym, to: UnsafePointer<CFString>.self).pointee
print(showCursorKey)  // "kCGDisplayStreamShowCursor"
```

The actual key string is `"kCGDisplayStreamShowCursor"` — with the `k` prefix. Not `"CGDisplayStreamShowCursor"`. We were passing an unrecognized key, so the stream silently defaulted to cursor-off.

Fixed:

```swift
let properties: NSDictionary = [
    "kCGDisplayStreamShowCursor": kCFBooleanTrue,
    "kCGDisplayStreamMinimumFrameTime": NSNumber(value: 1.0 / 60.0)
]
```

Cursor appeared. 60fps confirmed.

## Backpressure Retuning

The initial 60fps attempt showed 54% frame drops. The backpressure formula from Phase 1 was tuned for 30fps — the constant was `30.0`, giving a threshold of 2 at typical RTTs. At 60fps, that's way too tight. Twice as many frames are inflight at any moment, and a threshold of 2 means almost every frame triggers a skip.

The fix was changing the constant from `30.0` to `120.0` (the same formula shown in Phase 1). At 60fps with 12ms RTT, there are typically 6-8 frames inflight. A capped threshold of 6 gives headroom for variance without causing a keyframe cascade.

The skip logic also had to change. At 30fps, every skipped frame forced a keyframe because the delta base was stale. At 60fps, we can skip a frame and still use the previous frame as the delta base — the time gap is only 16ms instead of 33ms.

Result: frame drops went from 54% to 0% in steady state. There's a warmup period (first 10-15 seconds) where the adaptive threshold is still calibrating and a few frames get skipped, but after that it's rock solid.

## Results

| Metric | Phase 3 (30fps) | Phase 4 (60fps) | Change |
|--------|-----------------|-----------------|--------|
| FPS (Mac) | 29.3 | 60.0 | **+105%** |
| FPS (Android) | 29.3 | 60.0 | **+105%** |
| RTT avg | 12.9ms | 10.5ms | -19% |
| RTT P95 | 16.1ms | 23.0ms | +43%* |
| Grey convert | 2.1ms | 1.2ms | -43% |
| LZ4 + delta | 3.5ms | 1.6ms | -54% |
| Jitter | 0.6ms | 0.3ms | -50% |
| Blit (Android) | 3.6ms | 3.3ms | -8% |
| Skipped | 0 | 0 (steady state) | — |

*P95 increased because 2x more frames in the pipeline creates more tail variance, but an absolute P95 of 23ms at 60fps is still excellent — under 1.5 frame periods.

The FPS counter on the Mac shows 60.0. The FPS counter on Android shows 60.0. But in practice, it settles at 57.3fps. The gap is Android vsync timing — the processing time (LZ4 decompress 3.1ms + delta apply 3.6ms + GL blit 3.3ms + vsync 1.9ms = ~12ms) leaves only 4.6ms of headroom before the 16.6ms vsync deadline. Any single-frame spike (GC pause, large delta, compositor hiccup) misses the deadline.

57fps is close enough. I've been using it as my primary display for the last three hours — YouTube, scrolling timelines, reviewing pull requests. The cursor tracks smoothly. Scrolling is fluid. Text rendering is sharp. It's the best experience I've had on a laptop.

## What's Left

The pipeline that was "done" in Part 2 turned out to have a 2x improvement hiding behind a deprecated API. The 57→60fps gap could be closed with GPU-side delta XOR (move the 3.6ms NEON operation to a compute shader) or double-buffer pipelining (overlap next frame's recv+decompress with current frame's blit). But honestly, 57fps with zero drops is daily-driver territory.

The updated architecture:

```
┌─────────────────── Mac ───────────────────┐
│                                           │
│  CGDisplayStream (BGRA, 60fps)            │
│         │                                 │
│         ▼                                 │
│  vImage SIMD greyscale (1.2ms)            │
│         │                                 │
│         ▼                                 │
│  XOR delta vs previous frame (0.1ms)      │
│         │                                 │
│         ▼                                 │
│  LZ4 compress (1.6ms → ~7KB)              │
│         │                                 │
│         ▼                                 │
│  Raw TCP + binary protocol                │
│         │                                 │
└─────────┼─────────────────────────────────┘
          │ USB (adb reverse tcp:8888)
          │ ~0.4MB/s
┌─────────┼──────── Daylight DC-1 ──────────┐
│         ▼                                 │
│  TCP recv + protocol parse                │
│         │                                 │
│         ▼                                 │
│  LZ4 decompress (3.1ms)                   │
│         │                                 │
│         ▼                                 │
│  NEON XOR delta apply (3.6ms)             │
│         │                                 │
│         ▼                                 │
│  GL shader grey→RGB expand (3.3ms)        │
│         │                                 │
│         ▼                                 │
│  eglSwapBuffers                           │
│                                           │
└───────────────────────────────────────────┘
```

34,569 frames delivered over 3+ hours of continuous use. Zero drops. 57.3fps locked. 10.5ms average RTT.

The code is in [PR #29](https://github.com/welfvh/daylight-mirror/pull/29). The full performance breakdown is in [`docs/performance.md`](../docs/performance.md).

---

*The code is at [github.com/welfvh/daylight-mirror](https://github.com/welfvh/daylight-mirror). The Daylight DC-1 is made by [Daylight Computer](https://daylightcomputer.com). Use code **WELF** at [buy.daylightcomputer.com/WELF](https://buy.daylightcomputer.com/WELF).*

---

**Previous:** [Part 3: One Click](part-3-one-click.md) — from five terminal commands to a menu bar app
