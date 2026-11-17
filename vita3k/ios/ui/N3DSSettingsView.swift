// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

// Settings › Nintendo 3DS: the 3DS core's own settings, the player's keys, and a 3DS game's page.

import SwiftUI
import UniformTypeIdentifiers

struct N3DSKeysInfo: Codable {
    var aesKeys = false
    var ncch = false
    var ticket = false
    var seeds = 0
    var summary = ""
}

struct N3DSSettingsView: View {
    @EnvironmentObject var model: LibraryModel
    @State private var keys = N3DSKeysInfo()
    @State private var status = ""
    @State private var available = false
    @State private var picking = false
    @State private var builtInPicker = false
    @State private var message: String?
    @State private var confirmRemoveKeys = false
    @State private var values: [String: String] = [:]
    @AppStorage("n3ds.controlsOpacity") private var opacity = 0.9
    @AppStorage("n3ds.controlsScale") private var controlsScale = 1.0
    @AppStorage("n3ds.touchReach") private var touchReach = "near"
    @AppStorage("n3ds.floatingStick") private var floatingStick = false
    @AppStorage("n3ds.coolDown") private var coolDown = true
    @AppStorage("n3ds.ffSpeed") private var fastForwardSpeed = "200"
    @State private var landscapeLayout = N3DSSettings.landscapeLayout
    @AppStorage("n3ds.hideWithController") private var hideWithController = true
    @AppStorage("n3ds.haptics") private var haptics = true
    @AppStorage("n3ds.motion") private var motion = true
    @AppStorage("v3k.builtInPicker") private var preferBuiltInPicker = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Core") {
                    Text(available ? status : "Not available")
                        .foregroundStyle(available ? Color.secondary : Color.orange)
                }
                if !available && !status.isEmpty {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("3DS games run on Azahar, built into Hinoki. Import .3ds, .cci, .cia (games, updates, DLC) or .3dsx homebrew with the + button, like PS Vita games. They show up on the home screen with their own icons.")
            }

            keysSection

            Section {
                Picker("Landscape layout", selection: Binding(get: { landscapeLayout }, set: {
                    landscapeLayout = $0
                    N3DSSettings.landscapeLayout = $0
                })) {
                    ForEach(N3DSSettings.landscapeLayouts.indices, id: \.self) { index in
                        Text(N3DSSettings.landscapeLayouts[index].1).tag(N3DSSettings.landscapeLayouts[index].0)
                    }
                }
                Picker("Portrait layout", selection: text("portrait_layout_option")) {
                    Text("Top screen full width").tag("0")
                    Text("Original size").tag("2")
                }
                Toggle("Swap screens", isOn: flag("swap_screen"))
                if landscapeLayout == "2" {
                    VStack(alignment: .leading) {
                        Text("Large screen size: \(String(format: "%.1f", Double(current("large_screen_proportion")) ?? 4))×")
                        Slider(value: number("large_screen_proportion"), in: 1...6, step: 0.5)
                    }
                }
            } header: {
                Text("Screens")
            } footer: {
                Text("Screens between the controls: the big screen sits between two columns of controls so nothing covers the game, with the other screen small beside them. Tap the small screen (or ⇅) to swap which one is big. On iPad both screens fit in the middle.")
            }

            Section {
                Picker("Internal resolution", selection: text("resolution_factor")) {
                    ForEach(1...5, id: \.self) { factor in
                        Text("\(factor)× (\(400 * factor)×\(240 * factor))").tag(String(factor))
                    }
                }
                Picker("Texture filter", selection: text("texture_filter")) {
                    Text("None").tag("0")
                    Text("Anime4K").tag("1")
                    Text("Bicubic").tag("2")
                    Text("ScaleForce").tag("3")
                    Text("xBRZ").tag("4")
                    Text("MMPX").tag("5")
                }
                Toggle("Smooth screen scaling", isOn: flag("filter_mode"))
                Toggle("Async shader compilation", isOn: flag("async_shader_compilation"))
                Toggle("Async presentation", isOn: flag("async_presentation"))
                Toggle("Keep compiled shaders", isOn: flag("use_disk_shader_cache"))
                Toggle("V-Sync", isOn: flag("use_vsync"))
                Toggle("Accurate shader multiplication", isOn: flag("shaders_accurate_mul"))
                Toggle("Custom textures", isOn: flag("custom_textures"))
                Button("Clear 3DS shader cache", role: .destructive) {
                    v3k_n3ds_clear_shader_cache()
                    message = "3DS shader cache cleared: games build their shaders again the next time."
                }
            } header: {
                Text("Graphics")
            } footer: {
                Text("2× looks sharp on a phone; higher costs battery and heat. Async shader compilation avoids stutter the first time effects appear; async presentation shows frames on their own thread (smoother on older devices). Custom textures load from Documents/3DS/azahar/load/textures/<title ID>.")
            }

            Section {
                HStack(spacing: 8) {
                    presetButton("Battery", "leaf.fill", resolution: "1")
                    presetButton("Balanced", "circle.lefthalf.filled", resolution: "2")
                    presetButton("Quality", "sparkles", resolution: "3")
                }
                .buttonStyle(.borderless)
                Toggle("Draw one eye only (no 3D)", isOn: flag("disable_right_eye_render"))
                Toggle("Cool down when hot", isOn: $coolDown)
                Picker("Fast forward speed", selection: $fastForwardSpeed) {
                    Text("150%").tag("150")
                    Text("200%").tag("200")
                    Text("300%").tag("300")
                    Text("As fast as possible").tag("0")
                }
            } header: {
                Text("Performance and battery")
            } footer: {
                Text("Battery: 1×, the coolest and longest-lasting. Balanced: 2×. Quality: 3× on newer phones. The phone has no 3D screen, so drawing one eye only is free speed. Cool down when hot drops to 1× while iOS reports the phone as hot, then goes back. Fast forward: the » button in game, or click the right stick on a controller.")
            }

            Section {
                Toggle("New 3DS", isOn: flag("is_new_3ds"))
                Picker("Region", selection: text("region_value")) {
                    Text("Automatic").tag("-1")
                    Text("Japan").tag("0")
                    Text("USA").tag("1")
                    Text("Europe").tag("2")
                    Text("Australia").tag("3")
                    Text("China").tag("4")
                    Text("Korea").tag("5")
                    Text("Taiwan").tag("6")
                }
                VStack(alignment: .leading) {
                    Text("CPU clock: \(current("cpu_clock_percentage"))%")
                    Slider(value: number("cpu_clock_percentage"), in: 25...200, step: 5)
                }
                Toggle("JIT (much faster)", isOn: flag("use_cpu_jit"))
            } header: {
                Text("System")
            } footer: {
                Text("New 3DS mode adds the C-stick and ZL/ZR and runs New 3DS-only games. A lower CPU clock can speed up heavy games (some run too fast or glitch); higher fixes slowdowns that the real 3DS also had.")
            }

            Section("Audio") {
                VStack(alignment: .leading) {
                    Text("Volume: \(Int((Double(current("volume")) ?? 1) * 100))%")
                    Slider(value: number("volume"), in: 0...1, step: 0.05)
                }
                Toggle("Stretch audio when slow", isOn: flag("enable_audio_stretching"))
            }

            Section {
                VStack(alignment: .leading) {
                    Text("Touch controls opacity: \(Int(opacity * 100))%")
                    Slider(value: $opacity, in: 0.3...1, step: 0.05)
                }
                VStack(alignment: .leading) {
                    Text("Touch controls size: \(Int(controlsScale * 100))%")
                    Slider(value: $controlsScale, in: 0.8...1.3, step: 0.05)
                }
                Picker("Button touch area", selection: $touchReach) {
                    Text("On the button").tag("exact")
                    Text("Near the button").tag("near")
                    Text("Generous").tag("generous")
                }
                Toggle("Floating Circle Pad", isOn: $floatingStick)
                Toggle("Hide touch controls with a controller", isOn: $hideWithController)
                Toggle("Vibrate on touch", isOn: $haptics)
                Toggle("Motion controls (gyroscope)", isOn: $motion)
            } header: {
                Text("Controls")
            } footer: {
                Text("Touch the bottom screen directly. Near the button: a tap just beside a button still presses it. Floating Circle Pad: it starts where your thumb lands near it. Controllers: A, B, X and Y by position, triggers are ZL/ZR, the right stick click is fast forward, the guide button opens the menu.")
            }
        }
        .navigationTitle("Nintendo 3DS")
        .onAppear(perform: reload)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importKeys(urls)
            case .failure: builtInPicker = true
            }
        }
        .sheet(isPresented: $builtInPicker) {
            HinokiFilePicker(purpose: .keys) { importKeys($0) }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        }
        .confirmationDialog("Remove your 3DS keys?", isPresented: $confirmRemoveKeys, titleVisibility: .visible) {
            Button("Remove keys", role: .destructive) {
                _ = v3k_n3ds_remove_keys()
                reload()
            }
        } message: {
            Text("Games already imported keep working. Encrypted games can't be imported until you add them again.")
        }
    }

    private var keysSection: some View {
        Section {
            LabeledContent("aes_keys.txt") {
                Label(keys.ncch ? "Added" : (keys.aesKeys ? "Incomplete" : "Not added"),
                      systemImage: keys.ncch ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(keys.ncch ? .green : .orange)
            }
            LabeledContent("seeddb.bin") {
                Text(keys.seeds > 0 ? "\(keys.seeds) seeds" : "Not added")
                    .foregroundStyle(keys.seeds > 0 ? Color.green : Color.secondary)
            }
            if !keys.summary.isEmpty {
                Text(keys.summary).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                if preferBuiltInPicker { builtInPicker = true } else { picking = true }
            } label: {
                Label("Add keys (aes_keys.txt, seeddb.bin)", systemImage: "key.fill")
            }
            Button {
                builtInPicker = true
            } label: {
                Label("Add from Hinoki's folder", systemImage: "folder")
            }
            if keys.aesKeys || keys.seeds > 0 {
                Button("Remove keys", role: .destructive) { confirmRemoveKeys = true }
            }
        } header: {
            Text("Keys")
        } footer: {
            Text("Only needed for encrypted games and CIAs (dumps you didn't decrypt). Dump the keys from your own 3DS with GodMode9 (Scripts › \"GM9Megascript\" › Dump options, or [0:]/gm9/support/aes_keys.txt), and seeddb.bin for newer games. Encrypted games are decrypted once, when you import them.")
        }
    }

    private func presetButton(_ title: String, _ symbol: String, resolution: String) -> some View {
        let active = current("resolution_factor") == resolution
        return Button {
            store("resolution_factor", resolution)
            store("async_shader_compilation", "1")
            store("async_presentation", "1")
            store("disable_right_eye_render", "1")
            coolDown = true
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(active ? Theme.accent.opacity(0.25) : Color.secondary.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? Theme.accent : Color.clear, lineWidth: 1.5))
        }
        .foregroundStyle(active ? Theme.accent : Color.primary)
    }

    private func current(_ key: String) -> String {
        values[key] ?? N3DSSettings.value(key)
    }

    private func store(_ key: String, _ value: String) {
        values[key] = value
        N3DSSettings.set(key, value)
    }

    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { current(key) == "1" }, set: { store(key, $0 ? "1" : "0") })
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { current(key) }, set: { store(key, $0) })
    }

    private func number(_ key: String) -> Binding<Double> {
        Binding(get: { Double(current(key)) ?? 0 }, set: { store(key, String(format: "%g", $0)) })
    }

    private func reload() {
        available = v3k_n3ds_available()
        status = takeString(v3k_n3ds_status()) ?? ""
        if let json = takeString(v3k_n3ds_keys_json()), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(N3DSKeysInfo.self, from: data) {
            keys = decoded
        }
    }

    private func importKeys(_ urls: [URL]) {
        var lines: [String] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            var text: UnsafeMutablePointer<CChar>?
            _ = v3k_n3ds_import_keys(url.path, &text)
            if accessing { url.stopAccessingSecurityScopedResource() }
            if let line = takeString(text), !line.isEmpty { lines.append(line) }
        }
        message = lines.isEmpty ? "No keys were found there." : lines.joined(separator: "\n")
        reload()
    }
}

/// A 3DS game's page (long-press or Information on the home screen)
struct N3DSGameDetailsView: View {
    let app: GameApp
    @EnvironmentObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        if let icon = app.icon {
                            Image(uiImage: icon)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.title).font(.headline)
                            Text(app.version == "Homebrew" ? "3DS homebrew" : "Nintendo 3DS · \(app.titleId)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(app.playTimeText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        dismiss()
                        model.launchRequested = app
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                }
                Section {
                    NavigationLink {
                        N3DSSettingsView()
                    } label: {
                        Label("3DS settings", systemImage: "gearshape")
                    }
                } footer: {
                    Text("Saves are kept by the 3DS core in Documents/3DS/azahar (Files app › Hinoki › 3DS).")
                }
                Section {
                    Button("Delete game", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Removes the game and its updates and DLC. Save data stays.")
                }
            }
            .navigationTitle("Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Delete \(app.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    _ = v3k_n3ds_remove(app.titleId)
                    model.reload()
                    dismiss()
                }
            }
        }
    }
}
