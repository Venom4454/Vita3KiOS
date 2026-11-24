// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import AppIntents
import Foundation

/// Siri and Shortcuts: "Play <game> in Hinoki", and a Play a game action for automations (start a
/// game when a controller connects, from a Home Screen shortcut, ...). The games come from a small
/// list the library keeps up to date, so asking for them never needs the emulator started.
struct HinokiGame: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Game"
    static var defaultQuery = HinokiGameQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    private static let listKey = "v3k.intentGames"

    static func all() -> [HinokiGame] {
        guard let list = UserDefaults.standard.array(forKey: listKey) as? [[String]] else { return [] }
        return list.compactMap { $0.count == 2 ? HinokiGame(id: $0[0], title: $0[1]) : nil }
    }

    /// The library's games, kept for Siri and Shortcuts (only rewritten when they change)
    static func remember(_ apps: [GameApp]) {
        let list = apps.map { [$0.titleId, $0.title] }
        guard (UserDefaults.standard.array(forKey: listKey) as? [[String]]) != list else { return }
        UserDefaults.standard.set(list, forKey: listKey)
        HinokiShortcuts.updateAppShortcutParameters()
    }
}

struct HinokiGameQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [HinokiGame] {
        HinokiGame.all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [HinokiGame] {
        HinokiGame.all().filter { $0.title.localizedCaseInsensitiveContains(string) || $0.id.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [HinokiGame] { HinokiGame.all() }
}

struct PlayGameIntent: AppIntent {
    static var title: LocalizedStringResource = "Play a game"
    static var description = IntentDescription("Opens Hinoki and starts the game.")
    static var openAppWhenRun = true

    @Parameter(title: "Game")
    var game: HinokiGame

    @MainActor
    func perform() async throws -> some IntentResult {
        // the same way in as vita3k://launch/<ID>: from the library, once JIT is ready
        LibraryHost.requestLaunch(game.id)
        return .result()
    }
}

struct HinokiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayGameIntent(), phrases: ["Play \(\.$game) in \(.applicationName)", "Start \(\.$game) in \(.applicationName)"],
                    shortTitle: "Play a game", systemImageName: "gamecontroller.fill")
    }
}
