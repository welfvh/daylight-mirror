# Changelog

## [1.8.0] — 2026-03-07

### Added
- Clamshell mode — keep DC-1 alive with MacBook lid closed (works on battery)
- Uses `pmset disablesleep` with cached admin authorization (password asked once per session)
- Automatic re-mirror and capture restart on lid reopen
- Safety restore: clears stuck SleepDisabled on app launch if previous crash left it on
- `daylight-mirror clamshell [on|off]` CLI command
- `daylight-mirror health [verbose]` CLI command — full engine diagnostics
- ESC key dismisses menu bar popover
- Collapsible Speed stats section within More menu
- ScreenCapture stream restart for recovering from display pipeline stalls

## [1.7.0] — 2026-03-07

### Added
- Display profile presets: Crisp Paper, Balanced, Custom — bundles sharpen + contrast + gamma
- Gamma correction for reflective paper displays (adjustable 1.0–1.5)
- GL_NEAREST texture filtering on Android for pixel-perfect 1:1 text rendering
- `wm size` reset on ADB setup to prevent scaling artifacts from DC-1 factory override
- Modern fullscreen API (WindowInsetsController) on Android for full panel access
- v1.7 UserDefaults migration — clears stale saved values so new optimized defaults take effect
- Adaptive backpressure threshold based on RTT for frame skipping
- Trivial delta skip — drops frames where screen barely changed (< 512 bytes compressed)
- CompositorPacer upgraded to 4x4 dirty region for reliable compositor triggering

### Changed
- Default sharpen 1.0→1.5, contrast 1.0→1.2, gamma 0→1.2 for optimal DC-1 crispness
- Renamed "E-ink Crisp" profile → "Crisp Paper" — DC-1 is a reflective LCD, not e-ink
- Removed smoothstep shader from Android renderer — Mac-side LUT alone handles text crispness
- All e-ink references corrected to reflective paper display throughout codebase

### Fixed
- Double-processing crushing ~40% of greyscale range (Mac LUT + Android shader combined)
- 1:1 pixel mapping destroyed by DC-1 `display_size_forced` override
- Profile picker slider changes correctly fall back to Custom profile

## [1.6.1] — 2026-02-20

### Fixed
- Sync initial device brightness to TCPServer on startup

## [1.6.0] — 2026-02-18

### Added
- Developer ID signing + notarization in CI/CD (replaces ad-hoc signing)
- Feedback, support, and about links in app
- "Dim Mac display" toggle

### Changed
- Daylight referral links updated to buy.daylightcomputer.com
- Download links switched to Stripe, added stable GitHub release URL
- Website: swapped hero to daytime image, referral banner, cleaner pricing

### Fixed
- Re-send brightness on reconnect
- Broadcast resolution to connected clients on change
- Portrait rotation: switch Android orientation on resolution change
- Theme toggle icons on website
