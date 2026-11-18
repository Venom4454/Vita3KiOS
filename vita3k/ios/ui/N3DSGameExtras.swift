// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

// A 3DS game's updates and DLC, cheats and mods (its page in the library). Everything lands where
// Azahar looks for it: updates and DLC installed into the virtual SD card (from a .cia, like games),
// cheats in azahar/cheats/<title ID>.txt (Gateway format), mods in azahar/load/mods/<title ID>/
// (romfs/, exefs/, code.ips or code.bps: LayeredFS, read when the game starts).

import SwiftUI
import UniformTypeIdentifiers

private struct N3DSExtras: Decodable {
    var update = false
    var dlc = false
    var updateBytes: Double = 0
    var dlcBytes: Double = 0
}

private func bytesText(_ bytes: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

private var n3dsUserFolder: URL? {
    takeString(v3k_n3ds_user_folder()).map { URL(fileURLWithPath: $0, isDirectory: true) }
}

struct N3DSGameExtrasSections: View {
    let app: GameApp
    @EnvironmentObject var model: LibraryModel
    @State private var extras = N3DSExtras()
    /// One file picker for the page (several on one screen don't get along)
    private enum Picking: Identifiable {
        case update, mod, save
        var id: Int { hashValue }
    }
    @State private var picking: Picking?
    @State private var exported: URL?
    @State private var modSummary = ""
    @State private var cheatCount = 0
    @State private var message: String?
    @State private var confirmRemove: Bool? // true: DLC, false: update

    var body: some View {
        Group {
            Section {
                NavigationLink {
                    Form { N3DSInfoSections(app: app) }
                        .navigationTitle("Information & artwork")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Information, name & artwork", systemImage: "info.circle")
                }
            }

            Section {
                LabeledContent("Update", value: extras.update ? "Installed · \(bytesText(extras.updateBytes))" : "None")
                LabeledContent("DLC", value: extras.dlc ? "Installed · \(bytesText(extras.dlcBytes))" : "None")
                Button {
                    picking = .update
                } label: {
                    Label("Install update or DLC (.cia)", systemImage: "arrow.down.app")
                }
                if extras.update {
                    Button("Remove update", role: .destructive) { confirmRemove = false }
                }
                if extras.dlc {
                    Button("Remove DLC", role: .destructive) { confirmRemove = true }
                }
            } header: {
                Text("Updates & DLC")
            } footer: {
                Text("Pick the update or DLC as a .cia (or .zcia): encrypted ones work too once your keys are added. They apply to the game whether it is installed or a cartridge dump (.3ds, .cci).")
            }

            Section {
                Button {
                    picking = .save
                } label: {
                    Label("Import save (zip or folder)", systemImage: "square.and.arrow.down")
                }
                Button {
                    let (url, problem) = N3DSSaves.exportSave(app)
                    if let url { exported = url } else { message = problem }
                } label: {
                    Label("Export save", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("Save data")
            } footer: {
                Text("Import takes a save from Checkpoint, JKSM or another emulator: the folder with the save's files (or a zip of it). The current save is backed up to Files › Hinoki › Save Backups first. Close the game before importing.")
            }

            Section {
                NavigationLink {
                    N3DSCheatsView(app: app)
                } label: {
                    LabeledContent {
                        Text(cheatCount == 0 ? "None" : "\(cheatCount)")
                    } label: {
                        Label("Cheats", systemImage: "wand.and.stars")
                    }
                }
            } footer: {
                Text("Action Replay / Gateway codes. Turned-on cheats apply the next time the game starts.")
            }

            Section {
                LabeledContent("Installed", value: modSummary.isEmpty ? "None" : modSummary)
                Button {
                    picking = .mod
                } label: {
                    Label("Add a mod (zip or folder)", systemImage: "shippingbox")
                }
                if !modSummary.isEmpty {
                    Button("Remove mods", role: .destructive) {
                        if let folder = modFolder { try? FileManager.default.removeItem(at: folder) }
                        load()
                    }
                }
            } header: {
                Text("Mods")
            } footer: {
                Text("A mod's folder with romfs/ and/or exefs/ inside (or code.ips / code.bps), as Luma uses: luma/titles/\(app.titleId)/… works as is. Several mods are merged; files from the last one added win. They load the next time the game starts.")
            }
        }
        .onAppear(perform: load)
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: picking == .update ? [.item] : [.zip, .folder], allowsMultipleSelection: picking == .update) { result in
            let mode = picking
            picking = nil
            guard case let .success(urls) = result, let first = urls.first else { return }
            switch mode {
            case .update:
                model.enqueue(urls)
                // the queue installs in the background; look again in a moment
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { load() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { load() }
            case .mod:
                message = addMod(first)
                load()
            case .save:
                message = N3DSSaves.importSave(first, into: app)
            case nil:
                break
            }
        }
        .sheet(item: Binding(get: { exported.map(ShareItem.init) }, set: { if $0 == nil { exported = nil } })) { item in
            ShareSheet(items: [item.url])
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .confirmationDialog(confirmRemove == true ? "Remove the DLC?" : "Remove the update?",
                            isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let dlc = confirmRemove { _ = v3k_n3ds_remove_extra(app.titleId, dlc) }
                confirmRemove = nil
                load()
            }
        }
    }

    private var modFolder: URL? {
        n3dsUserFolder?.appendingPathComponent("load/mods/\(app.titleId.uppercased())", isDirectory: true)
    }

    private func load() {
        if let json = takeString(v3k_n3ds_extras_json(app.titleId)), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(N3DSExtras.self, from: data) {
            extras = decoded
        }
        cheatCount = N3DSCheatFile.load(app.titleId).count
        let fm = FileManager.default
        if let folder = modFolder, let entries = try? fm.contentsOfDirectory(atPath: folder.path), !entries.isEmpty {
            let parts = entries.filter { !$0.hasPrefix(".") }.sorted()
            modSummary = parts.joined(separator: ", ")
        } else {
            modSummary = ""
        }
    }

    /// Finds the mod's root (the folder holding romfs/, exefs/ or a code patch) and merges it in
    private func addMod(_ picked: URL) -> String {
        guard !v3k_n3ds_running() else { return "Close the game first, then add the mod." }
        guard let target = modFolder else { return "The 3DS core isn't available." }
        let fm = FileManager.default
        let access = picked.startAccessingSecurityScopedResource()
        defer { if access { picked.stopAccessingSecurityScopedResource() } }
        let work = fm.temporaryDirectory.appendingPathComponent("3ds-mod-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        var source = picked
        if picked.pathExtension.lowercased() == "zip" {
            var text: UnsafeMutablePointer<CChar>?
            let ok = v3k_unzip(picked.path, work.path, &text)
            let problem = takeString(text) ?? ""
            guard ok else { return problem.isEmpty ? "That zip couldn't be read." : problem }
            source = work
        }
        let markers: Set<String> = ["romfs", "exefs", "code.ips", "code.bps", "exheader.bin"]
        var root: URL?
        var queue: [(URL, Int)] = [(source, 0)]
        while !queue.isEmpty && root == nil {
            let (folder, depth) = queue.removeFirst()
            let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            if entries.contains(where: { markers.contains($0.lastPathComponent.lowercased()) }) {
                root = folder
                break
            }
            if depth < 6 {
                for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    queue.append((entry, depth + 1))
                }
            }
        }
        guard let root else {
            return "No mod found there: a 3DS mod has a romfs or exefs folder (or code.ips / code.bps)."
        }
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try merge(root, into: target)
        } catch {
            return "The mod couldn't be copied: \(error.localizedDescription)"
        }
        v3k_log_ui("3DS: added a mod to \(app.titleId) from \(picked.lastPathComponent)")
        return "Mod added. It loads the next time \(app.title) starts."
    }

    private func merge(_ source: URL, into target: URL) throws {
        let fm = FileManager.default
        for entry in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let name = entry.lastPathComponent
            if name == ".DS_Store" || name == "__MACOSX" { continue }
            // folder names as Azahar expects them (romfs, exefs in lower case)
            let lowered = ["romfs", "exefs"].contains(name.lowercased()) ? name.lowercased() : name
            let destination = target.appendingPathComponent(lowered)
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                try merge(entry, into: destination)
            } else {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: entry, to: destination)
            }
        }
    }
}

// MARK: - Cheats

struct N3DSCheat: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var enabled: Bool
    var notes: String
    var code: String
}

/// azahar/cheats/<title ID>.txt: "[Name]", "*citra_enabled", "*notes", then the code lines
enum N3DSCheatFile {
    static func url(_ titleId: String) -> URL? {
        n3dsUserFolder?.appendingPathComponent("cheats/\(titleId.uppercased()).txt")
    }

    static func load(_ titleId: String) -> [N3DSCheat] {
        guard let url = url(titleId), let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [N3DSCheat] {
        var cheats: [N3DSCheat] = []
        var current: N3DSCheat?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.count >= 2, line.hasPrefix("["), line.hasSuffix("]") {
                if let current, !current.code.isEmpty { cheats.append(current) }
                current = N3DSCheat(name: String(line.dropFirst().dropLast()), enabled: false, notes: "", code: "")
            } else if line.hasPrefix("*") {
                if line == "*citra_enabled" {
                    current?.enabled = true
                } else {
                    current?.notes += (current?.notes.isEmpty ?? true ? "" : "\n") + String(line.dropFirst())
                }
            } else if !line.isEmpty {
                current?.code += (current?.code.isEmpty ?? true ? "" : "\n") + line
            }
        }
        if let current, !current.code.isEmpty { cheats.append(current) }
        return cheats
    }

    static func text(_ cheats: [N3DSCheat]) -> String {
        cheats.map { cheat in
            var block = "[\(cheat.name.replacingOccurrences(of: "]", with: ")"))]\n"
            if cheat.enabled { block += "*citra_enabled\n" }
            for note in cheat.notes.components(separatedBy: .newlines) where !note.isEmpty { block += "*\(note)\n" }
            block += cheat.code.uppercased() + "\n"
            return block
        }.joined(separator: "\n")
    }

    static func save(_ cheats: [N3DSCheat], for titleId: String) {
        guard let url = url(titleId) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if cheats.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? text(cheats).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// A code line: two groups of 8 hex digits
    static func validCode(_ code: String) -> Bool {
        let lines = code.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { $0.range(of: "^[0-9A-Fa-f]{8} [0-9A-Fa-f]{8}$", options: .regularExpression) != nil }
    }
}

struct N3DSCheatsView: View {
    let app: GameApp
    @State private var cheats: [N3DSCheat] = []
    @State private var editing: N3DSCheat?
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        Form {
            if cheats.isEmpty {
                Section {
                    Text("No cheats yet. Add one with its code, or import a .txt cheat file (Azahar / Citra format).")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach($cheats) { $cheat in
                        Toggle(isOn: $cheat.enabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cheat.name)
                                if !cheat.notes.isEmpty { Text(cheat.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                        }
                        .contextMenu {
                            Button("Edit") { editing = cheat }
                            Button("Delete", role: .destructive) { cheats.removeAll { $0.id == cheat.id } }
                        }
                    }
                    .onDelete { cheats.remove(atOffsets: $0) }
                } footer: {
                    Text("Touch and hold a cheat to edit it. Changes apply the next time the game starts.")
                }
            }
            Section {
                Button {
                    editing = N3DSCheat(name: "", enabled: true, notes: "", code: "")
                } label: {
                    Label("Add a cheat", systemImage: "plus.circle.fill")
                }
                Button {
                    importing = true
                } label: {
                    Label("Import a cheat file (.txt)", systemImage: "doc.badge.plus")
                }
            }
        }
        .navigationTitle("Cheats")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { cheats = N3DSCheatFile.load(app.titleId) }
        .onChange(of: cheats) { _, updated in N3DSCheatFile.save(updated, for: app.titleId) }
        .sheet(item: $editing) { cheat in
            N3DSCheatEditor(cheat: cheat) { saved in
                if let index = cheats.firstIndex(where: { $0.id == saved.id }) {
                    cheats[index] = saved
                } else {
                    cheats.append(saved)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .item]) { result in
            guard case let .success(url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
                message = "That file couldn't be read."
                return
            }
            let found = N3DSCheatFile.parse(text)
            if found.isEmpty {
                message = "No cheats were found in it: each needs a [Name] line followed by its code."
            } else {
                let known = Set(cheats.map(\.name))
                cheats += found.filter { !known.contains($0.name) }
                message = "\(found.count) cheat\(found.count == 1 ? "" : "s") imported. Turn on the ones you want."
            }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}

private struct N3DSCheatEditor: View {
    @State var cheat: N3DSCheat
    let onSave: (N3DSCheat) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Infinite lives", text: $cheat.name)
                }
                Section {
                    TextEditor(text: $cheat.code)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .frame(minHeight: 160)
                } header: {
                    Text("Code")
                } footer: {
                    Text(cheat.code.isEmpty || N3DSCheatFile.validCode(cheat.code)
                         ? "One line per code: two groups of 8 hex digits, such as D3000000 00000000."
                         : "Each line must be two groups of 8 hex digits, such as D3000000 00000000.")
                        .foregroundStyle(cheat.code.isEmpty || N3DSCheatFile.validCode(cheat.code) ? Color.secondary : Color.orange)
                }
                Section("Notes") {
                    TextField("Optional", text: $cheat.notes, axis: .vertical)
                }
                Section {
                    Toggle("On", isOn: $cheat.enabled)
                }
            }
            .navigationTitle(cheat.name.isEmpty ? "New cheat" : cheat.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        cheat.code = cheat.code.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }.joined(separator: "\n")
                        onSave(cheat)
                        dismiss()
                    }
                    .disabled(cheat.name.trimmingCharacters(in: .whitespaces).isEmpty || !N3DSCheatFile.validCode(cheat.code))
                }
            }
        }
    }
}
