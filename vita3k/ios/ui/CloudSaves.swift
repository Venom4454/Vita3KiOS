// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

// Cloud saves: PS Vita and 3DS saves kept in a folder the player picks in iCloud Drive (or any other
// cloud folder the Files app shows), so they follow them to their other iPhone or iPad.
//
// Sideloaded apps can't use Apple's own iCloud storage (it needs an entitlement that SideStore,
// LiveContainer and developer certificates don't give), but a folder picked in the Files app works for
// any app, and iCloud Drive syncs it. Each game's save is copied there as a folder, with a small
// manifest saying when it last changed and on which device:
//
//   <folder>/PS Vita/<save ID>/...            <folder>/PS Vita/<save ID>.hinoki.json
//   <folder>/3DS/<title ID>/...               <folder>/3DS/<title ID>.hinoki.json
//
// A save is downloaded before its game starts and uploaded when the game ends. If both sides changed
// since the last sync, the newer one wins and the other is kept (Save Backups on this device, or
// "<ID>.previous" in the cloud folder).

import Foundation
import SwiftUI
import UIKit

struct CloudSaveItem: Sendable {
    let system: String // "PS Vita" or "3DS"
    let id: String // folder name in the cloud: the Vita save ID or the 3DS title ID
    let title: String
    let local: URL
    let device: String // this device's name, written in the manifest
}

enum CloudSyncResult: Sendable {
    case nothing, uploaded, downloaded, keptLocalOverCloud, tookCloudOverLocal
    case failed(String)
}

@MainActor
final class CloudSaves: ObservableObject {
    static let shared = CloudSaves()

    @Published private(set) var folderName: String?
    @Published private(set) var inICloud = false
    @Published private(set) var syncing = false
    @Published private(set) var status = ""
    @Published private(set) var lastSync: Date?

    private static let bookmarkKey = "v3k.cloud.bookmark"
    nonisolated static let queue = DispatchQueue(label: "hinoki.cloud-saves", qos: .utility)
    /// The game started last (its save is uploaded when the library comes back)
    private var playing: GameApp?

    private init() {
        refreshFolder()
        lastSync = UserDefaults.standard.object(forKey: "v3k.cloud.lastSync") as? Date
    }

    var isOn: Bool { folderName != nil && (UserDefaults.standard.object(forKey: "v3k.cloud.enabled") as? Bool ?? true) }

    // MARK: Folder

    func choose(_ url: URL) -> String? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            UserDefaults.standard.set(true, forKey: "v3k.cloud.enabled")
            // a new folder: nothing is known about what it holds
            Self.forgetRecords()
            refreshFolder()
            return nil
        } catch {
            return "Hinoki couldn't keep access to that folder: \(error.localizedDescription)"
        }
    }

    func forgetFolder() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        Self.forgetRecords()
        refreshFolder()
        status = ""
    }

    private func refreshFolder() {
        guard let url = Self.resolveFolder() else {
            folderName = nil
            inICloud = false
            return
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        folderName = url.lastPathComponent
        inICloud = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) ?? url.path.contains("Mobile Documents")
    }

    nonisolated static func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale {
            let access = url.startAccessingSecurityScopedResource()
            if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            }
            if access { url.stopAccessingSecurityScopedResource() }
        }
        return url
    }

    private nonisolated static func forgetRecords() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("v3k.cloud.rec.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: What to sync

    func item(for app: GameApp) -> CloudSaveItem? {
        if app.is3DS {
            guard let path = takeString(v3k_n3ds_save_folder(app.titleId)) else { return nil }
            return CloudSaveItem(system: "3DS", id: app.titleId, title: app.title, local: URL(fileURLWithPath: path), device: UIDevice.current.name)
        }
        guard let path = takeString(v3k_save_folder(app.titleId)) else { return nil }
        let url = URL(fileURLWithPath: path)
        return CloudSaveItem(system: "PS Vita", id: url.lastPathComponent, title: app.title, local: url, device: UIDevice.current.name)
    }

    func lastSynced(_ app: GameApp) -> Date? {
        guard let item = item(for: app) else { return nil }
        return (UserDefaults.standard.object(forKey: Self.recordKey(item, "at")) as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    // MARK: Sync points

    /// Before a game starts: its save from the cloud if it's newer there. The game starts when that's
    /// done, or after 15 seconds at most (a late download is then dropped, never put under a running game).
    func beforeLaunch(_ app: GameApp, then launch: @escaping () -> Void) {
        playing = app
        guard isOn, UserDefaults.standard.object(forKey: "v3k.cloud.atLaunch") as? Bool ?? true, let item = item(for: app),
              let folder = Self.resolveFolder() else {
            launch()
            return
        }
        let gate = CloudGate()
        var launched = false
        let go = {
            guard !launched else { return }
            launched = true
            gate.close()
            CloudGate.setRunning(item)
            launch()
        }
        syncing = true
        status = "Checking the cloud save of \(app.title)…"
        Self.queue.async {
            let result = CloudSync.sync(item, root: folder, gate: gate)
            DispatchQueue.main.async {
                self.finished([item.title: result])
                go()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            if !launched {
                v3k_log_ui("Cloud saves: \(app.title) took too long to download, starting with the save on this device")
                self.status = "The cloud save of \(app.title) took too long: the game used the save on this device."
                go()
            }
        }
    }

    /// Back in the library after a game: its save goes up
    func gameEnded() {
        CloudGate.setRunning(nil)
        guard let app = playing else { return }
        playing = nil
        guard isOn, let item = item(for: app), let folder = Self.resolveFolder() else { return }
        syncing = true
        status = "Uploading the save of \(app.title)…"
        Self.queue.async {
            let result = CloudSync.sync(item, root: folder, gate: CloudGate())
            DispatchQueue.main.async { self.finished([item.title: result]) }
        }
    }

    /// Every game with a save, both ways (Sync now, and when the app opens)
    func syncAll(_ apps: [GameApp]) {
        guard isOn, !syncing, let folder = Self.resolveFolder() else { return }
        let items = apps.compactMap { item(for: $0) }
        guard !items.isEmpty else { return }
        syncing = true
        status = "Syncing \(items.count) save\(items.count == 1 ? "" : "s")…"
        Self.queue.async {
            var results: [String: CloudSyncResult] = [:]
            for item in items {
                results[item.title] = CloudSync.sync(item, root: folder, gate: CloudGate())
            }
            DispatchQueue.main.async { self.finished(results) }
        }
    }

    private func finished(_ results: [String: CloudSyncResult]) {
        syncing = false
        var up = 0, down = 0, kept: [String] = [], errors: [String] = []
        for (title, result) in results {
            switch result {
            case .uploaded: up += 1
            case .downloaded: down += 1
            case .keptLocalOverCloud:
                up += 1
                kept.append("\(title): this device's save was newer; the cloud's is kept as .previous in the cloud folder")
            case .tookCloudOverLocal:
                down += 1
                kept.append("\(title): the cloud save was newer; this device's is in Files › Hinoki › Save Backups")
            case .failed(let why): errors.append("\(title): \(why)")
            case .nothing: break
            }
        }
        var parts: [String] = []
        if up > 0 { parts.append("\(up) uploaded") }
        if down > 0 { parts.append("\(down) downloaded") }
        status = (parts.isEmpty ? "Up to date" : parts.joined(separator: ", ")) + (kept.isEmpty ? "" : "\n" + kept.joined(separator: "\n"))
            + (errors.isEmpty ? "" : "\n" + errors.joined(separator: "\n"))
        if errors.isEmpty {
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: "v3k.cloud.lastSync")
        }
        for line in kept + errors { v3k_log_ui("Cloud saves: \(line)") }
    }

    nonisolated static func recordKey(_ item: CloudSaveItem, _ field: String) -> String {
        "v3k.cloud.rec.\(item.system).\(item.id).\(field)"
    }
}

/// Lets a download know the game has started without it (too slow): nothing is put in place then.
/// Also knows which game is running, so no sync (Sync now, the one at startup) touches its save.
final class CloudGate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    func close() { lock.lock(); closed = true; lock.unlock() }
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return !closed }

    private static let runningLock = NSLock()
    nonisolated(unsafe) private static var running: String?
    static func setRunning(_ item: CloudSaveItem?) {
        runningLock.lock()
        running = item.map { "\($0.system)/\($0.id)" }
        runningLock.unlock()
    }
    static func isRunning(_ item: CloudSaveItem) -> Bool {
        runningLock.lock()
        defer { runningLock.unlock() }
        return running == "\(item.system)/\(item.id)"
    }
}

/// The copying, on CloudSaves.queue
enum CloudSync {
    private struct Manifest: Codable {
        var modified: Double
        var device: String
        var title: String
        var files: Int
    }

    private static let junk: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini"]

    static func sync(_ item: CloudSaveItem, root: URL, gate: CloudGate) -> CloudSyncResult {
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let systemFolder = root.appendingPathComponent(item.system, isDirectory: true)
        let cloudFolder = systemFolder.appendingPathComponent(item.id, isDirectory: true)
        let manifestURL = systemFolder.appendingPathComponent(item.id + ".hinoki.json")
        do {
            try fm.createDirectory(at: systemFolder, withIntermediateDirectories: true)
        } catch {
            return .failed("the cloud folder can't be written (\(error.localizedDescription))")
        }

        let local = newest(in: item.local)
        let cloud = readManifest(manifestURL)
        let defaults = UserDefaults.standard
        let lastLocal = defaults.object(forKey: CloudSaves.recordKey(item, "local")) as? Double
        let lastCloud = defaults.object(forKey: CloudSaves.recordKey(item, "cloud")) as? Double

        let localChanged = local.map { stamp in lastLocal.map { stamp > $0 + 1 } ?? true } ?? false
        let cloudChanged = cloud.map { manifest in lastCloud.map { manifest.modified > $0 + 0.5 } ?? true } ?? false

        let upload = {
            guard let stamp = local, !CloudGate.isRunning(item) else { return CloudSyncResult.nothing }
            if let problem = uploadFolder(item.local, to: cloudFolder) { return .failed(problem) }
            let manifest = Manifest(modified: stamp, device: item.device, title: item.title, files: fileCount(item.local))
            if let problem = writeManifest(manifest, to: manifestURL) { return .failed(problem) }
            record(item, local: stamp, cloud: stamp)
            return .uploaded
        }
        let download = { (cloud: Manifest) -> CloudSyncResult in
            if let problem = downloadFolder(cloudFolder, to: item.local, item: item, gate: gate) { return .failed(problem) }
            record(item, local: newest(in: item.local) ?? cloud.modified, cloud: cloud.modified)
            return .downloaded
        }

        switch (localChanged, cloudChanged) {
        case (true, true):
            // both changed since the last sync (or the first sync with saves on both sides): newer wins
            guard let localStamp = local, let cloudManifest = cloud else { return .nothing }
            if localStamp >= cloudManifest.modified {
                let result = upload()
                if case .uploaded = result { return .keptLocalOverCloud }
                return result
            }
            let result = download(cloudManifest)
            if case .downloaded = result { return .tookCloudOverLocal }
            return result
        case (true, false):
            return upload()
        case (false, true):
            guard let cloudManifest = cloud else { return .nothing }
            return download(cloudManifest)
        case (false, false):
            return .nothing
        }
    }

    private static func record(_ item: CloudSaveItem, local: Double, cloud: Double) {
        let defaults = UserDefaults.standard
        defaults.set(local, forKey: CloudSaves.recordKey(item, "local"))
        defaults.set(cloud, forKey: CloudSaves.recordKey(item, "cloud"))
        defaults.set(Date().timeIntervalSince1970, forKey: CloudSaves.recordKey(item, "at"))
    }

    /// The latest change to any file of the save, nil when there's no save
    private static func newest(in folder: URL) -> Double? {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return nil }
        var latest: Double?
        for case let file as URL in files where !junk.contains(file.lastPathComponent) {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true,
                  let date = values.contentModificationDate else { continue }
            latest = max(latest ?? 0, date.timeIntervalSince1970)
        }
        return latest
    }

    private static func fileCount(_ folder: URL) -> Int {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var count = 0
        for case let file as URL in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { count += 1 }
        return count
    }

    private static func readManifest(_ url: URL) -> Manifest? {
        // (a coordinated read downloads it from iCloud first if it isn't on this device yet)
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            data = try? Data(contentsOf: readable)
        }
        guard let data else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    private static func writeManifest(_ manifest: Manifest, to url: URL) -> String? {
        guard let data = try? JSONEncoder().encode(manifest) else { return "the manifest could not be written" }
        var problem: String?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writable in
            do { try data.write(to: writable, options: .atomic) } catch { problem = error.localizedDescription }
        }
        return problem ?? coordinationError?.localizedDescription
    }

    /// This device's save into the cloud folder (what was there is kept as "<ID>.previous")
    private static func uploadFolder(_ local: URL, to cloud: URL) -> String? {
        let fm = FileManager.default
        let previous = cloud.deletingLastPathComponent().appendingPathComponent(cloud.lastPathComponent + ".previous", isDirectory: true)
        var problem: String?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: cloud, options: .forReplacing, error: &coordinationError) { target in
            do {
                if fm.fileExists(atPath: target.path) {
                    try? fm.removeItem(at: previous)
                    try fm.moveItem(at: target, to: previous)
                }
                try fm.copyItem(at: local, to: target)
                for junkFile in junk { try? fm.removeItem(at: target.appendingPathComponent(junkFile)) }
            } catch {
                problem = "upload failed (\(error.localizedDescription))"
            }
        }
        return problem ?? coordinationError.map { "upload failed (\($0.localizedDescription))" }
    }

    /// The cloud's save onto this device. Files not downloaded yet are fetched first; this device's save
    /// goes to Save Backups before it is replaced.
    private static func downloadFolder(_ cloud: URL, to local: URL, item: CloudSaveItem, gate: CloudGate) -> String? {
        let title = item.title
        let fm = FileManager.default
        try? fm.startDownloadingUbiquitousItem(at: cloud)
        let staging = local.deletingLastPathComponent().appendingPathComponent(local.lastPathComponent + ".cloud-incoming", isDirectory: true)
        try? fm.removeItem(at: staging)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            return "the save folder can't be written (\(error.localizedDescription))"
        }
        defer { try? fm.removeItem(at: staging) }

        guard let files = fm.enumerator(at: cloud, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: []) else {
            return "the cloud save can't be read"
        }
        var copied = 0
        for case let file as URL in files {
            var name = file.lastPathComponent
            var source = file
            // iCloud placeholders of files not downloaded yet: ".save.dat.icloud" stands for "save.dat"
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(".icloud".count))
                source = file.deletingLastPathComponent().appendingPathComponent(name)
                try? fm.startDownloadingUbiquitousItem(at: source)
            } else if junk.contains(name) || (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                continue
            }
            let relative = String(source.path.dropFirst(cloud.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let destination = staging.appendingPathComponent(relative)
            var problem: String?
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                do {
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.removeItem(at: destination)
                    try fm.copyItem(at: readable, to: destination)
                } catch {
                    problem = error.localizedDescription
                }
            }
            if let failure = problem ?? coordinationError?.localizedDescription {
                return "download failed (\(failure))"
            }
            copied += 1
        }
        guard copied > 0 else { return "the cloud save is empty" }
        // started without it (too slow), or the game is running: never swap a save under a running game
        guard gate.isOpen, !CloudGate.isRunning(item) else { return "the game started before the download finished" }

        if fm.fileExists(atPath: local.path), let contents = try? fm.contentsOfDirectory(atPath: local.path), !contents.isEmpty {
            let backups = URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0])
                .appendingPathComponent("Save Backups", isDirectory: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HHmmss"
            let safeTitle = title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: " ")
            let backup = backups.appendingPathComponent("\(safeTitle) (\(local.lastPathComponent)) before cloud download \(formatter.string(from: Date()))")
            do {
                try fm.createDirectory(at: backups, withIntermediateDirectories: true)
                try fm.copyItem(at: local, to: backup)
            } catch {
                return "this device's save couldn't be backed up, so it was kept (\(error.localizedDescription))"
            }
        }
        do {
            try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: local.path) { try fm.removeItem(at: local) }
            try fm.moveItem(at: staging, to: local)
        } catch {
            return "the save couldn't be put in place (\(error.localizedDescription))"
        }
        return nil
    }
}

// MARK: - Settings › Cloud saves

struct CloudSavesView: View {
    @EnvironmentObject var model: LibraryModel
    @ObservedObject private var cloud = CloudSaves.shared
    @AppStorage("v3k.cloud.enabled") private var enabled = true
    @AppStorage("v3k.cloud.atLaunch") private var atLaunch = true
    @State private var picking = false
    @State private var message: String?
    @State private var confirmForget = false

    var body: some View {
        Form {
            Section {
                if let name = cloud.folderName {
                    LabeledContent("Folder") {
                        Label(name, systemImage: cloud.inICloud ? "icloud.fill" : "folder.fill")
                            .foregroundStyle(cloud.inICloud ? Color.accentColor : Color.secondary)
                    }
                    Toggle("Cloud saves", isOn: $enabled)
                    Toggle("Sync when a game starts and ends", isOn: $atLaunch)
                    Button {
                        cloud.syncAll(model.apps)
                    } label: {
                        HStack {
                            Label("Sync now", systemImage: "arrow.triangle.2.circlepath.icloud")
                            Spacer()
                            if cloud.syncing { ProgressView() }
                        }
                    }
                    .disabled(cloud.syncing || !enabled)
                    Button("Choose another folder") { picking = true }
                    Button("Stop using this folder", role: .destructive) { confirmForget = true }
                } else {
                    Button {
                        picking = true
                    } label: {
                        Label("Choose a folder in iCloud Drive", systemImage: "icloud.and.arrow.up")
                    }
                }
            } header: {
                Text("Cloud saves")
            } footer: {
                Text("Pick (or make) a folder such as iCloud Drive › Hinoki Saves. PS Vita and 3DS saves are copied there and iCloud keeps them on all your devices: on another iPhone or iPad, pick the same folder in Hinoki. A save is downloaded before its game starts and uploaded when you quit. If both changed, the newer one wins and the other is kept (Save Backups on this device, or .previous in the folder).\n\nHinoki is sideloaded, so it can't use Apple's private iCloud storage; a folder in iCloud Drive works the same way. Any cloud folder the Files app shows (Google Drive, OneDrive, Dropbox) works too.")
            }

            if cloud.folderName != nil {
                Section("Status") {
                    if !cloud.status.isEmpty {
                        Text(cloud.status).font(.footnote)
                    }
                    LabeledContent("Last sync") {
                        Text(cloud.lastSync.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                    }
                }
                Section("Games") {
                    ForEach(model.apps.filter { cloud.item(for: $0) != nil }) { app in
                        HStack {
                            if let icon = app.icon {
                                Image(uiImage: icon).resizable().frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.title).lineLimit(1)
                                Text(app.is3DS ? "3DS" : "PS Vita").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(cloud.lastSynced(app).map { $0.formatted(.relative(presentation: .named)) } ?? "Not synced")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Cloud saves")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                message = cloud.choose(url)
                if message == nil { cloud.syncAll(model.apps) }
            case .failure(let error):
                // Some signing methods (a developer certificate in particular) leave Hinoki without the
                // system's folder picker: say so instead of doing nothing
                message = String(format: NSLocalizedString("iOS didn't let Hinoki open the folder picker (%@). This happens with some ways of installing it, a developer certificate in particular. Installed with SideStore, AltStore or LiveContainer it works. Meanwhile your saves are in Files › On My iPhone › Hinoki, to copy by hand.", comment: ""), error.localizedDescription)
            }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .confirmationDialog("Stop using this folder?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Stop using it", role: .destructive) { cloud.forgetFolder() }
        } message: {
            Text("Nothing is deleted: the saves stay on this device and in the folder.")
        }
    }
}
