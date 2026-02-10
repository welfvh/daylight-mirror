// UpdateChecker.swift — GitHub release checker for update notifications.

import Foundation

// MARK: - Update Checker

/// Checks GitHub releases for a newer version on launch. Non-blocking, fire-and-forget.
struct UpdateChecker {
    static let repo = "welfvh/daylight-mirror"

    struct Release {
        let version: String
        let url: String
    }

    static func check(currentVersion: String) async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let htmlURL = json["html_url"] as? String else {
            return nil
        }

        // Strip leading "v" for comparison (e.g. "v1.1.0" → "1.1.0")
        let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        if isNewer(remote: remoteVersion, local: currentVersion) {
            return Release(version: remoteVersion, url: htmlURL)
        }
        return nil
    }

    /// Simple semver comparison: returns true if remote > local
    static func isNewer(remote: String, local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}
