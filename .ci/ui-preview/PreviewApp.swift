// UI preview harness (CI only): shows the PS Vita home screen in fixed states with fake games, so
// changes to it can be looked at in the iOS simulator before they ship. Not part of the app.

import SwiftUI
import UIKit

@main
struct PreviewApp: App {
    @StateObject private var model = LibraryModel()
    private let scenario: String
    private let apps: [GameApp]

    init() {
        let args = ProcessInfo.processInfo.arguments
        scenario = args.firstIndex(of: "-scenario").map { args[$0 + 1] } ?? "home"
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "v3k.vitaHome")
        defaults.set(scenario == "lock", forKey: "v3k.vitaHome.lockScreen")
        defaults.set(scenario.hasPrefix("theme:") ? "style." + scenario.dropFirst(6) : "default", forKey: "v3k.vitaHome.theme")
        apps = PreviewApp.makeApps(count: scenario == "many" ? 23 : 8)
        // the simulator says a controller is connected: keep the touch controls on screen
        defaults.set(false, forKey: "n3ds.hideWithController")
        defaults.set(false, forKey: "v3k.touchHideWithController")
        if scenario.hasPrefix("n3ds") {
            N3DSGameViewController.layoutPreview = true
            defaults.set(true, forKey: "n3ds.layoutReset3")
            defaults.set(true, forKey: "n3ds.sbsMigrated")
            defaults.set("1", forKey: "n3ds.is_new_3ds")
            // "+classic" on the end: the classic control style (comfort otherwise)
            let parts = scenario.split(separator: "+")
            defaults.set(parts.count > 1 ? String(parts[1]) : "comfort", forKey: "n3ds.controlStyle")
            if scenario.hasPrefix("n3ds:") { defaults.set(String(parts[0].dropFirst(5)), forKey: "n3ds.screenLayout") }
        }
    }

    /// Upright scenarios turn the simulator's window to portrait (the rest stay landscape)
    private var portrait: Bool { scenario.hasPrefix("n3ds-portrait") || scenario.hasPrefix("setup") }

    var body: some Scene {
        WindowGroup {
            content
                .onAppear {
                    // after the 3DS screen's own request on appearing (any orientation), which would undo it
                    let mask: UIInterfaceOrientationMask = portrait ? .portrait : .landscapeRight
                    for delay in [0.0, 1.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
            if scenario.hasPrefix("n3ds") {
                // 3DS touch controls: "n3ds:<landscape layout>", "n3ds-portrait" (in a phone-sized frame)
                N3DSPreviewHost(app: apps[0], portrait: scenario.hasPrefix("n3ds-portrait"))
                    .ignoresSafeArea()
            } else if scenario.hasPrefix("setup") {
                // The first-run setup guide ("setup:<step>")
                SetupGuideView(startAt: Int(scenario.split(separator: ":").last ?? "") ?? 0).environmentObject(model)
            } else if scenario == "vitamenu" {
                // the quick menu HOME opens, over the Vita controls
                VitaPadPreview(openMenu: true).ignoresSafeArea()
            } else if scenario == "vitapad" {
                // PS Vita touch controls over a black game
                VitaPadPreview().ignoresSafeArea()
            } else if scenario == "brand" {
                // The in-app Hinoki mark and lockup (Settings › About)
                VStack(spacing: 40) {
                    HinokiMark().frame(width: 220, height: 220)
                    HinokiLockup(markSize: 64)
                    HStack(spacing: 24) {
                        HinokiMark().frame(width: 60, height: 60)
                        HinokiMark().frame(width: 40, height: 40)
                        HinokiMark().frame(width: 29, height: 29)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.96))
            } else {
            VitaHomeView(apps: apps, onLaunch: { _ in }, onDetails: { _ in }, onDelete: { _ in }, onDeleteSave: { _ in },
                         onImportFiles: {}, onImportFolder: {}, onEnterZrif: {}, preview: scenario)
                .environmentObject(model)
                .onAppear {
                    if scenario == "themechange" {
                        // The bug this guards against: changing the theme while the home screen is up
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            UserDefaults.standard.set("style.meadow", forKey: "v3k.vitaHome.theme")
                        }
                    }
                }
            }
    }

    static func makeApps(count: Int) -> [GameApp] {
        let names = ["Gravity Rush", "LittleBigPlanet PlayStation Vita", "Danganronpa Another Episode: Ultra Despair Girls",
                     "Danganronpa 2: Goodbye Despair", "Minecraft: PlayStation Vita Edition", "Netflix", "Stardew Valley",
                     "Persona 4 Golden", "Killzone Mercenary", "Uncharted: Golden Abyss", "Tearaway", "WipEout 2048"]
        let colors: [UIColor] = [.systemTeal, .systemPurple, .systemPink, .systemRed, .systemGreen, .systemOrange, .systemBlue, .systemYellow]
        let root = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/vita/ux0/app")
        return (0..<count).map { i in
            let id = String(format: "PCSA%05d", 100 + i)
            let folder = (root as NSString).appendingPathComponent(id)
            try? FileManager.default.createDirectory(atPath: folder + "/sce_sys", withIntermediateDirectories: true)
            let color = colors[i % colors.count]
            let icon = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { ctx in
                color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
                (id.suffix(3) as NSString).draw(at: CGPoint(x: 30, y: 44), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 34), .foregroundColor: UIColor.white])
            }
            let iconPath = folder + "/sce_sys/icon0.png"
            try? icon.pngData()?.write(to: URL(fileURLWithPath: iconPath))
            if i % 2 == 0 {
                let pic = UIGraphicsImageRenderer(size: CGSize(width: 960, height: 544)).image { ctx in
                    color.withAlphaComponent(0.8).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 960, height: 544))
                    UIColor.white.withAlphaComponent(0.3).setFill(); ctx.cgContext.fillEllipse(in: CGRect(x: 520, y: 80, width: 380, height: 380))
                }
                try? pic.pngData()?.write(to: URL(fileURLWithPath: folder + "/sce_sys/pic0.png"))
            }
            return GameApp(titleId: id, title: names[i % names.count], version: "01.00", category: "gd", iconPath: iconPath, path: id,
                           lastPlayed: Int64(Date().timeIntervalSince1970) - Int64(i * 3600), playTime: Int64(i * 2700), customConfig: false,
                           compat: i % 7, compatIssue: 0)
        }
    }
}

/// The 3DS game screen without a game: its controls laid out (portrait inside a phone-sized frame, the
/// harness only runs landscape)
struct N3DSPreviewHost: UIViewControllerRepresentable {
    let app: GameApp
    let portrait: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        // the window itself turns upright for the portrait scenario
        N3DSGameViewController(app: app, jit: true, onEnd: {})
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

struct VitaPadPreview: UIViewRepresentable {
    var openMenu = false

    /// Keeps the pad the size of the window as it turns to landscape
    final class Host: UIView {
        let pad = ControlsOverlayView(frame: .zero)
        var openMenu = false
        override func layoutSubviews() {
            super.layoutSubviews()
            if pad.superview == nil {
                addSubview(pad)
                if openMenu {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.pad.showMenu(fromController: false) }
                }
            }
            pad.frame = bounds
        }
    }

    func makeUIView(context: Context) -> UIView {
        let host = Host()
        host.openMenu = openMenu
        host.backgroundColor = .black
        return host
    }

    func updateUIView(_ view: UIView, context: Context) {}
}
