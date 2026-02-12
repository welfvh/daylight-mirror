// TCPServer.swift — Native TCP frame server for Daylight Mirror.
//
// Sends LZ4-compressed greyscale frames to connected Android clients over raw TCP.
// Protocol: [DA 7E] [flags] [len:4 LE] [payload]. Keyframes are full LZ4, deltas
// are XOR + LZ4. Also sends resolution and brightness/warmth commands.

import Foundation
import Network
import QuartzCore

struct LatencyStats {
    var rttMs: Double = 0
    var rttMinMs: Double = 0
    var rttMaxMs: Double = 0
    var rttAvgMs: Double = 0
    var rttP95Ms: Double = 0
    var acksReceived: Int = 0
    var ackRate: Double = 0
}

class TCPServer {
    let listener: NWListener
    var connections: [NWConnection] = []
    let queue = DispatchQueue(label: "tcp-server")
    let lock = NSLock()
    var lastKeyframeData: Data?
    var onClientCountChanged: ((Int) -> Void)?
    var onLatencyStats: ((LatencyStats) -> Void)?
    private(set) var latencyStats: LatencyStats?
    var frameWidth: UInt16 = 1024 {
        didSet { lock.lock(); lastKeyframeData = nil; lock.unlock() }
    }
    var frameHeight: UInt16 = 768 {
        didSet { lock.lock(); lastKeyframeData = nil; lock.unlock() }
    }

    private var sendTimestamps: [UInt32: Double] = [:]
    private let rttLock = NSLock()
    private var rttSamples: [Double] = []
    private let rttWindowSize = 150
    private var totalAcks: Int = 0
    private var lastAckStatsTime: Double = CACurrentMediaTime()
    private var _inflightFrames: Int = 0

    /// Number of frames sent but not yet ACK'd by Android. Thread-safe (reads rttLock).
    var inflightFrames: Int {
        rttLock.lock()
        let val = _inflightFrames
        rttLock.unlock()
        return val
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
                    self.lock.lock()
                    self.connections.append(conn)
                    let count = self.connections.count
                    let cachedKeyframe = self.lastKeyframeData
                    self.lock.unlock()
                    self.rttLock.lock()
                    self._inflightFrames = 0
                    self.sendTimestamps.removeAll()
                    self.rttLock.unlock()
                    self.onClientCountChanged?(count)

                    // Tell client our frame dimensions before sending any frames
                    self.sendResolution(to: conn)

                    if let kf = cachedKeyframe {
                        conn.send(content: kf, completion: .contentProcessed { _ in })
                        print("[TCP] Sent cached keyframe (\(kf.count) bytes)")
                    } else {
                        print("[TCP] No cached keyframe yet — client will get next broadcast keyframe")
                    }

                    self.receiveLoop(conn)
                case .failed, .cancelled:
                    self.lock.lock()
                    self.connections.removeAll { $0 === conn }
                    let count = self.connections.count
                    self.lock.unlock()
                    self.onClientCountChanged?(count)
                    print("[TCP] Client disconnected (\(state))")
                default: break
                }
            }
            conn.start(queue: self.queue)
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
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self, error == nil, let data = data else { return }
            self.rttLock.lock()
            self.parseAckData(data)
            self.rttLock.unlock()
            self.receiveLoop(conn)
        }
    }

    private var ackParseBuffer = Data()

    /// Must be called with rttLock held.
    private func parseAckData(_ data: Data) {
        ackParseBuffer.append(data)

        var scanned = 0
        while ackParseBuffer.count >= 6 {
            guard ackParseBuffer[ackParseBuffer.startIndex] == MAGIC_ACK[0]
                    && ackParseBuffer[ackParseBuffer.index(ackParseBuffer.startIndex, offsetBy: 1)] == MAGIC_ACK[1] else {
                ackParseBuffer.removeFirst()
                scanned += 1
                if scanned > 256 {
                    ackParseBuffer.removeAll()
                    return
                }
                continue
            }

            let base = ackParseBuffer.startIndex
            let b0 = UInt32(ackParseBuffer[ackParseBuffer.index(base, offsetBy: 2)])
            let b1 = UInt32(ackParseBuffer[ackParseBuffer.index(base, offsetBy: 3)]) << 8
            let b2 = UInt32(ackParseBuffer[ackParseBuffer.index(base, offsetBy: 4)]) << 16
            let b3 = UInt32(ackParseBuffer[ackParseBuffer.index(base, offsetBy: 5)]) << 24
            let seq = b0 | b1 | b2 | b3
            ackParseBuffer.removeFirst(6)

            let now = CACurrentMediaTime()

            guard let sendTime = sendTimestamps.removeValue(forKey: seq) else {
                continue
            }
            _inflightFrames -= 1
            if _inflightFrames < 0 { _inflightFrames = 0 }
            let rtt = (now - sendTime) * 1000.0
            rttSamples.append(rtt)
            if rttSamples.count > rttWindowSize {
                rttSamples.removeFirst(rttSamples.count - rttWindowSize)
            }
            totalAcks += 1

            let sorted = rttSamples.sorted()
            let avg = sorted.reduce(0, +) / Double(sorted.count)
            let p95Index = min(Int(Double(sorted.count) * 0.95), sorted.count - 1)

            let elapsed = now - lastAckStatsTime
            let rate = elapsed > 0 ? Double(totalAcks) / elapsed : 0

            let stats = LatencyStats(
                rttMs: rtt,
                rttMinMs: sorted.first ?? 0,
                rttMaxMs: sorted.last ?? 0,
                rttAvgMs: avg,
                rttP95Ms: sorted[p95Index],
                acksReceived: totalAcks,
                ackRate: rate
            )

            if totalAcks % 30 == 0 {
                print(String(format: "[RTT] last: %.1fms | avg: %.1fms | p95: %.1fms | min: %.1fms | max: %.1fms | acks: %d",
                             stats.rttMs, stats.rttAvgMs, stats.rttP95Ms, stats.rttMinMs, stats.rttMaxMs, stats.acksReceived))
            }

            latencyStats = stats
            onLatencyStats?(stats)
        }
    }

    func broadcast(payload: Data, isKeyframe: Bool, sequenceNumber: UInt32 = 0) {
        var header = Data(capacity: FRAME_HEADER_SIZE)
        header.append(contentsOf: MAGIC_FRAME)
        header.append(isKeyframe ? FLAG_KEYFRAME : 0)
        var seq = sequenceNumber.littleEndian
        header.append(Data(bytes: &seq, count: 4))
        var len = UInt32(payload.count).littleEndian
        header.append(Data(bytes: &len, count: 4))

        var frame = header
        frame.append(payload)

        let sendTime = CACurrentMediaTime()

        lock.lock()
        if isKeyframe { lastKeyframeData = frame }
        let conns = connections
        lock.unlock()

        rttLock.lock()
        sendTimestamps[sequenceNumber] = sendTime
        _inflightFrames += 1
        // Evict old entries to prevent unbounded growth
        if sendTimestamps.count > 300 {
            let evicted = sendTimestamps.count
            let cutoff = sequenceNumber &- 300
            sendTimestamps = sendTimestamps.filter { $0.key > cutoff }
            _inflightFrames -= (evicted - sendTimestamps.count)
            if _inflightFrames < 0 { _inflightFrames = 0 }
        }
        rttLock.unlock()

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
