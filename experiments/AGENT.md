# Latency Lab — Agent Loop

This document describes how an AI agent should use the latency lab to autonomously iterate on performance optimizations.

## Loop

```
1. Read ledger    →  python3 scripts/lab_analyze.py --json
2. Decide         →  Pick next experiment from suggestions (or invent one)
3. Write plan     →  experiments/<name>.local.json
4. Run            →  python3 scripts/latency_lab.py --plan experiments/<name>.local.json [--android]
5. Evaluate       →  Read the run directory output + updated ledger
6. Record         →  Ledger is auto-appended; commit the plan file if experiment passed
7. Repeat         →  Go to step 1
```

## Step 1: Read the Ledger

```bash
python3 scripts/lab_analyze.py --json
```

Returns:
- `rankings.by_rtt_avg_ms` — experiments ranked by average round-trip time (lower = better)
- `rankings.by_fps` — experiments ranked by frames per second (higher = better)
- `rankings.by_jitter_ms` — experiments ranked by frame timing consistency (lower = better)
- `failure_patterns` — common failure reasons and blocked commands
- `suggested_next` — proposed experiments with rationale

If the ledger is empty, start with the example plan: `experiments/plan.example.json`.

## Step 2: Decide What to Try

Priority order:
1. If `suggested_next` has entries, pick the highest-impact one
2. If a previous experiment was `blocked`, fix the blocking issue first
3. If all policy experiments passed, move to code-level changes (GL shader, backpressure, etc.)
4. If stuck, analyze `failure_patterns` for systemic issues

### Types of experiments

| Type | What changes | Risk |
|------|-------------|------|
| **Policy** | CLI settings only (resolution, sharpen, contrast) | None — no code changes |
| **Config** | Constants in `Sources/MirrorEngine/Configuration.swift` | Low — rebuild required |
| **Code** | Swift/C source changes | Medium — may break things |
| **Architecture** | Pipeline restructuring | High — use worktree isolation |

For policy experiments, you don't need worktrees — just set `"use_worktrees": false` in the plan.

## Step 3: Write a Plan

Create `experiments/<descriptive-name>.local.json`. The `.local.json` suffix is gitignored.

Minimal plan structure:

```json
{
  "baseline_id": "baseline-sharp",
  "default_warmup_s": 8,
  "default_measure_s": 25,
  "gates": {
    "fps_min": 26,
    "jitter_ms_max": 6.0,
    "rtt_avg_delta_max": 4.0,
    "rtt_p95_delta_max": 8.0
  },
  "experiments": [
    {
      "id": "baseline-sharp",
      "commands": [
        ["daylight-mirror", "resolution", "sharp"],
        ["daylight-mirror", "sharpen", "1.0"]
      ],
      "notes": "Control baseline"
    },
    {
      "id": "your-experiment-id",
      "commands": [
        ["daylight-mirror", "resolution", "comfortable"],
        ["daylight-mirror", "sharpen", "0.0"]
      ],
      "notes": "What you expect and why"
    }
  ]
}
```

Always include a baseline experiment first so the overseer has a reference point.

### For code-level experiments

Add build commands and use worktrees:

```json
{
  "git": {
    "use_worktrees": true,
    "base_ref": "main",
    "worktree_root": "../daylight-mirror-lab"
  },
  "experiments": [
    {
      "id": "gl-shader-blit",
      "branch": "exp/gl-shader-blit",
      "commands": [
        ["swift", "build", "-c", "release"],
        ["make", "install"],
        ["daylight-mirror", "resolution", "sharp"]
      ],
      "notes": "Replace NEON blit with GL shader on Android"
    }
  ]
}
```

## Step 4: Run

```bash
# Mac-only metrics
python3 scripts/latency_lab.py --plan experiments/your-plan.local.json

# Mac + Android metrics (requires connected device with adb)
python3 scripts/latency_lab.py --plan experiments/your-plan.local.json --android
```

Or use Makefile targets:

```bash
make lab-run LAB_PLAN=experiments/your-plan.local.json
make lab-run-android LAB_PLAN=experiments/your-plan.local.json
```

### Reproducible workload

Run `lab_scenario.py` during measurement for consistent screen activity:

```bash
# In a separate terminal, or before the lab run
python3 scripts/lab_scenario.py --scenario scroll --duration 30
```

Available scenarios: `idle`, `cursor`, `scroll`, `typing`, `drag`, `stress`, `full`.

## Step 5: Evaluate

After the run, check the output:

```bash
# Quick summary
cat experiments/results/<timestamp>/summary.json | python3 -m json.tool

# Detailed per-experiment results
cat experiments/results/<timestamp>/<experiment-id>.json | python3 -m json.tool

# Updated analysis across all runs
python3 scripts/lab_analyze.py
```

### Interpreting results

| Status | Meaning |
|--------|---------|
| `passed` | Met all gates — experiment is a viable improvement |
| `failed` | Violated one or more gates — check `reasons` field |
| `blocked` | Setup/build failed before measurement could start |
| `dry_run` | No execution (--dry-run mode) |

### Key metrics

From Mac status file (`/tmp/daylight-mirror.status`):
- `fps` — frames per second (target: 30)
- `rtt_avg_ms` — average round-trip latency
- `rtt_p95_ms` — 95th percentile RTT
- `jitter_ms` — frame timing variance
- `skipped_frames` — frames dropped due to backpressure

From Android logcat (when `--android` is used):
- `recv_ms` — time to receive frame over USB
- `lz4_ms` — LZ4 decompression time
- `delta_ms` — XOR delta application time
- `neon_ms` — NEON SIMD blit to surface time
- `vsync_ms` — time waiting for vsync
- `drops` — frames dropped by render thread

## Step 6: Record

The ledger (`experiments/results/ledger.jsonl`) is auto-appended by the overseer. If an experiment passed and represents a meaningful improvement:

1. Commit the plan file
2. If it was a code change in a worktree, merge the branch to main

## Available CLI Commands

The mirror daemon accepts these commands for runtime tuning:

```
daylight-mirror start|stop|status|reconnect
daylight-mirror resolution cozy|comfortable|balanced|sharp
daylight-mirror sharpen 0.0-1.5
daylight-mirror contrast 0.5-1.5
daylight-mirror fontsmoothing on|off
daylight-mirror brightness 0-255
daylight-mirror warmth 0-255
daylight-mirror backlight on|off|toggle
daylight-mirror latency [--watch]
```

## Current Bottleneck Order

From highest to lowest impact (Sharp 1600x1200 baseline):

1. Capture delay: 16.7ms (47%) — ScreenCaptureKit policy
2. NEON blit: 5.6ms (16%) — Android surface write
3. Delta XOR: 4.6ms (13%) — Android XOR application
4. LZ4 decompress: 3.0ms (9%) — Android decompression
5. Mac processing: 1.9ms (5%) — greyscale + sharpen + compress
6. USB transit: ~1.5ms (4%)
7. Vsync wait: 0.7ms (2%)

## Experiment Ideas Not Yet Tried

Run `python3 scripts/lab_analyze.py` for current suggestions. Common next steps:

- Zero sharpen (`sharpen 0.0`) — eliminates vImage convolution
- GL shader blit — replace NEON blit with OpenGL ES texture upload
- Adaptive backpressure — RTT-aware inflight threshold instead of fixed `> 2`
- ScreenCaptureKit `minimumFrameInterval` tuning
- Double-buffered decode — decode next frame while current one renders
