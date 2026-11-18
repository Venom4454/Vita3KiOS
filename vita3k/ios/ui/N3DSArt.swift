// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

// Art for 3DS games (PS Vita games keep their own LiveAreas): found by itself, in this order,
//   1. GameTDB, by the product code inside the game (exact: done by the core, n3ds.cpp)
//   2. libretro's 3DS box art set (thumbnails.libretro.com), matched by name: always the 3DS version
//   3. SteamGridDB, when the player has added their (free) API key
// and a picker on the game's LiveArea to choose any of them instead.

import SwiftUI
import UIKit

struct N3DSArtCandidate: Identifiable, Hashable {
    let id: String // the full picture's URL
    let thumb: URL
    let full: URL
    let label: String
    let wide: Bool
}

enum N3DSArt {
    private static let libretroBase = "https://thumbnails.libretro.com/Nintendo%20-%20Nintendo%203DS/"

    static var steamGridKey: String {
        get { UserDefaults.standard.string(forKey: "n3ds.steamGridDBKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "n3ds.steamGridDBKey") }
    }

    // MARK: Names

    /// "New SUPER MARIO BROS. 2" and "New Super Mario Bros. 2 (USA)" both become "newsupermariobros2"
    static func normalized(_ text: String) -> String {
        var base = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        // no regions, revisions or languages: "(USA)", "[b]"
        base = base.replacingOccurrences(of: "\\([^)]*\\)|\\[[^\\]]*\\]", with: "", options: .regularExpression)
        base = base.replacingOccurrences(of: "&", with: "and")
        return base.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static func words(_ text: String) -> Set<String> {
        let base = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
            .replacingOccurrences(of: "\\([^)]*\\)|\\[[^\\]]*\\]", with: "", options: .regularExpression)
        return Set(base.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    /// The region libretro names carry for a product code's last letter (E USA, P Europe, J Japan…)
    private static func region(_ product: String) -> String? {
        switch product.last ?? " " {
        case "E": "USA"
        case "P", "D", "F", "S", "I": "Europe"
        case "J": "Japan"
        case "K": "Korea"
        default: nil
        }
    }

    /// Best matches first; a score of 100 is the same name
    static func rank(_ names: [String], for title: String, product: String) -> [(String, Int)] {
        let wanted = normalized(title)
        let wantedWords = words(title)
        let preferred = region(product)
        var scored: [(String, Int)] = []
        for name in names {
            let candidate = normalized(name)
            var score: Int
            if candidate == wanted {
                score = 100
            } else {
                let other = words(name)
                let shared = wantedWords.intersection(other).count
                let union = max(wantedWords.union(other).count, 1)
                score = shared * 80 / union
                if candidate.hasPrefix(wanted) || wanted.hasPrefix(candidate) { score += 10 }
            }
            if let preferred, name.contains("(\(preferred)") || name.contains(", \(preferred)") { score += 4 }
            if name.contains("(Demo)") || name.contains("(Beta)") || name.contains("Kiosk") { score -= 20 }
            if score >= 40 { scored.append((name, score)) }
        }
        return scored.sorted { $0.1 > $1.1 }
    }

    // MARK: libretro's 3DS box art

    /// The list of 3DS box art names (kept for a week)
    static func libretroNames(kind: String = "Named_Boxarts") async -> [String] {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("libretro-3ds-\(kind).txt")
        if let values = try? cache.resourceValues(forKeys: [.contentModificationDateKey]), let date = values.contentModificationDate,
           Date().timeIntervalSince(date) < 7 * 24 * 3600, let text = try? String(contentsOf: cache, encoding: .utf8), !text.isEmpty {
            return text.components(separatedBy: "\n").filter { !$0.isEmpty }
        }
        guard let url = URL(string: libretroBase + kind + "/"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, let html = String(data: data, encoding: .utf8) else { return [] }
        // the directory listing: href="New%20Super%20Mario%20Bros.%202%20%28USA%29.png"
        var names: [String] = []
        let pattern = try? NSRegularExpression(pattern: "href=\"([^\"/?]+)\\.png\"")
        let range = NSRange(html.startIndex..., in: html)
        pattern?.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, let found = Range(match.range(at: 1), in: html) else { return }
            if let name = String(html[found]).removingPercentEncoding { names.append(name) }
        }
        if !names.isEmpty { try? names.joined(separator: "\n").write(to: cache, atomically: true, encoding: .utf8) }
        return names
    }

    static func libretroURL(_ name: String, kind: String = "Named_Boxarts") -> URL? {
        guard let encoded = (name + ".png").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "&#?+"))) else { return nil }
        return URL(string: libretroBase + kind + "/" + encoded)
    }

    static func libretroCandidates(title: String, product: String, limit: Int = 8) async -> [N3DSArtCandidate] {
        var found: [N3DSArtCandidate] = []
        for (kind, label, wide) in [("Named_Boxarts", "Box art", false), ("Named_Titles", "Title screen", true), ("Named_Snaps", "Screenshot", true)] {
            let names = await libretroNames(kind: kind)
            for (name, _) in rank(names, for: title, product: product).prefix(kind == "Named_Boxarts" ? limit : 2) {
                if let url = libretroURL(name, kind: kind) {
                    found.append(N3DSArtCandidate(id: url.absoluteString, thumb: url, full: url, label: "\(label) · \(name)", wide: wide))
                }
            }
        }
        return found
    }

    // MARK: GameTDB (by product code)

    static func gameTDBCandidates(product: String) -> [N3DSArtCandidate] {
        guard product.count == 4 else { return [] }
        let regions: [String]
        switch product.last ?? " " {
        case "E": regions = ["US"]
        case "P": regions = ["EN", "FR", "DE"]
        case "J": regions = ["JA"]
        case "K": regions = ["KO"]
        default: regions = ["US", "EN", "JA"]
        }
        return regions.flatMap { region in
            ["coverHQ", "cover"].compactMap { kind -> N3DSArtCandidate? in
                guard let url = URL(string: "https://art.gametdb.com/3ds/\(kind)/\(region)/\(product).jpg") else { return nil }
                return N3DSArtCandidate(id: url.absoluteString, thumb: url, full: url, label: "GameTDB · \(region)", wide: false)
            }
        }
    }

    // MARK: SteamGridDB

    struct SGDBGame: Decodable, Identifiable, Hashable {
        let id: Int
        let name: String
    }

    private struct SGDBList<T: Decodable>: Decodable {
        let success: Bool
        let data: [T]?
    }

    private struct SGDBImage: Decodable {
        let id: Int
        let url: String
        let thumb: String
        let width: Int?
        let height: Int?
    }

    private static func sgdb<T: Decodable>(_ path: String, _ type: T.Type) async throws -> [T] {
        guard !steamGridKey.isEmpty, let url = URL(string: "https://www.steamgriddb.com/api/v2/" + path) else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(steamGridKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            throw NSError(domain: "SteamGridDB", code: 401, userInfo: [NSLocalizedDescriptionKey: "SteamGridDB refused the API key. Check it in Settings › Nintendo 3DS."])
        }
        return try JSONDecoder().decode(SGDBList<T>.self, from: data).data ?? []
    }

    static func steamGridGames(_ query: String) async throws -> [SGDBGame] {
        guard let term = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#&"))) else { return [] }
        let games = try await sgdb("search/autocomplete/\(term)", SGDBGame.self)
        // the exact name first (the 3DS game when the name is the 3DS title)
        let wanted = normalized(query)
        return games.sorted { (normalized($0.name) == wanted ? 0 : 1) < (normalized($1.name) == wanted ? 0 : 1) }
    }

    static func steamGridImages(game: Int) async throws -> [N3DSArtCandidate] {
        var found: [N3DSArtCandidate] = []
        for (path, label, wide) in [("grids/game/\(game)?dimensions=600x900,342x482,660x930,512x512,1024x1024", "Cover", false),
                                    ("heroes/game/\(game)", "Banner", true),
                                    ("grids/game/\(game)?dimensions=920x430,460x215", "Wide cover", true)] {
            let images = (try? await sgdb(path, SGDBImage.self)) ?? []
            for image in images.prefix(12) {
                guard let thumb = URL(string: image.thumb), let full = URL(string: image.url) else { continue }
                found.append(N3DSArtCandidate(id: image.url, thumb: thumb, full: full, label: label, wide: wide))
            }
        }
        return found
    }

    // MARK: Putting it in place

    static func apply(_ url: URL, to id: String) async -> Bool {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true, data.count > 512 else { return false }
        return data.withUnsafeBytes { buffer in v3k_n3ds_set_art(id, buffer.baseAddress, buffer.count) }
    }

    private struct MissingArt: Decodable {
        let id: String
        let title: String
        let product: String
    }

    /// Games GameTDB had nothing for: libretro's 3DS box art by name, then SteamGridDB (with a key).
    /// true when some art was added.
    static func fillMissing() async -> Bool {
        guard let json = takeString(v3k_n3ds_games_without_art_json()), let data = json.data(using: .utf8),
              let missing = try? JSONDecoder().decode([MissingArt].self, from: data), !missing.isEmpty else { return false }
        var added = false
        let names = await libretroNames()
        for game in missing {
            let tried = "n3ds.artTried.\(game.id)"
            if let last = UserDefaults.standard.object(forKey: tried) as? Date, Date().timeIntervalSince(last) < 6 * 3600 { continue }
            UserDefaults.standard.set(Date(), forKey: tried)
            if let best = rank(names, for: game.title, product: game.product).first, best.1 >= 90, let url = libretroURL(best.0),
               await apply(url, to: game.id) {
                v3k_log_ui("3DS art: \(game.title) from libretro (\(best.0))")
                added = true
                continue
            }
            if !steamGridKey.isEmpty, let match = try? await steamGridGames(game.title).first, normalized(match.name) == normalized(game.title),
               let cover = try? await steamGridImages(game: match.id).first(where: { !$0.wide }), await apply(cover.full, to: game.id) {
                v3k_log_ui("3DS art: \(game.title) from SteamGridDB (\(match.name))")
                added = true
                continue
            }
            v3k_log_ui("3DS art: nothing found for \(game.title) (\(game.product))")
        }
        return added
    }
}

// MARK: - The picker (a 3DS game's LiveArea › Artwork)

struct N3DSArtPicker: View {
    let app: GameApp
    var onChanged: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var product = ""
    @State private var boxArt: [N3DSArtCandidate] = []
    @State private var games: [N3DSArt.SGDBGame] = []
    @State private var selectedGame: Int?
    @State private var gridImages: [N3DSArtCandidate] = []
    @State private var loading = false
    @State private var applying: String?
    @State private var message: String?
    @State private var keyDraft = ""
    @State private var hasKey = !N3DSArt.steamGridKey.isEmpty

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Game name", text: $query)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await search() } }
                        if loading { ProgressView() }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.15)))

                    section("3DS box art", footnote: "GameTDB (by the game's product code) and libretro's 3DS set: always the 3DS version.", items: boxArt)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("SteamGridDB").font(.headline)
                        if hasKey {
                            if !games.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack {
                                        ForEach(games) { game in
                                            Button(game.name) { Task { await loadGrids(game.id) } }
                                                .buttonStyle(.bordered)
                                                .tint(game.id == selectedGame ? Theme.accent : .secondary)
                                        }
                                    }
                                }
                            }
                            grid(gridImages)
                            if gridImages.isEmpty && !loading {
                                Text(games.isEmpty ? "No SteamGridDB match for that name. Try a shorter name." : "No pictures for this one.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("SteamGridDB needs a free API key: sign in at steamgriddb.com, open Preferences › API, copy the key and paste it here.")
                                .font(.footnote).foregroundStyle(.secondary)
                            HStack {
                                SecureField("API key", text: $keyDraft)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                Button("Save") {
                                    N3DSArt.steamGridKey = keyDraft
                                    hasKey = !N3DSArt.steamGridKey.isEmpty
                                    Task { await search() }
                                }
                                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            Link("Get a key at steamgriddb.com", destination: URL(string: "https://www.steamgriddb.com/profile/preferences/api")!)
                                .font(.footnote)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Artwork")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .task {
                if let json = takeString(v3k_n3ds_info_json(app.titleId)), let data = json.data(using: .utf8),
                   let info = try? JSONDecoder().decode(N3DSGameInfo.self, from: data) {
                    product = info.product
                    query = info.title.isEmpty ? app.title : info.title
                } else {
                    query = app.title
                }
                await search()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func section(_ title: String, footnote: String, items: [N3DSArtCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(footnote).font(.caption).foregroundStyle(.secondary)
            grid(items)
            if items.isEmpty && !loading {
                Text("Nothing found under this name.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func grid(_ items: [N3DSArtCandidate]) -> some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(items) { item in
                Button {
                    Task { await choose(item) }
                } label: {
                    AsyncImage(url: item.thumb) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        case .failure: Color.clear
                        default: Color.secondary.opacity(0.15).overlay(ProgressView())
                        }
                    }
                    .frame(height: item.wide ? 70 : 140)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        if applying == item.id {
                            RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.5)).overlay(ProgressView())
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
            }
        }
    }

    private func search() async {
        loading = true
        defer { loading = false }
        var found = N3DSArt.gameTDBCandidates(product: product)
        found += await N3DSArt.libretroCandidates(title: query, product: product)
        boxArt = found
        guard hasKey else { return }
        do {
            games = Array(try await N3DSArt.steamGridGames(query).prefix(8))
            if let first = games.first { await loadGrids(first.id) } else { gridImages = [] }
        } catch {
            message = error.localizedDescription
        }
    }

    private func loadGrids(_ game: Int) async {
        selectedGame = game
        loading = true
        defer { loading = false }
        gridImages = (try? await N3DSArt.steamGridImages(game: game)) ?? []
    }

    private func choose(_ item: N3DSArtCandidate) async {
        applying = item.id
        let ok = await N3DSArt.apply(item.full, to: app.titleId)
        applying = nil
        if ok {
            VitaImageCache.forgetAll()
            onChanged()
            dismiss()
        } else {
            message = "That picture couldn't be downloaded. Try another one."
        }
    }
}

struct N3DSGameInfo: Decodable {
    var title = ""
    var customTitle = ""
    var publisher = ""
    var regions = ""
    var product = ""
    var titleId = ""
    var kind = ""
    var file = ""
    var bytes: Double = 0
    var art = ""
}

// MARK: - A 3DS game's details in its Information page: name editor, what it is, artwork

struct N3DSInfoSections: View {
    let app: GameApp
    @EnvironmentObject var model: LibraryModel
    @State private var info = N3DSGameInfo()
    @State private var name = ""
    @State private var picking = false

    var body: some View {
        Group {
            Section {
                HStack {
                    TextField("Name", text: $name)
                        .submitLabel(.done)
                        .onSubmit(saveName)
                    if name != (info.customTitle.isEmpty ? info.title : info.customTitle) {
                        Button("Save", action: saveName)
                    }
                }
                if !info.customTitle.isEmpty {
                    Button("Use the game's own name (\(info.title))") {
                        name = info.title
                        saveName()
                    }
                }
            } header: {
                Text("Name")
            } footer: {
                Text("Shown on the home screen and in the LiveArea.")
            }
            Section("About this game") {
                if !info.publisher.isEmpty { LabeledContent("Publisher", value: info.publisher) }
                if !info.regions.isEmpty { LabeledContent("Regions", value: info.regions.replacingOccurrences(of: ",", with: ", ")) }
                if !info.product.isEmpty { LabeledContent("Product code", value: info.product) }
                if !info.titleId.isEmpty { LabeledContent("Title ID", value: info.titleId).font(.callout.monospaced()) }
                LabeledContent("Format", value: formatText)
                if info.bytes > 0 { LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(info.bytes), countStyle: .file)) }
            }
            Section {
                Button {
                    picking = true
                } label: {
                    Label("Change artwork", systemImage: "photo.on.rectangle.angled")
                }
            } footer: {
                Text(info.art == "custom" ? "Artwork chosen by you." : info.art == "online" ? "Box art found automatically." : "No artwork yet: pick some, or Hinoki keeps looking.")
            }
        }
        .onAppear(perform: load)
        .sheet(isPresented: $picking) {
            N3DSArtPicker(app: app) {
                load()
                model.reload()
            }
        }
    }

    private var formatText: String {
        switch info.kind {
        case "installed": "Installed (CIA)"
        case "homebrew": "Homebrew"
        default: info.file.isEmpty ? "Cartridge dump" : "Cartridge dump (\((info.file as NSString).pathExtension.uppercased()))"
        }
    }

    private func load() {
        if let json = takeString(v3k_n3ds_info_json(app.titleId)), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(N3DSGameInfo.self, from: data) {
            info = decoded
            name = decoded.customTitle.isEmpty ? decoded.title : decoded.customTitle
        }
    }

    private func saveName() {
        _ = v3k_n3ds_rename(app.titleId, name.trimmingCharacters(in: .whitespaces))
        load()
        model.reload()
    }
}
