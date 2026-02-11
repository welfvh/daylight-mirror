// ADBBridge.swift — ADB communication layer for Daylight Mirror.
//
// Manages the adb binary (bundled or PATH), reverse tunnels, device queries,
// companion APK installation, and app launching on the Daylight DC-1.

import Foundation

struct ADBBridge {
    /// Resolved path to the adb binary. Prefers system adb (user-managed, up-to-date),
    /// falls back to bundled copy (for users without Homebrew/Android SDK).
    private static let resolvedADBPath: String? = {
        // 1. System adb on PATH (e.g. Homebrew install) — preferred because the user
        //    keeps it updated and it won't conflict with their other Android tooling.
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "adb"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0,
           let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            print("[ADB] Using system adb: \(path)")
            return path
        }
        // 2. Fallback: bundled adb inside the .app bundle (Resources/adb).
        //    Only used when no system adb exists. May be stale — `make fetch-adb`
        //    downloads latest at build time but won't auto-update.
        if let bundled = Bundle.main.resourcePath.map({ $0 + "/adb" }),
           FileManager.default.isExecutableFile(atPath: bundled) {
            print("[ADB] Using bundled adb (no system adb found): \(bundled)")
            return bundled
        }
        print("[ADB] No adb binary found (checked PATH + bundle)")
        return nil
    }()

    /// Create a Process configured to run adb with the given arguments.
    private static func makeADBProcess(_ arguments: [String]) -> Process? {
        guard let adbPath = resolvedADBPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = arguments
        return process
    }

    static func isAvailable() -> Bool {
        return resolvedADBPath != nil
    }

    static func connectedDevice() -> String? {
        let pipe = Pipe()
        guard let process = makeADBProcess(["devices"]) else { return nil }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t")
            if parts.count >= 2 && parts[1] == "device" {
                return String(parts[0])
            }
        }
        return nil
    }

    @discardableResult
    static func setupReverseTunnel(port: UInt16) -> Bool {
        guard let process = makeADBProcess(["reverse", "tcp:\(port)", "tcp:\(port)"]) else { return false }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @discardableResult
    static func removeReverseTunnel(port: UInt16) -> Bool {
        guard let process = makeADBProcess(["reverse", "--remove", "tcp:\(port)"]) else { return false }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func querySystemSetting(_ setting: String) -> Int? {
        let pipe = Pipe()
        guard let process = makeADBProcess(["shell", "settings", "get", "system", setting]) else { return nil }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        if let str = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            return Int(str)
        }
        return nil
    }

    static func setSystemSetting(_ setting: String, value: Int) {
        guard let process = makeADBProcess(["shell", "settings", "put", "system", setting, "\(value)"]) else { return }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Check if the companion Android app is installed on the connected device.
    static func isAppInstalled() -> Bool {
        let pipe = Pipe()
        guard let process = makeADBProcess(["shell", "pm", "list", "packages", "com.daylight.mirror"]) else { return false }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.contains("package:com.daylight.mirror")
    }

    /// Install the bundled APK onto the connected device.
    /// Returns nil on success, or an error message on failure.
    static func installBundledAPK() -> String? {
        guard let resourcePath = Bundle.main.resourcePath else {
            return "No resource path in bundle"
        }
        let apkPath = resourcePath + "/app-debug.apk"
        guard FileManager.default.fileExists(atPath: apkPath) else {
            return "No bundled APK found"
        }
        let pipe = Pipe()
        guard let process = makeADBProcess(["install", "-r", apkPath]) else {
            return "ADB not available"
        }
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            return "Install failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        print("[ADB] Installed bundled APK successfully")
        return nil
    }

    /// Launch the Daylight Mirror Android app on the connected device.
    static func launchApp() {
        guard let process = makeADBProcess(["shell", "am", "start", "-n",
                             "com.daylight.mirror/.MirrorActivity"]) else { return }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        print("[ADB] Launched Daylight Mirror on device")
    }
}
