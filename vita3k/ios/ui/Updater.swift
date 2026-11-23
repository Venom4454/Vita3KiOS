// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

/// Finds a newer Hinoki on the GitHub releases page and hands its IPA to whatever installed Hinoki.
/// iOS doesn't let an app install itself: LiveContainer, TrollStore, SideStore and AltStore each take an
/// IPA link and install it over this copy (same bundle ID: games, saves and settings stay).
/// A release build compares version numbers; a test build compares its commit with the release's
/// (GitHub's compare API), so it is only offered a release made after it.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release: Identifiable, Equatable {
        let tag: String
        let version: String
        let notes: String
        let ipa: URL
        let page: URL
        let size: Int64
        var id: String { tag }
    }

    @Published var available: Release? // shown as a sheet
    @Published var checking = false
    @Published var status: String?

    @AppStorage("v3k.update.autoCheck") var autoCheck = true
    @AppStorage("v3k.update.lastCheck") private var lastCheck: Double = 0
    @AppStorage("v3k.update.skipped") private var skippedTag = ""

    private static let repo = "oledz-i/Hinoki"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static var commit: String? {
        Bundle.main.infoDictionary?["V3KCommit"] as? String
    }

    /// Built by the release workflow (not a test build from a push)
    static var isReleaseBuild: Bool {
        Bundle.main.infoDictionary?["V3KRelease"] as? Bool ?? false
    }

    /// At most every 12 hours, quietly; a version the player skipped isn't offered again
    func checkIfDue() {
        guard autoCheck, Date().timeIntervalSince1970 - lastCheck > 12 * 3600 else { return }
        Task { await check(quiet: true) }
    }

    func check(quiet: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        if !quiet { status = nil }
        do {
            let release = try await Self.latestRelease()
            lastCheck = Date().timeIntervalSince1970
            let newer = try await Self.isNewer(release)
            if newer && !(quiet && release.tag == skippedTag) {
                v3k_log_ui("Updates: \(release.tag) is available (this is \(Self.currentVersion)\(Self.commit.map { ", " + $0 } ?? ""))")
                available = release
                status = String(format: NSLocalizedString("Hinoki %@ is available.", comment: ""), release.version)
            } else if !quiet {
                status = newer ? String(format: NSLocalizedString("Hinoki %@ is available.", comment: ""), release.version)
                    : NSLocalizedString("Hinoki is up to date.", comment: "")
                if newer { available = release }
            }
        } catch {
            v3k_log_ui("Updates: check failed: \(error.localizedDescription)")
            if !quiet {
                status = NSLocalizedString("Couldn't reach GitHub. Check your connection and try again.", comment: "")
            }
        }
    }

    func skip(_ release: Release) {
        skippedTag = release.tag
        available = nil
    }

    // MARK: GitHub

    private struct APIRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int64
        }
        let tag_name: String
        let body: String?
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private static func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/\(path)")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Hinoki/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private static func latestRelease() async throws -> Release {
        let (data, response) = try await URLSession.shared.data(for: request("releases/latest"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let api = try JSONDecoder().decode(APIRelease.self, from: data)
        guard !api.draft, !api.prerelease,
              let asset = api.assets.first(where: { $0.name.lowercased().hasSuffix(".ipa") }) else {
            throw URLError(.resourceUnavailable)
        }
        let version = api.tag_name.hasPrefix("v") ? String(api.tag_name.dropFirst()) : api.tag_name
        return Release(tag: api.tag_name, version: version, notes: api.body ?? "", ipa: asset.browser_download_url,
                       page: api.html_url, size: asset.size)
    }

    private static func isNewer(_ release: Release) async throws -> Bool {
        if isReleaseBuild {
            return compareVersions(release.version, currentVersion) > 0
        }
        // A test build: newer only if the release holds commits this build doesn't have
        guard let commit, !commit.isEmpty else { return false }
        struct Comparison: Decodable { let status: String; let ahead_by: Int }
        let (data, response) = try await URLSession.shared.data(for: request("compare/\(commit)...\(release.tag)"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        let comparison = try JSONDecoder().decode(Comparison.self, from: data)
        return (comparison.status == "ahead" || comparison.status == "diverged") && comparison.ahead_by > 0
    }

    /// 1.6.10 > 1.6.9; missing parts count as 0
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}

/// Apps that can install an IPA from a link
enum UpdateInstaller: String, CaseIterable, Identifiable {
    case liveContainer = "LiveContainer"
    case trollStore = "TrollStore"
    case sideStore = "SideStore"
    case altStore = "AltStore"

    var id: String { rawValue }

    /// TrollStore marks the apps it installed with this file next to the .app
    static var installedByTrollStore: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("_TrollStore").path)
    }

    /// The ones on this device, the one that installed Hinoki first
    @MainActor
    static var available: [UpdateInstaller] {
        var list: [UpdateInstaller] = []
        if JITEnabler.inLiveContainer { list.append(.liveContainer) }
        if installedByTrollStore { list.append(.trollStore) }
        for installer in [UpdateInstaller.sideStore, .altStore, .trollStore, .liveContainer] where !list.contains(installer) {
            if let url = URL(string: installer.scheme + "://"), UIApplication.shared.canOpenURL(url) { list.append(installer) }
        }
        return list
    }

    private var scheme: String {
        switch self {
        case .liveContainer: "livecontainer"
        case .trollStore: "apple-magnifier"
        case .sideStore: "sidestore"
        case .altStore: "altstore"
        }
    }

    func link(for ipa: URL) -> URL? {
        let encoded = ipa.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ipa.absoluteString
        return URL(string: "\(scheme)://install?url=\(encoded)")
    }
}

struct UpdateSheet: View {
    let release: Updater.Release
    @ObservedObject var updater = Updater.shared
    @Environment(\.dismiss) private var dismiss
    @State private var installers: [UpdateInstaller] = []
    @State private var failed: String?

    private var notes: AttributedString {
        (try? AttributedString(markdown: release.notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(release.notes)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(format: NSLocalizedString("Hinoki %@", comment: ""), release.version))
                            .font(.title2.weight(.bold))
                        Text(String(format: NSLocalizedString("You have %@. Download: %@", comment: ""),
                                    Updater.isReleaseBuild ? Updater.currentVersion : NSLocalizedString("a test build", comment: ""),
                                    ByteCountFormatter.string(fromByteCount: release.size, countStyle: .file)))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                if !release.notes.isEmpty {
                    Section("What's new") {
                        Text(notes).font(.callout)
                    }
                }
                Section {
                    ForEach(installers) { installer in
                        Button {
                            install(with: installer)
                        } label: {
                            Label(String(format: NSLocalizedString("Install with %@", comment: ""), installer.rawValue),
                                  systemImage: installer == installers.first ? "arrow.down.circle.fill" : "arrow.down.circle")
                        }
                    }
                    Link(destination: release.ipa) {
                        Label("Download the IPA", systemImage: "square.and.arrow.down")
                    }
                    Link(destination: release.page) {
                        Label("Open the release page", systemImage: "safari")
                    }
                } header: {
                    Text("Install")
                } footer: {
                    if installers.isEmpty {
                        Text("No installer app was found. Download the IPA and open it with the app you installed Hinoki with.")
                    } else {
                        Text("The installer replaces this copy of Hinoki: your games, saves and settings stay. Open Hinoki again when it's done.")
                    }
                }
                Section {
                    Button("Skip this version", role: .destructive) {
                        updater.skip(release)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
            }
            .onAppear { installers = UpdateInstaller.available }
            .alert(failed ?? "", isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } })) {
                Button("OK", role: .cancel) { failed = nil }
            }
        }
    }

    private func install(with installer: UpdateInstaller) {
        guard let url = installer.link(for: release.ipa) else { return }
        v3k_log_ui("Updates: asking \(installer.rawValue) to install \(release.tag)")
        UIApplication.shared.open(url) { opened in
            if !opened {
                failed = String(format: NSLocalizedString("%@ could not be opened. Download the IPA instead.", comment: ""), installer.rawValue)
            }
        }
    }
}

/// Settings › Updates
struct UpdatesSection: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Section {
            LabeledContent("This version", value: Updater.isReleaseBuild
                           ? Updater.currentVersion
                           : String(format: NSLocalizedString("Test build %@", comment: ""), Updater.commit ?? "?"))
            Button {
                Task { await updater.check(quiet: false) }
            } label: {
                HStack {
                    Label("Check for updates", systemImage: "arrow.triangle.2.circlepath")
                    if updater.checking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(updater.checking)
            if let status = updater.status {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
            Toggle("Check automatically", isOn: $updater.autoCheck)
            if let profile = SigningInfo.profile {
                LabeledContent("Signed until", value: profile.expires.formatted(date: .abbreviated, time: .shortened))
            }
        } footer: {
            Text("Hinoki looks for a new release on its GitHub page and offers to install it with LiveContainer, TrollStore, SideStore or AltStore. Test builds are only offered releases made after them.")
        }
    }
}

/// How this copy of Hinoki was signed, from its provisioning profile (absent under TrollStore and
/// inside LiveContainer, which sign apps their own way). Free SideStore signing lasts 7 days: past it
/// iOS won't open Hinoki at all, so the library warns while there's still time to refresh it.
enum SigningInfo {
    struct Profile {
        let expires: Date
        let team: String
        let increasedMemory: Bool
        let largeAddressSpace: Bool
        let debuggable: Bool
    }

    static let profile: Profile? = {
        guard !JITEnablerInfo.inLiveContainer,
              let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        // a signed (CMS) wrapper around a property list
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let expires = plist["ExpirationDate"] as? Date else { return nil }
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        return Profile(expires: expires,
                       team: plist["TeamName"] as? String ?? "?",
                       increasedMemory: entitlements["com.apple.developer.kernel.increased-memory-limit"] as? Bool ?? false,
                       largeAddressSpace: entitlements["com.apple.developer.kernel.extended-virtual-addressing"] as? Bool ?? false,
                       debuggable: entitlements["get-task-allow"] as? Bool ?? false)
    }()

    /// One line for the log: what JIT and memory depend on
    static func logOnce() {
        guard !logged else { return }
        logged = true
        guard let profile else {
            v3k_log_ui("Signing: no provisioning profile (TrollStore, LiveContainer or a jailbreak)")
            return
        }
        let formatter = ISO8601DateFormatter()
        v3k_log_ui("Signing: \(profile.team), until \(formatter.string(from: profile.expires)); debugger allowed: \(profile.debuggable ? "yes" : "no"), increased memory limit: \(profile.increasedMemory ? "yes" : "no"), large address space: \(profile.largeAddressSpace ? "yes" : "no")")
    }

    private static var logged = false

    /// Shown in the library at most every 12 hours from 3 days before the end
    static func expiryWarning() -> String? {
        guard let profile else { return nil }
        let left = profile.expires.timeIntervalSinceNow
        guard left > 0, left < 3 * 24 * 3600 else { return nil }
        let key = "v3k.signingWarningShown"
        let last = UserDefaults.standard.double(forKey: key)
        guard Date().timeIntervalSince1970 - last > 12 * 3600 else { return nil }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        let when = RelativeDateTimeFormatter().localizedString(for: profile.expires, relativeTo: Date())
        return String(format: NSLocalizedString("Hinoki's signing runs out %@. Refresh it in SideStore (or the app you installed it with) before then: once it has run out, iOS won't open Hinoki until it is refreshed. Your games and saves stay.", comment: ""), when)
    }
}

/// JITEnabler.inLiveContainer from outside the main actor (it only reads the environment)
enum JITEnablerInfo {
    static var inLiveContainer: Bool {
        ProcessInfo.processInfo.environment["LC_HOME_PATH"] != nil || Bundle.main.bundlePath.contains("LiveContainer")
    }
}
