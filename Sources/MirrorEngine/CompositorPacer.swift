// CompositorPacer.swift — Dirty pixel trick to force continuous frame delivery from SCStream.

import Foundation
import AppKit

// MARK: - Compositor Pacer (dirty pixel trick to force frame delivery)

/// Forces the macOS compositor to continuously redraw by toggling a 1x1 pixel
/// window between two nearly-identical colors at 30Hz. Without this, SCStream
/// only delivers ~13fps for mirrored virtual displays because WindowServer
/// considers static content "clean" and skips recompositing.
///
/// The pixel toggles between #000000 and #010000 (1/255 red channel diff) —
/// completely imperceptible on any display, especially e-ink. Positioned at
/// (0, maxY-1) to hide under the menu bar.
///
/// Uses CADisplayLink (macOS 14+) for vsync-aligned timing. The 1x1 dirty
/// region has essentially zero compositing cost — WindowServer already checks
/// for dirty regions every frame, we just ensure it always finds one.
class CompositorPacer {
    private var window: NSWindow?
    private var displayLink: CADisplayLink?
    private var toggle = false

    func start() {
        DispatchQueue.main.async { [weak self] in
            self?.startOnMain()
        }
    }

    private func startOnMain() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver + 1
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.backgroundColor = NSColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Position under the menu bar on the main screen
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: 0, y: screen.frame.maxY - 1))
        }
        window.orderFrontRegardless()
        self.window = window

        // CADisplayLink (macOS 14+) for vsync-aligned ticking
        let displayLink = NSScreen.main!.displayLink(target: self, selector: #selector(tick))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30, maximum: 60, preferred: 30
        )
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink

        print("[Pacer] Compositor pacer started (1x1 dirty pixel @ 30Hz)")
    }

    @objc private func tick(_ link: CADisplayLink) {
        toggle.toggle()
        window?.backgroundColor = toggle
            ? NSColor(red: 0, green: 0, blue: 0, alpha: 1)
            : NSColor(red: 1.0 / 255.0, green: 0, blue: 0, alpha: 1)
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.displayLink?.invalidate()
            self?.displayLink = nil
            self?.window?.close()
            self?.window = nil
            print("[Pacer] Compositor pacer stopped")
        }
    }
}
