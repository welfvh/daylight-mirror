# Performance Guide

How to measure, profile, and optimize latency in Daylight Mirror.

## Architecture

```
Mac                              USB                 Daylight DC-1
┌──────────────────┐         ┌───────┐         ┌──────────────────┐
│ CGDisplayStream  │──BGRA──▶│       │         │                  │
│ vImage greyscale │──grey──▶│       │  TCP    │ LZ4 decompress   │
│ LZ4 delta compress│─bytes─▶│  USB  │────────▶│ XOR delta apply  │
│                  │         │       │         │ GL shader blit   │
│                  │◀──ACK───│       │◀───ACK──│ eglSwapBuffers   │
└──────────────────┘         └───────┘         └──────────────────┘
```

Every frame follows this pipeline:

1. **Capture** — CGDisplayStream delivers an IOSurface with BGRA pixels at 60fps
2. **Greyscale** — vImage SIMD converts BGRA→grey (1 byte/pixel)
3. **Compress** — LZ4 compresses either a full keyframe or XOR delta against the previous frame
4. **Transmit** — TCP over USB sends `[DA 7E][flags][seq][len][payload]`
5. **Decompress** — Android LZ4-decompresses into a buffer
6. **Delta apply** — NEON XOR reconstructs the current frame (skip for keyframes)
7. **Blit** — NEON expands grey→RGBX (4 bytes/pixel) into ANativeWindow buffer
8. **Display** — `ANativeWindow_unlockAndPost` presents to screen

Android sends an ACK `[DA 7A][seq]` back to Mac after step 5 (after decode, before blit). The Mac uses this to measure RTT and track inflight frames for backpressure.

## Measuring Latency

### Mac-side

```bash
# One-shot snapshot
daylight-mirror latency

# Live monitoring (refreshes every 2s)
daylight-mirror latency --watch
```

Output:
```
FPS:              28.5
Clients:          1
Total frames:     837
Skipped frames:   12

Mac processing:
  Greyscale:      0.4 ms
  LZ4 compress:   1.5 ms
  Jitter:         1.7 ms

Round-trip (Mac → Daylight → Mac):
  Average:        23.5 ms
  P95:            44.3 ms

Est. one-way:     ~11.8 ms
```

### Android-side

```bash
adb logcat -s DaylightMirror
```

Output:
```
FPS: 28.5 | recv: 20.0ms | lz4: 3.0ms | delta: 4.6ms | neon: 5.6ms | vsync: 0.7ms | 294KB delta | drops: 1 | total: 827
```

### What each metric means

| Metric | Source | What it measures |
|--------|--------|------------------|
| **FPS** | Both | Frames actually processed per second |
| **Greyscale** | Mac | vImage BGRA→grey conversion |
| **LZ4 compress** | Mac | Compression time (keyframe or delta) |
| **Jitter** | Mac | Deviation from expected 16.6ms frame interval |
| **RTT avg/P95** | Mac | Time from `broadcast()` to ACK received |
| **Skipped frames** | Mac | Frames dropped by backpressure (inflight > adaptive threshold, except scheduled keyframes) |
| **recv** | Android | Time from start of `read()` to payload complete — mostly idle wait, not a bottleneck |
| **lz4** | Android | LZ4 decompression |
| **delta** | Android | NEON XOR delta apply |
| **neon** | Android | Grey→RGBX pixel expansion (the expensive blit step) |
| **vsync** | Android | Time in `ANativeWindow_unlockAndPost` after buffer is written |
| **drops** | Android | Sequence gaps (frames lost in transit) |

### Machine-readable

```bash
# Status file updated every 5s (CLI daemon only)
cat /tmp/daylight-mirror.status

# Control socket query (works with GUI app too)
daylight-mirror latency
```

## Current Baseline (v1.3 + Phase 4, 1600x1200 Sharp, 60fps)

| Stage | Time | % of pipeline |
|-------|------|---------------|
| Capture delay (avg) | 8.3 ms | 37% |
| Mac processing | 2.8 ms | 12% |
| USB transit | ~1.5 ms | 7% |
| LZ4 decompress | 3.1 ms | 14% |
| Delta apply | 3.6 ms | 16% |
| GL shader blit | 3.3 ms | 15% |
| Vsync wait | 1.9 ms | 8% |
| USB return (ACK) | ~1.5 ms | 7% |
| **Total** | **~22.5 ms** | |

Measured RTT: 10.5ms avg, 23.0ms P95. FPS: 60.0 Mac / 60.0 Android.

## Where Time Is Spent

### Capture delay — 8.3ms (37%)

At 60fps, a screen change waits on average half a frame interval (8.3ms) before CGDisplayStream captures it. This was halved from 16.7ms by migrating from SCStream (capped at 30fps on mirrored displays) to CGDisplayStream.

### Delta apply — 3.6ms (16%)

NEON XOR of 1.92M bytes with 64-byte unrolled loop + prefetch hints. Memory-bandwidth bound.

### GL shader blit — 3.3ms (15%)

GL_LUMINANCE texture upload + fragment shader grey→RGB expansion + `eglSwapBuffers`. Replaced the 5.6ms NEON CPU blit.

### LZ4 decompress — 3.1ms (14%)

LZ4 is already one of the fastest decompressors. Delta frames compress well (~7KB idle, ~300KB active), keyframes ~1.4MB.

### Mac processing — 2.8ms (12%)

vImage SIMD greyscale (1.2ms) + LZ4 compress (1.6ms). Fast.

## Optimization Opportunities

### Research Synthesis (Feb 2026)

Recent internal + external research confirms the existing profile in this doc: the most valuable work is on Android render-path memory bandwidth, not Mac capture/greyscale/compress.

### Confirmed bottleneck order (Sharp 1600x1200, post all Phase 1-4 optimizations, 60fps)

1. Capture delay (60fps cadence): 8.3ms
2. Android delta XOR apply: 3.6ms
3. Android GL shader blit: 3.3ms
4. Android LZ4 decompress: 3.1ms
5. Mac processing total: 1.2ms grey + 1.6ms LZ4 = 2.8ms
6. Android vsync: 1.9ms

All stages are now under 9ms. The pipeline is well-balanced with no single dominant bottleneck.

### Recommended Execution Plan

### Phase 1 (high confidence, low-medium risk) — DONE

1. ~~Add a latency-focused profile that defaults to 1024x768 (Comfortable).~~ — Resolution changes trigger pipeline restarts; not a reliable latency optimization. Sharp performs best due to capture stability.
2. ✓ Backpressure is now adaptive (RTT/inflight-aware): `max(1, min(4, Int(30.0 / rttAvgMs)))`.
3. ✓ Forced keyframe recovery preserved. Skipped frames dropped from ~20 to 0-4.
4. ✓ `SCStreamConfiguration.queueDepth` reduced from 3→2. P95 latency improved 13%.

Outcome: P95 RTT 21.6→18.8ms, frame skipping nearly eliminated, zero regression in FPS or avg RTT.

### Phase 2 (highest upside) — DONE

GL shader blit path on Android: greyscale uploaded as GL_LUMINANCE texture, expanded to RGB in fragment shader, presented via `eglSwapBuffers` with `eglSwapInterval(0)`. Falls back to NEON blit if GL init fails.

Results (Sharp 1600x1200, Feb 2026 lab sweep):

| Metric | Before GL (NEON) | After GL shader |
|--------|-----------------|-----------------|
| Blit time | 5.6ms | 3.9ms (-30%) |
| RTT avg | 14.2ms | 13.3ms (-6%) |
| RTT P95 | 18.8ms | 16.3ms (-13%) |
| Skipped | 0-4 | 0 |

Combined Phase 1+2 vs original baseline:

| Metric | Original | After all opts |
|--------|---------|----------------|
| RTT avg | 14.3ms | 13.3ms (-7%) |
| RTT P95 | 21.6ms | 16.3ms (-25%) |
| Skipped | 20 | 0 |

### Phase 3 (incremental) — DONE

Wider NEON delta XOR: unrolled `apply_delta_neon()` from 16-byte to 64-byte per iteration (4x NEON vectors per loop body). Reduces iteration count from 120K to 30K for 1600x1200.

Results (Sharp 1600x1200, Feb 2026 lab sweep):

| Metric | Before (16B/iter) | After (64B/iter) |
|--------|-------------------|------------------|
| delta_ms | 5.5ms | 4.9ms (-11%) |
| neon_ms (blit) | 3.9ms | 3.6ms (-8%) |
| RTT avg | 13.3ms | 12.9ms (-3%) |
| RTT P95 | 16.3ms | 16.1ms (-1%) |
| Skipped | 0 | 0 |

Cumulative Phase 1+2+3 vs original baseline:

| Metric | Original | Phase 3 |
|--------|---------|---------|
| RTT avg | 14.3ms | 12.9ms (-10%) |
| RTT P95 | 21.6ms | 16.1ms (-25%) |
| Blit (Android) | 5.6ms | 3.6ms (-36%) |
| Delta XOR | 4.6ms | 4.9ms* |
| Skipped | 20 | 0 |

*Delta XOR increased slightly vs Phase 1 baseline due to GL shader path changing measurement context; absolute time is 4.9ms down from pre-unroll 5.5ms.

### Phase 4 (60fps via CGDisplayStream) — DONE

Replaced SCStream (ScreenCaptureKit) with CGDisplayStream for frame capture. SCStream was hard-capped at ~30fps on mirrored virtual displays — a macOS limitation. CGDisplayStream (deprecated in macOS 15 SDK but still present at runtime) achieves 60fps on the same display.

Changes:
- `ScreenCapture.swift`: Complete rewrite of capture backend. SCStream → CGDisplayStream via `dlsym` (runtime loading bypasses SDK deprecation). Frame callback receives `IOSurfaceRef` instead of `CMSampleBuffer`. All downstream processing (vImage greyscale, LZ4 delta, TCP broadcast) unchanged.
- `CompositorPacer.swift`: CADisplayLink preferred rate 30→60Hz, timer fallback 33ms→16ms.
- Backpressure formula: `max(2, min(6, Int(120.0 / max(rtt, 1.0))))` — allows more inflight frames at 60fps.

Results (Sharp 1600x1200, Feb 2026):

| Metric | Phase 3 (30fps) | Phase 4 (60fps) | Change |
|--------|-----------------|-----------------|--------|
| FPS (Mac) | 29.3 | 60.0 | **+105%** |
| FPS (Android) | 29.3 | 60.0 | **+105%** |
| RTT avg | 12.9ms | 10.5ms | -19% |
| RTT P95 | 16.1ms | 23.0ms | +43%* |
| Grey convert | 2.1ms | 1.2ms | -43% |
| LZ4 + delta | 3.5ms | 1.6ms | -54% |
| Jitter | 0.6ms | 0.3ms | -50% |
| Skipped | 0 | 254 (warmup only) | Stable after warmup |

*P95 increased because 2x more frames in the pipeline creates more tail variance, but absolute P95 of 23ms is still excellent at 60fps (under 1.5 frame periods).

### Cumulative Phase 1+2+3+4 vs original baseline:

| Metric | Original | Current |
|--------|---------|---------|
| FPS | 29.3 | **60.0 (+105%)** |
| RTT avg | 14.3ms | **10.5ms (-27%)** |
| RTT P95 | 21.6ms | 23.0ms (+6%) |
| Blit (Android) | 5.6ms | **3.3ms (-41%)** |
| Delta XOR | 4.6ms | **3.6ms (-22%)** |
| Grey convert (Mac) | 1.4ms | **1.2ms (-14%)** |
| LZ4 compress (Mac) | 4.3ms | **1.6ms (-63%)** |
| Skipped | 20 | 0 (steady state) |

### Updated bottleneck order (post Phase 1-2-3-4, 60fps)

1. Capture delay (60fps cadence): 8.3ms avg wait
2. Android delta XOR: 3.6ms
3. Android GL shader blit: 3.3ms
4. Android LZ4 decompress: 3.1ms
5. Mac grey+compress: 2.8ms
6. Android vsync: 1.9ms

### Experiment Rules (to avoid regressions)

For each optimization, run the same evaluation loop:

1. Capture baseline with `daylight-mirror latency --watch` and Android logcat stats.
2. Apply one change at a time.
3. Compare: FPS stability, skipped/overwritten frames, RTT avg/P95, subjective cursor smoothness.
4. Keep change only if metrics improve without introducing visual instability.

### External Research Notes (applied to this codebase)

- CGDisplayStream (deprecated but runtime-available) is the only path to >30fps capture on mirrored virtual displays. SCStream has an internal cap. DeskPad (github.com/Stengo/DeskPad) also uses CGDisplayStream for this reason.
- ScreenCaptureKit guidance generally favors minimizing queued work and dropping late frames instead of building latency. This aligns with current backpressure behavior in `ScreenCapture.swift`.
- Android guidance confirms `ANativeWindow` + CPU blit paths are sensitive to memory bandwidth and compositor constraints for single-channel formats; this matches observed `R8_UNORM` limitations in this project.
- DC-1 panel (MT6789/Helio G99) supports 6/10/15/24/30/45/60/72/90/120 Hz. Currently runs at 60Hz via `Surface.setFrameRate(60.0f)`.
- This project should prefer measured pipeline wins over generic platform tuning folklore; each step above is intentionally test-first.

### Remaining Opportunities (Phase 5+)

Current state: 57fps locked, zero drops, 10.5ms RTT avg over 3+ hours of real-world use (YouTube, scrolling, PR review). These are diminishing-returns optimizations — user-perceptible improvements are unlikely, but they could close the 57→60fps gap.

#### 57→60fps gap

We consistently hit 57.3fps instead of 60.0. Android processing totals ~14.7ms with only 1.9ms of headroom before the 16.6ms vsync deadline. Any single-frame spike (GC pause, large delta, compositor hiccup) misses the deadline. Three approaches:

1. **Investigate vsync wait time** — Android reports 4.0–4.6ms in `eglSwapBuffers`, which seems high for `eglSwapInterval(0)`. If the swap interval isn't actually being honored, fixing it would recover ~2ms of headroom.

2. **GPU-side delta XOR** — The 3.2ms NEON XOR could move to a compute or fragment shader. CPU wouldn't touch pixel data at all: LZ4 decompresses into a GPU-mapped buffer, shader XORs against previous frame, same shader expands grey→RGB. Eliminates ~3ms of CPU work.

3. **Double-buffer pipelining** — Overlap next frame's recv+decompress with current frame's blit:
   ```
   Current:  [recv][lz4][delta][blit]  [recv][lz4][delta][blit]
   Pipelined: [recv][lz4][delta][blit]
                            [recv][lz4][delta][blit]
   ```
   Requires a second decode buffer and a producer-consumer thread. Medium complexity but would absorb the heavy-delta dips (48-54fps during fast scrolling) by hiding recv+decompress latency behind blit.

#### Heavy-content dips

During fast scrolling or video playback, delta sizes spike to 300–744KB. LZ4 decompression scales with payload size, pushing total processing past 16.6ms for 2–3 frames. Double-buffer pipelining (above) is the most direct fix. Alternatively, LZ4 HC compression on the Mac side would shrink payloads (better ratio, same decompress speed) at the cost of slower Mac-side compression — but Mac processing is only 2.8ms, so there's budget.

## What We Tried and Why It Didn't Work

### R8_UNORM single-channel surface

**Goal**: Write 1 byte/pixel directly to ANativeWindow instead of 4 bytes/pixel RGBX.

`ANativeWindow_setBuffersGeometry(window, w, h, AHARDWAREBUFFER_FORMAT_R8_UNORM)` returns success, and `ANativeWindow_lock` works, but SurfaceFlinger cannot composite single-channel surfaces — the display shows blank. This is an Android compositor limitation, not a hardware limitation.

The code is still in `mirror_native.c` behind `g_r8_supported = 0` if a future Android version adds support.

### 60fps via SCStream (failed) → CGDisplayStream (succeeded)

**Goal**: Halve capture delay from 16.7ms to 8.3ms.

SCStream (ScreenCaptureKit) is hard-capped at ~30fps on mirrored virtual displays regardless of `minimumFrameInterval` setting. This is a macOS limitation — the WindowServer only delivers frames at the mirrored display's compositor rate.

CGDisplayStream (deprecated in macOS 15 SDK but still present at runtime) does NOT have this limitation and delivers 60fps on the same virtual display. Confirmed via `dlsym` + POC: 302 frames in 5.1s = 59.3fps. Now integrated as the production capture backend (Phase 4).

### queueDepth 1

**Goal**: Reduce SCStream buffering delay.

`SCStreamConfiguration.queueDepth = 1` causes SCStream to stall frame delivery entirely. The first frame renders but no subsequent frames arrive. queueDepth 3 (default) works reliably.

### queueDepth 2 + adaptive backpressure ✓ (SCStream era, now CGDisplayStream)

**Goal**: Reduce capture-to-delivery latency without stalling.

Combined two changes (during SCStream era):
1. `SCStreamConfiguration.queueDepth = 2` (was 3) — fewer buffers in the ScreenCaptureKit pool
2. Adaptive backpressure threshold based on RTT — replaces fixed `inflight > 2`

Now using CGDisplayStream (Phase 4), backpressure formula is `max(2, min(6, Int(120.0 / max(rtt, 1.0)))`.

**Results** (Sharp 1600x1200, Feb 2026 lab sweep):

| Metric         | Before (qD=3, fixed) | After (qD=2, adaptive) |
|----------------|----------------------|------------------------|
| FPS            | 29.3                 | 29.3                   |
| RTT avg        | 14.3ms               | 14.2ms                 |
| RTT P95        | 21.6ms               | 18.8ms (-13%)          |
| Grey ms        | 1.4ms                | 0.8ms (-43%)           |
| LZ4 compress   | 4.3ms                | 1.5ms (-65%)           |
| Jitter         | 0.8ms                | 0.9ms                  |
| Skipped frames | 20                   | 0-4                    |

P95 tail latency improved 13% and frame skipping was nearly eliminated. The adaptive threshold at 14ms RTT computes to 2 (same as old fixed threshold), but dynamically tightens under congestion and loosens when the pipe is clear.

## Protocol Reference

### Frame packet
```
[0xDA 0x7E] [flags:1] [seq:4 LE] [len:4 LE] [LZ4 payload]
```
- `flags` bit 0: 1=keyframe (full frame), 0=delta (XOR with previous)
- `seq`: monotonically increasing frame sequence number
- `len`: byte length of LZ4 payload

### ACK packet
```
[0xDA 0x7A] [seq:4 LE]
```
Sent by Android after decompressing and applying the frame (before blit). Used by Mac for RTT measurement and inflight backpressure.

### Command packet
```
[0xDA 0x7F] [cmd:1] [value:1]
```
Mac→Android control commands (brightness, warmth, backlight, resolution).
