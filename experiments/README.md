# Latency Lab

Sequential overseer workflow for trying latency ideas with isolated git worktrees,
repeatable measurements, and an experiment ledger.

## Goals

- Run experiments one-by-one (no async requirement)
- Keep each experiment isolated in its own worktree
- Capture comparable metrics from `/tmp/daylight-mirror.status`
- Keep a persistent failure/success history for follow-up agents

## Files

- `scripts/latency_lab.py` - overseer runner (supports `--android` for device metrics)
- `scripts/lab_logcat.py` - Android-side metric capture via adb logcat
- `scripts/lab_analyze.py` - ledger analyzer and next-experiment suggester
- `scripts/lab_scenario.py` - deterministic screen activity generator for reproducible measurements
- `experiments/plan.example.json` - sample experiment plan
- `experiments/AGENT.md` - instructions for AI agent iteration loop
- `experiments/results/<timestamp>/` - per-run artifacts
- `experiments/results/ledger.jsonl` - append-only experiment registry

## Quick Start

1. Ensure your permissioned app identity is stable (same bundle id/signing/path).
2. Start mirror once (manual mode), or let the plan spawn the daemon.
3. Copy and customize the example plan.

```bash
cp experiments/plan.example.json experiments/plan.local.json
python3 scripts/latency_lab.py --plan experiments/plan.local.json
```

Dry run:

```bash
python3 scripts/latency_lab.py --plan experiments/plan.local.json --dry-run
```

## Plan Shape

Top-level fields:

- `baseline_id`: experiment id used as comparison baseline
- `status_file`: where metrics are sampled (default `/tmp/daylight-mirror.status`)
- `poll_interval_s`: metric sampling interval
- `default_warmup_s`, `default_measure_s`
- `command_timeout_s`
- `results_dir`
- `git`: worktree settings (`use_worktrees`, `base_ref`, `worktree_root`)
- `daemon`: `manual` or `spawn`
- `gates`: pass/fail rules
- `experiments`: ordered list of sequential experiments

Each experiment includes:

- `id`
- `branch` (optional)
- `commands` (build/setup commands to run in that experiment worktree)
- `warmup_s`, `measure_s` (optional overrides)
- `notes`

## Outputs

Per run directory:

- `plan.json` - exact plan snapshot
- `<experiment-id>.json` - detailed result for each experiment
- `summary.json` - run summary
- `stop.json` - daemon shutdown state

Global ledger:

- `experiments/results/ledger.jsonl` - one JSON result per line across all runs

## Overseer Rules

- If any experiment command fails, that experiment is marked `blocked`.
- If gates are violated, experiment is marked `failed`.
- If no metrics are sampled, experiment is marked `blocked`.
- Otherwise experiment is marked `passed`.

This gives your AI supervisor a stable memory of what was attempted, what failed,
and why.
