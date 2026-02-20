#!/usr/bin/env python3
"""Analyze the experiment ledger and rank results.

Reads experiments/results/ledger.jsonl, computes rankings across all recorded
experiments, identifies failure patterns, and proposes next experiments.

Usage:
    python3 scripts/lab_analyze.py
    python3 scripts/lab_analyze.py --ledger path/to/ledger.jsonl
    python3 scripts/lab_analyze.py --json
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Any


def load_ledger(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    entries: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return entries


def latest_per_id(entries: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    latest: dict[str, dict[str, Any]] = {}
    for entry in entries:
        eid = entry.get("id", "")
        latest[eid] = entry
    return latest


def rank_by_metric(
    experiments: dict[str, dict[str, Any]],
    metric_key: str,
    lower_is_better: bool = True,
) -> list[tuple[str, float | None]]:
    scored: list[tuple[str, float | None]] = []
    for eid, exp in experiments.items():
        avg = exp.get("metrics", {}).get("averages", {}).get(metric_key)
        scored.append((eid, avg))

    scored.sort(key=lambda x: (x[1] is None, x[1] if lower_is_better else -(x[1] or 0)))
    return scored


def failure_patterns(entries: list[dict[str, Any]]) -> dict[str, Any]:
    status_counts: Counter[str] = Counter()
    reason_counts: Counter[str] = Counter()
    blocked_commands: list[str] = []

    for entry in entries:
        status_counts[entry.get("status", "unknown")] += 1
        for reason in entry.get("reasons", []):
            reason_counts[reason] += 1
        if entry.get("status") == "blocked":
            for cr in entry.get("command_results", []):
                if cr.get("returncode", 0) != 0:
                    blocked_commands.append(" ".join(cr.get("argv", [])))

    return {
        "status_distribution": dict(status_counts),
        "top_failure_reasons": dict(reason_counts.most_common(10)),
        "blocked_commands": blocked_commands[:10],
    }


def suggest_next(experiments: dict[str, dict[str, Any]], all_entries: list[dict[str, Any]]) -> list[dict[str, str]]:
    suggestions: list[dict[str, str]] = []
    tried_ids = set(experiments.keys())

    best_rtt: float | None = None
    best_rtt_id: str | None = None
    for eid, exp in experiments.items():
        if exp.get("status") != "passed":
            continue
        avg_rtt = exp.get("metrics", {}).get("averages", {}).get("rtt_avg_ms")
        if avg_rtt is not None and (best_rtt is None or avg_rtt < best_rtt):
            best_rtt = avg_rtt
            best_rtt_id = eid

    if best_rtt_id and "comfortable" in best_rtt_id and "balanced" not in " ".join(tried_ids):
        suggestions.append({
            "id": "policy-balanced",
            "rationale": f"Best result so far is {best_rtt_id} (RTT {best_rtt:.1f}ms). Try balanced (1280x960) as middle ground.",
        })

    has_sharpen_variants = any("sharpen" in eid or "lowsharpen" in eid for eid in tried_ids)
    if has_sharpen_variants and not any("nosharpen" in eid for eid in tried_ids):
        suggestions.append({
            "id": "policy-nosharpen",
            "rationale": "Sharpening variants tried but zero-sharpen not yet tested. Eliminates vImage convolution entirely.",
        })

    has_gl = any("gl" in eid for eid in tried_ids)
    if not has_gl:
        suggestions.append({
            "id": "gl-shader-blit",
            "rationale": "GL shader blit path not yet attempted. Largest expected single-optimization gain (~5ms).",
        })

    has_backpressure = any("backpressure" in eid or "adaptive" in eid for eid in tried_ids)
    if not has_backpressure:
        suggestions.append({
            "id": "adaptive-backpressure",
            "rationale": "Adaptive backpressure (RTT-aware threshold) not yet tested. Low risk, moderate expected gain.",
        })

    blocked_count = sum(1 for e in all_entries if e.get("status") == "blocked")
    if blocked_count > 3:
        suggestions.append({
            "id": "fix-build-stability",
            "rationale": f"{blocked_count} blocked experiments detected. Investigate build/setup reliability before more experiments.",
        })

    if not suggestions:
        suggestions.append({
            "id": "custom",
            "rationale": "All standard suggestions exhausted. Review ledger and define a custom experiment.",
        })

    return suggestions


def print_report(ledger_path: Path, as_json: bool) -> int:
    all_entries = load_ledger(ledger_path)
    if not all_entries:
        print(f"No entries in {ledger_path}", file=sys.stderr)
        return 1

    experiments = latest_per_id(all_entries)
    rtt_ranking = rank_by_metric(experiments, "rtt_avg_ms", lower_is_better=True)
    fps_ranking = rank_by_metric(experiments, "fps", lower_is_better=False)
    jitter_ranking = rank_by_metric(experiments, "jitter_ms", lower_is_better=True)
    patterns = failure_patterns(all_entries)
    next_steps = suggest_next(experiments, all_entries)

    report = {
        "total_entries": len(all_entries),
        "unique_experiments": len(experiments),
        "rankings": {
            "by_rtt_avg_ms": [{"id": eid, "value": val} for eid, val in rtt_ranking],
            "by_fps": [{"id": eid, "value": val} for eid, val in fps_ranking],
            "by_jitter_ms": [{"id": eid, "value": val} for eid, val in jitter_ranking],
        },
        "failure_patterns": patterns,
        "suggested_next": next_steps,
    }

    if as_json:
        print(json.dumps(report, indent=2))
        return 0

    print("=" * 60)
    print("LATENCY LAB — EXPERIMENT ANALYSIS")
    print("=" * 60)
    print(f"Ledger: {ledger_path}")
    print(f"Total entries: {len(all_entries)} | Unique experiments: {len(experiments)}")
    print()

    print("Status distribution:")
    for status, count in patterns["status_distribution"].items():
        print(f"  {status}: {count}")
    print()

    print("Rankings by RTT (lower is better):")
    for eid, val in rtt_ranking:
        marker = " ✓" if experiments[eid].get("status") == "passed" else " ✗" if experiments[eid].get("status") == "failed" else " ?"
        val_str = f"{val:.1f}ms" if val is not None else "N/A"
        print(f"  {marker} {eid}: {val_str}")
    print()

    print("Rankings by FPS (higher is better):")
    for eid, val in fps_ranking:
        val_str = f"{val:.1f}" if val is not None else "N/A"
        print(f"    {eid}: {val_str}")
    print()

    if patterns["top_failure_reasons"]:
        print("Top failure reasons:")
        for reason, count in patterns["top_failure_reasons"].items():
            print(f"  [{count}x] {reason}")
        print()

    if patterns["blocked_commands"]:
        print("Blocked commands:")
        for cmd in patterns["blocked_commands"]:
            print(f"  {cmd}")
        print()

    print("Suggested next experiments:")
    for s in next_steps:
        print(f"  → {s['id']}: {s['rationale']}")
    print()

    return 0


def main() -> int:
    repo_root = Path(__file__).resolve().parents[1]
    default_ledger = repo_root / "experiments" / "results" / "ledger.jsonl"

    parser = argparse.ArgumentParser(description="Analyze latency lab experiment ledger")
    parser.add_argument("--ledger", default=str(default_ledger), help="Path to ledger.jsonl")
    parser.add_argument("--json", action="store_true", help="Output as JSON instead of human-readable")
    args = parser.parse_args()

    return print_report(Path(args.ledger), as_json=args.json)


if __name__ == "__main__":
    raise SystemExit(main())
