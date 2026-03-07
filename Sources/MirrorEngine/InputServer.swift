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

    // Scroll acceleration: accumulate fractional remainders for smooth scrolling
    private var scrollRemainderX: CGFloat = 0
    private var scrollRemainderY: CGFloat = 0
    private static let scrollSensitivity: CGFloat = 50.0

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
            lastMouseLocation = point
            injectMouseDown(at: point)

        case INPUT_TOUCH_MOVE:
            lastMouseLocation = point
            if mouseDown {
                injectMouseDragged(at: point)
            } else {
                injectMouseMoved(at: point)
            }

        case INPUT_TOUCH_UP:
            mouseDown = false
            lastMouseLocation = point
            injectMouseUp(at: point)

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

    /// Inject scroll wheel events with acceleration and remainder tracking for smooth sub-pixel scrolling.
    private func injectScroll(at point: CGPoint, dx: Float, dy: Float) {
        // Accumulate with sensitivity and remainder for smooth scrolling
        let rawY = CGFloat(dy) * Self.scrollSensitivity + scrollRemainderY
        let rawX = CGFloat(dx) * Self.scrollSensitivity + scrollRemainderX

        let scrollY = Int32(rawY)
        let scrollX = Int32(rawX)

        scrollRemainderY = rawY - CGFloat(scrollY)
        scrollRemainderX = rawX - CGFloat(scrollX)

        guard scrollY != 0 || scrollX != 0 else { return }

        // Move cursor to touch location first so scroll targets the right window
        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                    mouseCursorPosition: point, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }

        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                   wheelCount: 2, wheel1: scrollY, wheel2: scrollX, wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }
}
