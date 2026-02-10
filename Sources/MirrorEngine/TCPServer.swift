// TCPServer.swift — Native TCP server for streaming frames to the Daylight app.

import Foundation
import Network

// MARK: - TCP Server

class TCPServer {
    let listener: NWListener
    var connections: [NWConnection] = []
    let queue = DispatchQueue(label: "tcp-server")
    let lock = NSLock()
    var lastKeyframeData: Data?
    var onClientCountChanged: ((Int) -> Void)?
    var frameWidth: UInt16 = 1024 {
        didSet { lock.lock(); lastKeyframeData = nil; lock.unlock() }
    }
    var frameHeight: UInt16 = 768 {
        didSet { lock.lock(); lastKeyframeData = nil; lock.unlock() }
    }

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        let tcpOptions = params.defaultProtocolStack.transportProtocol as! NWProtocolTCP.Options
        tcpOptions.noDelay = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                print("TCP server on tcp://localhost:\(TCP_PORT)")
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[TCP] Client connected")
                case .failed, .cancelled:
                    self.lock.lock()
                    self.connections.removeAll { $0 === conn }
                    let count = self.connections.count
                    self.lock.unlock()
                    self.onClientCountChanged?(count)
                    print("[TCP] Client disconnected")
                default: break
                }
            }
            conn.start(queue: self.queue)
            self.lock.lock()
            self.connections.append(conn)
            let count = self.connections.count
            let cachedKeyframe = self.lastKeyframeData
            self.lock.unlock()
            self.onClientCountChanged?(count)

            // Tell client our frame dimensions before sending any frames
            self.sendResolution(to: conn)

            if let kf = cachedKeyframe {
                conn.send(content: kf, completion: .contentProcessed { _ in })
                print("[TCP] Sent cached keyframe (\(kf.count) bytes)")
            }

            self.receiveLoop(conn)
        }

        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        lock.lock()
        for conn in connections { conn.cancel() }
        connections.removeAll()
        lock.unlock()
    }

    func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, _, error in
            if error != nil { return }
            self?.receiveLoop(conn)
        }
    }

    func broadcast(payload: Data, isKeyframe: Bool) {
        var header = Data(capacity: 7)
        header.append(contentsOf: MAGIC_FRAME)
        header.append(isKeyframe ? FLAG_KEYFRAME : 0)
        var len = UInt32(payload.count).littleEndian
        header.append(Data(bytes: &len, count: 4))

        var frame = header
        frame.append(payload)

        lock.lock()
        if isKeyframe { lastKeyframeData = frame }
        let conns = connections
        lock.unlock()

        for conn in conns {
            conn.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    func sendCommand(_ cmd: UInt8, value: UInt8) {
        var packet = Data(capacity: 4)
        packet.append(contentsOf: MAGIC_CMD)
        packet.append(cmd)
        packet.append(value)

        lock.lock()
        let conns = connections
        lock.unlock()

        for conn in conns {
            conn.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    /// Send resolution command to a specific client: [DA 7F] [04] [w:2 LE] [h:2 LE]
    func sendResolution(to conn: NWConnection) {
        var packet = Data(capacity: 7)
        packet.append(contentsOf: MAGIC_CMD)
        packet.append(CMD_RESOLUTION)
        var w = frameWidth.littleEndian
        var h = frameHeight.littleEndian
        packet.append(Data(bytes: &w, count: 2))
        packet.append(Data(bytes: &h, count: 2))
        conn.send(content: packet, completion: .contentProcessed { _ in })
        print("[TCP] Sent resolution: \(self.frameWidth)x\(self.frameHeight)")
    }
}
