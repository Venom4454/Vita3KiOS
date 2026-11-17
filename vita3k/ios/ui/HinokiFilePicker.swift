// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Hinoki's own file picker, for its folder in the Files app (On My iPhone › Hinoki, or the app's
/// folder in LiveContainer). The system picker doesn't open, or gives back files that can't be read,
/// for some apps signed with a developer certificate; this one reads the app's folder directly, so it
/// works however the app was signed. Files get there from the Files app, AirDrop (Save to Files) or a
/// computer (Finder / iTunes file sharing).
struct HinokiFilePicker: View {
    /// What the picked files are for: shapes the hint and which files are marked as usable
    enum Purpose { case install, plugin }

    var purpose: Purpose = .install
    let onPick: ([URL]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var directory = HinokiFilePicker.root
    @State private var entries: [Entry] = []
    @State private var selection = Set<URL>()

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The Import folder: created so it shows up in the Files app, ready to drop files into
    static var importFolder: URL {
        let url = root.appendingPathComponent("Import", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    struct Entry: Identifiable, Hashable {
        let url: URL
        let isFolder: Bool
        let isGameFolder: Bool
        let size: Int64
        let usable: Bool
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    var body: some View {
        NavigationStack {
            List {
                if directory.standardizedFileURL == Self.root.standardizedFileURL {
                    Section {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        open(directory.deletingLastPathComponent())
                    } label: {
                        Label("Back to \(parentName)", systemImage: "chevron.left")
                    }
                }

                Section(directory.standardizedFileURL == Self.root.standardizedFileURL ? "Hinoki's folder" : directory.lastPathComponent) {
                    if entries.isEmpty {
                        Text("Nothing here yet.").foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        row(entry)
                    }
                }
            }
            .navigationTitle(purpose == .plugin ? "Pick plugins" : "Pick files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selection.isEmpty ? (purpose == .plugin ? "Add" : "Install") : "\(purpose == .plugin ? "Add" : "Install") (\(selection.count))") {
                        let picked = Array(selection)
                        dismiss()
                        // after the sheet is gone, so the install overlay and alerts can show
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onPick(picked) }
                    }
                    .disabled(selection.isEmpty)
                }
            }
            .refreshable { load() }
            .onAppear {
                _ = Self.importFolder
                load()
            }
        }
    }

    private var hint: String {
        switch purpose {
        case .install:
            return "Put games (.vpk, .zip, .pkg), firmware (.PUP), licenses (work.bin, .rif, .zrif), plugins or game folders in Hinoki's folder (Files app › On My iPhone › Hinoki, the Import folder is a good spot), then pick them here. Tap a folder to open it; tick it to install everything in it."
        case .plugin:
            return "Put .suprx / .skprx plugins (and libshacccg.suprx for ports) in Hinoki's folder (Files app › On My iPhone › Hinoki › Import), then pick them here."
        }
    }

    private var parentName: String {
        let parent = directory.deletingLastPathComponent()
        return parent.standardizedFileURL == Self.root.standardizedFileURL ? "Hinoki" : parent.lastPathComponent
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        let picked = selection.contains(entry.url)
        HStack(spacing: 12) {
            Button {
                if picked { selection.remove(entry.url) } else { selection.insert(entry.url) }
            } label: {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(picked ? Theme.accent : (entry.usable ? Color.secondary : Color.secondary.opacity(0.35)))
            }
            .buttonStyle(.borderless)
            .disabled(!entry.usable)

            Button {
                if entry.isFolder && !entry.isGameFolder {
                    open(entry.url)
                } else if entry.usable {
                    if picked { selection.remove(entry.url) } else { selection.insert(entry.url) }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon(entry))
                        .foregroundStyle(entry.usable || entry.isFolder ? Theme.accent : .secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).lineLimit(2)
                            .foregroundStyle(entry.usable || entry.isFolder ? .primary : .secondary)
                        Text(detail(entry)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if entry.isFolder && !entry.isGameFolder {
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func icon(_ entry: Entry) -> String {
        if entry.isGameFolder { return "gamecontroller.fill" }
        if entry.isFolder { return "folder.fill" }
        switch v3k_install_kind(entry.url.path) {
        case 1: return "cpu"
        case 2, 3: return "shippingbox.fill"
        case 5: return "key.fill"
        case 6: return "puzzlepiece.extension.fill"
        default: return "doc"
        }
    }

    private func detail(_ entry: Entry) -> String {
        if entry.isGameFolder { return "Game folder" }
        if entry.isFolder { return "Folder" }
        let size = ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        return entry.usable ? size : "\(size) · not something Hinoki installs"
    }

    private func open(_ url: URL) {
        directory = url
        selection.removeAll()
        load()
    }

    /// The emulator's own folders (the PS Vita drives, caches, logs) are hidden at the top level
    private static func isInternal(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.count <= 5, lower.last == "0", lower.dropLast().allSatisfy({ $0.isLetter }) { return true } // ux0, ur0, vs0...
        let hidden: Set<String> = ["cache", "shaders", "shaderlog", "textures", "texture", "patch", "lang", "data", "config.yml",
                                   "vita3k.log", "vita3k-previous.log", "save backups", "crash reports", "fonts", "music"]
        return hidden.contains(lower) || lower.hasSuffix(".log") || lower.hasSuffix(".yml")
    }

    private func load() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let atRoot = directory.standardizedFileURL == Self.root.standardizedFileURL
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var list: [Entry] = []
        for url in urls {
            if atRoot && Self.isInternal(url.lastPathComponent) { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory ?? false
            let isGame = isFolder && fm.fileExists(atPath: url.appendingPathComponent("sce_sys/param.sfo").path)
            let kind = isFolder ? 4 : Int(v3k_install_kind(url.path))
            let usable: Bool
            switch purpose {
            case .install: usable = kind != 0
            case .plugin: usable = kind == 6
            }
            list.append(Entry(url: url, isFolder: isFolder, isGameFolder: isGame, size: Int64(values?.fileSize ?? 0),
                              usable: purpose == .plugin ? usable : (usable || isFolder)))
        }
        // Import first, then folders, then files, each by name
        entries = list.sorted { a, b in
            let rank: (Entry) -> Int = { $0.name == "Import" ? 0 : ($0.isFolder ? 1 : 2) }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
