// ADBBridge.swift — Android Debug Bridge integration for USB device control.

import Foundation

// MARK: - ADB Bridge

struct ADBBridge {

    // MARK: - Process Helper

    /// Run an external command, returning (exitCode, stdout).
    /// Silences stderr. Uses `/usr/bin/env` to resolve PATH.
    @discardableResult
    private static func run(_ args: String..., captureOutput: Bool = false) -> (status: Int32, output: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = Array(args)
        process.standardError = FileHandle.nullDevice

        let pipe: Pipe? = captureOutput ? Pipe() : nil
        process.standardOutput = pipe ?? FileHandle.nullDevice

        try? process.run()
        process.waitUntilExit()

        let output: String? = pipe.flatMap {
            String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        }
        return (process.terminationStatus, output)
    }

    // MARK: - Device Discovery

    static func isAvailable() -> Bool {
        run("which", "adb").status == 0
    }

    static func connectedDevice() -> String? {
        guard let output = run("adb", "devices", captureOutput: true).output else { return nil }
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t")
            if parts.count >= 2 && parts[1] == "device" {
                return String(parts[0])
            }
        }
        return nil
    }

    // MARK: - Reverse Tunnel

    @discardableResult
    static func setupReverseTunnel(port: UInt16) -> Bool {
        run("adb", "reverse", "tcp:\(port)", "tcp:\(port)").status == 0
    }

    @discardableResult
    static func removeReverseTunnel(port: UInt16) -> Bool {
        run("adb", "reverse", "--remove", "tcp:\(port)").status == 0
    }

    // MARK: - System Settings

    static func querySystemSetting(_ setting: String) -> Int? {
        guard let str = run("adb", "shell", "settings", "get", "system", setting, captureOutput: true)
            .output?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return Int(str)
    }

    static func setSystemSetting(_ setting: String, value: Int) {
        run("adb", "shell", "settings", "put", "system", setting, "\(value)")
    }

    // MARK: - App Control

    /// Launch the Daylight Mirror Android app on the connected device.
    static func launchApp() {
        run("adb", "shell", "am", "start", "-n", "com.daylight.mirror/.MirrorActivity")
        print("[ADB] Launched Daylight Mirror on device")
    }
}
