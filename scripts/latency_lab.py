#!/usr/bin/env python3
"""Sequential overseer for latency experiments.

This script runs a plan of experiments, captures metrics from
/tmp/daylight-mirror.status, evaluates candidates against a baseline, and
stores an experiment ledger for follow-up AI agents.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from statistics import mean
from typing import Any


NUMERIC_KEYS = {
    "fps",
    "bandwidth_mbps",
    "jitter_ms",
    "rtt_avg_ms",
    "rtt_p95_ms",
    "total_frames",
    "skipped_frames",
    "grey_ms",
    "compress_ms",
}

SOCKET_PATH = "/tmp/daylight-mirror.sock"


@dataclass
class CommandResult:
    argv: list[str]
    returncode: int
    stdout: str
    stderr: str
    duration_s: float


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def as_argv(command: Any) -> list[str]:
    if isinstance(command, list):
        return [str(x) for x in command]
    if isinstance(command, str):
        return shlex.split(command)
    raise ValueError(f"Unsupported command format: {command!r}")


def run_command(command: Any, cwd: Path, timeout_s: int = 300, dry_run: bool = False) -> CommandResult:
    argv = as_argv(command)
    start = time.time()
    if dry_run:
        return CommandResult(argv=argv, returncode=0, stdout="", stderr="", duration_s=0.0)

    proc = subprocess.run(
        argv,
        cwd=str(cwd),
        capture_output=True,
        text=True,
        timeout=timeout_s,
        check=False,
    )
    return CommandResult(
        argv=argv,
        returncode=proc.returncode,
        stdout=proc.stdout.strip(),
        stderr=proc.stderr.strip(),
        duration_s=time.time() - start,
    )


def parse_status_file(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}

    data: dict[str, Any] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if key in NUMERIC_KEYS:
            try:
                data[key] = float(value)
            except ValueError:
                data[key] = None
        else:
            data[key] = value
    return data


def query_socket(socket_path: str = SOCKET_PATH) -> dict[str, Any]:
    import socket as sock
    data: dict[str, Any] = {}
    try:
        s = sock.socket(sock.AF_UNIX, sock.SOCK_STREAM)
        s.settimeout(3.0)
        s.connect(socket_path)
        s.sendall(b"LATENCY\n")
        response = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            response += chunk
        s.close()
    except (OSError, sock.timeout):
        return {}

    for line in response.decode("utf-8", errors="replace").splitlines():
        if line.startswith("OK"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if key in NUMERIC_KEYS:
            try:
                data[key] = float(value)
            except ValueError:
                data[key] = None
        else:
            data[key] = value
    return data


def sample_metrics(status_file: Path, duration_s: int, poll_s: float) -> dict[str, Any]:
    started_at = time.time()
    samples: list[dict[str, Any]] = []

    use_socket = os.path.exists(SOCKET_PATH)

    while time.time() - started_at < duration_s:
        point = query_socket() if use_socket else parse_status_file(status_file)
        if not point and use_socket:
            point = parse_status_file(status_file)
        if point:
            point["sample_ts"] = now_iso()
            samples.append(point)
        time.sleep(poll_s)

    if not samples:
        return {
            "sample_count": 0,
            "averages": {},
            "first": {},
            "last": {},
            "deltas": {},
        }

    averages: dict[str, float] = {}
    for key in NUMERIC_KEYS:
        vals = [float(s[key]) for s in samples if s.get(key) is not None]
        if vals:
            averages[key] = round(mean(vals), 3)

    first = samples[0]
    last = samples[-1]
    deltas: dict[str, float] = {}
    for key in ("total_frames", "skipped_frames"):
        if first.get(key) is not None and last.get(key) is not None:
            deltas[key] = round(float(last[key]) - float(first[key]), 3)

    return {
        "sample_count": len(samples),
        "averages": averages,
        "first": first,
        "last": last,
        "deltas": deltas,
    }


def start_logcat_capture(output_path: Path, dry_run: bool) -> subprocess.Popen[str] | None:
    if dry_run:
        return None
    lab_logcat = Path(__file__).parent / "lab_logcat.py"
    if not lab_logcat.exists():
        return None
    return subprocess.Popen(
        [sys.executable, str(lab_logcat), "--output", str(output_path), "--follow"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def stop_logcat_capture(proc: subprocess.Popen[str] | None) -> None:
    if proc is None:
        return
    try:
        proc.send_signal(signal.SIGINT)
        proc.wait(timeout=5)
    except (subprocess.TimeoutExpired, OSError):
        proc.kill()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass


def load_android_metrics(output_path: Path) -> dict[str, Any]:
    if not output_path.exists():
        return {}
    try:
        data = json.loads(output_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    samples = data.get("samples", [])
    if not samples:
        return {"android_sample_count": 0}

    avg_keys = ["fps", "recv_ms", "lz4_ms", "delta_ms", "neon_ms", "vsync_ms"]
    averages: dict[str, float] = {}
    for key in avg_keys:
        vals = [s[key] for s in samples if key in s]
        if vals:
            averages[key] = round(mean(vals), 3)

    last = samples[-1]
    return {
        "android_sample_count": len(samples),
        "android_averages": averages,
        "android_last": {
            "drops": last.get("drops"),
            "overwritten": last.get("overwritten"),
            "total": last.get("total"),
            "frame_type": last.get("frame_type"),
        },
    }


def build_worktree(repo_root: Path, git_cfg: dict[str, Any], exp: dict[str, Any], dry_run: bool) -> Path:
    if not git_cfg.get("use_worktrees", False):
        return repo_root

    root = Path(git_cfg.get("worktree_root", str(repo_root.parent / "daylight-mirror-lab"))).expanduser()
    ensure_dir(root)

    exp_id = exp["id"]
    branch = exp.get("branch", f"exp/{exp_id}")
    base_ref = git_cfg.get("base_ref", "main")
    wt_path = root / exp_id

    if wt_path.exists():
        return wt_path

    command = ["git", "worktree", "add", "-B", branch, str(wt_path), base_ref]
    result = run_command(command, cwd=repo_root, timeout_s=120, dry_run=dry_run)
    if result.returncode != 0:
        raise RuntimeError(f"worktree add failed for {exp_id}: {result.stderr or result.stdout}")
    return wt_path


def evaluate(
    exp_id: str,
    metrics: dict[str, Any],
    baseline_metrics: dict[str, Any] | None,
    gates: dict[str, Any],
) -> tuple[str, list[str]]:
    reasons: list[str] = []
    averages = metrics.get("averages", {})
    deltas = metrics.get("deltas", {})

    fps_min = gates.get("fps_min")
    if fps_min is not None and averages.get("fps") is not None and averages["fps"] < float(fps_min):
        reasons.append(f"fps {averages['fps']} < min {fps_min}")

    jitter_max = gates.get("jitter_ms_max")
    if jitter_max is not None and averages.get("jitter_ms") is not None and averages["jitter_ms"] > float(jitter_max):
        reasons.append(f"jitter_ms {averages['jitter_ms']} > max {jitter_max}")

    skipped_max_delta = gates.get("skipped_frames_delta_max")
    if skipped_max_delta is not None and deltas.get("skipped_frames") is not None:
        if deltas["skipped_frames"] > float(skipped_max_delta):
            reasons.append(f"skipped_frames delta {deltas['skipped_frames']} > max {skipped_max_delta}")

    if baseline_metrics:
        base_avg = baseline_metrics.get("averages", {})
        rtt_delta_max = gates.get("rtt_avg_delta_max")
        if (
            rtt_delta_max is not None
            and averages.get("rtt_avg_ms") is not None
            and base_avg.get("rtt_avg_ms") is not None
        ):
            delta = averages["rtt_avg_ms"] - base_avg["rtt_avg_ms"]
            if delta > float(rtt_delta_max):
                reasons.append(f"rtt_avg_ms delta +{round(delta, 3)} > max {rtt_delta_max}")

        rtt_p95_delta_max = gates.get("rtt_p95_delta_max")
        if (
            rtt_p95_delta_max is not None
            and averages.get("rtt_p95_ms") is not None
            and base_avg.get("rtt_p95_ms") is not None
        ):
            delta = averages["rtt_p95_ms"] - base_avg["rtt_p95_ms"]
            if delta > float(rtt_p95_delta_max):
                reasons.append(f"rtt_p95_ms delta +{round(delta, 3)} > max {rtt_p95_delta_max}")

    if reasons:
        return "failed", reasons
    if metrics.get("sample_count", 0) == 0:
        return "blocked", ["No status samples captured. Ensure mirror is running and writing status."]
    return "passed", [f"{exp_id} met configured gates"]


def append_jsonl(path: Path, payload: dict[str, Any]) -> None:
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(payload, ensure_ascii=True) + "\n")


def run_experiment(
    repo_root: Path,
    plan: dict[str, Any],
    exp: dict[str, Any],
    baseline_metrics: dict[str, Any] | None,
    dry_run: bool,
    run_dir: Path,
    android: bool = False,
) -> dict[str, Any]:
    exp_id = exp["id"]
    git_cfg = plan.get("git", {})
    status_file = Path(plan.get("status_file", "/tmp/daylight-mirror.status"))
    poll_s = float(plan.get("poll_interval_s", 2.0))
    warmup_s = int(exp.get("warmup_s", plan.get("default_warmup_s", 8)))
    measure_s = int(exp.get("measure_s", plan.get("default_measure_s", 25)))
    timeout_s = int(plan.get("command_timeout_s", 300))
    gates = plan.get("gates", {})

    started = now_iso()
    worktree = build_worktree(repo_root, git_cfg, exp, dry_run=dry_run)
    commands = exp.get("commands", [])
    command_results: list[dict[str, Any]] = []

    for command in commands:
        r = run_command(command, cwd=worktree, timeout_s=timeout_s, dry_run=dry_run)
        command_results.append(
            {
                "argv": r.argv,
                "returncode": r.returncode,
                "stdout": r.stdout,
                "stderr": r.stderr,
                "duration_s": round(r.duration_s, 3),
            }
        )
        if r.returncode != 0:
            return {
                "id": exp_id,
                "status": "blocked",
                "started_at": started,
                "finished_at": now_iso(),
                "worktree": str(worktree),
                "command_results": command_results,
                "reasons": [f"Command failed: {' '.join(r.argv)}", r.stderr or r.stdout],
                "metrics": {},
                "notes": exp.get("notes", ""),
            }

    if dry_run:
        result = {
            "id": exp_id,
            "status": "dry_run",
            "started_at": started,
            "finished_at": now_iso(),
            "worktree": str(worktree),
            "command_results": command_results,
            "reasons": ["Dry run: commands not executed, metrics not sampled"],
            "metrics": {},
            "notes": exp.get("notes", ""),
        }
        out_file = run_dir / f"{exp_id}.json"
        out_file.write_text(json.dumps(result, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
        return result

    if not dry_run and warmup_s > 0:
        time.sleep(warmup_s)

    android_output = run_dir / f"{exp_id}.android.json"
    logcat_proc = start_logcat_capture(android_output, dry_run=not android) if android else None

    metrics = sample_metrics(status_file, duration_s=measure_s, poll_s=poll_s)

    stop_logcat_capture(logcat_proc)
    if android:
        android_metrics = load_android_metrics(android_output)
        metrics.update(android_metrics)

    status, reasons = evaluate(exp_id=exp_id, metrics=metrics, baseline_metrics=baseline_metrics, gates=gates)

    result = {
        "id": exp_id,
        "status": status,
        "started_at": started,
        "finished_at": now_iso(),
        "worktree": str(worktree),
        "command_results": command_results,
        "reasons": reasons,
        "metrics": metrics,
        "notes": exp.get("notes", ""),
    }

    out_file = run_dir / f"{exp_id}.json"
    out_file.write_text(json.dumps(result, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    return result


def maybe_start_stop_daemon(plan: dict[str, Any], repo_root: Path, dry_run: bool) -> tuple[Any, dict[str, Any]]:
    daemon = plan.get("daemon", {})
    mode = daemon.get("mode", "manual")
    state: dict[str, Any] = {"mode": mode, "started": False, "spawned_pid": None}

    if mode != "spawn":
        return None, state

    start_cmd = daemon.get("start")
    if not start_cmd:
        return None, state

    argv = as_argv(start_cmd)
    if dry_run:
        state["started"] = True
        return None, state

    proc = subprocess.Popen(argv, cwd=str(repo_root), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    state["started"] = True
    state["spawned_pid"] = proc.pid

    wait_s = int(daemon.get("startup_wait_s", 5))
    if wait_s > 0:
        time.sleep(wait_s)
    return proc, state


def stop_daemon(plan: dict[str, Any], repo_root: Path, proc: Any, dry_run: bool) -> dict[str, Any]:
    daemon = plan.get("daemon", {})
    mode = daemon.get("mode", "manual")
    if mode != "spawn":
        return {"stopped": False}

    stop_cmd = daemon.get("stop")
    if stop_cmd:
        r = run_command(stop_cmd, cwd=repo_root, timeout_s=60, dry_run=dry_run)
        if not dry_run and proc and proc.poll() is None:
            try:
                proc.terminate()
            except Exception:
                pass
        return {
            "stopped": True,
            "command": r.argv,
            "returncode": r.returncode,
            "stdout": r.stdout,
            "stderr": r.stderr,
        }

    if not dry_run and proc and proc.poll() is None:
        try:
            proc.terminate()
        except Exception:
            pass
    return {"stopped": True}


def main() -> int:
    parser = argparse.ArgumentParser(description="Sequential overseer for latency experiments")
    parser.add_argument("--plan", required=True, help="Path to JSON experiment plan")
    parser.add_argument("--dry-run", action="store_true", help="Print actions without executing commands")
    parser.add_argument("--android", action="store_true", help="Capture Android-side metrics via adb logcat in parallel")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    plan_path = Path(args.plan)
    if not plan_path.is_absolute():
        plan_path = (repo_root / plan_path).resolve()

    if not plan_path.exists():
        print(f"Plan file not found: {plan_path}", file=sys.stderr)
        return 1

    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    experiments = plan.get("experiments", [])
    if not experiments:
        print("No experiments in plan", file=sys.stderr)
        return 1

    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    results_root = Path(plan.get("results_dir", "experiments/results"))
    if not results_root.is_absolute():
        results_root = (repo_root / results_root).resolve()
    run_dir = results_root / ts
    ensure_dir(run_dir)
    ledger_path = results_root / "ledger.jsonl"

    (run_dir / "plan.json").write_text(json.dumps(plan, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")

    proc, daemon_state = maybe_start_stop_daemon(plan, repo_root, dry_run=args.dry_run)
    summary: list[dict[str, Any]] = []

    try:
        baseline_id = plan.get("baseline_id")
        baseline_metrics: dict[str, Any] | None = None

        for exp in experiments:
            result = run_experiment(
                repo_root=repo_root,
                plan=plan,
                exp=exp,
                baseline_metrics=baseline_metrics,
                dry_run=args.dry_run,
                run_dir=run_dir,
                android=args.android,
            )
            append_jsonl(ledger_path, result)
            summary.append({"id": result["id"], "status": result["status"], "reasons": result["reasons"]})

            if baseline_id and result["id"] == baseline_id and result.get("metrics"):
                baseline_metrics = result["metrics"]

        report = {
            "started_at": now_iso(),
            "plan": str(plan_path),
            "run_dir": str(run_dir),
            "dry_run": args.dry_run,
            "daemon": daemon_state,
            "summary": summary,
        }
        (run_dir / "summary.json").write_text(json.dumps(report, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    finally:
        stop_state = stop_daemon(plan, repo_root, proc, dry_run=args.dry_run)
        (run_dir / "stop.json").write_text(json.dumps(stop_state, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")

    passed = [s for s in summary if s["status"] == "passed"]
    failed = [s for s in summary if s["status"] == "failed"]
    blocked = [s for s in summary if s["status"] == "blocked"]
    dry = [s for s in summary if s["status"] == "dry_run"]

    print(f"Run directory: {run_dir}")
    print(f"Passed: {len(passed)} | Failed: {len(failed)} | Blocked: {len(blocked)} | Dry-run: {len(dry)}")
    for row in summary:
        print(f"- {row['id']}: {row['status']} ({'; '.join(row['reasons'])})")

    if args.dry_run:
        return 0
    return 0 if not failed and not blocked else 2


if __name__ == "__main__":
    raise SystemExit(main())
