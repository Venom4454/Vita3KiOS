// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// taiHEN plugins (.suprx / .skprx), loaded at game start like on a hacked PS Vita: listed in
/// ux0:tai/config.txt under *KERNEL, *ALL (every game) or a game's title ID. Also the shader compiler
/// (libshacccg.suprx) that ports drawn with vitaGL need.
struct PluginsView: View {
    @EnvironmentObject var model: LibraryModel

    struct Plugin: Codable, Hashable, Identifiable {
        let path: String
        let file: String
        let section: String
        let exists: Bool
        let builtIn: Bool
        var hardwareOnly: Bool? = nil
        var id: String { section + "|" + path }
    }

    struct Info: Codable {
        let plugins: [Plugin]
        let shaderCompiler: Bool
    }

    @State private var info = Info(plugins: [], shaderCompiler: false)
    @State private var systemPicker = false
    @State private var builtInPicker = false
    @State private var message: String?
    @AppStorage("v3k.builtInPicker") private var preferBuiltInPicker = false

    private var sections: [String] {
        var seen: [String] = []
        for plugin in info.plugins where !seen.contains(plugin.section) { seen.append(plugin.section) }
        let order: (String) -> Int = { $0 == "KERNEL" ? 0 : ($0 == "ALL" ? 1 : 2) }
        return seen.sorted { order($0) != order($1) ? order($0) < order($1) : sectionTitle($0) < sectionTitle($1) }
    }

    var body: some View {
        Form {
            Section {
                Button {
                    if preferBuiltInPicker { builtInPicker = true } else { systemPicker = true }
                } label: {
                    Label("Add plugin (.suprx / .skprx)", systemImage: "plus.circle.fill")
                }
                Button {
                    builtInPicker = true
                } label: {
                    Label("Add from Hinoki's folder", systemImage: "folder")
                }
            } footer: {
                Text("A new plugin loads for every game (kernel plugins with the kernel). Tap a plugin to load it for one game only. Plugins start with the next game you open.")
            }

            if info.plugins.isEmpty {
                Section {
                    Text("No plugins yet.").foregroundStyle(.secondary)
                }
            }

            ForEach(sections, id: \.self) { section in
                Section(sectionTitle(section)) {
                    ForEach(info.plugins.filter { $0.section == section }) { plugin in
                        pluginRow(plugin)
                    }
                    .onDelete { offsets in
                        let list = info.plugins.filter { $0.section == section }
                        for index in offsets {
                            _ = v3k_remove_plugin(list[index].path, list[index].section, true)
                        }
                        reload()
                    }
                }
            }

            Section {
                LabeledContent {
                    Text(info.shaderCompiler ? "Installed" : "Not installed")
                        .foregroundStyle(info.shaderCompiler ? .green : .secondary)
                } label: {
                    Label("Shader compiler", systemImage: "cpu")
                }
                if info.shaderCompiler {
                    Button("Remove shader compiler", role: .destructive) {
                        _ = v3k_remove_shader_compiler()
                        reload()
                    }
                }
                LabeledContent {
                    Text("Built in").foregroundStyle(.green)
                } label: {
                    Label("kubridge", systemImage: "puzzlepiece.extension")
                }
            } header: {
                Text("For ports and homebrew")
            } footer: {
                Text("Ports of Android games (built with so_loader) need kubridge, which Hinoki has built in. Ports that draw with vitaGL also need the shader compiler, libshacccg.suprx, extracted from your own PS Vita's firmware (with ShaRKF00D): add it here like a plugin.")
            }
        }
        .navigationTitle("Plugins")
        .onAppear(perform: reload)
        .fileImporter(isPresented: $systemPicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                add(urls)
            case .failure:
                // some signing setups can't use the system picker: fall back to Hinoki's own
                builtInPicker = true
            }
        }
        .sheet(isPresented: $builtInPicker) {
            HinokiFilePicker(purpose: .plugin) { add($0) }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        }
    }

    @ViewBuilder
    private func pluginRow(_ plugin: Plugin) -> some View {
        Menu {
            Section("Load for") {
                if plugin.file.lowercased().hasSuffix(".skprx") {
                    target(plugin, "KERNEL")
                }
                target(plugin, "ALL")
                ForEach(model.apps) { app in
                    target(plugin, app.titleId)
                }
            }
            Button("Remove", role: .destructive) {
                _ = v3k_remove_plugin(plugin.path, plugin.section, true)
                reload()
            }
        } label: {
            HStack {
                Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.file).foregroundStyle(.primary)
                    if plugin.builtIn {
                        Text("Built into Hinoki: this file is not loaded").font(.caption).foregroundStyle(.secondary)
                    } else if plugin.hardwareOnly == true {
                        Text("Made for a real PS Vita: not loaded in Hinoki, which already does its job or can't use it").font(.caption).foregroundStyle(.secondary)
                    } else if !plugin.exists {
                        Text("File missing: add it again").font(.caption).foregroundStyle(.orange)
                    } else {
                        Text(plugin.path).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func target(_ plugin: Plugin, _ section: String) -> some View {
        Button {
            _ = v3k_move_plugin(plugin.path, plugin.section, section)
            reload()
        } label: {
            if plugin.section == section {
                Label(sectionTitle(section), systemImage: "checkmark")
            } else {
                Text(sectionTitle(section))
            }
        }
    }

    private func sectionTitle(_ section: String) -> String {
        switch section {
        case "KERNEL": return "Kernel (every game)"
        case "ALL": return "Every game"
        default:
            if let app = model.apps.first(where: { $0.titleId.uppercased() == section }) {
                return "\(app.title) (\(app.titleId))"
            }
            return section
        }
    }

    private func add(_ urls: [URL]) {
        var lines: [String] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            var text: UnsafeMutablePointer<CChar>?
            _ = v3k_add_plugin(url.path, nil, &text)
            if accessing { url.stopAccessingSecurityScopedResource() }
            lines.append(takeString(text) ?? "\(url.lastPathComponent): done")
        }
        message = lines.joined(separator: "\n")
        reload()
    }

    private func reload() {
        if let json = takeString(v3k_plugins_json()), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Info.self, from: data) {
            info = decoded
        }
    }
}
