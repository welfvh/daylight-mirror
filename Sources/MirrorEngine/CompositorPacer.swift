// CompositorPacer.swift — Dirty pixel trick to force 60fps frame delivery.
//
// Forces the macOS compositor to continuously redraw by toggling a 4x4 pixel
// window between two nearly-identical colors at 60Hz. Without this, CGDisplayStream
// only delivers ~13fps for mirrored virtual displays because WindowServer
// considers static content "clean" and skips recompositing.
//
// The pixel toggles between #000000 and #010000 (1/255 red channel diff) —
// completely imperceptible on any display, especially e-ink.
//
// Uses CADisplayLink (macOS 14+) for vsync-aligned timing. The 4x4 dirty
// region forces WindowServer to recomposite the target display every frame.
//
// IMPORTANT: The dirty-pixel window must live on the virtual display's
// NSScreen, not NSScreen.main. If the window is on the built-in display,
// only that display's compositor sees dirty regions — the virtual display
// compositor stays idle and CGDisplayStream delivers frames at ~13 FPS.

import AppKit

class CompositorPacer {
    private var window: NSWindow?
    private var displayLink: CADisplayLink?
    private var timer: DispatchSourceTimer?
    private var toggle = false
    private let targetDisplayID: CGDirectDisplayID
    private var tickCount: UInt64 = 0

    init(targetDisplayID: CGDirectDisplayID) {
        self.targetDisplayID = targetDisplayID
    }

    func start() {
        DispatchQueue.main.async { [weak self] in
            self?.startOnMain()
        }
    }

    /// Find the NSScreen matching a CGDirectDisplayID.
    private func screenForDisplay(_ displayID: CGDirectDisplayID) -> NSScreen? {
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               screenNumber == displayID {
                return screen
            }
        }
        return nil
    }

    private func startOnMain() {
        // Find the virtual display's NSScreen; fall back to main
        let targetScreen = screenForDisplay(targetDisplayID)
        let screen = targetScreen ?? NSScreen.main
        let onVirtual = targetScreen != nil

        // 4x4 dirty region — above any per-pixel compositing threshold
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 4, height: 4),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.backgroundColor = NSColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Position at top-left corner of the target screen
        if let s = screen {
            window.setFrameOrigin(NSPoint(x: s.frame.minX, y: s.frame.maxY - 4))
        }
        window.orderFrontRegardless()
        self.window = window

        // Use CADisplayLink from the target screen for vsync-aligned ticking.
        // If virtual display has no NSScreen (mirror mode), use a timer at 30Hz.
        if let targetScreen = targetScreen {
            let dl = targetScreen.displayLink(target: self, selector: #selector(tick))
            dl.preferredFrameRateRange = CAFrameRateRange(
                minimum: 30, maximum: 60, preferred: 60
            )
            dl.add(to: .main, forMode: .common)
            self.displayLink = dl
            print("[Pacer] Started on virtual display \(targetDisplayID) (CADisplayLink, 4x4)")
        } else {
            // Fallback: DispatchSourceTimer at ~30Hz
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now(), repeating: .milliseconds(16))
            t.setEventHandler { [weak self] in
                self?.timerTick()
            }
            t.resume()
            self.timer = t
            print("[Pacer] Started on main screen (timer fallback, 4x4) — virtual display \(targetDisplayID) has no NSScreen")
        }

        print("[Pacer] Target display: \(targetDisplayID), on virtual screen: \(onVirtual)")
    }

    @objc private func tick(_ link: CADisplayLink) {
        performToggle()
    }

    private func timerTick() {
        performToggle()
    }

    private func performToggle() {
        toggle.toggle()
        window?.backgroundColor = toggle
            ? NSColor(red: 0, green: 0, blue: 0, alpha: 1)
            : NSColor(red: 1.0 / 255.0, green: 0, blue: 0, alpha: 1)
        tickCount += 1
        if tickCount % 300 == 0 {
            print("[Pacer] \(tickCount) ticks (~\(tickCount / 60)s)")
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.displayLink?.invalidate()
            self?.displayLink = nil
            self?.timer?.cancel()
            self?.timer = nil
            self?.window?.close()
            self?.window = nil
            print("[Pacer] Compositor pacer stopped")
        }
    }
}
