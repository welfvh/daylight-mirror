# Contributing to Daylight Mirror

Contributions are welcome. This guide helps you understand the codebase and submit quality PRs.

## Getting Started

### Prerequisites

- macOS 14 or later
- Xcode or Swift 5.9+
- `adb` (optional): `brew install android-platform-tools`

### Clone and Build

```bash
git clone https://github.com/welfvh/daylight-mirror
cd daylight-mirror
swift build
swift test
```

### Run

```bash
swift run DaylightMirror    # Menu bar app
swift run daylight-mirror   # CLI
```

### Optional: Build Bundles

```bash
make install    # Mac .app → ~/Applications
make deploy     # Android APK → Daylight (requires Android SDK)
```

## Architecture Overview

```
Sources/
  MirrorEngine/          # Core library (shared by GUI + CLI)
    MirrorEngine.swift   # Orchestrator — wires everything together
    Configuration.swift  # Constants, resolution presets, protocol defs
    ADBBridge.swift      # ADB binary discovery + device commands
    ScreenCapture.swift  # SCStream → vImage greyscale → LZ4 delta
    TCPServer.swift      # Native TCP frame server (raw protocol)
    WebSocketServer.swift # WS fallback for browser viewers
    HTTPServer.swift     # Serves HTML viewer page
    ControlSocket.swift  # Unix socket IPC for CLI commands
    DisplayController.swift # Keyboard shortcuts for brightness/warmth
    CompositorPacer.swift   # Dirty-pixel trick for 30fps capture
    VirtualDisplayManager.swift # CGVirtualDisplay private API
    USBDeviceMonitor.swift # Auto-detect DC-1 connect/disconnect
    MacBrightness.swift    # IOKit Mac brightness control
    UpdateChecker.swift    # GitHub release version check
  App/                   # SwiftUI menu bar app
  Mirror/                # CLI entry point
  CLZ4/                  # C LZ4 compression library
  CVirtualDisplay/       # C bridge for CGVirtualDisplay private API
Tests/
  MirrorEngineTests/     # Unit tests (swift test)
android/                 # Android companion app (Kotlin + native C)
```

## How It Works

Mac creates a virtual display at the DC-1's resolution, mirrors the built-in display to it, captures frames via ScreenCaptureKit, converts to greyscale with vImage SIMD, compresses with LZ4 (keyframes + XOR deltas), and streams over TCP to the Android app which renders via a native C SurfaceView. Zero GPU usage. Under 10ms latency.

## Development Workflow

1. Fork the repo and create a feature branch
2. Make changes, run `swift build && swift test`
3. CI runs automatically on PRs (build + test on macOS)
4. Keep PRs focused — one feature or fix per PR
5. Follow existing code style (no linter configured, but the codebase is consistent)

## Testing

Tests live in `Tests/MirrorEngineTests/`. Run with:

```bash
swift test
```

Tests cover pure logic only (no hardware, no network, no GUI). When adding new logic, add tests. When fixing bugs, add a regression test.

## What to Contribute

- Bug fixes (check issues)
- Test coverage for untested modules
- Documentation improvements
- Performance optimizations (capture pipeline, compression)
- New display presets or control features

## Pull Request Guidelines

- One feature or fix per PR
- Include tests for new logic
- Update documentation if behavior changes
- Verify `swift build && swift test` passes before submitting
- Write clear commit messages describing the "why" not the "what"

## Questions?

Open an issue or check the [blog series](blog/) for deep dives into the architecture.
