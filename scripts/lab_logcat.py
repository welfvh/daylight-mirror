#!/usr/bin/env python3
"""Capture Android-side latency metrics from adb logcat.

Parses DaylightMirror log lines and writes structured samples to a JSON file
that the overseer can merge with Mac-side status metrics.

Usage:
    python3 scripts/lab_logcat.py --output /tmp/daylight-mirror-android.json --duration 30
    python3 scripts/lab_logcat.py --output /tmp/daylight-mirror-android.json --follow
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


# Match the LOGI line from mirror_native.c:
# FPS: 28.5 | recv: 20.0ms | lz4: 3.0ms | delta: 4.6ms | neon: 5.6ms | vsync: 0.7ms | 294KB delta | drops: 1 | overwritten: 0 | total: 827
STATS_RE = re.compile(
    r"FPS:\s*(?P<fps>[\d.]+)\s*\|"
    r"\s*recv:\s*(?P<recv_ms>[\d.]+)ms\s*\|"
    r"\s*lz4:\s*(?P<lz4_ms>[\d.]+)ms\s*\|"
    r"\s*delta:\s*(?P<delta_ms>[\d.]+)ms\s*\|"
    r"\s*neon:\s*(?P<neon_ms>[\d.]+)ms\s*\|"
    r"\s*vsync:\s*(?P<vsync_ms>[\d.]+)ms\s*\|"
    r"\s*(?P<frame_kb>\d+)KB\s+(?P<frame_type>\w+)\s*\|"
    r"\s*drops:\s*(?P<drops>\d+)\s*\|"
    r"\s*overwritten:\s*(?P<overwritten>\d+)\s*\|"
    r"\s*total:\s*(?P<total>\d+)"
)


def parse_stats_line(line: str) -> dict[str, Any] | None:
    m = STATS_RE.search(line)
    if not m:
        return None
    return {
        "ts": datetime.now(timezone.utc).isoformat(),
        "fps": float(m.group("fps")),
        "recv_ms": float(m.group("recv_ms")),
        "lz4_ms": float(m.group("lz4_ms")),
        "delta_ms": float(m.group("delta_ms")),
        "neon_ms": float(m.group("neon_ms")),
        "vsync_ms": float(m.group("vsync_ms")),
        "frame_kb": int(m.group("frame_kb")),
        "frame_type": m.group("frame_type"),
        "drops": int(m.group("drops")),
        "overwritten": int(m.group("overwritten")),
        "total": int(m.group("total")),
    }


def run_logcat(output_path: Path, duration_s: float | None, follow: bool) -> int:
    samples: list[dict[str, Any]] = []
    deadline = time.time() + duration_s if duration_s else None

    subprocess.run(["adb", "logcat", "-c"], capture_output=True, check=False)

    proc = subprocess.Popen(
        ["adb", "logcat", "-s", "DaylightMirror:I"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    try:
        assert proc.stdout is not None
        for line in proc.stdout:
            line = line.strip()
            sample = parse_stats_line(line)
            if sample:
                samples.append(sample)
                if follow:
                    print(json.dumps(sample))

                output_path.write_text(
                    json.dumps({"samples": samples, "count": len(samples)}, indent=2) + "\n",
                    encoding="utf-8",
                )

            if deadline and time.time() >= deadline:
                break
    except KeyboardInterrupt:
        pass
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()

    output_path.write_text(
        json.dumps({"samples": samples, "count": len(samples)}, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Captured {len(samples)} Android metric samples → {output_path}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Capture Android-side latency metrics via adb logcat")
    parser.add_argument("--output", default="/tmp/daylight-mirror-android.json", help="Output JSON path")
    parser.add_argument("--duration", type=float, default=None, help="Capture duration in seconds (default: until Ctrl+C)")
    parser.add_argument("--follow", action="store_true", help="Print samples to stdout as they arrive")
    args = parser.parse_args()

    result = subprocess.run(["adb", "devices"], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        print("ERROR: adb not found. Install with: brew install android-platform-tools", file=sys.stderr)
        return 1

    return run_logcat(Path(args.output), args.duration, args.follow)


if __name__ == "__main__":
    raise SystemExit(main())
