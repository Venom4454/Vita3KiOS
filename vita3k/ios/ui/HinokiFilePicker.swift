// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Hinoki's own file picker, for its folder in the Files app (On My iPhone › Hinoki, or the app's
/// folder in LiveContainer). The system picker doesn't open, or gives back files that can't be read,
/// for some apps signed with a developer certificate; this one reads the app's folder directly, so it
/// works however the app was signed. Files get there from the Files app, AirDrop (Save to Files) or a
/// computer (Finder / iTunes file sharing).
struct HinokiFilePicker: View {
    /// What the picked files are for: shapes the hint and which files are marked as usable
    /// (mod and save also take folders: tick one, or open it and tap "Use this folder")
    enum Purpose { case install, plugin, keys, mod, save, cheat, patch }

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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selection.isEmpty ? (purpose == .install ? "Install" : "Add") : "\(purpose == .install ? "Install" : "Add") (\(selection.count))") {
                        finish(Array(selection))
                    }
                    .disabled(selection.isEmpty)
                }
                if takesFolders && directory.standardizedFileURL != Self.root.standardizedFileURL {
                    // "the folder I'm in is the mod": the load folder, a title ID folder, a romfs' parent...
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            finish([directory])
                        } label: {
                            Label("Use this folder (\(directory.lastPathComponent))", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .refreshable { load() }
            .onAppear {
                _ = Self.importFolder
                load()
            }
        }
    }

    private var takesFolders: Bool { purpose == .mod || purpose == .save }

    private var title: String {
        switch purpose {
        case .plugin: return "Pick plugins"
        case .keys: return "Pick keys"
        case .mod: return "Pick a mod"
        case .save: return "Pick a save"
        case .cheat: return "Pick a cheat file"
        case .patch: return "Pick a patch file"
        case .install: return "Pick files"
        }
    }

    private func finish(_ picked: [URL]) {
        dismiss()
        // after the sheet is gone, so the install overlay and alerts can show
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onPick(picked) }
    }

    private var hint: String {
        switch purpose {
        case .mod:
            return "Put the mod in Hinoki's folder (Files app › On My iPhone › Hinoki, the Import folder is a good spot): a .zip, or its folder. Tick the folder, or open it and tap \"Use this folder\". The mod's own wrappers (load, mods, luma, titles, a title ID folder, rePatch) are fine: Hinoki finds the files inside. 3DS code patches (.ips, .bps) work too."
        case .save:
            return "Put the save (a .zip or its folder) in Hinoki's folder (Files app › On My iPhone › Hinoki › Import). Tick it, or open the folder and tap \"Use this folder\"."
        case .cheat:
            return "Put the cheat file (3DS: .txt in Azahar / Citra format; Vita: VitaCheat .psv) in Hinoki's folder (Files app › On My iPhone › Hinoki › Import), then pick it here."
        case .patch:
            return "Put the patch file (.txt, Vita3K patch format) in Hinoki's folder (Files app › On My iPhone › Hinoki › Import), then pick it here."
        case .install:
            return "Put games (.vpk, .zip, .pkg, 3DS .3ds/.cci/.cia/.3dsx), firmware (.PUP), licenses (work.bin, .rif, .zrif), plugins or game folders in Hinoki's folder (Files app › On My iPhone › Hinoki, the Import folder is a good spot), then pick them here. Tap a folder to open it; tick it to install everything in it."
        case .plugin:
            return "Put .suprx / .skprx plugins (and libshacccg.suprx for ports) in Hinoki's folder (Files app › On My iPhone › Hinoki › Import), then pick them here."
        case .keys:
            return "Put aes_keys.txt and seeddb.bin from your 3DS in Hinoki's folder (Files app › On My iPhone › Hinoki › Import), then pick them here."
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
        case 7: return "gamecontroller"
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
                                   "vita3k.log", "vita3k-previous.log", "save backups", "crash reports", "fonts", "music", "3ds"]
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
            case .keys:
                let name = url.lastPathComponent.lowercased()
                usable = name == "seeddb.bin" || name.hasSuffix(".txt")
            case .mod:
                let ext = url.pathExtension.lowercased()
                usable = isFolder || ext == "zip" || ext == "ips" || ext == "bps"
            case .save:
                usable = isFolder || url.pathExtension.lowercased() == "zip"
            case .cheat:
                let ext = url.pathExtension.lowercased()
                usable = !isFolder && (ext == "txt" || ext == "psv")
            case .patch:
                usable = !isFolder && url.pathExtension.lowercased() == "txt"
            }
            list.append(Entry(url: url, isFolder: isFolder, isGameFolder: isGame && purpose == .install, size: Int64(values?.fileSize ?? 0),
                              usable: purpose == .install ? (usable || isFolder) : usable))
        }
        // Import first, then folders, then files, each by name
        entries = list.sorted { a, b in
            let rank: (Entry) -> Int = { $0.name == "Import" ? 0 : ($0.isFolder ? 1 : 2) }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

// MARK: - Importing for a game's page

/// The system document picker, presented by UIKit itself over whatever is on screen (a sheet included).
/// Embedded in a SwiftUI sheet it could close itself right after opening, and SwiftUI's .fileImporter
/// opens only once per branch of views (a game's page has several imports).
final class SystemDocumentPicker: NSObject, UIDocumentPickerDelegate {
    private static var current: SystemDocumentPicker?
    private let onPick: ([URL]) -> Void

    private init(onPick: @escaping ([URL]) -> Void) {
        self.onPick = onPick
    }

    /// false when there is nothing to present it from
    @discardableResult
    static func present(types: [UTType], multiple: Bool, onPick: @escaping ([URL]) -> Void) -> Bool {
        guard let top = topViewController() else { return false }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = multiple
        let delegate = SystemDocumentPicker(onPick: onPick)
        picker.delegate = delegate
        current = delegate // the picker holds its delegate weakly
        top.present(picker, animated: true)
        return true
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Self.current = nil
        onPick(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Self.current = nil
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

/// Picks files (or folders) for one of a game's imports: the system picker, or Hinoki's own when that is
/// preferred (Settings, as the library does) or when the system picker hands back something unreadable
/// (some developer-certificate installs and LiveContainer).
private struct HinokiImporter: ViewModifier {
    @Binding var isPresented: Bool
    let types: [UTType]
    let multiple: Bool
    let purpose: HinokiFilePicker.Purpose
    let onPick: ([URL]) -> Void

    @AppStorage("v3k.builtInPicker") private var preferBuiltInPicker = false
    @State private var showingBuiltIn = false

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, requested in
                guard requested else { return }
                isPresented = false
                if preferBuiltInPicker || !SystemDocumentPicker.present(types: types, multiple: multiple, onPick: picked) {
                    showingBuiltIn = true
                }
            }
            .sheet(isPresented: $showingBuiltIn) {
                HinokiFilePicker(purpose: purpose, onPick: onPick)
            }
    }

    private func picked(_ urls: [URL]) {
        let readable = urls.filter(Self.readable)
        if urls.isEmpty || readable.count < urls.count {
            v3k_log_ui("Import: the system picker gave back \(urls.count) item(s), \(readable.count) readable; opening Hinoki's picker")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showingBuiltIn = true }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onPick(readable) }
    }

    private static func readable(_ url: URL) -> Bool {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return false }
        return isFolder.boolValue ? (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
                                  : FileManager.default.isReadableFile(atPath: url.path)
    }
}

extension View {
    /// One of a game's imports (see HinokiImporter)
    func hinokiImporter(isPresented: Binding<Bool>, types: [UTType], multiple: Bool = false,
                        purpose: HinokiFilePicker.Purpose, onPick: @escaping ([URL]) -> Void) -> some View {
        modifier(HinokiImporter(isPresented: isPresented, types: types, multiple: multiple, purpose: purpose, onPick: onPick))
    }
}
