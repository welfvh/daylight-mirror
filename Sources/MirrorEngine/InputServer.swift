// InputServer.swift — Reverse input channel from Daylight -> Mac.
//
// Receives normalized touch/scroll packets from Android and injects mouse/scroll
// events on macOS. This enables basic remote control (tap, drag, scroll).

import Foundation
import AppKit
import Network

class InputServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "input-server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    private let targetDisplayID: CGDirectDisplayID
    private var parserBuffer = Data()
    private var mouseIsDown = false
    private var lastPoint: CGPoint = .zero
    private var filteredScrollX: Double = 0
    private var filteredScrollY: Double = 0
    private var scrollRemainderX: Double = 0
    private var scrollRemainderY: Double = 0

    init(port: UInt16, targetDisplayID: CGDirectDisplayID) throws {
        self.targetDisplayID = targetDisplayID
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                print("Input server on tcp://localhost:\(INPUT_PORT)")
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.lock.lock()
                    self.connections.append(conn)
                    self.lock.unlock()
                    self.receiveLoop(conn)
                case .failed, .cancelled:
                    self.lock.lock()
                    self.connections.removeAll { $0 === conn }
                    self.lock.unlock()
                default:
                    break
                }
            }
            conn.start(queue: self.queue)
        }

        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        lock.lock()
        for conn in connections {
            conn.cancel()
        }
        connections.removeAll()
        lock.unlock()
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self, error == nil, let data = data else { return }
            self.parseInputData(data)
            self.receiveLoop(conn)
        }
    }

    private func parseInputData(_ data: Data) {
        parserBuffer.append(data)

        while parserBuffer.count >= INPUT_PACKET_SIZE {
            guard parserBuffer[parserBuffer.startIndex] == MAGIC_INPUT[0],
                  parserBuffer[parserBuffer.index(parserBuffer.startIndex, offsetBy: 1)] == MAGIC_INPUT[1] else {
                parserBuffer.removeFirst()
                continue
            }

            let packet = parserBuffer.prefix(INPUT_PACKET_SIZE)
            parserBuffer.removeFirst(INPUT_PACKET_SIZE)

            let type = packet[packet.index(packet.startIndex, offsetBy: 2)]
            let xNorm = floatLE(packet, at: 3)
            let yNorm = floatLE(packet, at: 7)
            let dx = floatLE(packet, at: 11)
            let dy = floatLE(packet, at: 15)
            // Reserved for future multi-touch support.
            _ = uint32LE(packet, at: 19)

            handleEvent(type: type, xNorm: xNorm, yNorm: yNorm, dx: dx, dy: dy)
        }
    }

    private func handleEvent(type: UInt8, xNorm: Float, yNorm: Float, dx: Float, dy: Float) {
        let point = mapToDisplayPoint(xNorm: xNorm, yNorm: yNorm)

        DispatchQueue.main.async {
            switch type {
            case INPUT_TOUCH_DOWN:
                self.postMouse(type: .leftMouseDown, at: point)
                self.mouseIsDown = true
                self.lastPoint = point

            case INPUT_TOUCH_MOVE:
                if self.mouseIsDown {
                    self.postMouse(type: .leftMouseDragged, at: point)
                    self.lastPoint = point
                } else {
                    self.postMouse(type: .mouseMoved, at: point)
                    self.lastPoint = point
                }

            case INPUT_TOUCH_UP:
                self.postMouse(type: .leftMouseUp, at: point)
                self.mouseIsDown = false
                self.lastPoint = point

            case INPUT_SCROLL:
                self.postScroll(dx: dx, dy: dy)

            default:
                break
            }
        }
    }

    private func mapToDisplayPoint(xNorm: Float, yNorm: Float) -> CGPoint {
        let bounds = CGDisplayBounds(targetDisplayID)
        let x = CGFloat(max(0.0, min(1.0, xNorm)))
        let y = CGFloat(max(0.0, min(1.0, yNorm)))
        // Use direct mapping so finger movement direction matches cursor movement.
        let px = bounds.minX + x * bounds.width
        let py = bounds.minY + y * bounds.height
        return CGPoint(x: px, y: py)
    }

    private func postMouse(type: CGEventType, at point: CGPoint) {
        guard AXIsProcessTrusted() else { return }
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func postScroll(dx: Float, dy: Float) {
        guard AXIsProcessTrusted() else { return }
        let bounds = CGDisplayBounds(targetDisplayID)
        // Convert normalized deltas into pixel deltas.
        let pxX = Double(dx) * Double(bounds.width)
        let pxY = Double(dy) * Double(bounds.height)

        // Smooth short jitter while preserving responsive direction changes.
        filteredScrollX = filteredScrollX * 0.35 + pxX * 0.65
        filteredScrollY = filteredScrollY * 0.35 + pxY * 0.65

        // Apply mild acceleration based on gesture speed for a less "stiff" feel.
        let speed = hypot(filteredScrollX, filteredScrollY)
        let gain = min(2.4, 1.2 + speed * 0.02)
        scrollRemainderX += filteredScrollX * gain
        scrollRemainderY += filteredScrollY * gain

        let horizontal = Int32(scrollRemainderX.rounded(.towardZero))
        let vertical = Int32(scrollRemainderY.rounded(.towardZero))
        scrollRemainderX -= Double(horizontal)
        scrollRemainderY -= Double(vertical)

        if horizontal == 0 && vertical == 0 { return }
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func uint32LE(_ data: Data.SubSequence, at offset: Int) -> UInt32 {
        let base = data.startIndex
        let b0 = UInt32(data[data.index(base, offsetBy: offset)])
        let b1 = UInt32(data[data.index(base, offsetBy: offset + 1)]) << 8
        let b2 = UInt32(data[data.index(base, offsetBy: offset + 2)]) << 16
        let b3 = UInt32(data[data.index(base, offsetBy: offset + 3)]) << 24
        return b0 | b1 | b2 | b3
    }

    private func floatLE(_ data: Data.SubSequence, at offset: Int) -> Float {
        let raw = uint32LE(data, at: offset)
        return Float(bitPattern: raw)
    }
}
