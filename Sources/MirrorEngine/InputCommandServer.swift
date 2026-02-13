// InputCommandServer.swift — Text/shortcut command channel from Daylight -> Mac.
//
// Receives newline-delimited commands over TCP and injects keyboard actions:
//   SPOTLIGHT           -> Cmd+Space
//   SEARCH              -> Cmd+Space
//   SEARCH <base64-utf8>-> Cmd+Space then type query
//   DOCS                -> opens project docs URL in default browser
//   TEXT <base64-utf8>  -> types unicode text into focused macOS app
//   KEY BACKSPACE|ENTER|ESCAPE -> sends key event

import Foundation
import AppKit
import Network

class InputCommandServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "input-command-server")
    private let docsURL = URL(string: "https://github.com/welfvh/daylight-mirror#readme")!

    init(port: UInt16) throws {
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                print("Input command server on tcp://localhost:\(INPUT_CMD_PORT)")
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            conn.start(queue: self.queue)
            self.receiveLoop(conn, buffer: Data())
        }

        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func receiveLoop(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self, error == nil else { return }
            var next = buffer
            if let data = data { next.append(data) }

            while let nl = next.firstIndex(of: 0x0A) {
                let lineData = next[..<nl]
                next.removeSubrange(...nl)
                if let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                    self.handleCommand(line)
                }
            }

            if !isComplete {
                self.receiveLoop(conn, buffer: next)
            }
        }
    }

    private func handleCommand(_ line: String) {
        DispatchQueue.main.async {
            if line == "SPOTLIGHT" {
                self.postSpotlightShortcut()
                return
            }
            if line == "SEARCH" {
                self.focusSearchUI()
                return
            }
            if line == "DOCS" {
                NSWorkspace.shared.open(self.docsURL)
                return
            }
            if line.hasPrefix("SEARCH ") {
                let payload = String(line.dropFirst(7))
                guard let data = Data(base64Encoded: payload),
                      let query = String(data: data, encoding: .utf8) else { return }
                self.focusSearchUI()
                // Give Spotlight a short beat to focus before typing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    self.typeText(query)
                }
                return
            }
            if line.hasPrefix("TEXT ") {
                let payload = String(line.dropFirst(5))
                guard let data = Data(base64Encoded: payload),
                      let text = String(data: data, encoding: .utf8) else { return }
                self.typeText(text)
                return
            }
            if line == "KEY BACKSPACE" {
                self.postKey(code: 51)
                return
            }
            if line == "KEY ENTER" {
                self.postKey(code: 36)
                return
            }
            if line == "KEY ESCAPE" {
                self.postKey(code: 53)
            }
        }
    }

    private func focusSearchUI() {
        // Prefer Raycast when installed; fallback to Spotlight.
        if let raycastURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.raycast.macos") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: raycastURL, configuration: config) { _, _ in }
            return
        }
        postSpotlightShortcut()
    }

    private func postSpotlightShortcut() {
        guard AXIsProcessTrusted() else { return }
        let keyCode: CGKeyCode = 49 // space
        let flags: CGEventFlags = .maskCommand
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func typeText(_ text: String) {
        guard AXIsProcessTrusted() else { return }
        for unit in text.utf16 {
            var scalar = unit
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &scalar)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &scalar)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func postKey(code: CGKeyCode) {
        guard AXIsProcessTrusted() else { return }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
