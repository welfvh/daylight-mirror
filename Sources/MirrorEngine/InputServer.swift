// InputServer.swift — Receives touch events from the DC-1 and injects them as Mac cursor events.
//
// Listens on a TCP port for 23-byte binary packets from the Android companion app.
// Each packet encodes a touch event (down/move/up/scroll) with normalized coordinates
// that get mapped to the target virtual display's pixel space. Uses CGEvent injection
// for mouse and scroll wheel simulation.
//
// Protocol: [DA 70][type:1][x:4][y:4][dx:4][dy:4][pointer:4] = 23 bytes
// Coordinates are IEEE 754 floats normalized to 0.0–1.0 (device screen space).

import Foundation
import Network
import CoreGraphics
import ApplicationServices

public class InputServer {
    private let port: UInt16
    private let targetDisplayID: CGDirectDisplayID
    private let queue = DispatchQueue(label: "com.daylight.mirror.input", qos: .userInteractive)
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    // Mouse state tracking
    private var mouseDown = false
    private var lastMouseLocation: CGPoint = .zero
    /// Where the finger first touched — used for tap vs drag deadzone detection
    private var touchDownLocation: CGPoint = .zero
    /// Whether the finger has moved far enough from the initial touch to count as a drag
    private var dragStarted = false
    /// Deadzone in screen points — movement within this radius after touch-down is a tap, not a drag.
    /// Prevents accidental text selection when the user just wants to place the cursor.
    private static let tapDeadzonePoints: CGFloat = 8.0

    // Scroll state: track gesture phases so macOS treats events as trackpad input
    // and provides native momentum, rubber-banding, etc. automatically.
    private var scrollGestureActive = false
    private var scrollEndTimer: DispatchWorkItem?
    private var scrollRemainderX: CGFloat = 0
    private var scrollRemainderY: CGFloat = 0
    /// Amplifies normalized (0–1) touch deltas to pixel-space scroll distances.
    private static let scrollSensitivity: CGFloat = 800.0
    /// How long after the last scroll packet to emit Ended phase (ms).
    /// Finger-lift detection — if no scroll arrives within this window, the gesture is over.
    private static let scrollEndTimeoutMs: Int = 60

    // CGScrollPhase values (NOT NSEventPhase — different numeric values)
    private static let scrollPhaseBegan: Int64 = 1
    private static let scrollPhaseChanged: Int64 = 2
    private static let scrollPhaseEnded: Int64 = 4

    private var accessibilityWarned = false

    public private(set) var running = false

    public init(port: UInt16, targetDisplayID: CGDirectDisplayID) throws {
        self.port = port
        self.targetDisplayID = targetDisplayID
    }

    public func start() {
        guard !running else { return }

        // Check accessibility permission (required for CGEvent injection)
        if !AXIsProcessTrusted() {
            if !accessibilityWarned {
                NSLog("[Input] WARNING: Accessibility permission not granted — touch injection will fail. Grant in System Settings > Privacy > Accessibility.")
                accessibilityWarned = true
            }
        }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            NSLog("[Input] Failed to create listener on port %d: %@", port, "\(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                NSLog("[Input] Listening on port %d (display %u)", self.port, self.targetDisplayID)
                self.running = true
            case .failed(let error):
                NSLog("[Input] Listener failed: %@", "\(error)")
                self.running = false
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: queue)
    }

    public func stop() {
        scrollEndTimer?.cancel()
        scrollEndTimer = nil
        if scrollGestureActive { endScrollGesture(at: lastMouseLocation) }
        listener?.cancel()
        listener = nil
        for conn in connections { conn.cancel() }
        connections.removeAll()
        running = false
        NSLog("[Input] Stopped")
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)
        NSLog("[Input] Client connected")

        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.removeConnection(connection) }
            if case .cancelled = state { self?.removeConnection(connection) }
        }

        connection.start(queue: queue)
        receivePackets(from: connection)
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
        connection.cancel()
        // Reset mouse state when client disconnects
        if mouseDown {
            mouseDown = false
            injectMouseUp(at: lastMouseLocation)
        }
        // End any active scroll gesture cleanly
        if scrollGestureActive {
            endScrollGesture(at: lastMouseLocation)
        }
        scrollEndTimer?.cancel()
        scrollEndTimer = nil
    }

    /// Continuously receive and parse 23-byte touch packets from the connection.
    private func receivePackets(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: INPUT_PACKET_SIZE, maximumLength: INPUT_PACKET_SIZE * 16) { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let data = content, !data.isEmpty {
                self.parsePackets(data)
            }

            if isComplete || error != nil {
                self.removeConnection(connection)
                return
            }

            // Continue receiving
            self.receivePackets(from: connection)
        }
    }

    // MARK: - Packet Parsing

    /// Parse one or more 23-byte packets from a data buffer.
    private func parsePackets(_ data: Data) {
        var offset = 0
        while offset + INPUT_PACKET_SIZE <= data.count {
            let packet = data[offset..<(offset + INPUT_PACKET_SIZE)]
            offset += INPUT_PACKET_SIZE

            // Verify magic bytes
            guard packet[packet.startIndex] == MAGIC_INPUT[0],
                  packet[packet.startIndex + 1] == MAGIC_INPUT[1] else {
                continue
            }

            let type = packet[packet.startIndex + 2]
            let x = readFloat(packet, offset: 3)
            let y = readFloat(packet, offset: 7)
            let dx = readFloat(packet, offset: 11)
            let dy = readFloat(packet, offset: 15)
            // pointer ID at offset 19 (4 bytes) — reserved for future multi-touch

            handleTouchEvent(type: type, x: x, y: y, dx: dx, dy: dy)
        }
    }

    /// Read a little-endian IEEE 754 float from a Data slice at the given byte offset.
    private func readFloat(_ data: Data, offset: Int) -> Float {
        let start = data.startIndex + offset
        var value: UInt32 = 0
        value |= UInt32(data[start])
        value |= UInt32(data[start + 1]) << 8
        value |= UInt32(data[start + 2]) << 16
        value |= UInt32(data[start + 3]) << 24
        return Float(bitPattern: value)
    }

    // MARK: - Event Injection

    /// Map normalized touch coordinates to the target display's pixel space and inject CGEvents.
    private func handleTouchEvent(type: UInt8, x: Float, y: Float, dx: Float, dy: Float) {
        // Map normalized coords (0.0–1.0) to target display bounds
        let bounds = CGDisplayBounds(targetDisplayID)
        let screenX = bounds.origin.x + CGFloat(x) * bounds.width
        let screenY = bounds.origin.y + CGFloat(y) * bounds.height
        let point = CGPoint(x: screenX, y: screenY)

        switch type {
        case INPUT_TOUCH_DOWN:
            mouseDown = true
            dragStarted = false
            touchDownLocation = point
            lastMouseLocation = point
            // Don't inject mouseDown yet — wait to see if this becomes a drag or stays a tap
            injectMouseMoved(at: point)

        case INPUT_TOUCH_MOVE:
            lastMouseLocation = point
            if mouseDown {
                if !dragStarted {
                    // Check if finger moved past the deadzone threshold
                    let dist = hypot(point.x - touchDownLocation.x, point.y - touchDownLocation.y)
                    if dist < Self.tapDeadzonePoints {
                        // Still in deadzone — don't drag, just absorb the movement
                        break
                    }
                    // Past deadzone — commit to drag: send mouseDown at original location first
                    dragStarted = true
                    injectMouseDown(at: touchDownLocation)
                }
                injectMouseDragged(at: point)
            } else {
                injectMouseMoved(at: point)
            }

        case INPUT_TOUCH_UP:
            if mouseDown && !dragStarted {
                // Never left the deadzone — this is a tap (click)
                injectMouseDown(at: touchDownLocation)
                injectMouseUp(at: touchDownLocation)
            } else if mouseDown {
                // Was dragging — release at current position
                injectMouseUp(at: point)
            }
            mouseDown = false
            dragStarted = false
            lastMouseLocation = point

        case INPUT_SCROLL:
            injectScroll(at: lastMouseLocation, dx: dx, dy: dy)

        default:
            break
        }
    }

    private func injectMouseDown(at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                   mouseCursorPosition: point, mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func injectMouseUp(at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                   mouseCursorPosition: point, mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func injectMouseMoved(at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                   mouseCursorPosition: point, mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func injectMouseDragged(at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                   mouseCursorPosition: point, mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }

    /// Inject scroll events with proper trackpad phases so macOS provides native
    /// momentum, rubber-banding, and smooth deceleration automatically.
    /// Phase state machine: Began → Changed... → Ended (after timeout).
    private func injectScroll(at point: CGPoint, dx: Float, dy: Float) {
        // Cancel any pending scroll-end — finger is still moving
        scrollEndTimer?.cancel()
        scrollEndTimer = nil

        // Accumulate with sensitivity and remainder for smooth sub-pixel scrolling
        let rawY = CGFloat(dy) * Self.scrollSensitivity + scrollRemainderY
        let rawX = CGFloat(dx) * Self.scrollSensitivity + scrollRemainderX
        let scrollY = Int32(rawY)
        let scrollX = Int32(rawX)
        scrollRemainderY = rawY - CGFloat(scrollY)
        scrollRemainderX = rawX - CGFloat(scrollX)

        guard scrollY != 0 || scrollX != 0 else { return }

        // Determine phase: first scroll event = Began, subsequent = Changed
        let phase: Int64
        if !scrollGestureActive {
            scrollGestureActive = true
            phase = Self.scrollPhaseBegan
            // Move cursor so scroll targets the right window
            if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                        mouseCursorPosition: point, mouseButton: .left) {
                moveEvent.post(tap: .cghidEventTap)
            }
        } else {
            phase = Self.scrollPhaseChanged
        }

        // Create continuous (trackpad-style) scroll event with phase info
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                   wheelCount: 2, wheel1: scrollY, wheel2: scrollX, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.post(tap: .cghidEventTap)

        // Schedule scroll-end: if no more scroll packets arrive within the timeout,
        // emit Ended phase so macOS kicks in momentum scrolling automatically.
        let endItem = DispatchWorkItem { [weak self] in
            self?.endScrollGesture(at: point)
        }
        scrollEndTimer = endItem
        queue.asyncAfter(deadline: .now() + .milliseconds(Self.scrollEndTimeoutMs), execute: endItem)
    }

    /// Emit the Ended phase event, signaling macOS to start momentum scrolling.
    private func endScrollGesture(at point: CGPoint) {
        guard scrollGestureActive else { return }
        scrollGestureActive = false
        scrollRemainderX = 0
        scrollRemainderY = 0

        // Ended event must have delta = 0
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                   wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Self.scrollPhaseEnded)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.post(tap: .cghidEventTap)
    }
}
