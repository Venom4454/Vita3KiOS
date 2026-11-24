// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

/// Trophies as the games earned them in Hinoki (Vita3K's trophy files, v3k_trophies_json)
struct TrophyCollection: Decodable, Identifiable {
    struct Trophy: Decodable, Identifiable {
        let id: Int
        let name: String
        let detail: String
        let grade: Int
        let hidden: Bool
        let earned: Bool
        let time: Double
        let icon: String
    }

    let id: String
    let title: String
    let titleId: String
    let icon: String
    let total: Int
    let unlocked: Int
    let platinum: Int
    let gold: Int
    let silver: Int
    let bronze: Int
    let trophies: [Trophy]

    var progress: Double { total > 0 ? Double(unlocked) / Double(total) : 0 }

    static func loadAll() -> [TrophyCollection] {
        guard let json = takeString(v3k_trophies_json()), let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([TrophyCollection].self, from: data) else { return [] }
        return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

/// Grade colours and names (SceNpTrophyGrade: 1 platinum, 2 gold, 3 silver, 4 bronze)
enum TrophyGrade {
    static func color(_ grade: Int) -> Color {
        switch grade {
        case 1: Color(red: 0.72, green: 0.78, blue: 0.88)
        case 2: Color(red: 0.95, green: 0.75, blue: 0.25)
        case 3: Color(red: 0.78, green: 0.80, blue: 0.83)
        default: Color(red: 0.80, green: 0.52, blue: 0.30)
        }
    }

    static func name(_ grade: Int) -> LocalizedStringKey {
        switch grade {
        case 1: "Platinum"
        case 2: "Gold"
        case 3: "Silver"
        default: "Bronze"
        }
    }
}

/// An icon file from the trophy folder, loaded once
private final class TrophyImageCache {
    static let shared = TrophyImageCache()
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200 // a long list's icons, not every icon ever looked at
        return cache
    }()

    func image(_ path: String) -> UIImage? {
        guard !path.isEmpty else { return nil }
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

private struct TrophyIcon: View {
    let path: String
    let size: CGFloat
    var dimmed = false
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "trophy.fill").font(.system(size: size * 0.45)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.secondary.opacity(0.15))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.5 : 1)
        .task(id: path) {
            let path = path
            image = await Task.detached(priority: .utility) { TrophyImageCache.shared.image(path) }.value
        }
    }
}

private struct GradeCounts: View {
    let collection: TrophyCollection

    var body: some View {
        HStack(spacing: 10) {
            ForEach([(1, collection.platinum), (2, collection.gold), (3, collection.silver), (4, collection.bronze)], id: \.0) { grade, count in
                HStack(spacing: 3) {
                    Image(systemName: "trophy.fill").foregroundStyle(TrophyGrade.color(grade))
                    Text("\(count)").monospacedDigit()
                }
            }
        }
        .font(.caption)
    }
}

/// Every game's trophies (library menu)
struct TrophiesView: View {
    @State private var collections: [TrophyCollection]?

    var body: some View {
        List {
            if let collections {
                if collections.isEmpty {
                    ContentUnavailableView("No trophies yet", systemImage: "trophy",
                                           description: Text("A game's trophies show up here once it has been started in Hinoki."))
                } else {
                    Section {
                        let earned = collections.reduce(0) { $0 + $1.unlocked }
                        let total = collections.reduce(0) { $0 + $1.total }
                        LabeledContent("Earned", value: "\(earned) / \(total)")
                        LabeledContent("Platinum", value: "\(collections.reduce(0) { $0 + $1.platinum })")
                    }
                    Section("Games") {
                        ForEach(collections) { collection in
                            NavigationLink {
                                TrophyListView(collection: collection)
                            } label: {
                                CollectionRow(collection: collection)
                            }
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Trophies")
        .task {
            collections = await Task.detached(priority: .userInitiated) { TrophyCollection.loadAll() }.value
        }
    }
}

private struct CollectionRow: View {
    let collection: TrophyCollection

    var body: some View {
        HStack(spacing: 12) {
            TrophyIcon(path: collection.icon, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(collection.title).font(.headline).lineLimit(2)
                ProgressView(value: collection.progress).tint(Theme.accent)
                HStack {
                    Text("\(Int((collection.progress * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    GradeCounts(collection: collection)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// One game's trophies
struct TrophyListView: View {
    let collection: TrophyCollection
    @State private var showHidden = false

    private var sorted: [TrophyCollection.Trophy] {
        // earned first (newest on top), then the rest in the game's order
        collection.trophies.sorted {
            if $0.earned != $1.earned { return $0.earned }
            if $0.earned { return $0.time > $1.time }
            return $0.id < $1.id
        }
    }

    var body: some View {
        List {
            Section {
                CollectionRow(collection: collection)
            }
            Section {
                ForEach(sorted) { trophy in
                    let secret = trophy.hidden && !trophy.earned && !showHidden
                    HStack(spacing: 12) {
                        TrophyIcon(path: secret ? "" : trophy.icon, size: 44, dimmed: !trophy.earned)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: "trophy.fill").font(.caption).foregroundStyle(TrophyGrade.color(trophy.grade))
                                if secret {
                                    Text("Hidden trophy").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                } else {
                                    Text(trophy.name).font(.subheadline.weight(.semibold))
                                }
                            }
                            if !secret {
                                Text(trophy.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            if trophy.earned, trophy.time > 0 {
                                Text(Date(timeIntervalSince1970: trophy.time), format: .dateTime.day().month().year().hour().minute())
                                    .font(.caption2).foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                if collection.trophies.contains(where: { $0.hidden && !$0.earned }) {
                    Toggle("Show hidden trophies", isOn: $showHidden).font(.footnote)
                }
            }
        }
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A game page's row: that game's trophies, when it has any
struct GameTrophiesRow: View {
    let titleId: String
    @State private var collection: TrophyCollection?

    var body: some View {
        Group {
            if let collection {
                NavigationLink {
                    TrophyListView(collection: collection)
                } label: {
                    HStack {
                        Label("Trophies", systemImage: "trophy.fill")
                        Spacer()
                        Text("\(collection.unlocked) / \(collection.total)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        .task {
            let titleId = titleId
            collection = await Task.detached(priority: .utility) {
                TrophyCollection.loadAll().first { $0.titleId == titleId }
            }.value
        }
    }
}
