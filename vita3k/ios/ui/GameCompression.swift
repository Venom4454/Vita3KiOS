// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

/// Compressing a game to save space, for both systems: Vita games file by file (v3k_compress_game),
/// 3DS dumps into Azahar's compressed format (v3k_n3ds_convert). Games play from the compressed files.
final class GameCompressionModel: ObservableObject {
    enum System { case vita, n3ds }

    let system: System
    let id: String
    @Published var supported = true
    @Published var unsupportedReason = ""
    @Published var compressed = false
    @Published var sizeText = ""
    @Published var running = false
    @Published var compressing = true
    @Published var progress: Double = 0
    @Published var message: String?
    @Published var confirming = false
    @Published var canCompressMore = true

    init(system: System, id: String) {
        self.system = system
        self.id = id
    }

    private static let compressedExtensions = ["zcci", "zcxi", "zcia", "z3dsx"]

    func refresh() {
        guard !running else { return }
        let id = id
        let system = system
        DispatchQueue.global(qos: .userInitiated).async {
            var supported = true
            var reason = ""
            var compressed = false
            var more = true // something left to compress
            var size = ""
            switch system {
            case .vita:
                struct State: Decodable {
                    var supported: Bool?
                    var compressedFiles: UInt64?
                    var storedBytes: UInt64?
                    var originalBytes: UInt64?
                }
                if let json = takeString(v3k_compress_state_json(id)), let data = json.data(using: .utf8),
                   let state = try? JSONDecoder().decode(State.self, from: data) {
                    supported = state.supported ?? false
                    compressed = (state.compressedFiles ?? 0) > 0
                    let stored = state.storedBytes ?? 0
                    let original = state.originalBytes ?? 0
                    size = Self.bytes(stored)
                    if compressed && original > stored {
                        size += " · " + String(format: NSLocalizedString("%@ saved", comment: ""), Self.bytes(original - stored))
                    }
                }
            case .n3ds:
                struct Info: Decodable {
                    var kind: String?
                    var file: String?
                    var bytes: UInt64?
                    var packedContents: Int?
                    var contents: Int?
                }
                if let json = takeString(v3k_n3ds_info_json(id)), let data = json.data(using: .utf8),
                   let info = try? JSONDecoder().decode(Info.self, from: data) {
                    if info.kind == "installed" {
                        // installed from a .cia: its content files are packed in place
                        let packed = info.packedContents ?? 0
                        compressed = packed > 0
                        more = packed < (info.contents ?? 0)
                    } else {
                        let ext = ((info.file ?? "") as NSString).pathExtension.lowercased()
                        compressed = Self.compressedExtensions.contains(ext)
                        more = !compressed
                    }
                    if let bytes = info.bytes, bytes > 0 { size = Self.bytes(bytes) }
                }
            }
            DispatchQueue.main.async {
                self.supported = supported
                self.unsupportedReason = reason
                self.compressed = compressed
                self.canCompressMore = more
                self.sizeText = size
            }
        }
    }

    /// Runs off the main thread; done is called on the main thread once the files changed
    func start(compress: Bool, done: @escaping () -> Void) {
        guard !running else { return }
        running = true
        compressing = compress
        progress = 0
        // Long work: keep the screen on, and ask iOS for time if the player switches apps meanwhile
        UIApplication.shared.isIdleTimerDisabled = true
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "Compress game") {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }

        let box = ProgressBox { [weak self] fraction in
            DispatchQueue.main.async { self?.progress = fraction }
        }
        let context = Unmanaged.passRetained(box).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64) -> Void = { context, done, total in
            guard let context, total > 0 else { return }
            Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue().report(Double(done) / Double(total))
        }
        let id = id
        let system = system
        DispatchQueue.global(qos: .userInitiated).async {
            var text: UnsafeMutablePointer<CChar>?
            switch system {
            case .vita:
                _ = v3k_compress_game(id, compress, callback, context, &text)
            case .n3ds:
                _ = v3k_n3ds_convert(id, compress, callback, context, &text)
            }
            Unmanaged<ProgressBox>.fromOpaque(context).release()
            let result = takeString(text)
            DispatchQueue.main.async {
                self.running = false
                self.message = result
                UIApplication.shared.isIdleTimerDisabled = false
                if task != .invalid {
                    UIApplication.shared.endBackgroundTask(task)
                    task = .invalid
                }
                self.refresh()
                done()
            }
        }
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}

/// Progress from the worker thread, sent on only when it moved by a whole percent
private final class ProgressBox {
    private let send: (Double) -> Void
    private var lastPercent = -1
    private let lock = NSLock()

    init(_ send: @escaping (Double) -> Void) {
        self.send = send
    }

    func report(_ fraction: Double) {
        let percent = Int(fraction * 100)
        lock.lock()
        let changed = percent != lastPercent
        if changed { lastPercent = percent }
        lock.unlock()
        if changed { send(min(max(fraction, 0), 1)) }
    }
}

/// The "Compression" section of a game's page. Its dialogs are attached once for the whole page
/// (GameCompressionPresenters): modifiers on rows inside a Form get copied onto every row
struct GameCompressionSection: View {
    @ObservedObject var model: GameCompressionModel
    let changed: () -> Void

    var body: some View {
        Section {
            if !model.sizeText.isEmpty {
                LabeledContent("Size", value: model.sizeText)
            }
            if model.running {
                VStack(alignment: .leading, spacing: 6) {
                    if model.compressing {
                        Text("Compressing…")
                    } else {
                        Text("Decompressing…")
                    }
                    ProgressView(value: model.progress)
                    Text("\(Int(model.progress * 100))%").font(.caption).foregroundStyle(.secondary)
                }
            } else if model.supported {
                if model.compressed {
                    Button {
                        model.start(compress: false, done: changed)
                    } label: {
                        Label("Decompress", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
                // a Vita game can be partly compressed (new files from an update): compressing again packs those
                if !model.compressed || model.system == .vita || model.canCompressMore {
                    Button {
                        model.confirming = true
                    } label: {
                        if model.compressed {
                            Label("Compress new files", systemImage: "arrow.down.right.and.arrow.up.left")
                        } else {
                            Label("Compress game", systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                    }
                }
            }
        } header: {
            Text("Compression")
        } footer: {
            if !model.supported && !model.unsupportedReason.isEmpty {
                Text(model.unsupportedReason)
            } else if model.system == .vita {
                Text("Packs the game's files to save space; it plays from them. Loading can take a little longer. Takes a few minutes for a big game, and Decompress brings the files back as they were.")
            } else {
                Text("Converts the game to the 3DS core's compressed format; it plays as before. Installed games (.cia) are packed with their update and DLC. Decompress brings back plain files.")
            }
        }
    }
}

struct GameCompressionPresenters: ViewModifier {
    @ObservedObject var model: GameCompressionModel
    let changed: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Compress this game?", isPresented: $model.confirming, titleVisibility: .visible) {
                Button("Compress") { model.start(compress: true, done: changed) }
            } message: {
                Text("Keep Hinoki open until it's done. Each file is checked before it replaces the original, so stopping halfway leaves the game playable.")
            }
            .alert(model.message ?? "", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK", role: .cancel) { model.message = nil }
            }
    }
}
