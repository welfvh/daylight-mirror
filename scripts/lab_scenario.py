#!/usr/bin/env python3
"""Deterministic test scenario generator for latency lab.

Generates reproducible screen activity patterns using macOS Quartz/CoreGraphics
APIs so that experiment measurements are comparable across runs.

Each scenario produces a predictable workload:
  - idle:       No activity (baseline noise floor)
  - cursor:     Smooth cursor sweep across the screen
  - scroll:     Simulated scroll wheel events
  - typing:     Simulated keystrokes (opens TextEdit if needed)
  - drag:       Click-drag rectangle across screen
  - stress:     Rapid full-screen changes (worst case for delta compression)
  - full:       All scenarios in sequence

Usage:
    python3 scripts/lab_scenario.py                    # run 'full' suite
    python3 scripts/lab_scenario.py --scenario cursor   # cursor sweep only
    python3 scripts/lab_scenario.py --scenario idle --duration 10
    python3 scripts/lab_scenario.py --list              # list available scenarios
"""

from __future__ import annotations

import argparse
import math
import subprocess
import sys
import time
from typing import Any

try:
    import Quartz  # type: ignore[import-untyped]
    from Quartz import (
        CGEventCreateMouseEvent,
        CGEventCreateScrollWheelEvent,
        CGEventCreateKeyboardEvent,
        CGEventPost,
        CGEventSetIntegerValueField,
        kCGEventMouseMoved,
        kCGEventLeftMouseDown,
        kCGEventLeftMouseUp,
        kCGEventLeftMouseDragged,
        kCGEventScrollWheel,
        kCGHIDEventTap,
        kCGScrollEventUnitPixel,
    )
except ImportError:
    print("ERROR: Quartz (pyobjc-framework-Quartz) not available.", file=sys.stderr)
    print("Install with: pip3 install pyobjc-framework-Quartz", file=sys.stderr)
    print("Or use system Python which includes it: /usr/bin/python3", file=sys.stderr)
    sys.exit(1)


def get_main_display_size() -> tuple[int, int]:
    """Get the main display resolution."""
    main = Quartz.CGMainDisplayID()
    w = Quartz.CGDisplayPixelsWide(main)
    h = Quartz.CGDisplayPixelsHigh(main)
    return int(w), int(h)


def move_mouse(x: float, y: float) -> None:
    """Move cursor to absolute position."""
    point = Quartz.CGPointMake(x, y)
    event = CGEventCreateMouseEvent(None, kCGEventMouseMoved, point, 0)
    CGEventPost(kCGHIDEventTap, event)


def mouse_down(x: float, y: float) -> None:
    """Press left mouse button at position."""
    point = Quartz.CGPointMake(x, y)
    event = CGEventCreateMouseEvent(None, kCGEventLeftMouseDown, point, 0)
    CGEventPost(kCGHIDEventTap, event)


def mouse_up(x: float, y: float) -> None:
    """Release left mouse button at position."""
    point = Quartz.CGPointMake(x, y)
    event = CGEventCreateMouseEvent(None, kCGEventLeftMouseUp, point, 0)
    CGEventPost(kCGHIDEventTap, event)


def mouse_drag(x: float, y: float) -> None:
    """Drag (mouse move while button held) to position."""
    point = Quartz.CGPointMake(x, y)
    event = CGEventCreateMouseEvent(None, kCGEventLeftMouseDragged, point, 0)
    CGEventPost(kCGHIDEventTap, event)


def scroll(dx: int, dy: int) -> None:
    """Send scroll wheel event."""
    event = CGEventCreateScrollWheelEvent(None, kCGScrollEventUnitPixel, 2, dy, dx)
    CGEventPost(kCGHIDEventTap, event)


def key_tap(keycode: int) -> None:
    """Press and release a key."""
    down = CGEventCreateKeyboardEvent(None, keycode, True)
    up = CGEventCreateKeyboardEvent(None, keycode, False)
    CGEventPost(kCGHIDEventTap, down)
    time.sleep(0.02)
    CGEventPost(kCGHIDEventTap, up)



def scenario_idle(duration: float, **_: Any) -> None:
    """Do nothing. Measures noise floor — how the pipeline behaves with zero input."""
    print(f"  idle: waiting {duration:.1f}s (no input)")
    time.sleep(duration)


def scenario_cursor(duration: float, **_: Any) -> None:
    """Sweep cursor in a smooth sine wave across the screen.

    Produces moderate, predictable pixel changes — mostly small delta frames
    since only the cursor region changes between frames.
    """
    w, h = get_main_display_size()
    print(f"  cursor: sine sweep across {w}x{h} for {duration:.1f}s")

    start = time.time()
    step = 0
    while time.time() - start < duration:
        t = (time.time() - start) / duration
        x = t * w
        y = h / 2 + math.sin(t * math.pi * 6) * (h * 0.3)
        move_mouse(x, max(0, min(h - 1, y)))
        step += 1
        time.sleep(1 / 120)  # 120 Hz input rate

    print(f"    {step} cursor moves generated")


def scenario_scroll(duration: float, **_: Any) -> None:
    """Scroll up and down in a repeating pattern.

    Produces large delta frames since scrolling shifts every visible pixel.
    Good stress test for delta compression + NEON blit path.
    """
    w, h = get_main_display_size()
    move_mouse(w / 2, h / 2)
    time.sleep(0.1)

    print(f"  scroll: alternating up/down for {duration:.1f}s")
    start = time.time()
    step = 0
    direction = -3  # pixels per scroll event (negative = scroll down)

    while time.time() - start < duration:
        scroll(0, direction)
        step += 1
        elapsed = time.time() - start
        if int(elapsed / 2) % 2 == 1:
            direction = 3
        else:
            direction = -3
        time.sleep(1 / 30)  # 30 Hz scroll rate

    print(f"    {step} scroll events generated")


def scenario_typing(duration: float, **_: Any) -> None:
    """Simulate typing by pressing letter keys.

    Opens TextEdit first (if not running) for a visible text target.
    Produces small, localized delta frames — text cursor + new character.
    """
    result = subprocess.run(
        ["pgrep", "-x", "TextEdit"], capture_output=True, text=True, check=False
    )
    opened_textedit = False
    if result.returncode != 0:
        print("  typing: opening TextEdit...")
        subprocess.Popen(
            ["open", "-a", "TextEdit"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        opened_textedit = True
        time.sleep(1.5)

    # macOS virtual keycodes are non-sequential; this maps a-z in order
    letter_keycodes = [
        0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,   # a-m
        45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,  # n-z
    ]
    space_keycode = 49
    return_keycode = 36

    print(f"  typing: simulated keystrokes for {duration:.1f}s")
    start = time.time()
    step = 0
    word_len = 0

    while time.time() - start < duration:
        if word_len >= 8:
            key_tap(space_keycode)
            word_len = 0
        else:
            idx = step % len(letter_keycodes)
            key_tap(letter_keycodes[idx])
            word_len += 1

        step += 1
        if step % 40 == 0:
            key_tap(return_keycode)
            word_len = 0

        time.sleep(1 / 15)  # ~15 chars/sec (fast typing)

    print(f"    {step} keystrokes generated")

    if opened_textedit:
        time.sleep(0.3)
        cmd_down = CGEventCreateKeyboardEvent(None, 13, True)  # keycode 13 = W
        CGEventSetIntegerValueField(cmd_down, Quartz.kCGKeyboardEventAutorepeat, 0)
        Quartz.CGEventSetFlags(cmd_down, Quartz.kCGEventFlagMaskCommand)
        CGEventPost(kCGHIDEventTap, cmd_down)
        cmd_up = CGEventCreateKeyboardEvent(None, 13, False)
        Quartz.CGEventSetFlags(cmd_up, Quartz.kCGEventFlagMaskCommand)
        CGEventPost(kCGHIDEventTap, cmd_up)
        time.sleep(0.5)
        d_down = CGEventCreateKeyboardEvent(None, 2, True)  # keycode 2 = D ("Don't Save")
        Quartz.CGEventSetFlags(d_down, Quartz.kCGEventFlagMaskCommand)
        CGEventPost(kCGHIDEventTap, d_down)
        d_up = CGEventCreateKeyboardEvent(None, 2, False)
        Quartz.CGEventSetFlags(d_up, Quartz.kCGEventFlagMaskCommand)
        CGEventPost(kCGHIDEventTap, d_up)


def scenario_drag(duration: float, **_: Any) -> None:
    """Click-drag in a rectangular pattern across the screen.

    This simulates window dragging — moderate delta frames concentrated
    around the drag region.
    """
    w, h = get_main_display_size()
    margin = 100
    cx, cy = w / 2, h / 2

    print(f"  drag: rectangular pattern for {duration:.1f}s")

    rect = [
        (margin, margin),
        (w - margin, margin),
        (w - margin, h - margin),
        (margin, h - margin),
    ]

    start = time.time()
    step = 0

    while time.time() - start < duration:
        sx, sy = cx, cy
        mouse_down(sx, sy)
        time.sleep(0.05)

        for tx, ty in rect:
            steps_to_target = 30
            for i in range(steps_to_target):
                frac = (i + 1) / steps_to_target
                ix = sx + (tx - sx) * frac
                iy = sy + (ty - sy) * frac
                mouse_drag(ix, iy)
                time.sleep(1 / 120)
            sx, sy = tx, ty
            step += 1

            if time.time() - start >= duration:
                break

        mouse_up(sx, sy)
        time.sleep(0.1)

    print(f"    {step} drag segments completed")


def scenario_stress(duration: float, **_: Any) -> None:
    """Rapidly toggle between light and dark mode to force full-screen redraws.

    This is the worst case for delta compression — every pixel changes.
    Uses AppleScript to toggle appearance, falling back to rapid app switching.
    """
    print(f"  stress: rapid appearance toggle for {duration:.1f}s")
    start = time.time()
    toggles = 0

    check = subprocess.run(
        ["osascript", "-e", 'tell application "System Events" to get dark mode of appearance preferences'],
        capture_output=True, text=True, check=False,
    )
    can_toggle = check.returncode == 0

    if can_toggle:
        original_dark = "true" in check.stdout.strip().lower()
        while time.time() - start < duration:
            subprocess.run(
                ["osascript", "-e",
                 'tell application "System Events" to set dark mode of appearance preferences to not (dark mode of appearance preferences)'],
                capture_output=True, check=False,
            )
            toggles += 1
            time.sleep(0.8)

        mode = "true" if original_dark else "false"
        subprocess.run(
            ["osascript", "-e",
             f'tell application "System Events" to set dark mode of appearance preferences to {mode}'],
            capture_output=True, check=False,
        )
    else:
        print("    (appearance toggle not available, using rapid cursor sweep)")
        w, h = get_main_display_size()
        while time.time() - start < duration:
            for i in range(0, max(w, h), 4):
                x = min(i, w - 1)
                y = min(i, h - 1)
                move_mouse(x, y)
                time.sleep(1 / 240)
                if time.time() - start >= duration:
                    break
            toggles += 1

    print(f"    {toggles} stress cycles completed")



SCENARIOS: dict[str, dict[str, Any]] = {
    "idle": {
        "fn": scenario_idle,
        "default_duration": 10,
        "description": "No input — measures noise floor",
    },
    "cursor": {
        "fn": scenario_cursor,
        "default_duration": 10,
        "description": "Smooth sine-wave cursor sweep",
    },
    "scroll": {
        "fn": scenario_scroll,
        "default_duration": 10,
        "description": "Alternating scroll wheel events",
    },
    "typing": {
        "fn": scenario_typing,
        "default_duration": 15,
        "description": "Simulated keystroke input",
    },
    "drag": {
        "fn": scenario_drag,
        "default_duration": 10,
        "description": "Click-drag rectangular pattern",
    },
    "stress": {
        "fn": scenario_stress,
        "default_duration": 10,
        "description": "Rapid full-screen redraws (dark/light toggle)",
    },
}

FULL_ORDER = ["idle", "cursor", "scroll", "typing", "drag", "stress", "idle"]


def run_scenario(name: str, duration: float | None = None) -> None:
    """Run a single scenario."""
    spec = SCENARIOS[name]
    dur = duration if duration is not None else spec["default_duration"]
    print(f"\n[scenario: {name}] — {spec['description']}")
    spec["fn"](duration=dur)
    print(f"  done ({dur:.1f}s)")


def run_full(duration_per: float | None = None) -> None:
    """Run the full scenario suite in sequence."""
    print("=" * 50)
    print("LATENCY LAB — FULL SCENARIO SUITE")
    print("=" * 50)

    total_start = time.time()
    for name in FULL_ORDER:
        run_scenario(name, duration=duration_per)
        time.sleep(1)

    elapsed = time.time() - total_start
    print(f"\n{'=' * 50}")
    print(f"Full suite completed in {elapsed:.1f}s")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Deterministic test scenario generator for latency lab"
    )
    parser.add_argument(
        "--scenario",
        choices=list(SCENARIOS.keys()) + ["full"],
        default="full",
        help="Scenario to run (default: full)",
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=None,
        help="Override duration in seconds for each scenario",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List available scenarios and exit",
    )
    args = parser.parse_args()

    if args.list:
        print("Available scenarios:")
        for name, spec in SCENARIOS.items():
            print(f"  {name:12s} ({spec['default_duration']:2d}s)  {spec['description']}")
        print(f"  {'full':12s}         All scenarios in sequence")
        return 0

    if args.scenario == "full":
        run_full(duration_per=args.duration)
    else:
        run_scenario(args.scenario, duration=args.duration)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
