// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// First-run setup guide. New players go through it once; anyone who used Hinoki before this guide
/// existed never sees it. Its steps live here and change with the app: a new player always gets the
/// setup of the version they installed (each step checks the real state: JIT, firmware, games).
enum SetupGuide {
    private static let doneKey = "v3k.setupGuide.done"

    /// Whether to show it now. The first time it's asked, a player who ran Hinoki before (the previous
    /// session's log is there: it's kept from every run) or has games or firmware counts as done
    @MainActor
    static func shouldShow(model: LibraryModel) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: doneKey) { return false }
        let previousLog = URL(fileURLWithPath: String(cString: v3k_log_path())).deletingLastPathComponent()
            .appendingPathComponent("vita3k-previous.log").path
        let returning = FileManager.default.fileExists(atPath: previousLog) || !model.apps.isEmpty || model.hasFirmware
        if returning {
            defaults.set(true, forKey: doneKey)
            return false
        }
        return true
    }

    static func finish() {
        UserDefaults.standard.set(true, forKey: doneKey)
    }
}

struct SetupGuideView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var importer: ImportKind?
    @State private var showingBuiltInPicker = false
    @State private var keysMessage: String?

    /// One file importer for every kind: SwiftUI shows only the last of several on a view
    private enum ImportKind {
        case files, folder, keys
        var types: [UTType] { self == .folder ? [.folder] : [.item] }
    }

    private enum Step: Int, CaseIterable {
        case welcome, jit, firmware, games, controls, done
    }

    @State private var step: Step

    /// startAt: the UI preview harness only
    init(startAt: Int = 0) {
        _step = State(initialValue: Step(rawValue: startAt) ?? .welcome)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Theme.accent : Color.white.opacity(0.2))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                    if let progress = model.installProgress {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(format: NSLocalizedString("Installing %@", comment: ""), progress.name))
                                .font(.footnote.weight(.semibold)).lineLimit(1)
                            ProgressView(value: min(max(progress.percent, 0), 100), total: 100).tint(Theme.accent)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            HStack {
                if step != .welcome {
                    Button("Back") { withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .welcome } }
                } else {
                    Button("Skip") { close() }
                }
                Spacer()
                Button {
                    if step == .done { close() } else { withAnimation { step = Step(rawValue: step.rawValue + 1) ?? .done } }
                } label: {
                    Text(step == .done ? "Start playing" : "Next").fontWeight(.semibold).frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .fileImporter(isPresented: Binding(get: { importer != nil }, set: { if !$0 { importer = nil } }),
                      allowedContentTypes: importer?.types ?? [.item], allowsMultipleSelection: true) { result in
            let kind = importer
            switch result {
            case .success(let urls):
                if kind == .keys { importKeys(urls) } else { model.enqueue(urls) }
            case .failure:
                // The system picker fails for some developer-certificate signed installs: Hinoki's own instead
                if kind != .keys { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showingBuiltInPicker = true } }
            }
        }
        .sheet(isPresented: $showingBuiltInPicker) {
            HinokiFilePicker { model.enqueue($0) }
        }
        .onChange(of: model.packageNeedingLicense != nil) { _, needed in
            // A .pkg asking for its license: the library's prompt can't show over the guide
            if needed { close() }
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
        keysMessage = lines.isEmpty ? NSLocalizedString("No keys were found there.", comment: "") : lines.joined(separator: "\n")
    }

    private func close() {
        SetupGuide.finish()
        dismiss()
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            HinokiMark().frame(width: 84, height: 84)
            Text("Welcome to Hinoki").font(.largeTitle.weight(.bold))
            Text("Hinoki plays PS Vita and Nintendo 3DS games. This takes a minute: a few things need setting up once, then you're playing.")
                .foregroundStyle(.secondary)
            point("bolt.fill", "JIT", "makes games run at full speed")
            point("cpu", "PS Vita firmware", "the system files most Vita games need")
            point("square.stack.3d.down.forward", "Your games", "dumped from your own consoles")
        case .jit:
            title("bolt.fill", "Turn on JIT")
            Text("JIT lets Hinoki turn game code into iPhone code as it runs. Without it, Vita games won't start and 3DS games run very slowly. iOS doesn't allow it on its own: an app like StikDebug or LiveContainer turns it on for Hinoki.")
                .foregroundStyle(.secondary)
            status(model.jitEnabled, done: "JIT is on", todo: "JIT is off")
            if !model.jitEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    EnableJITButtons()
                }
                .buttonStyle(.bordered)
                Text("You can do this later too: the JIT pill at the top of the library does the same. JIT has to be turned on again each time Hinoki is opened.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .firmware:
            title("cpu", "PS Vita firmware")
            Text("Most Vita games need the PS Vita firmware (PSVUPDAT.PUP) and the font package (PSP2UPDAT.PUP). Download both from PlayStation's PS Vita system software page, then import them. 3DS games don't need this.")
                .foregroundStyle(.secondary)
            status(model.hasFirmware, done: "Firmware installed", todo: "No firmware yet")
            status(model.hasFonts, done: "Fonts installed", todo: "No fonts yet")
            if !model.hasFirmware || !model.hasFonts {
                Button { importer = .files } label: { Label("Import PUP files", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.bordered)
            }
        case .games:
            title("square.stack.3d.down.forward", "Add your games")
            Text("Import games you dumped from your own consoles. Hinoki installs them, so the original file can be deleted afterwards.")
                .foregroundStyle(.secondary)
            point("rectangle.portrait", "PS Vita", ".vpk, .zip or a game folder; .pkg with its zRIF key or license file")
            point("rectangle.split.1x2", "Nintendo 3DS", ".3ds, .cci, .cia or .3dsx. Encrypted ones need your 3DS's aes_keys.txt (and seeddb.bin for newer games)")
            HStack {
                Button { importer = .files } label: { Label("Import files", systemImage: "doc.badge.plus") }
                Button { importer = .folder } label: { Label("Game folder", systemImage: "folder.badge.plus") }
            }
            .buttonStyle(.bordered)
            Button { importer = .keys } label: { Label("Add 3DS keys (aes_keys.txt, seeddb.bin)", systemImage: "key.fill") }
                .buttonStyle(.bordered)
            if let keysMessage {
                Text(keysMessage).font(.footnote).foregroundStyle(.secondary)
            }
            if !model.apps.isEmpty {
                status(true, done: String(format: NSLocalizedString("%lld games in your library", comment: ""), model.apps.count), todo: "")
            }
        case .controls:
            title("gamecontroller.fill", "Controls")
            Text("Touch controls appear over the game. Any MFi, Xbox, PlayStation or Switch controller works too and hides them.")
                .foregroundStyle(.secondary)
            point("hand.draw", "Make them yours", "In a game, HOME (bottom left) opens the quick menu › Edit layout: drag and pinch any control")
            point("slider.horizontal.3", "More in Settings", "Sizes, floating sticks, macro buttons, haptics and Advanced touch (mouse-style camera)")
            point("iphone.landscape", "Landscape or upright", "Both work; each keeps its own layout")
        case .done:
            title("checkmark.seal.fill", "You're set")
            Text("A few things worth knowing:").foregroundStyle(.secondary)
            point("hand.tap", "Long-press a game", "Settings for that game, patches, saves, favorites")
            point("trophy.fill", "Trophies", "Every game's trophies: a bubble on the Vita home screen, or the library's menu")
            point("arrow.down.right.and.arrow.up.left", "Running out of space?", "A game's page can compress it; it keeps playing")
            point("ladybug.fill", "Something broke?", "Settings › About › Report a problem gathers the logs that show what happened")
        }
    }

    private func title(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title).foregroundStyle(Theme.accent)
            Text(text).font(.title.weight(.bold))
        }
    }

    private func point(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Theme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func status(_ ok: Bool, done: String, todo: String) -> some View {
        Label(LocalizedStringKey(ok ? done : todo), systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(ok ? .green : .orange)
            .font(.subheadline.weight(.semibold))
    }
}
