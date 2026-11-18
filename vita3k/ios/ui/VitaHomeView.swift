// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import AVFoundation
import CoreText
import SwiftUI
import UIKit

/// Assets of the installed PS Vita firmware (vs0 / pd0 partitions) and of installed themes (ux0/theme),
/// used to dress the home screen like the real thing.
enum VitaFirmware {
    private static var cache: [String: UIImage] = [:]

    static var root: String {
        guard let cPath = v3k_pref_path() else { return "" }
        defer { v3k_free_string(cPath) }
        return String(cString: cPath)
    }

    private static func full(_ relative: String) -> String {
        (root as NSString).appendingPathComponent(relative)
    }

    /// Image at a path below the Vita folder, nil when it doesn't exist
    static func image(atPath relative: String) -> UIImage? {
        if let cached = cache[relative] { return cached }
        guard let image = UIImage(contentsOfFile: full(relative)) else { return nil }
        cache[relative] = image
        return image
    }

    static func image(_ relativeToVs0: String) -> UIImage? { image(atPath: "vs0/" + relativeToVs0) }

    /// Wallpapers of the firmware's default theme
    static var defaultWallpapers: [String] {
        ["NPXS10002", "NPXS10006", "NPXS10013", "NPXS10018", "NPXS10098"]
            .map { "vs0/app/\($0)/sce_sys/pic0.png" }
            .filter { FileManager.default.fileExists(atPath: full($0)) }
    }

    /// The start (lock) screen picture
    static var lockScreen: UIImage? { image("data/internal/keylock/keylock.png") }

    static let defaultMusicPath = "pd0/data/systembgm/home.at9"

    static func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: full(relative)) }
    static func absolute(_ relative: String) -> String { full(relative) }
}

/// A theme for the home screen: the firmware's default one, or one installed in ux0/theme
struct VitaTheme: Identifiable, Hashable {
    let id: String
    let name: String
    /// Paths below the Vita folder, one per page (the last ones repeat)
    let wallpapers: [String]
    /// Home music below the Vita folder (.at9), nil when the theme has none
    let music: String?
    let fontColor: Color
    /// Start (lock) screen picture below the Vita folder; nil uses the firmware's keylock.png
    var startImage: String? = nil
    /// Colour of the start screen clock and date
    var dateColor: Color = .white
    /// Where the start screen clock sits: 0 bottom left (the Vita default), 1 top left, 2 bottom right
    var dateLayout: Int = 0
    /// Information bar colour, nil for the default translucent black
    var barColor: Color? = nil
    /// Name of a built-in animated background (see VitaBackgroundStyle); nil for themes that bring pictures
    var style: String? = nil

    static let defaultId = "default"

    static func color(hex: String?) -> Color? {
        guard var hex else { return nil }
        hex = hex.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: "#", with: "")
        guard let value = UInt32(hex, radix: 16) else { return nil }
        // theme.xml colours are RRGGBB or AABBGGRR-style 8 digits; use the low 24 bits as RGB like Vita3K
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    static var builtIn: VitaTheme {
        var theme = VitaTheme(id: defaultId, name: "Vita Blue", wallpapers: [],
                              music: VitaFirmware.exists(VitaFirmware.defaultMusicPath) ? VitaFirmware.defaultMusicPath : nil, fontColor: .white)
        theme.style = "vita"
        return theme
    }

    /// The built-in Frutiger Aero style backgrounds (drawn, so they work without the firmware) and, when the
    /// firmware is installed, its own wallpapers
    static var styled: [VitaTheme] {
        let music = VitaFirmware.exists(VitaFirmware.defaultMusicPath) ? VitaFirmware.defaultMusicPath : nil
        var list: [VitaTheme] = VitaBackgroundStyle.all.filter { $0.id != "vita" }.map { style in
            var theme = VitaTheme(id: "style." + style.id, name: style.name, wallpapers: [], music: music, fontColor: .white)
            theme.style = style.id
            return theme
        }
        if !VitaFirmware.defaultWallpapers.isEmpty {
            list.append(VitaTheme(id: "firmware", name: "Firmware wallpapers", wallpapers: VitaFirmware.defaultWallpapers, music: music, fontColor: .white))
        }
        return list
    }

    static func installed() -> [VitaTheme] {
        let folder = (VitaFirmware.root as NSString).appendingPathComponent("ux0/theme")
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
        return [builtIn] + styled + ids.compactMap { load(id: $0) }
    }

    private static var cache: [String: (theme: VitaTheme, time: Date)] = [:]

    /// The selected theme. Read again after a few seconds, so a theme installed meanwhile shows up, but not on
    /// every redraw (a theme.xml is parsed each time it is loaded)
    static func current() -> VitaTheme {
        let id = UserDefaults.standard.string(forKey: "v3k.vitaHome.theme") ?? defaultId
        if let cached = cache[id], Date().timeIntervalSince(cached.time) < 5 { return cached.theme }
        let theme = id == defaultId ? builtIn : (styled.first { $0.id == id } ?? load(id: id) ?? builtIn)
        cache[id] = (theme, Date())
        return theme
    }

    private static func load(id: String) -> VitaTheme? {
        let dir = "ux0/theme/" + id
        guard let data = FileManager.default.contents(atPath: VitaFirmware.absolute(dir + "/theme.xml")) else { return nil }
        let parser = ThemeXML()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { return nil }
        let wallpapers = parser.images.map { dir + "/" + $0 }.filter { VitaFirmware.exists($0) }
        guard !wallpapers.isEmpty else { return nil }
        var music: String?
        if let file = parser.music, VitaFirmware.exists(dir + "/" + file) { music = dir + "/" + file }
        var theme = VitaTheme(id: id, name: parser.title ?? id, wallpapers: wallpapers, music: music,
                              fontColor: color(hex: parser.fontColor) ?? .white)
        if let file = parser.startImage, VitaFirmware.exists(dir + "/" + file) { theme.startImage = dir + "/" + file }
        theme.dateColor = color(hex: parser.dateColor) ?? .white
        theme.dateLayout = Int(parser.dateLayout ?? "") ?? 0
        theme.barColor = color(hex: parser.barColor)
        return theme
    }
}

/// Reads the few things the home screen needs from a theme.xml (HomeProperty: m_bgParam images, m_bgmFilePath)
private final class ThemeXML: NSObject, XMLParserDelegate {
    var images: [String] = []
    var music: String?
    var fontColor: String?
    var title: String?
    var startImage: String?
    var dateColor: String?
    var dateLayout: String?
    var barColor: String?
    private var path: [String] = []
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        path.append(name)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            if name == "m_imageFilePath", path.contains("m_bgParam") {
                images.append(value)
            } else if name == "m_bgmFilePath", path.contains("HomeProperty") {
                music = value
            } else if name == "m_fontColor", path.contains("m_bgParam"), fontColor == nil {
                fontColor = value
            } else if name == "m_default", path.contains("m_title"), title == nil {
                title = value
            } else if path.contains("StartScreenProperty") {
                if name == "m_filePath" { startImage = value }
                if name == "m_dateColor" { dateColor = value }
                if name == "m_dateLayout" { dateLayout = value }
            } else if name == "m_barColor", path.contains("InfomationBarProperty") {
                barColor = value
            }
        }
        path.removeLast()
        text = ""
    }
}

/// The home music of the Vita (ATRAC9 file from the firmware or a theme), decoded to a WAV once and played in a loop.
/// MenuMusic uses it instead of the generated songs when Settings > Music asks for it.
@MainActor
final class VitaBGM {
    static let shared = VitaBGM()

    private var player: AVAudioPlayer?
    private var loadedSource = ""
    private var failedSource = ""
    private var loading = false
    private var wantsToPlay = false

    /// Where the music would come from, nil when the Vita music isn't used (setting off) or not available
    var source: String? {
        guard UserDefaults.standard.bool(forKey: "v3k.vitaMusic") else { return nil }
        guard let path = VitaTheme.current().music ?? (VitaFirmware.exists(VitaFirmware.defaultMusicPath) ? VitaFirmware.defaultMusicPath : nil) else { return nil }
        return path == failedSource ? nil : path
    }

    var isActive: Bool { source != nil }

    func play(volume: Double) {
        guard let source else { return }
        wantsToPlay = true
        if loadedSource == source, let player {
            player.volume = Float(volume)
            if !player.isPlaying { player.play() }
            return
        }
        guard !loading else { return }
        loading = true
        let input = VitaFirmware.absolute(source)
        DispatchQueue.global(qos: .utility).async {
            let output = Self.cachedWav(for: input)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishLoading(source: source, wav: output, volume: volume) }
            }
        }
    }

    func pause() {
        wantsToPlay = false
        player?.pause()
    }

    private func finishLoading(source: String, wav: String?, volume: Double) {
        loading = false
        guard let wav, let newPlayer = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: wav)) else {
            v3k_log_ui("Vita music: could not decode \(source)")
            failedSource = source
            MenuMusic.shared.settingsChanged() // back to the generated songs
            return
        }
        newPlayer.numberOfLoops = -1
        newPlayer.volume = Float(volume)
        player?.stop()
        player = newPlayer
        loadedSource = source
        v3k_log_ui("Vita music: playing \(source)")
        if wantsToPlay { newPlayer.play() }
    }

    /// nonisolated: runs on a background queue
    nonisolated private static func cachedWav(for input: String) -> String? {
        let ext = (input as NSString).pathExtension.lowercased()
        guard ext == "at9" else { return FileManager.default.fileExists(atPath: input) ? input : nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: input)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let folder = (NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory() as String) + "/VitaMusic"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // A stable hash (String.hashValue changes on every launch)
        var hash: UInt32 = 5381
        for byte in input.utf8 { hash = hash &* 33 &+ UInt32(byte) }
        let name = String(format: "%08x-%d.wav", hash, size)
        let output = folder + "/" + name
        if FileManager.default.fileExists(atPath: output) { return output }
        return v3k_decode_at9(input, output) ? output : nil
    }
}

/// The Vita's own typeface. The firmware's .pvf font files are OpenType fonts under another name
/// (sa0/data/font/pvf: ltn0 regular, ltn4 bold, jpn0 for Japanese), so iOS can register them directly.
/// Without the firmware (or if a file can't be read) the system font is used. Characters the Vita font
/// doesn't have (Japanese, Chinese, Korean) come from iOS's own fallback fonts.
enum VitaFont {
    private static var names: [String: String?] = [:]

    private static func register(_ file: String) -> String? {
        if let cached = names[file] { return cached }
        var result: String?
        let path = VitaFirmware.absolute("sa0/data/font/pvf/" + file)
        if let data = FileManager.default.contents(atPath: path),
           let provider = CGDataProvider(data: data as CFData),
           let cgFont = CGFont(provider),
           let name = cgFont.postScriptName as String? {
            var error: Unmanaged<CFError>?
            // Already registered (a second launch of the screen) also counts as available
            if CTFontManagerRegisterGraphicsFont(cgFont, &error) || UIFont(name: name, size: 12) != nil {
                result = name
            } else {
                v3k_log_ui("Vita font \(file): could not register (\(error?.takeRetainedValue().localizedDescription ?? "unknown"))")
            }
        } else if FileManager.default.fileExists(atPath: path) {
            v3k_log_ui("Vita font \(file): not a font iOS can read, using the system font")
        }
        names[file] = result
        return result
    }

    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        if let name = (bold ? register("ltn4.pvf") : nil) ?? register("ltn0.pvf") {
            return Font.custom(name, size: size)
        }
        return .system(size: size, weight: bold ? .semibold : .regular)
    }
}

/// The information screen of a game: what is known about it on this device
struct GameInfoView: View {
    let app: GameApp
    @Environment(\.dismiss) private var dismiss

    /// Pictures that ship with the game: LiveArea backgrounds and the start-up / pause pictures
    private var pictures: [UIImage] {
        let names = ["sce_sys/livearea/contents/bg0.png", "sce_sys/livearea/contents/bg.png", "sce_sys/livearea/contents/startup.png",
                     "sce_sys/pic0.png", "sce_sys/pic1.png"]
        var seen = Set<String>()
        return names.compactMap { name in
            let path = (app.folder as NSString).appendingPathComponent(name)
            guard seen.insert(path).inserted else { return nil }
            return UIImage(contentsOfFile: path)
        }
    }

    private var lastPlayedText: String {
        guard app.lastPlayed > 0 else { return "Never" }
        return Date(timeIntervalSince1970: TimeInterval(app.lastPlayed)).formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        if let icon = app.icon {
                            Image(uiImage: icon).resizable().scaledToFill().frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.title).font(.headline)
                            Text(app.titleId).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                if !pictures.isEmpty {
                    Section("Pictures") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Array(pictures.enumerated()), id: \.offset) { _, image in
                                    Image(uiImage: image).resizable().scaledToFit().frame(height: 120)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        }
                    }
                }
                if app.is3DS && app.version != "Homebrew" {
                    N3DSInfoSections(app: app)
                }
                Section("Details") {
                    if app.is3DS {
                        LabeledContent("System", value: app.version == "Homebrew" ? "Nintendo 3DS (homebrew)" : "Nintendo 3DS")
                    } else {
                        if !app.version.isEmpty { LabeledContent("Version", value: app.version) }
                        if !app.category.isEmpty { LabeledContent("Type", value: app.category) }
                    }
                    LabeledContent("Last played", value: lastPlayedText)
                    Text(app.playTimeText)
                }
                if let compatibility = app.compatibility {
                    Section("Compatibility in Vita3K") {
                        CompatibilityBadge(compatibility: compatibility)
                        Text(compatibility.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !app.is3DS {
                    Section {
                        Text("Descriptions, ratings and screenshots come from the PlayStation Store, which isn't available offline. The pictures above are the ones that came with the game.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

extension GameApp {
    /// The game's folder (ux0/app/<folder>): Vita3K lists apps by folder name, not by full path
    var folder: String {
        path.hasPrefix("/") ? path : VitaFirmware.absolute("ux0/app/" + path)
    }
}
