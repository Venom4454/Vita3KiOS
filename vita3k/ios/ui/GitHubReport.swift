// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

/// One tap from About: the problem report saved where Files can reach it, and a GitHub issue opened with
/// the device, versions and the end of the log already filled in. Opening an issue needs the player's
/// own GitHub account, so the page opens in Safari; the report zip is attached there from Files.
enum GitHubReport {
    static let repository = "oledz-i/Hinoki"
    /// GitHub turns down longer links; percent-encoding grows text, so the log tail is cut to fit
    private static let maxURLLength = 7_600

    /// Builds the report, keeps it in Documents/Reports and returns the issue link (nil if the report failed)
    static func prepare(appVersion: String) -> (url: URL, report: URL?)? {
        var message: UnsafeMutablePointer<CChar>?
        let made = takeString(v3k_make_problem_report(&message))
        _ = takeString(message)

        var saved: URL?
        if let made {
            let reports = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Reports", isDirectory: true)
            try? FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            let target = reports.appendingPathComponent(URL(fileURLWithPath: made).lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            if (try? FileManager.default.copyItem(at: URL(fileURLWithPath: made), to: target)) != nil { saved = target }
        }

        let device = UIDevice.current
        var head = """
        **What happened:**
        <!-- Which game (title ID if you know it), what you did and what went wrong -->


        **Device:** \(deviceModel()) · \(device.systemName) \(device.systemVersion)
        **Hinoki:** \(appVersion)
        **Core:** \(String(cString: v3k_version()))
        **JIT:** \(v3k_is_jit_enabled() ? "on" : "off")

        """
        if let saved {
            head += "**Report:** saved as `\(saved.lastPathComponent)` in Files › On My iPhone › Hinoki › Reports. Drag it into this box to attach it.\n\n"
        }

        let logPath = String(cString: v3k_log_path())
        let previousPath = URL(fileURLWithPath: logPath).deletingLastPathComponent().appendingPathComponent("vita3k-previous.log").path
        let current = tail(logPath)
        let previous = tail(previousPath)

        // Shrink the log tails until the whole link fits
        var budget = 4_000
        while budget >= 0 {
            var body = head
            if !current.isEmpty { body += section("End of the log", current, limit: budget) }
            if !previous.isEmpty { body += section("End of the previous session's log", previous, limit: budget / 2) }
            if let url = issueURL(body: body), url.absoluteString.count <= maxURLLength || budget == 0 {
                return (url, saved)
            }
            budget = budget > 500 ? budget - 500 : 0
            if budget == 0, let url = issueURL(body: head) { return (url, saved) }
        }
        return nil
    }

    private static func issueURL(body: String) -> URL? {
        var parts = URLComponents(string: "https://github.com/\(repository)/issues/new")
        parts?.queryItems = [
            URLQueryItem(name: "template", value: "0-hinoki-report.md"),
            URLQueryItem(name: "labels", value: "bug"),
            URLQueryItem(name: "title", value: "[Hinoki] "),
            URLQueryItem(name: "body", value: body),
        ]
        // URLComponents leaves + and & inside values alone in places GitHub reads differently
        let query = parts?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        parts?.percentEncodedQuery = query
        return parts?.url
    }

    private static func section(_ title: String, _ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        let cut = text.count > limit ? String(text.suffix(limit)) : text
        // Start on a whole line
        let lines = cut.split(separator: "\n", omittingEmptySubsequences: false)
        let trimmed = (text.count > limit ? lines.dropFirst() : lines[...]).joined(separator: "\n")
        return "<details><summary>\(title)</summary>\n\n```\n\(redact(trimmed))\n```\n</details>\n\n"
    }

    /// The last part of a log file (read from the end, logs can be large)
    private static func tail(_ path: String, bytes: UInt64 = 16_384) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        guard let data = try? handle.readToEnd() else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Paths inside the app's container name the device's container UUID: not needed on a public page
    private static func redact(_ text: String) -> String {
        let home = NSHomeDirectory()
        return home.isEmpty ? text : text.replacingOccurrences(of: home, with: "~")
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
