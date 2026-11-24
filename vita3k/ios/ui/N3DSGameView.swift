// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

// Playing a 3DS game: a full-screen view the Azahar core draws into (CAMetalLayer through MoltenVK),
// with on-screen controls laid out like a 3DS, the touch screen under your finger, controllers and
// the phone's motion sensors. In landscape the screens sit between two columns of controls (Hinoki's
// own layout), so the controls never cover the game; the other layouts are Azahar's.

import CoreMotion
import GameController
import Metal
import QuartzCore
import SwiftUI
import UIKit

extension GameApp {
    var is3DS: Bool { category == "3ds" }
}

/// Button bits (hinoki_azahar.h)
enum N3DSKey: UInt32 {
    case a = 0x1, b = 0x2, x = 0x4, y = 0x8, up = 0x10, down = 0x20, left = 0x40, right = 0x80
    case l = 0x100, r = 0x200, start = 0x400, select = 0x800, zl = 0x1000, zr = 0x2000, home = 0x4000
}

/// 3DS settings with their defaults (the core's names)
enum N3DSSettings {
    static let defaults: [String: String] = [
        "resolution_factor": "2", "layout_option": "6", "portrait_layout_option": "0", "swap_screen": "0",
        "large_screen_proportion": "4", "async_shader_compilation": "1", "use_disk_shader_cache": "1",
        "use_vsync": "1", "is_new_3ds": "1", "region_value": "-1", "cpu_clock_percentage": "100",
        "use_cpu_jit": "1", "volume": "1", "filter_mode": "1", "texture_filter": "0",
        "enable_audio_stretching": "1", "shaders_accurate_mul": "0", "custom_textures": "0",
        "async_presentation": "1", "disable_right_eye_render": "1", "match_display": "1", "use_shader_jit": "1",
        // 30 FPS games present every frame twice otherwise (Azahar on Android has it on by default)
        "use_skip_duplicate_frames": "1",
    ]

    static func value(_ key: String) -> String {
        UserDefaults.standard.string(forKey: "n3ds." + key) ?? defaults[key] ?? "0"
    }

    static func set(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: "n3ds." + key)
        v3k_n3ds_set_setting(key, value)
    }

    /// Every setting sent to the core (before a boot)
    static func sendAll() {
        for key in defaults.keys where key != "layout_option" { v3k_n3ds_set_setting(key, value(key)) }
        v3k_n3ds_set_setting("layout_option", coreLayout(landscapeLayout))
    }

    /// Hinoki's own landscape layouts (Azahar's custom layout, worked out with the controls)
    static let hinokiLayouts: Set<String> = ["hinoki", "sbs", "sbs-top"]

    /// The core's layout_option for a landscape layout
    static func coreLayout(_ layout: String) -> String { hinokiLayouts.contains(layout) ? "6" : layout }

    /// Landscape screen layout: Hinoki's ("hinoki" big screen with the other small beside the controls,
    /// "sbs" side by side with the controls below, "sbs-top" side by side as large as possible at the top),
    /// or one of Azahar's: "0" stacked, "1" one screen, "2" large top screen, "3" side by side, "5" hybrid
    static var landscapeLayout: String {
        get {
            let defaults = UserDefaults.standard
            // The controls were redone around the thumbs: everyone starts once from the layout made for
            // them (the overlay layouts cover the game; any layout can be picked again in game)
            if !defaults.bool(forKey: "n3ds.layoutReset3") {
                defaults.set(true, forKey: "n3ds.layoutReset3")
                if let chosen = defaults.string(forKey: "n3ds.screenLayout"), !hinokiLayouts.contains(chosen) {
                    defaults.set("hinoki", forKey: "n3ds.screenLayout")
                    defaults.set("6", forKey: "n3ds.layout_option")
                }
            }
            if var chosen = defaults.string(forKey: "n3ds.screenLayout") {
                // Azahar's side by side covered the screens with the controls: Hinoki's replaces it once
                if chosen == "3" && !defaults.bool(forKey: "n3ds.sbsMigrated") {
                    defaults.set(true, forKey: "n3ds.sbsMigrated")
                    chosen = "sbs"
                    defaults.set(chosen, forKey: "n3ds.screenLayout")
                }
                return chosen
            }
            // Before Hinoki's layouts: the Azahar layout picked in Settings (4 was a wrong value for hybrid)
            if let old = defaults.string(forKey: "n3ds.layout_option") {
                if old == "3" { return "sbs" }
                return old == "4" ? "5" : old
            }
            return "hinoki"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "n3ds.screenLayout")
            UserDefaults.standard.set(true, forKey: "n3ds.sbsMigrated")
            UserDefaults.standard.set(coreLayout(newValue), forKey: "n3ds.layout_option")
            v3k_n3ds_set_setting("layout_option", coreLayout(newValue))
        }
    }

    static let landscapeLayouts: [(String, String)] = [
        ("hinoki", "Big screen + small screen"), ("sbs", "Side by side, controls below"),
        ("sbs-top", "Side by side at the top (largest)"), ("2", "Large top screen (overlay)"),
        ("3", "Side by side (overlay)"), ("0", "Stacked (overlay)"), ("5", "Hybrid (overlay)"), ("1", "One screen (overlay)"),
    ]

    private static func double(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    static var controlsOpacity: Double { double("n3ds.controlsOpacity", 0.9) }

    /// "comfort" (the controls placed along the thumbs' reach, off the edges) or "classic" (the layout
    /// before it). Anyone who had already moved controls keeps classic, so nothing of theirs shifts;
    /// everyone else starts on comfort. Each style keeps its own moves.
    static var controlStyle: String {
        get {
            let defaults = UserDefaults.standard
            if let chosen = defaults.string(forKey: "n3ds.controlStyle") { return chosen }
            let customized = defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("n3ds.controls.") }
            let style = customized ? "classic" : "comfort"
            defaults.set(style, forKey: "n3ds.controlStyle")
            return style
        }
        set { UserDefaults.standard.set(newValue, forKey: "n3ds.controlStyle") }
    }
    static var controlsScale: Double { double("n3ds.controlsScale", 1.0) }
    static var hideControlsWithController: Bool { bool("n3ds.hideWithController", true) }
    static var haptics: Bool { bool("n3ds.haptics", true) }
    static var motionControls: Bool { bool("n3ds.motion", true) }
    /// On by default: the Circle Pad starts where the thumb lands near it
    static var floatingStick: Bool { bool("n3ds.floatingStick", true) }
    /// Lower the resolution while the phone is hot
    static var coolDown: Bool { bool("n3ds.coolDown", true) }
    /// Share of a button's size around it that still presses it
    static var touchReach: CGFloat {
        switch UserDefaults.standard.string(forKey: "n3ds.touchReach") ?? "near" {
        case "exact": 0
        case "generous": 0.6
        default: 0.35
        }
    }
    /// Fast forward speed in percent, 0 = as fast as the phone can
    static var fastForwardSpeed: Int { Int(UserDefaults.standard.string(forKey: "n3ds.ffSpeed") ?? "200") ?? 200 }
}

@MainActor
enum N3DSLauncher {
    static func launch(_ app: GameApp, model: LibraryModel) {
        guard v3k_n3ds_available() else {
            model.lastMessage = takeString(v3k_n3ds_status()) ?? "The 3DS core is not available."
            return
        }
        guard let presenter = topController() else { return }
        let controller = N3DSGameViewController(app: app, jit: model.jitEnabled) {
            CloudSaves.shared.gameEnded()
            MenuMusic.shared.libraryShown()
            BackgroundMotion.shared.setActive(true)
            model.reload()
            LibraryHost.updateOrientation()
        }
        MenuMusic.shared.libraryHidden()
        BackgroundMotion.shared.setActive(false)
        presenter.present(controller, animated: true)
    }

    static func topController() -> UIViewController? {
        var controller = LibraryHost.window?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
}

/// The view the core draws into
final class N3DSMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    var onTouch: ((Int32, CGPoint) -> Void)?
    private var tracked: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracked == nil, let touch = touches.first else { return }
        tracked = touch
        onTouch?(0, touch.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracked, touches.contains(touch) else { return }
        onTouch?(1, touch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracked, touches.contains(touch) else { return }
        tracked = nil
        onTouch?(2, touch.location(in: self))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}

// MARK: - On-screen controls

private let n3dsFill = UIColor(white: 0.1, alpha: 0.9)
private let n3dsPressedFill = UIColor(white: 0.55, alpha: 0.95)
private let n3dsEdge = UIColor(white: 1, alpha: 0.28)

/// A round or pill button that reports pressed / released
final class N3DSPadButton: UIView {
    let key: N3DSKey
    var changed: ((N3DSKey, Bool) -> Void)?
    private let label = UILabel()
    private var touchCount = 0
    private let accent: UIColor?

    /// accent: the face buttons' 3DS colours (the rest are dark grey)
    init(_ key: N3DSKey, title: String, accent: UIColor? = nil, fontSize: CGFloat = 18) {
        self.key = key
        self.accent = accent
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        label.text = title
        label.font = .systemFont(ofSize: fontSize, weight: .heavy)
        label.textColor = .white
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        addSubview(label)
        layer.borderWidth = accent == nil ? 1.5 : 2
        layer.borderColor = (accent ?? n3dsEdge).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1.5)
        update(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 4, dy: 0)
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    private func update(_ pressed: Bool) {
        if let accent {
            backgroundColor = pressed ? accent : darkened(accent, by: 0.32).withAlphaComponent(0.92)
            label.textColor = pressed ? .white : accent.withAlphaComponent(1)
        } else {
            backgroundColor = pressed ? n3dsPressedFill : n3dsFill
        }
        transform = pressed ? CGAffineTransform(scaleX: 0.93, y: 0.93) : .identity
    }

    func releaseIfHeld() {
        guard touchCount > 0 else { return }
        touchCount = 0
        changed?(key, false)
        update(false)
    }

    /// Drawn pressed or not by N3DSFacePad (which takes the touches for A B X Y)
    func showPressed(_ pressed: Bool) { update(pressed) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touchCount == 0 {
            changed?(key, true)
            update(true)
            if N3DSSettings.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        }
        touchCount += touches.count
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touchCount > 0 else { return }
        touchCount = max(0, touchCount - touches.count)
        if touchCount == 0 {
            changed?(key, false)
            update(false)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}

/// A B X Y as one touch area, the way a thumb plays them: slide from one button to the next without
/// lifting, and a thumb between two neighbours presses both (A held, roll up onto X: A and X). Every
/// finger on it counts, so a second finger adds its buttons.
final class N3DSFacePad: UIView {
    /// The four buttons it draws through (positions come from their frames)
    var buttons: [N3DSPadButton] = []
    var changed: ((N3DSKey, Bool) -> Void)?
    private var touchKeys: [ObjectIdentifier: Set<N3DSKey>] = [:]
    private var shown: Set<N3DSKey> = []
    private let feedback = UISelectionFeedbackGenerator()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The buttons under a point: the nearest one, plus its neighbour when the point sits between
    /// the two (within about a third of a button of the line that splits them)
    private func keys(at point: CGPoint, previous: Set<N3DSKey>) -> Set<N3DSKey> {
        let visible = buttons.filter { !$0.isHidden }
        guard !visible.isEmpty, let superview else { return [] }
        let p = convert(point, to: superview)
        let centers = visible.map { ($0.key, CGPoint(x: $0.frame.midX, y: $0.frame.midY), $0.frame.width) }
        let ranked = centers.map { (key: $0.0, distance: hypot(p.x - $0.1.x, p.y - $0.1.y), size: $0.2) }
            .sorted { $0.distance < $1.distance }
        guard let first = ranked.first else { return [] }
        // Far outside the cluster: nothing (the area is a little larger than the buttons)
        if first.distance > first.size * 1.15 { return [] }
        var result: Set<N3DSKey> = [first.key]
        if ranked.count > 1 {
            let second = ranked[1]
            // neighbours only (A-X, A-B, B-Y, Y-X), not opposites (A-Y, X-B)
            let opposite: Set<Set<N3DSKey>> = [[.a, .y], [.x, .b]]
            if !opposite.contains([first.key, second.key]) && second.distance - first.distance < first.size * 0.32 {
                result.insert(second.key)
            }
        }
        // In the gap at the very middle, keep what this finger already had
        let middle = centers.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.1.x / CGFloat(centers.count), y: $0.y + $1.1.y / CGFloat(centers.count)) }
        if hypot(p.x - middle.x, p.y - middle.y) < first.size * 0.3, !previous.isEmpty { return previous }
        return result
    }

    private func refresh() {
        let all = touchKeys.values.reduce(into: Set<N3DSKey>()) { $0.formUnion($1) }
        guard all != shown else { return }
        let added = all.subtracting(shown)
        for key in shown.subtracting(all) { changed?(key, false) }
        for key in added { changed?(key, true) }
        for button in buttons { button.showPressed(all.contains(button.key)) }
        if !added.isEmpty, N3DSSettings.haptics { feedback.selectionChanged() }
        shown = all
    }

    private func track(_ touches: Set<UITouch>) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            touchKeys[id] = keys(at: touch.location(in: self), previous: touchKeys[id] ?? [])
        }
        refresh()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        feedback.prepare()
        track(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { track(touches) }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { touchKeys[ObjectIdentifier(touch)] = nil }
        refresh()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    func releaseIfHeld() {
        touchKeys.removeAll()
        refresh()
    }

    /// The touch area: the four buttons and a margin around them
    func fit() {
        let visible = buttons.filter { !$0.isHidden }
        let box = visible.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        guard !box.isNull, let size = visible.first?.frame.width else { return }
        frame = box.insetBy(dx: -size * 0.3, dy: -size * 0.3)
    }
}

/// The D-pad: one touch area, eight directions, drawn as a cross
final class N3DSDpad: UIView {
    var changed: ((UInt32) -> Void)?
    private var touch: UITouch?
    private let cross = CAShapeLayer()
    private var arms: [CAShapeLayer] = []
    private var arrows: [CAShapeLayer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        cross.fillColor = n3dsFill.cgColor
        cross.strokeColor = n3dsEdge.cgColor
        cross.lineWidth = 1.5
        cross.shadowColor = UIColor.black.cgColor
        cross.shadowOpacity = 0.4
        cross.shadowRadius = 3
        cross.shadowOffset = CGSize(width: 0, height: 1.5)
        layer.addSublayer(cross)
        for _ in 0..<4 {
            let arm = CAShapeLayer()
            arm.fillColor = UIColor.clear.cgColor
            layer.addSublayer(arm)
            arms.append(arm)
            let arrow = CAShapeLayer()
            arrow.fillColor = UIColor.white.withAlphaComponent(0.75).cgColor
            layer.addSublayer(arrow)
            arrows.append(arrow)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = min(bounds.width, bounds.height), w = s / 3
        let ox = (bounds.width - s) / 2, oy = (bounds.height - s) / 2
        let rects = [CGRect(x: ox + w, y: oy, width: w, height: w * 1.5), CGRect(x: ox + w, y: oy + s - w * 1.5, width: w, height: w * 1.5),
                     CGRect(x: ox, y: oy + w, width: w * 1.5, height: w), CGRect(x: ox + s - w * 1.5, y: oy + w, width: w * 1.5, height: w)]
        let path = UIBezierPath(roundedRect: CGRect(x: ox + w, y: oy, width: w, height: s), cornerRadius: w * 0.22)
        path.append(UIBezierPath(roundedRect: CGRect(x: ox, y: oy + w, width: s, height: w), cornerRadius: w * 0.22))
        path.usesEvenOddFillRule = false
        cross.path = path.cgPath
        cross.shadowPath = path.cgPath
        for (arm, rect) in zip(arms, rects) {
            arm.path = UIBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: w * 0.2).cgPath
        }
        // little arrows near the end of each arm
        let a = w * 0.18
        let tips: [(CGPoint, CGFloat)] = [(CGPoint(x: ox + s / 2, y: oy + w * 0.3), -.pi / 2), (CGPoint(x: ox + s / 2, y: oy + s - w * 0.3), .pi / 2),
                                           (CGPoint(x: ox + w * 0.3, y: oy + s / 2), .pi), (CGPoint(x: ox + s - w * 0.3, y: oy + s / 2), 0)]
        for (arrow, (tip, angle)) in zip(arrows, tips) {
            let p = UIBezierPath()
            p.move(to: CGPoint(x: tip.x + cos(angle) * a * 0.6, y: tip.y + sin(angle) * a * 0.6))
            p.addLine(to: CGPoint(x: tip.x + cos(angle + 2.4) * a, y: tip.y + sin(angle + 2.4) * a))
            p.addLine(to: CGPoint(x: tip.x + cos(angle - 2.4) * a, y: tip.y + sin(angle - 2.4) * a))
            p.close()
            arrow.path = p.cgPath
        }
    }

    private func highlight(_ mask: UInt32) {
        let keys: [N3DSKey] = [.up, .down, .left, .right]
        for (arm, key) in zip(arms, keys) {
            arm.fillColor = (mask & key.rawValue != 0 ? UIColor.white.withAlphaComponent(0.55) : UIColor.clear).cgColor
        }
    }

    /// Up, down, left and right each own 60° around their axis; the diagonals only the 30° between
    /// (equal 45° slices made a thumb slightly off the arm press a diagonal, which most games ignore:
    /// the D-pad "worked sometimes"). The centre presses nothing.
    private func mask(at point: CGPoint) -> UInt32 {
        let dx = point.x - bounds.midX, dy = point.y - bounds.midY
        let dead = min(bounds.width, bounds.height) * 0.08
        if hypot(dx, dy) < dead { return 0 }
        var degrees = atan2(-dy, dx) * 180 / .pi // 0 = right, 90 = up
        if degrees < 0 { degrees += 360 }
        let up = N3DSKey.up.rawValue, down = N3DSKey.down.rawValue, left = N3DSKey.left.rawValue, right = N3DSKey.right.rawValue
        switch degrees {
        case ..<30, 330...: return right
        case 30..<60: return right | up
        case 60..<120: return up
        case 120..<150: return up | left
        case 150..<210: return left
        case 210..<240: return left | down
        case 240..<300: return down
        default: return down | right
        }
    }

    private var current: UInt32 = 0
    private let selection = UISelectionFeedbackGenerator()

    private func report(_ value: UInt32) {
        if value != current, value != 0, N3DSSettings.haptics { selection.selectionChanged() }
        current = value
        highlight(value)
        changed?(value)
    }

    func releaseIfHeld() {
        touch = nil
        report(0)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touch == nil, let first = touches.first else { return }
        touch = first
        report(mask(at: first.location(in: self)))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        report(mask(at: touch.location(in: self)))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        self.touch = nil
        report(0)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}

/// The Circle Pad (or the C-stick). Floating: the view is a larger landing area and the pad comes to
/// where the thumb lands.
final class N3DSStick: UIView {
    var changed: ((CGFloat, CGFloat) -> Void)?
    private let base = UIView()
    private let knob = UIView()
    private var touch: UITouch?
    private var origin: CGPoint?
    private(set) var floating = false
    private var padSize: CGFloat = 0
    private var restCenter = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        base.backgroundColor = n3dsFill
        base.layer.borderColor = n3dsEdge.cgColor
        base.layer.borderWidth = 1.5
        base.layer.shadowColor = UIColor.black.cgColor
        base.layer.shadowOpacity = 0.4
        base.layer.shadowRadius = 3
        base.layer.shadowOffset = CGSize(width: 0, height: 1.5)
        base.isUserInteractionEnabled = false
        addSubview(base)
        knob.backgroundColor = UIColor(white: 0.72, alpha: 1)
        knob.layer.borderColor = UIColor(white: 0.92, alpha: 1).cgColor
        knob.layer.borderWidth = 1.5
        knob.layer.shadowColor = UIColor.black.cgColor
        knob.layer.shadowOpacity = 0.5
        knob.layer.shadowRadius = 4
        knob.layer.shadowOffset = CGSize(width: 0, height: 2)
        knob.isUserInteractionEnabled = false
        addSubview(knob)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// pad: where the pad is drawn, in the superview. Floating: this view's frame is the landing area.
    func configure(floating: Bool, pad: CGRect) {
        self.floating = floating
        padSize = pad.width
        restCenter = CGPoint(x: pad.midX - frame.minX, y: pad.midY - frame.minY)
        setNeedsLayout()
    }

    var padFrame: CGRect { base.frame.offsetBy(dx: frame.minX, dy: frame.minY) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = floating ? padSize : min(bounds.width, bounds.height)
        let center = origin ?? (floating ? restCenter : CGPoint(x: bounds.midX, y: bounds.midY))
        base.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        base.center = center
        base.layer.cornerRadius = size / 2
        base.layer.shadowPath = UIBezierPath(ovalIn: base.bounds).cgPath
        let knobSize = size * 0.52
        knob.bounds = CGRect(x: 0, y: 0, width: knobSize, height: knobSize)
        knob.layer.cornerRadius = knobSize / 2
        if touch == nil { knob.center = center }
    }

    private func move(to point: CGPoint) {
        if origin == nil {
            if floating {
                let half = padSize / 2
                origin = CGPoint(x: min(max(point.x, half), max(bounds.width - half, half)),
                                 y: min(max(point.y, half), max(bounds.height - half, half)))
            } else {
                origin = CGPoint(x: bounds.midX, y: bounds.midY)
            }
            setNeedsLayout()
            layoutIfNeeded()
        }
        guard let center = origin else { return }
        let radius = base.bounds.width / 2
        var dx = point.x - center.x, dy = point.y - center.y
        let distance = hypot(dx, dy)
        if distance > radius {
            dx *= radius / distance
            dy *= radius / distance
        }
        knob.center = CGPoint(x: center.x + dx, y: center.y + dy)
        changed?(dx / radius, -dy / radius)
    }

    func releaseIfHeld() {
        guard touch != nil else { return }
        touch = nil
        origin = nil
        setNeedsLayout()
        changed?(0, 0)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touch == nil, let first = touches.first else { return }
        touch = first
        move(to: first.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        move(to: touch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        self.touch = nil
        origin = nil
        UIView.animate(withDuration: 0.12) {
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
        changed?(0, 0)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}

/// A small round icon button (menu, fast forward, swap screens)
final class N3DSIconButton: UIButton {
    init(symbol: String, label: String) {
        super.init(frame: .zero)
        setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)), for: .normal)
        tintColor = .white
        backgroundColor = n3dsFill
        layer.borderColor = n3dsEdge.cgColor
        layer.borderWidth = 1
        accessibilityLabel = label
    }

    required init?(coder: NSCoder) { fatalError() }

    var isOn = false {
        didSet { backgroundColor = isOn ? Theme.accentUIColor : n3dsFill }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

/// Passes touches that miss every control through to the game view below (the touch screen); a tap
/// just beside a button presses it (Settings › 3DS › Button touch area)
final class N3DSOverlay: UIView {
    var reach: CGFloat = 0.35

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        let inStickArea = (hit as? N3DSStick)?.floating ?? false
        if reach > 0, hit === self || inStickArea, let near = nearest(to: point) { return near }
        return hit === self ? nil : hit
    }

    private func nearest(to point: CGPoint) -> UIView? {
        var best: (UIView, CGFloat)?
        for view in subviews where !view.isHidden && view.isUserInteractionEnabled && view.alpha > 0.01 {
            if let stick = view as? N3DSStick, stick.floating { continue }
            let frame = view.frame
            let limit = min(frame.width, frame.height) * reach
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            let distance = hypot(dx, dy)
            if distance <= limit && (best == nil || distance < best!.1) { best = (view, distance) }
        }
        return best?.0
    }
}

// MARK: - The game screen

final class N3DSGameViewController: UIViewController {
    private let app: GameApp
    private let jit: Bool
    private let onEnd: () -> Void

    private let gameView = N3DSMetalView()
    private let overlay = N3DSOverlay()
    private let menuButton = N3DSIconButton(symbol: "line.3.horizontal", label: "Menu")
    private let fastButton = N3DSIconButton(symbol: "forward.fill", label: "Fast forward")
    private let swapButton = N3DSIconButton(symbol: "arrow.up.arrow.down", label: "Swap screens")
    private let miniScreenButton = UIButton(type: .custom)
    private let loadingLabel = UILabel()
    private let loadingSpinner = UIActivityIndicatorView(style: .large)
    private let fpsLabel = UILabel()

    private var dpad = N3DSDpad()
    private let facePad = N3DSFacePad()
    private var circle = N3DSStick()
    private var cstick = N3DSStick()
    private var buttons: [N3DSPadButton] = []

    private var touchMask: UInt32 = 0
    private var dpadMask: UInt32 = 0
    private var circleStick = CGPoint.zero
    private var cStickTouch = CGPoint.zero
    private var displayLink: CADisplayLink?
    private let motion = CMMotionManager()
    private var booted = false
    private var running = false
    private var menuOpen = false
    private var startedAt = Date()
    private var lastSize = CGSize.zero
    private var lastPortrait = false
    private var errorShown = false
    private var fastForward = false
    private var rightStickClickWasDown = false
    /// Hinoki's landscape layout: the touch screen is the big one (the top screen goes small)
    private var bottomScreenBig = false
    /// Resolution lowered while the phone is hot (the chosen one comes back when it cools)
    private var cooledDown = false
    private var lastLayoutSent = ""

    init(app: GameApp, jit: Bool, onEnd: @escaping () -> Void) {
        self.app = app
        self.jit = jit
        self.onEnd = onEnd
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        gameView.backgroundColor = .black
        gameView.isMultipleTouchEnabled = false
        gameView.metalLayer.pixelFormat = .bgra8Unorm
        gameView.metalLayer.framebufferOnly = true
        gameView.onTouch = { [weak self] phase, point in self?.touch(phase, point) }
        view.addSubview(gameView)

        overlay.isMultipleTouchEnabled = true
        overlay.reach = N3DSSettings.touchReach
        view.addSubview(overlay)
        buildControls()

        miniScreenButton.accessibilityLabel = "Swap screens"
        miniScreenButton.addTarget(self, action: #selector(swapScreens), for: .touchUpInside)
        let badge = UIImageView(image: UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)))
        badge.tintColor = .white
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        badge.contentMode = .center
        badge.layer.cornerRadius = 9
        badge.clipsToBounds = true
        badge.frame = CGRect(x: 0, y: 0, width: 18, height: 18)
        badge.tag = 1
        miniScreenButton.addSubview(badge)
        overlay.addSubview(miniScreenButton)

        menuButton.addTarget(self, action: #selector(showMenu), for: .touchUpInside)
        fastButton.addTarget(self, action: #selector(toggleFastForward), for: .touchUpInside)
        swapButton.addTarget(self, action: #selector(swapScreens), for: .touchUpInside)
        [menuButton, fastButton, swapButton].forEach { view.addSubview($0) }

        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        fpsLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        fpsLabel.isHidden = !UserDefaults.standard.bool(forKey: "v3k.hud.enabled")
        view.addSubview(fpsLabel)

        loadingLabel.text = "Starting \(app.title)…"
        loadingLabel.textColor = .white
        loadingLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        loadingLabel.textAlignment = .center
        loadingLabel.numberOfLines = 2
        view.addSubview(loadingLabel)
        loadingSpinner.color = .white
        loadingSpinner.startAnimating()
        view.addSubview(loadingSpinner)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appInactive), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(controllersChanged), name: .GCControllerDidConnect, object: nil)
        center.addObserver(self, selector: #selector(controllersChanged), name: .GCControllerDidDisconnect, object: nil)
        center.addObserver(self, selector: #selector(thermalChanged), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        controllersChanged()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        if let scene = view.window?.windowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .allButUpsideDown)) { _ in }
        }
        boot()
    }

    private var isPortrait: Bool { view.bounds.height > view.bounds.width }
    /// One of Hinoki's own landscape layouts (screens placed around the controls)
    private var hinokiLayout: Bool { !isPortrait && N3DSSettings.hinokiLayouts.contains(N3DSSettings.landscapeLayout) }

    // MARK: Layout

    /// Hinoki's landscape layout: the big screen centred between the two columns of controls, the
    /// other small in the right column (phones), or both stacked in the middle when there's height for
    /// it (iPad). In the view's points.
    private struct ScreenPlan {
        var top: CGRect
        var bottom: CGRect
        var mini: CGRect? = nil // the small screen (tap to swap), phones only
        var gutter: CGFloat = 0
        /// Side-by-side layouts: the controls go in this band along the bottom (nil: in two columns)
        var strip: CGRect? = nil
    }

    /// Both screens side by side, from the top of the window: "sbs" leaves a band below for the
    /// controls, "sbs-top" makes them as large as the width allows (the controls then reach up over the
    /// bottom of the screens). Swapping puts the touch screen on the left.
    private func sideBySidePlan(bounds: CGRect, safe: UIEdgeInsets, unit: CGFloat, largest: Bool) -> ScreenPlan {
        let width = bounds.width, height = bounds.height
        let wanted = min(max(height * 0.36, 118), 175) * CGFloat(min(max(N3DSSettings.controlsScale, 0.8), 1.25))
        let band = largest ? 0 : wanted
        let scale = min((height - band - max(safe.bottom, 6)) / 240, (width - 8) / 720)
        let total = 720 * scale
        let x = (width - total) / 2
        let topRect: CGRect, bottomRect: CGRect
        if bottomScreenBig {
            bottomRect = CGRect(x: x, y: 0, width: 320 * scale, height: 240 * scale)
            topRect = CGRect(x: bottomRect.maxX, y: 0, width: 400 * scale, height: 240 * scale)
        } else {
            topRect = CGRect(x: x, y: 0, width: 400 * scale, height: 240 * scale)
            bottomRect = CGRect(x: topRect.maxX, y: 0, width: 320 * scale, height: 240 * scale)
        }
        let bottomEdge = height - max(safe.bottom, 8)
        let stripTop = min(topRect.maxY + 6, bottomEdge - wanted)
        return ScreenPlan(top: topRect, bottom: bottomRect, strip: CGRect(x: 0, y: stripTop, width: width, height: bottomEdge - stripTop))
    }

    private func screenPlan(bounds: CGRect, safe: UIEdgeInsets, unit: CGFloat) -> ScreenPlan {
        let width = bounds.width, height = bounds.height
        let gutter = min(max(width * 0.21, 124), 220) * CGFloat(min(max(N3DSSettings.controlsScale, 0.8), 1.25))
        let centre = width - gutter * 2
        let rowSpace: CGFloat = 34 // the icon buttons above the screens

        // both stacked in the middle (iPad, iPhone Duo open), meeting at the middle of the window: on
        // a foldable held half open like a laptop the fold runs there, between the screens like a 3DS
        // hinge
        let hinge: CGFloat = 10
        let half = height / 2
        let screenHeight = min(half - hinge / 2 - rowSpace, half - hinge / 2 - 8, centre * 0.6)
        // the big one alone
        let bigAspect: CGFloat = bottomScreenBig ? 4.0 / 3 : 5.0 / 3
        let bigHeight = min(height - rowSpace * 2, centre / bigAspect)
        let bigWidth = bigHeight * bigAspect
        if screenHeight / 0.6 >= bigWidth * 0.75 {
            let topSize = CGSize(width: screenHeight / 0.6, height: screenHeight)
            let bottomSize = CGSize(width: screenHeight / 0.75, height: screenHeight)
            let upper = bottomScreenBig ? bottomSize : topSize, lower = bottomScreenBig ? topSize : bottomSize
            let upperRect = CGRect(x: (width - upper.width) / 2, y: half - hinge / 2 - upper.height, width: upper.width, height: upper.height)
            let lowerRect = CGRect(x: (width - lower.width) / 2, y: half + hinge / 2, width: lower.width, height: lower.height)
            return ScreenPlan(top: bottomScreenBig ? lowerRect : upperRect, bottom: bottomScreenBig ? upperRect : lowerRect, mini: nil, gutter: gutter)
        }
        let big = CGRect(x: (width - bigWidth) / 2, y: max(rowSpace, (height - bigHeight) / 2), width: bigWidth, height: bigHeight)
        let inset = max(safe.right * 0.45, 10)
        let miniWidth = gutter - inset - 10
        let miniAspect: CGFloat = bottomScreenBig ? 5.0 / 3 : 4.0 / 3
        let mini = CGRect(x: width - inset - miniWidth, y: max(safe.top, 8) + 34 * unit + 10, width: miniWidth, height: miniWidth / miniAspect)
        return ScreenPlan(top: bottomScreenBig ? mini : big, bottom: bottomScreenBig ? big : mini, mini: mini, gutter: gutter)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        // the display this window is on (a foldable has two)
        let scale = view.traitCollection.displayScale > 0 ? view.traitCollection.displayScale : (view.window?.screen.scale ?? 2)
        var plan: ScreenPlan?
        if isPortrait {
            // the two screens stacked at the top (400x240 over 320x240), the controls below
            let height = min(bounds.width * 480 / 400, bounds.height * 0.6)
            gameView.frame = CGRect(x: 0, y: safe.top, width: bounds.width, height: height)
        } else {
            gameView.frame = bounds
            switch N3DSSettings.landscapeLayout {
            case "hinoki": plan = screenPlan(bounds: bounds, safe: safe, unit: controlUnit)
            case "sbs": plan = sideBySidePlan(bounds: bounds, safe: safe, unit: controlUnit, largest: false)
            case "sbs-top": plan = sideBySidePlan(bounds: bounds, safe: safe, unit: controlUnit, largest: true)
            default: break
            }
        }
        overlay.frame = bounds
        layoutControls(plan: plan)
        fpsLabel.frame = CGRect(x: max(safe.left, 8) + 4, y: max(safe.top, 4), width: 160, height: 16)
        loadingLabel.frame = CGRect(x: 20, y: gameView.frame.midY + 30, width: bounds.width - 40, height: 44)
        loadingSpinner.center = CGPoint(x: gameView.frame.midX, y: gameView.frame.midY - 10)

        gameView.metalLayer.contentsScale = scale
        let size = CGSize(width: gameView.bounds.width * scale, height: gameView.bounds.height * scale)
        gameView.metalLayer.drawableSize = size
        if let plan { sendScreenPlan(plan, scale: scale) }
        if booted && (size != lastSize || isPortrait != lastPortrait) {
            v3k_n3ds_surface_changed(Int32(size.width), Int32(size.height), Float(scale), isPortrait)
        }
        lastSize = size
        lastPortrait = isPortrait
    }

    /// Hinoki's layout is Azahar's custom layout (6) with the rectangles worked out here, in pixels
    private func sendScreenPlan(_ plan: ScreenPlan, scale: CGFloat) {
        func px(_ value: CGFloat) -> String { String(max(Int((value * scale).rounded()), 0)) }
        let values = [("custom_top_x", plan.top.minX), ("custom_top_y", plan.top.minY), ("custom_top_width", plan.top.width),
                      ("custom_top_height", plan.top.height), ("custom_bottom_x", plan.bottom.minX), ("custom_bottom_y", plan.bottom.minY),
                      ("custom_bottom_width", plan.bottom.width), ("custom_bottom_height", plan.bottom.height)]
        let signature = values.map { px($0.1) }.joined(separator: ",")
        guard signature != lastLayoutSent else { return }
        lastLayoutSent = signature
        v3k_n3ds_set_setting("swap_screen", "0")
        for (key, value) in values { v3k_n3ds_set_setting(key, px(value)) }
        v3k_n3ds_set_setting("layout_option", "6")
    }

    private var controlUnit: CGFloat {
        let bounds = view.bounds
        let base = isPortrait ? bounds.width / 390 : min(bounds.height / 393, 1.3)
        return min(max(base, 0.75), 1.4) * CGFloat(N3DSSettings.controlsScale)
    }

    // MARK: Controls

    private func buildControls() {
        let faceColors: [(N3DSKey, String, UIColor)] = [
            (.x, "X", UIColor(red: 0.36, green: 0.52, blue: 1.0, alpha: 1)),
            (.a, "A", UIColor(red: 1.0, green: 0.33, blue: 0.36, alpha: 1)),
            (.b, "B", UIColor(red: 1.0, green: 0.82, blue: 0.25, alpha: 1)),
            (.y, "Y", UIColor(red: 0.35, green: 0.82, blue: 0.45, alpha: 1)),
        ]
        for (key, title, color) in faceColors {
            buttons.append(N3DSPadButton(key, title: title, accent: color, fontSize: 21))
        }
        for (key, title) in [(N3DSKey.l, "L"), (.r, "R"), (.zl, "ZL"), (.zr, "ZR")] {
            buttons.append(N3DSPadButton(key, title: title, fontSize: 16))
        }
        for (key, title) in [(N3DSKey.start, "START"), (.select, "SELECT"), (.home, "HOME")] {
            buttons.append(N3DSPadButton(key, title: title, fontSize: 11))
        }
        for button in buttons {
            button.changed = { [weak self] key, pressed in
                guard let self else { return }
                if pressed { touchMask |= key.rawValue } else { touchMask &= ~key.rawValue }
            }
            overlay.addSubview(button)
        }
        // A B X Y take their touches through one area (slide and roll between them)
        let face = [N3DSKey.a, .b, .x, .y].compactMap { button($0) }
        face.forEach { $0.isUserInteractionEnabled = false }
        facePad.buttons = face
        facePad.changed = { [weak self] key, pressed in
            guard let self else { return }
            if pressed { touchMask |= key.rawValue } else { touchMask &= ~key.rawValue }
        }
        overlay.addSubview(facePad)
        dpad.changed = { [weak self] mask in self?.dpadMask = mask }
        circle.changed = { [weak self] x, y in self?.circleStick = CGPoint(x: x, y: y) }
        cstick.changed = { [weak self] x, y in self?.cStickTouch = CGPoint(x: x, y: y) }
        overlay.addSubview(dpad)
        overlay.addSubview(cstick)
        // under the buttons: a floating Circle Pad's landing area reaches behind them
        overlay.insertSubview(circle, at: 0)
        applyControlsVisibility()
    }

    private func button(_ key: N3DSKey) -> N3DSPadButton? { buttons.first { $0.key == key } }

    private func place(_ key: N3DSKey, _ frame: CGRect) { button(key)?.frame = frame }

    /// Where everything goes, made to be held: the Circle Pad where the left thumb rests (lower left),
    /// A B X Y where the right thumb rests (lower right), the D-pad and C-stick just above them, L/ZL and
    /// R/ZR in the top corners, SELECT HOME START (with the menu, fast forward and swap) in one small row.
    /// Then the player's own moves and sizes (Edit controls) on top.
    private func layoutControls(plan: ScreenPlan?) {
        let bounds = view.bounds, safe = view.safeAreaInsets
        let u = controlUnit
        let newMode = N3DSSettings.value("is_new_3ds") == "1"
        var circleFrame = CGRect.zero
        miniScreenButton.isHidden = true

        if comfortStyle {
            circleFrame = layoutComfort(plan: plan, u: u, newMode: newMode)
        } else if isPortrait {
            let left = safe.left + 14 * u, right = bounds.width - safe.right - 14 * u
            let bottom = bounds.height - max(safe.bottom, 10) - 6 * u
            let top = gameView.frame.maxY + 8 * u
            let shoulderW = 62 * u, shoulderH = 36 * u
            placeShoulders(left: left, right: right, top: top, width: shoulderW, height: shoulderH)
            layoutIconRow(center: CGPoint(x: bounds.midX, y: top + shoulderH / 2))

            let small = 28 * u, pillW = 66 * u
            let rowY = bottom - small
            placeSystemRow(center: CGPoint(x: bounds.midX, y: rowY + small / 2), pillW: pillW, height: small, withIcons: false)

            // left: the D-pad, the Circle Pad under it; right: the C-stick, A B X Y under it
            let areaTop = top + shoulderH + 10 * u, areaBottom = rowY - 8 * u
            let space = areaBottom - areaTop
            let stick = min(124 * u, space * 0.52, (right - left) * 0.36)
            let dpadSize = max(min(112 * u, space - stick - 8 * u, (right - left) * 0.33), 64)
            circleFrame = CGRect(x: left, y: areaBottom - stick, width: stick, height: stick)
            dpad.frame = CGRect(x: left + (stick - dpadSize) / 2 + 10 * u, y: max(areaTop, circleFrame.minY - 8 * u - dpadSize), width: dpadSize, height: dpadSize)
            let face = min(56 * u, (right - left) * 0.36 / 3.1, space / 4.3)
            let faceCenter = CGPoint(x: right - face * 1.55, y: areaBottom - face * 1.55)
            layoutFace(center: faceCenter, size: face)
            let cSize = newMode ? max(min(54 * u, space - face * 3.1 - 8 * u), 0) : 0
            cstick.frame = CGRect(x: faceCenter.x - face * 1.55 - cSize * 0.2, y: max(areaTop, faceCenter.y - face * 1.55 - 8 * u - cSize), width: cSize, height: cSize)
        } else if let strip = plan?.strip {
            circleFrame = layoutBand(strip, plan: plan, u: u, newMode: newMode)
        } else {
            // two columns: in Hinoki's big + small layout outside the screens, over their edges in the
            // overlay layouts
            let gutter = plan?.gutter ?? min(max(bounds.width * 0.2, 130), 230) * CGFloat(min(max(N3DSSettings.controlsScale, 0.8), 1.25))
            let leftX = max(safe.left * 0.45, 10), rightEdge = bounds.width - max(safe.right * 0.45, 10)
            let column = gutter - leftX - 8
            let top = max(safe.top, 6)
            let bottom = bounds.height - max(safe.bottom, 6)
            let shoulderH = 34 * u
            placeShoulders(left: leftX, right: rightEdge, top: top, width: newMode ? column * 0.56 : column, height: shoulderH, columnWidth: column)

            // left column: the Circle Pad at the bottom (where the thumb rests), the D-pad above it
            let leftTop = top + shoulderH + 8
            let stick = min(column, 126 * u, (bottom - leftTop) * 0.55)
            circleFrame = CGRect(x: leftX + (column - stick) / 2, y: bottom - stick, width: stick, height: stick)
            let dpadRoom = circleFrame.minY - 6 - leftTop
            let dpadSize = max(min(column * 0.96, 116 * u, dpadRoom), 64)
            dpad.frame = CGRect(x: leftX + (column - dpadSize) / 2, y: max(leftTop, circleFrame.minY - 6 - dpadSize), width: dpadSize, height: dpadSize)

            // right column: (the small screen,) the C-stick, A B X Y at the bottom
            var rightTop = top + shoulderH + 8
            if let mini = plan?.mini {
                miniScreenButton.isHidden = false
                miniScreenButton.frame = mini
                miniScreenButton.viewWithTag(1)?.frame = CGRect(x: mini.width - 20, y: 2, width: 18, height: 18)
                rightTop = mini.maxY + 8
            }
            let face = min(column / 3.1, 54 * u, (bottom - rightTop) / 3.6)
            let faceCenter = CGPoint(x: rightEdge - column / 2, y: bottom - face * 1.55)
            layoutFace(center: faceCenter, size: face)
            let faceTop = faceCenter.y - face * 1.55
            let cRoom = faceTop - 6 - rightTop
            var cSize = newMode ? max(min(52 * u, cRoom, column * 0.42), 0) : 0
            cstick.frame = CGRect(x: rightEdge - column, y: faceTop - 6 - cSize, width: cSize, height: cSize)
            if newMode && cSize < 34 {
                // no room above the buttons (under a tall small screen): just inside them instead
                cSize = 40 * u
                cstick.frame = CGRect(x: rightEdge - column - cSize * 0.5, y: faceTop - cSize * 0.4, width: cSize, height: cSize)
            }

            // SELECT HOME [menu » ⇅] START across the top, between the shoulder buttons
            var rowY = top + 15
            if let plan {
                let centralTop = plan.mini == nil ? min(plan.top.minY, plan.bottom.minY) : (bottomScreenBig ? plan.bottom.minY : plan.top.minY)
                if centralTop > 30 { rowY = centralTop / 2 }
            }
            placeSystemRow(center: CGPoint(x: bounds.midX, y: max(rowY, 15)), pillW: 60 * u, height: 26 * u, withIcons: true)
        }

        circleFrame = applyPlacements(circleFrame: circleFrame)
        circleFrameNow = circleFrame
        facePad.fit()

        // Floating Circle Pad: the pad comes to the thumb anywhere around where it's drawn (never over
        // the touch screen)
        if N3DSSettings.floatingStick && editor == nil {
            var zone = circleFrame.insetBy(dx: -circleFrame.width * 0.6, dy: -circleFrame.width * 0.6).intersection(bounds)
            if isPortrait {
                zone = zone.intersection(CGRect(x: 0, y: gameView.frame.maxY, width: bounds.width, height: bounds.height - gameView.frame.maxY))
            } else if let plan {
                let touch = plan.bottom
                if zone.intersects(touch) {
                    if touch.minX >= circleFrame.maxX {
                        zone.size.width = touch.minX - zone.minX
                    } else if touch.maxY <= circleFrame.minY {
                        let cut = touch.maxY - zone.minY
                        zone.origin.y += cut
                        zone.size.height -= cut
                    } else {
                        zone = circleFrame
                    }
                }
            } else {
                // Azahar's layouts: where the touch screen is isn't known here, keep the area tight
                zone = circleFrame.insetBy(dx: -circleFrame.width * 0.3, dy: -circleFrame.width * 0.3).intersection(bounds)
            }
            circle.frame = zone.union(circleFrame)
            circle.configure(floating: true, pad: circleFrame)
        } else {
            circle.frame = circleFrame
            circle.configure(floating: false, pad: circleFrame)
        }
        editor?.refresh()
    }

    private func placeShoulders(left: CGFloat, right: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat, columnWidth: CGFloat? = nil) {
        place(.l, CGRect(x: left, y: top, width: width, height: height))
        place(.r, CGRect(x: right - width, y: top, width: width, height: height))
        let zlWidth = max(columnWidth.map { $0 - width - 6 } ?? width * 0.75, 0)
        place(.zl, CGRect(x: left + width + 6, y: top, width: zlWidth, height: height))
        place(.zr, CGRect(x: right - width - 6 - zlWidth, y: top, width: zlWidth, height: height))
    }

    /// SELECT and HOME on the left of the row, START on the right, the icon buttons in the middle (or not)
    private func placeSystemRow(center: CGPoint, pillW: CGFloat, height: CGFloat, withIcons: Bool) {
        let icons: CGFloat = withIcons ? 3 * 30 + 2 * 10 + 24 : 12
        place(.select, CGRect(x: center.x - icons / 2 - pillW * 2 - 6, y: center.y - height / 2, width: pillW, height: height))
        place(.home, CGRect(x: center.x - icons / 2 - pillW, y: center.y - height / 2, width: pillW, height: height))
        place(.start, CGRect(x: center.x + icons / 2, y: center.y - height / 2, width: pillW, height: height))
        if withIcons { layoutIconRow(center: center) }
    }

    // MARK: Comfort layout

    /// The comfort style. A thumb pivots from the phone's lower corner, so its tip sweeps an arc: it
    /// rests about a third of the way up, reaches up-and-out easily and down-and-in easily, and has to
    /// curl to reach the very bottom edge or stretch to the top corner. So on each side the control used
    /// most (Circle Pad, A B X Y) sits where the thumb rests, the other one (D-pad, C-stick) up and out
    /// from it along the arc, nothing hugs the edges, and the shoulder buttons are bigger targets.
    /// Returns where the Circle Pad goes.
    private func layoutComfort(plan: ScreenPlan?, u: CGFloat, newMode: Bool) -> CGRect {
        let bounds = view.bounds, safe = view.safeAreaInsets
        if isPortrait {
            let left = safe.left + 16 * u, right = bounds.width - safe.right - 16 * u
            let top = gameView.frame.maxY + 8 * u
            let shoulderW = 72 * u, shoulderH = 38 * u
            placeShoulders(left: left, right: right, top: top, width: shoulderW, height: shoulderH)
            layoutIconRow(center: CGPoint(x: bounds.midX, y: top + shoulderH / 2))

            let bottom = bounds.height - max(safe.bottom, 12) - 8 * u
            let areaTop = top + shoulderH + 10 * u
            let space = max(bottom - areaTop, 120)
            let half = (right - left) / 2
            // the thumb rests a bit over a third of the way up
            let stick = min(128 * u, space * 0.46, half * 0.78)
            let circleCenter = CGPoint(x: left + half * 0.52, y: min(bottom - space * 0.36, bottom - stick / 2))
            let circleFrame = CGRect(x: circleCenter.x - stick / 2, y: circleCenter.y - stick / 2, width: stick, height: stick)
            let dpadSize = max(min(112 * u, circleFrame.minY - 8 * u - areaTop, half * 0.7), 64)
            dpad.frame = CGRect(x: max(left, circleFrame.minX - dpadSize * 0.32), y: max(areaTop, circleFrame.minY - 8 * u - dpadSize),
                                width: dpadSize, height: dpadSize)

            let face = min(58 * u, half * 0.84 / 3.2, space / 4.4)
            let faceCenter = CGPoint(x: right - half * 0.52, y: circleCenter.y)
            layoutFace(center: faceCenter, size: face, spacing: 1.12)
            let faceTop = faceCenter.y - face * 1.62
            let cSize = newMode ? max(min(56 * u, faceTop - 8 * u - areaTop), 0) : 0
            cstick.frame = CGRect(x: min(right - cSize, faceCenter.x + face * 0.6), y: max(areaTop, faceTop - 8 * u - cSize), width: cSize, height: cSize)

            // SELECT HOME START up between the D-pad and the C-stick: out of the thumbs' way
            let small = 28 * u
            let rightLimit = newMode ? min(cstick.frame.minX, faceCenter.x - face * 1.62) : faceCenter.x - face * 1.62
            let pillW = max(min(56 * u, (rightLimit - dpad.frame.maxX - 24) / 3), 40)
            let rowWidth = pillW * 3 + 12
            let rowX = min(max((dpad.frame.maxX + rightLimit) / 2, bounds.midX - 30), bounds.midX + 30) - rowWidth / 2
            let rowY = areaTop
            place(.select, CGRect(x: rowX, y: rowY, width: pillW, height: small))
            place(.home, CGRect(x: rowX + pillW + 6, y: rowY, width: pillW, height: small))
            place(.start, CGRect(x: rowX + rowWidth - pillW, y: rowY, width: pillW, height: small))
            return circleFrame
        }

        if let strip = plan?.strip {
            return layoutComfortBand(strip, plan: plan, u: u, newMode: newMode)
        }

        // two columns: beside the screens (Hinoki's layout) or over their edges (the overlay layouts)
        let gutter = plan?.gutter ?? min(max(bounds.width * 0.2, 130), 230) * CGFloat(min(max(N3DSSettings.controlsScale, 0.8), 1.25))
        let leftX = max(safe.left * 0.45, 10) + 6 * u, rightEdge = bounds.width - max(safe.right * 0.45, 10) - 6 * u
        let column = gutter - leftX - 4
        let top = max(safe.top, 6)
        let bottom = bounds.height - max(safe.bottom, 8) - 10 * u
        let shoulderH = 40 * u
        placeShoulders(left: leftX, right: rightEdge, top: top, width: newMode ? column * 0.56 : column, height: shoulderH, columnWidth: column)
        let restY = bottom - (bottom - top) * 0.3

        // left: the Circle Pad where the thumb rests, a little in from the edge; the D-pad up and out
        let leftTop = top + shoulderH + 10 * u
        let stick = min(column * 0.94, 126 * u, (bottom - leftTop) * 0.5)
        let circleCenter = CGPoint(x: leftX + column * 0.5 + min(column * 0.06, (column - stick) / 2),
                                   y: min(max(restY, leftTop + stick / 2 + 70 * u), bottom - stick / 2))
        let circleFrame = CGRect(x: circleCenter.x - stick / 2, y: circleCenter.y - stick / 2, width: stick, height: stick)
        let dpadSize = max(min(column * 0.88, 112 * u, circleFrame.minY - 8 * u - leftTop), 64)
        dpad.frame = CGRect(x: max(leftX - 4, circleCenter.x - dpadSize / 2 - column * 0.1), y: max(leftTop, circleFrame.minY - 8 * u - dpadSize),
                            width: dpadSize, height: dpadSize)

        // right: (the small screen,) A B X Y where the thumb rests, the C-stick up and in from them
        var rightTop = top + shoulderH + 10 * u
        if let mini = plan?.mini {
            miniScreenButton.isHidden = false
            miniScreenButton.frame = mini
            miniScreenButton.viewWithTag(1)?.frame = CGRect(x: mini.width - 20, y: 2, width: 18, height: 18)
            rightTop = mini.maxY + 8
        }
        let face = min(column / 3.2, 56 * u, (bottom - rightTop) / 3.6)
        let reach = face * 1.6
        let cWanted = newMode ? min(50 * u, column * 0.4) : 0
        // as close to the resting height as the C-stick above them allows
        let lowest = bottom - reach
        let highest = rightTop + (newMode ? cWanted + 8 * u : 0) + reach
        let faceCenter = CGPoint(x: rightEdge - column / 2, y: min(max(restY, highest), lowest))
        layoutFace(center: faceCenter, size: face, spacing: 1.1)
        let faceTop = faceCenter.y - reach
        var cSize = newMode ? max(min(cWanted, faceTop - 8 * u - rightTop), 0) : 0
        cstick.frame = CGRect(x: rightEdge - column, y: faceTop - 8 * u - cSize, width: cSize, height: cSize)
        if newMode && cSize < 34 {
            // no room above the buttons (under a tall small screen): just inside them instead
            cSize = 40 * u
            cstick.frame = CGRect(x: rightEdge - column - cSize * 0.5, y: faceTop - cSize * 0.4, width: cSize, height: cSize)
        }

        // SELECT HOME [menu » ⇅] START across the top, between the shoulder buttons
        var rowY = top + 15
        if let plan {
            let centralTop = plan.mini == nil ? min(plan.top.minY, plan.bottom.minY) : (bottomScreenBig ? plan.bottom.minY : plan.top.minY)
            if centralTop > 30 { rowY = centralTop / 2 }
        }
        placeSystemRow(center: CGPoint(x: bounds.midX, y: max(rowY, 15)), pillW: 60 * u, height: 26 * u, withIcons: true)
        return circleFrame
    }

    /// Comfort in the side-by-side band: on each side the main control in from the edge and a little
    /// lower, the other one beside it towards the middle and a little higher (along the thumb's arc)
    private func layoutComfortBand(_ band: CGRect, plan: ScreenPlan?, u: CGFloat, newMode: Bool) -> CGRect {
        let safe = view.safeAreaInsets
        let left = band.minX + max(safe.left * 0.45, 10) + 8 * u, right = band.maxX - max(safe.right * 0.45, 10) - 8 * u
        let height = band.height
        let gap = 14 * u
        var dpadSize = min(height * 0.84, 108 * u), stick = min(height * 0.9, 124 * u)
        var face = min(height / 3.3, 52 * u)
        var cSize = newMode ? min(height * 0.42, 50 * u) : 0
        let pillW = 58 * u, small = 26 * u
        let middle = pillW * 3 + 12
        let needed = dpadSize + stick + face * 3.3 + cSize + middle + gap * 6
        let fit = min(1, (right - left) / needed)
        if fit < 1 {
            dpadSize *= fit
            stick *= fit
            face *= fit
            cSize *= fit
        }
        // the slope along the arc: what the band's height leaves
        let slope = min(max(height - stick, 0) / 2, 14 * u)
        let midY = band.midY

        let screens = plan.map { $0.top.union($0.bottom) } ?? .zero
        let margin = screens.minX - left
        let top = max(safe.top, 6)
        if margin >= 50 {
            let w = min(margin - 6, 74 * u), h = min(44 * u, (screens.height - 12) / 2)
            place(.l, CGRect(x: left, y: top, width: w, height: h))
            place(.zl, CGRect(x: left, y: top + h + 6, width: w, height: h))
            place(.r, CGRect(x: right - w, y: top, width: w, height: h))
            place(.zr, CGRect(x: right - w, y: top + h + 6, width: w, height: h))
        } else {
            placeShoulders(left: left, right: right, top: top, width: 68 * u, height: 36 * u)
        }

        let circleFrame = CGRect(x: left, y: midY - stick / 2 + slope, width: stick, height: stick)
        dpad.frame = CGRect(x: circleFrame.maxX + gap, y: midY - dpadSize / 2 - slope, width: dpadSize, height: dpadSize)

        let faceCenter = CGPoint(x: right - face * 1.62, y: midY + slope)
        layoutFace(center: faceCenter, size: face, spacing: 1.12)
        cstick.frame = CGRect(x: faceCenter.x - face * 1.62 - gap - cSize, y: midY - cSize / 2 - slope, width: cSize, height: cSize)

        let centreX = (dpad.frame.maxX + (newMode ? cstick.frame.minX : faceCenter.x - face * 1.62)) / 2
        let rowY = band.maxY - small
        place(.select, CGRect(x: centreX - pillW * 1.5 - 6, y: rowY, width: pillW, height: small))
        place(.home, CGRect(x: centreX - pillW / 2, y: rowY, width: pillW, height: small))
        place(.start, CGRect(x: centreX + pillW / 2 + 6, y: rowY, width: pillW, height: small))
        layoutIconRow(center: CGPoint(x: centreX, y: max(band.minY + 15, rowY - 26)))
        return circleFrame
    }

    /// Side-by-side layouts: the controls in a band along the bottom, left to right
    /// [Circle Pad] [D-pad]   [SELECT HOME START, icons above]   [C-stick] [A B X Y], the shoulder
    /// buttons in the margins beside the screens (or in the top corners when there's no margin).
    /// Returns where the Circle Pad goes.
    private func layoutBand(_ band: CGRect, plan: ScreenPlan?, u: CGFloat, newMode: Bool) -> CGRect {
        let safe = view.safeAreaInsets
        let left = band.minX + max(safe.left * 0.45, 10), right = band.maxX - max(safe.right * 0.45, 10)
        let height = band.height
        let gap = 12 * u
        var dpadSize = min(height * 0.9, 116 * u), stick = min(height * 0.96, 126 * u)
        var face = min(height / 3.1, 50 * u)
        var cSize = newMode ? min(height * 0.42, 52 * u) : 0
        let pillW = 58 * u, small = 26 * u
        let middle = pillW * 3 + 12
        let needed = dpadSize + stick + face * 3.1 + cSize + middle + gap * 6
        let fit = min(1, (right - left) / needed)
        if fit < 1 {
            dpadSize *= fit
            stick *= fit
            face *= fit
            cSize *= fit
        }
        let midY = band.midY

        // shoulders: beside the screens when there's a margin, else in the top corners
        let screens = plan.map { $0.top.union($0.bottom) } ?? .zero
        let margin = screens.minX - left
        let top = max(safe.top, 6)
        if margin >= 50 {
            let w = min(margin - 6, 70 * u), h = min(40 * u, (screens.height - 12) / 2)
            place(.l, CGRect(x: left, y: top, width: w, height: h))
            place(.zl, CGRect(x: left, y: top + h + 6, width: w, height: h))
            place(.r, CGRect(x: right - w, y: top, width: w, height: h))
            place(.zr, CGRect(x: right - w, y: top + h + 6, width: w, height: h))
        } else {
            placeShoulders(left: left, right: right, top: top, width: 64 * u, height: 32 * u)
        }

        // left: the Circle Pad on the outside (thumb), the D-pad inside it
        let circleFrame = CGRect(x: left, y: midY - stick / 2, width: stick, height: stick)
        dpad.frame = CGRect(x: circleFrame.maxX + gap, y: midY - dpadSize / 2, width: dpadSize, height: dpadSize)

        // right: A B X Y on the outside, the C-stick inside them
        let faceCenter = CGPoint(x: right - face * 1.55, y: midY)
        layoutFace(center: faceCenter, size: face)
        cstick.frame = CGRect(x: faceCenter.x - face * 1.55 - gap - cSize, y: midY - cSize / 2, width: cSize, height: cSize)

        // middle: SELECT HOME START at the bottom, the icon buttons above them
        let centreX = (dpad.frame.maxX + (newMode ? cstick.frame.minX : faceCenter.x - face * 1.55)) / 2
        let rowY = band.maxY - small
        place(.select, CGRect(x: centreX - pillW * 1.5 - 6, y: rowY, width: pillW, height: small))
        place(.home, CGRect(x: centreX - pillW / 2, y: rowY, width: pillW, height: small))
        place(.start, CGRect(x: centreX + pillW / 2 + 6, y: rowY, width: pillW, height: small))
        layoutIconRow(center: CGPoint(x: centreX, y: max(band.minY + 15, rowY - 26)))
        return circleFrame
    }

    // MARK: Edit controls (move and resize, kept per screen layout)

    enum ControlGroup: String, CaseIterable {
        case circle, dpad, face, cstick, left, right, system
    }

    struct Placement: Codable, Equatable {
        /// offset as a share of the screen's width and height (so it fits other phones)
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var scale: CGFloat = 1
    }

    private var placements: [String: Placement] = [:]
    /// where the Circle Pad is drawn (its view can be a larger landing area)
    private var circleFrameNow = CGRect.zero
    private var placementsLoadedFor = ""
    private var editor: N3DSControlEditor?

    private var placementsKey: String {
        "n3ds.controls." + (comfortStyle ? "comfort." : "") + (isPortrait ? "portrait" : N3DSSettings.landscapeLayout)
    }

    private var comfortStyle: Bool { N3DSSettings.controlStyle == "comfort" }

    private func loadPlacementsIfNeeded() {
        guard placementsLoadedFor != placementsKey else { return }
        placementsLoadedFor = placementsKey
        if let data = UserDefaults.standard.data(forKey: placementsKey), let saved = try? JSONDecoder().decode([String: Placement].self, from: data) {
            placements = saved
        } else {
            placements = [:]
        }
    }

    private func savePlacements() {
        if placements.isEmpty {
            UserDefaults.standard.removeObject(forKey: placementsKey)
        } else if let data = try? JSONEncoder().encode(placements) {
            UserDefaults.standard.set(data, forKey: placementsKey)
        }
    }

    private func groupViews(_ group: ControlGroup) -> [UIView] {
        switch group {
        case .circle: []
        case .dpad: [dpad]
        case .face: [N3DSKey.a, .b, .x, .y].compactMap { button($0) }
        case .cstick: N3DSSettings.value("is_new_3ds") == "1" ? [cstick] : []
        case .left: [N3DSKey.l, .zl].compactMap { button($0) }
        case .right: [N3DSKey.r, .zr].compactMap { button($0) }
        case .system: [N3DSKey.select, .home, .start].compactMap { button($0) }
        }
    }

    private func moved(_ rect: CGRect, around center: CGPoint, by placement: Placement) -> CGRect {
        let bounds = view.bounds
        return CGRect(x: center.x + (rect.minX - center.x) * placement.scale + placement.dx * bounds.width,
                      y: center.y + (rect.minY - center.y) * placement.scale + placement.dy * bounds.height,
                      width: rect.width * placement.scale, height: rect.height * placement.scale)
    }

    /// Kept on screen
    private func shiftInside(_ box: CGRect) -> CGPoint {
        let bounds = view.bounds
        return CGPoint(x: max(bounds.minX - box.minX, 0) + min(bounds.maxX - box.maxX, 0),
                       y: max(bounds.minY - box.minY, 0) + min(bounds.maxY - box.maxY, 0))
    }

    /// The player's moves and sizes over the default layout; returns where the Circle Pad goes
    private func applyPlacements(circleFrame: CGRect) -> CGRect {
        loadPlacementsIfNeeded()
        var circleOut = circleFrame
        for group in ControlGroup.allCases {
            guard let placement = placements[group.rawValue], placement != Placement() else { continue }
            if group == .circle {
                let rect = moved(circleFrame, around: CGPoint(x: circleFrame.midX, y: circleFrame.midY), by: placement)
                let shift = shiftInside(rect)
                circleOut = rect.offsetBy(dx: shift.x, dy: shift.y)
                continue
            }
            let members = groupViews(group)
            let box = members.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            guard !box.isNull else { continue }
            let center = CGPoint(x: box.midX, y: box.midY)
            let frames = members.map { moved($0.frame, around: center, by: placement) }
            let shift = shiftInside(frames.reduce(CGRect.null) { $0.union($1) })
            for (member, frame) in zip(members, frames) { member.frame = frame.offsetBy(dx: shift.x, dy: shift.y) }
        }
        return circleOut
    }

    func groupFrame(_ group: ControlGroup) -> CGRect {
        group == .circle ? circleFrameNow : groupViews(group).map(\.frame).reduce(CGRect.null) { $0.union($1) }
    }

    /// The smallest group under the finger
    func group(at point: CGPoint) -> ControlGroup? {
        ControlGroup.allCases.filter { !groupFrame($0).isNull && groupFrame($0).insetBy(dx: -14, dy: -14).contains(point) }
            .min { groupFrame($0).width * groupFrame($0).height < groupFrame($1).width * groupFrame($1).height }
    }

    func placement(_ group: ControlGroup) -> Placement { placements[group.rawValue] ?? Placement() }

    func setPlacement(_ placement: Placement, for group: ControlGroup) {
        placements[group.rawValue] = placement == Placement() ? nil : placement
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    func resetPlacements() {
        placements = [:]
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private func beginEditingControls() {
        guard editor == nil else { return }
        if controlsHidden { setControlsHidden(false) }
        releaseTouchControls()
        if running { v3k_n3ds_set_paused(true) }
        menuOpen = true
        overlay.isUserInteractionEnabled = false
        let newEditor = N3DSControlEditor(owner: self)
        newEditor.frame = view.bounds
        newEditor.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(newEditor)
        editor = newEditor
        view.setNeedsLayout()
        view.layoutIfNeeded()
        newEditor.refresh()
    }

    func endEditingControls(save: Bool) {
        guard let editor else { return }
        if save {
            savePlacements()
        } else {
            placementsLoadedFor = ""
        }
        editor.removeFromSuperview()
        self.editor = nil
        overlay.isUserInteractionEnabled = true
        view.setNeedsLayout()
        view.layoutIfNeeded()
        closeMenu()
        if save { showToast(L("Controls saved for this layout")) }
    }

    /// The screen layouts, with the current one ticked
    private func showLayoutPicker() {
        let sheet = UIAlertController(title: L("Screen layout"), message: isPortrait ? L("Upright, the screens are stacked above the controls. These are for holding the phone sideways.") : nil, preferredStyle: .actionSheet)
        for (value, name) in N3DSSettings.landscapeLayouts {
            let current = N3DSSettings.landscapeLayout == value
            sheet.addAction(UIAlertAction(title: (current ? "✓ " : "") + L(name), style: .default) { [weak self] _ in
                guard let self else { return }
                N3DSSettings.landscapeLayout = value
                if !N3DSSettings.hinokiLayouts.contains(value) {
                    v3k_n3ds_set_setting("swap_screen", N3DSSettings.value("swap_screen"))
                }
                lastLayoutSent = ""
                view.setNeedsLayout()
                view.layoutIfNeeded()
                closeMenu()
            })
        }
        sheet.addAction(UIAlertAction(title: L("Back"), style: .cancel) { [weak self] _ in
            self?.menuOpen = false
            self?.showMenu()
        })
        present(sheet: sheet)
    }

    private func layoutFace(center: CGPoint, size face: CGFloat, spacing: CGFloat = 1.05) {
        let offsets: [(N3DSKey, CGFloat, CGFloat)] = [(.x, 0, -1), (.a, 1, 0), (.b, 0, 1), (.y, -1, 0)]
        for (key, dx, dy) in offsets {
            place(key, CGRect(x: center.x + dx * face * spacing - face / 2, y: center.y + dy * face * spacing - face / 2, width: face, height: face))
        }
    }

    private func layoutIconRow(center: CGPoint) {
        let size: CGFloat = 30
        let row = [menuButton, fastButton, swapButton]
        let total = CGFloat(row.count) * size + CGFloat(row.count - 1) * 10
        for (index, button) in row.enumerated() {
            button.frame = CGRect(x: center.x - total / 2 + CGFloat(index) * (size + 10), y: center.y - size / 2, width: size, height: size)
        }
    }

    private var controllerConnected: Bool { GCController.current?.extendedGamepad != nil || GCController.controllers().contains { $0.extendedGamepad != nil } }

    private func applyControlsVisibility() {
        let hidden = controllerConnected && N3DSSettings.hideControlsWithController
        setControlsHidden(hidden)
        overlay.alpha = CGFloat(N3DSSettings.controlsOpacity)
        // (ZL, ZR and the C-stick: setControlsHidden shows them only on a New 3DS, and keeps them hidden
        // with the rest while a controller is in use)
    }

    /// The controls hidden (the small screen stays: it swaps the screens)
    private func setControlsHidden(_ hidden: Bool) {
        for view in overlay.subviews where view !== miniScreenButton {
            if view === cstick || view === button(.zl) || view === button(.zr) {
                view.isHidden = hidden || N3DSSettings.value("is_new_3ds") != "1"
            } else {
                view.isHidden = hidden
            }
        }
        if hidden { releaseTouchControls() }
        controlsHidden = hidden
    }

    private var controlsHidden = false

    private func releaseTouchControls() {
        buttons.forEach { $0.releaseIfHeld() }
        facePad.releaseIfHeld()
        dpad.releaseIfHeld()
        circle.releaseIfHeld()
        cstick.releaseIfHeld()
        touchMask = 0
        dpadMask = 0
        circleStick = .zero
        cStickTouch = .zero
    }

    @objc private func controllersChanged() {
        applyControlsVisibility()
    }

    // MARK: Input, every frame

    private func controllerState() -> (UInt32, CGPoint, CGPoint) {
        guard let pad = GCController.current?.extendedGamepad ?? GCController.controllers().first?.extendedGamepad else {
            return (0, .zero, .zero)
        }
        var mask: UInt32 = 0
        let map: [(GCControllerButtonInput?, N3DSKey)] = [
            (pad.buttonA, .b), (pad.buttonB, .a), (pad.buttonX, .y), (pad.buttonY, .x),
            (pad.leftShoulder, .l), (pad.rightShoulder, .r), (pad.leftTrigger, .zl), (pad.rightTrigger, .zr),
            (pad.buttonMenu, .start), (pad.buttonOptions, .select), (pad.dpad.up, .up), (pad.dpad.down, .down),
            (pad.dpad.left, .left), (pad.dpad.right, .right),
        ]
        for (input, key) in map where input?.isPressed == true { mask |= key.rawValue }
        // the guide button opens Hinoki's menu, not the 3DS HOME menu
        if pad.buttonHome?.isPressed == true, !menuOpen {
            DispatchQueue.main.async { [weak self] in self?.showMenu() }
        }
        // clicking the right stick: fast forward on / off
        let rightClick = pad.rightThumbstickButton?.isPressed == true
        if rightClick && !rightStickClickWasDown {
            DispatchQueue.main.async { [weak self] in self?.toggleFastForward() }
        }
        rightStickClickWasDown = rightClick
        let left = CGPoint(x: CGFloat(pad.leftThumbstick.xAxis.value), y: CGFloat(pad.leftThumbstick.yAxis.value))
        let right = CGPoint(x: CGFloat(pad.rightThumbstick.xAxis.value), y: CGFloat(pad.rightThumbstick.yAxis.value))
        return (mask, left, right)
    }

    private var perfTicks = 0

    @objc private func tick() {
        let (padMask, padLeft, padRight) = controllerState()
        v3k_n3ds_set_buttons(touchMask | dpadMask | padMask)
        let circleX = abs(padLeft.x) + abs(padLeft.y) > 0.05 ? padLeft : circleStick
        v3k_n3ds_set_stick(0, Float(circleX.x), Float(circleX.y))
        let c = abs(padRight.x) + abs(padRight.y) > 0.05 ? padRight : cStickTouch
        v3k_n3ds_set_stick(1, Float(c.x), Float(c.y))

        // the counter: four times a second is plenty (formatting it every frame cost for nothing)
        perfTicks &+= 1
        if !fpsLabel.isHidden && perfTicks % 15 == 0 {
            var fps = 0.0, speed = 0.0
            v3k_n3ds_perf(&fps, &speed)
            fpsLabel.text = String(format: "%.0f FPS · %.0f%%", fps, speed) + (fastForward ? " · »" : "") + (cooledDown ? " · cooling" : "")
        }
    }

    private func touch(_ phase: Int32, _ point: CGPoint) {
        guard running else { return }
        let scale = gameView.metalLayer.contentsScale
        v3k_n3ds_touch(phase, Float(point.x * scale), Float(point.y * scale))
    }

    private func startMotion() {
        guard N3DSSettings.motionControls, motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            // 3DS axes: x to the left of the d-pad, y out of the screen, z up the d-pad
            let g = data.gravity, a = data.userAcceleration, r = data.rotationRate
            let ax = g.x + a.x, ay = g.y + a.y, az = g.z + a.z
            let degrees = 180 / Double.pi
            let orientation = view.window?.windowScene?.interfaceOrientation ?? .landscapeRight
            let (x, z, rx, rz): (Double, Double, Double, Double)
            switch orientation {
            case .landscapeRight: (x, z, rx, rz) = (ay, ax, r.y, r.x)
            case .landscapeLeft: (x, z, rx, rz) = (-ay, -ax, -r.y, -r.x)
            default: (x, z, rx, rz) = (-ax, ay, -r.x, r.y)
            }
            v3k_n3ds_set_motion(Float(rx * degrees), Float(r.z * degrees), Float(rz * degrees), Float(x), Float(az), Float(z))
        }
    }

    // MARK: Fast forward, screens, heat

    @objc private func toggleFastForward() {
        guard running else { return }
        fastForward.toggle()
        v3k_n3ds_set_fast_forward(fastForward, Int32(N3DSSettings.fastForwardSpeed))
        fastButton.isOn = fastForward
        let speed = N3DSSettings.fastForwardSpeed
        showToast(fastForward ? (speed == 0 ? "Fast forward: as fast as possible" : "Fast forward: \(speed)%") : "Normal speed")
    }

    @objc private func swapScreens() {
        if hinokiLayout {
            bottomScreenBig.toggle()
            UIView.animate(withDuration: 0.2) {
                self.view.setNeedsLayout()
                self.view.layoutIfNeeded()
            }
        } else {
            N3DSSettings.set("swap_screen", N3DSSettings.value("swap_screen") == "1" ? "0" : "1")
        }
    }

    private func nextLayout() {
        let order = N3DSSettings.landscapeLayouts.map(\.0)
        let current = N3DSSettings.landscapeLayout
        let next = order[((order.firstIndex(of: current) ?? 0) + 1) % order.count]
        N3DSSettings.landscapeLayout = next
        if next != "hinoki" {
            v3k_n3ds_set_setting("swap_screen", N3DSSettings.value("swap_screen"))
        }
        lastLayoutSent = ""
        view.setNeedsLayout()
        view.layoutIfNeeded()
        showToast(L(N3DSSettings.landscapeLayouts.first { $0.0 == next }?.1 ?? ""))
    }

    /// Hot phone: 1x resolution until it cools down (Settings › 3DS › Cool down when hot)
    @objc private func thermalChanged() {
        DispatchQueue.main.async { [weak self] in self?.applyThermalState() }
    }

    private func applyThermalState() {
        guard running, N3DSSettings.coolDown else { return }
        let hot = ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
        let chosen = N3DSSettings.value("resolution_factor")
        if hot && !cooledDown && chosen != "1" {
            cooledDown = true
            v3k_n3ds_set_setting("resolution_factor", "1")
            showToast(L("The phone is hot: lower resolution until it cools down"))
        } else if !hot && cooledDown && ProcessInfo.processInfo.thermalState == .nominal {
            cooledDown = false
            v3k_n3ds_set_setting("resolution_factor", chosen)
            showToast("Cooled down: resolution back to \(chosen)×")
        }
    }

    // MARK: Session

    /// UI preview harness only (.ci/ui-preview): lay the controls out without starting a game
    static var layoutPreview = false

    private func boot() {
        guard !booted, !Self.layoutPreview else { return }
        booted = true
        startedAt = Date()
        N3DSSettings.sendAll()
        // no JIT: the interpreter (slow, but it runs)
        v3k_n3ds_set_setting("use_cpu_jit", jit && N3DSSettings.value("use_cpu_jit") == "1" ? "1" : "0")
        // The shader JIT writes code too: the shader interpreter without JIT
        v3k_n3ds_set_setting("use_shader_jit", jit && N3DSSettings.value("use_shader_jit") == "1" ? "1" : "0")
        lastLayoutSent = ""
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let size = gameView.metalLayer.drawableSize
        lastSize = size
        lastPortrait = isPortrait
        let context = Unmanaged.passRetained(self).toOpaque()
        let ok = v3k_n3ds_boot(app.titleId, Unmanaged.passUnretained(gameView.metalLayer).toOpaque(), Int32(size.width), Int32(size.height),
                               Float(gameView.metalLayer.contentsScale), isPortrait, { context, kind, a, b, text in
            guard let context else { return }
            let message = text.map { String(cString: $0) }
            let controller = Unmanaged<N3DSGameViewController>.fromOpaque(context)
            let owned = kind == 4 // stopped: the last event, releases the controller
            let target = owned ? controller.takeRetainedValue() : controller.takeUnretainedValue()
            DispatchQueue.main.async { target.event(kind, a, b, message) }
        }, context)
        if !ok {
            Unmanaged<N3DSGameViewController>.fromOpaque(context).release()
            finish(message: L("The game could not start."))
            return
        }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // 3DS games run at 60: on a 120 Hz iPad (ProMotion) the input poll would wake twice as often
        // and hold the screen at 120 Hz for nothing
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
        startMotion()
    }

    private func event(_ kind: Int32, _ a: Int32, _ b: Int32, _ text: String?) {
        switch kind {
        case 1:
            let stages = ["Preparing", "Loading shaders", "Loading shaders", "Building shaders", "Starting"]
            let stage = Int(a) < stages.count ? stages[Int(a)] : "Loading"
            loadingLabel.text = b > 0 && b < 100 ? "\(stage)… \(b)%" : "\(stage)…"
        case 2:
            running = true
            if !UserDefaults.standard.bool(forKey: "n3ds.controlsTipShown2") {
                UserDefaults.standard.set(true, forKey: "n3ds.controlsTipShown2")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.showToast(L("Tip: slide your thumb between A B X Y; between two of them presses both. ☰ › Edit controls moves and resizes"))
                }
            }
            UIView.animate(withDuration: 0.25) {
                self.loadingLabel.alpha = 0
                self.loadingSpinner.alpha = 0
            }
            applyThermalState()
            if !jit {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.showToast(L("No JIT: playing in the interpreter, so slower. Turn JIT on for full speed."))
                }
            }
        case 3:
            if let text, !errorShown {
                errorShown = true
                lastError = text
                if running { showToast(text) }
            }
        case 4:
            finish(message: a == 0 ? nil : lastError)
        case 5:
            let slot = b == 0 ? "the quick slot" : "slot \(b)"
            if let text {
                showToast(text)
            } else {
                showToast(a == 0 ? "Saved to \(slot)" : "Loaded \(slot)")
                if N3DSSettings.haptics { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            }
        case 6:
            if let text { showKeyboard(text) }
        default:
            break
        }
    }

    private var lastError: String?

    // MARK: Text input (the game's own keyboard: naming a Mii, a save, a message)

    /// What the game asked for (hinoki_azahar.h, AZH_EVENT_KEYBOARD)
    fileprivate struct KeyboardRequest: Decodable {
        let type: String
        let buttons: [String]
        let hint: String
        let text: String
        let error: String
        let max: Int
        /// At most this many digits, -1 when the game doesn't limit them
        let digits: Int
        let multiline: Bool
        let accept: String
        let noAt: Bool
        let noPercent: Bool
        let noBackslash: Bool
    }

    fileprivate var keyboardRequest: KeyboardRequest?
    fileprivate var keyboardAlert: UIAlertController?

    /// The game opened its keyboard: iOS's own keyboard on a text prompt. The game keeps running behind it;
    /// the answer goes back with the button pressed (0 left ... the last one is Ok), and when the game
    /// doesn't take the text (blank, too long...) it comes back here once more with the reason.
    private func showKeyboard(_ json: String) {
        guard let data = json.data(using: .utf8), let request = try? JSONDecoder().decode(KeyboardRequest.self, from: data), !request.buttons.isEmpty else {
            v3k_n3ds_keyboard_result("", 0) // the game must never be left waiting
            return
        }
        keyboardRequest = request
        releaseTouchControls()
        let alert = UIAlertController(title: request.hint.isEmpty ? L("Enter text") : request.hint,
                                      message: request.error.isEmpty ? nil : L(request.error), preferredStyle: .alert)
        alert.addTextField { [weak self] field in
            field.text = request.text
            field.delegate = self
            field.returnKeyType = .done
            field.clearButtonMode = .whileEditing
            field.autocorrectionType = .no
            field.autocapitalizationType = request.type == "numpad" ? .none : .words
            field.smartQuotesType = .no
            field.smartDashesType = .no
            switch request.type {
            case "numpad": field.keyboardType = .numberPad
            case "qwerty", "western": field.keyboardType = .asciiCapable
            default: field.keyboardType = .default
            }
        }
        let last = request.buttons.count - 1
        for (index, title) in request.buttons.enumerated() {
            let cancel = last > 0 && index == 0
            let action = UIAlertAction(title: title, style: cancel ? .cancel : .default) { [weak self] _ in
                self?.finishKeyboard(button: index)
            }
            alert.addAction(action)
            if index == last { alert.preferredAction = action }
        }
        let show = { [weak self] in
            guard let self else { return }
            keyboardAlert = alert
            let presenter = N3DSLauncher.topController() ?? self
            presenter.present(alert, animated: true)
        }
        if let old = keyboardAlert, old.presentingViewController != nil {
            old.dismiss(animated: false, completion: show)
        } else {
            show()
        }
    }

    /// The player pressed a button (or Done on the keyboard): the text and the button go to the game
    fileprivate func finishKeyboard(button: Int, dismissing alert: UIAlertController? = nil) {
        let text = keyboardAlert?.textFields?.first?.text ?? ""
        keyboardAlert = nil
        keyboardRequest = nil
        alert?.dismiss(animated: true)
        v3k_n3ds_keyboard_result(text, Int32(button))
    }

    private func showToast(_ text: String) {
        view.subviews.filter { $0 is PaddedLabel }.forEach { $0.removeFromSuperview() }
        let label = PaddedLabel()
        label.text = text
        label.numberOfLines = 0
        label.textColor = .white
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        label.layer.cornerRadius = 12
        label.clipsToBounds = true
        let width = min(view.bounds.width - 40, 420)
        let size = label.sizeThatFits(CGSize(width: width, height: 200))
        label.frame = CGRect(x: (view.bounds.width - size.width) / 2, y: max(view.safeAreaInsets.top, 8) + 40, width: size.width, height: size.height)
        view.addSubview(label)
        UIView.animate(withDuration: 0.3, delay: 2.6, options: []) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
    }

    private var finished = false

    private func finish(message: String?) {
        guard !finished else { return }
        finished = true
        keyboardAlert?.dismiss(animated: false)
        keyboardAlert = nil
        keyboardRequest = nil
        displayLink?.invalidate()
        displayLink = nil
        motion.stopDeviceMotionUpdates()
        UIApplication.shared.isIdleTimerDisabled = false
        v3k_n3ds_session_ended(app.titleId, Date().timeIntervalSince(startedAt))
        let end = onEnd
        let title = app.title
        dismiss(animated: true) {
            end()
            if let message, let presenter = N3DSLauncher.topController() {
                let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L("OK"), style: .default))
                presenter.present(alert, animated: true)
            }
        }
    }

    private func quit() {
        if running || booted {
            loadingLabel.text = "Closing…"
            loadingLabel.alpha = 1
            v3k_n3ds_stop()
        } else {
            finish(message: nil)
        }
    }

    @objc private func appInactive() {
        if running { v3k_n3ds_set_paused(true) }
        releaseTouchControls()
    }

    @objc private func appActive() {
        if running && !menuOpen { v3k_n3ds_set_paused(false) }
    }

    // MARK: Menu

    @objc private func showMenu() {
        guard !menuOpen else { return }
        menuOpen = true
        releaseTouchControls()
        if running { v3k_n3ds_set_paused(true) }
        let sheet = UIAlertController(title: app.title, message: L("Paused"), preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: L("Resume"), style: .cancel) { [weak self] _ in self?.closeMenu() })
        if running {
            sheet.addAction(UIAlertAction(title: L("Quick save"), style: .default) { [weak self] _ in
                _ = v3k_n3ds_save_state(0)
                self?.closeMenu()
            })
            let quick = saveStates().first { $0.slot == 0 }
            let quickLoad = UIAlertAction(title: L("Quick load"), style: .default) { [weak self] _ in
                _ = v3k_n3ds_load_state(0)
                self?.closeMenu()
            }
            quickLoad.isEnabled = quick != nil
            sheet.addAction(quickLoad)
            sheet.addAction(UIAlertAction(title: L("Save state…"), style: .default) { [weak self] _ in self?.showStates(saving: true) })
            sheet.addAction(UIAlertAction(title: L("Load state…"), style: .default) { [weak self] _ in self?.showStates(saving: false) })
            sheet.addAction(UIAlertAction(title: fastForward ? L("Normal speed") : L("Fast forward"), style: .default) { [weak self] _ in
                self?.closeMenu()
                self?.toggleFastForward()
            })
        }
        sheet.addAction(UIAlertAction(title: L("Swap screens"), style: .default) { [weak self] _ in
            self?.swapScreens()
            self?.closeMenu()
        })
        sheet.addAction(UIAlertAction(title: L("Screen layout…"), style: .default) { [weak self] _ in self?.showLayoutPicker() })
        sheet.addAction(UIAlertAction(title: L("Edit controls (move and resize)"), style: .default) { [weak self] _ in
            self?.menuOpen = false
            self?.beginEditingControls()
        })
        sheet.addAction(UIAlertAction(title: controlsHidden ? L("Show touch controls") : L("Hide touch controls"), style: .default) { [weak self] _ in
            guard let self else { return }
            setControlsHidden(!controlsHidden)
            closeMenu()
        })
        sheet.addAction(UIAlertAction(title: L("HOME Menu button"), style: .default) { [weak self] _ in
            guard let self else { return }
            closeMenu()
            touchMask |= N3DSKey.home.rawValue
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.touchMask &= ~N3DSKey.home.rawValue }
        })
        sheet.addAction(UIAlertAction(title: L("Quit game"), style: .destructive) { [weak self] _ in
            self?.menuOpen = false
            self?.quit()
        })
        present(sheet: sheet)
    }

    private func present(sheet: UIAlertController) {
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = menuButton
            popover.sourceRect = menuButton.bounds
        }
        present(sheet, animated: true)
    }

    private struct SaveStateInfo: Decodable {
        let slot: Int
        let time: Double
        let ok: Bool
    }

    private func saveStates() -> [SaveStateInfo] {
        guard let json = takeString(v3k_n3ds_save_states_json()), let data = json.data(using: .utf8),
              let states = try? JSONDecoder().decode([SaveStateInfo].self, from: data) else { return [] }
        return states
    }

    /// Slots 1...8 with when each was saved
    private func showStates(saving: Bool) {
        let states = saveStates()
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let sheet = UIAlertController(title: saving ? L("Save state") : L("Load state"),
                                      message: saving ? "Saving over a slot replaces it." : "Unsaved progress since then is lost.", preferredStyle: .actionSheet)
        for slot in 1...8 {
            let state = states.first { $0.slot == slot }
            var title = "Slot \(slot): "
            if let state {
                title += formatter.string(from: Date(timeIntervalSince1970: state.time))
                if !state.ok { title += " (older version)" }
            } else {
                title += "empty"
            }
            let action = UIAlertAction(title: title, style: .default) { [weak self] _ in
                _ = saving ? v3k_n3ds_save_state(Int32(slot)) : v3k_n3ds_load_state(Int32(slot))
                self?.closeMenu()
            }
            action.isEnabled = saving || (state?.ok ?? false)
            sheet.addAction(action)
        }
        sheet.addAction(UIAlertAction(title: L("Back"), style: .cancel) { [weak self] _ in
            self?.menuOpen = false
            self?.showMenu()
        })
        present(sheet: sheet)
    }

    private func closeMenu() {
        menuOpen = false
        if running { v3k_n3ds_set_paused(false) }
    }
}

/// A label with room around its text (toasts)
final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.insetBy(dx: 12, dy: 8))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let inner = super.sizeThatFits(CGSize(width: size.width - 24, height: size.height - 16))
        return CGSize(width: inner.width + 24, height: inner.height + 16)
    }
}

/// Edit controls: every group outlined; drag one to move it, pinch to resize it. Done keeps the
/// changes for this screen layout (and orientation), Reset puts everything back.
final class N3DSControlEditor: UIView, UIGestureRecognizerDelegate {
    private weak var owner: N3DSGameViewController?
    private var outlines: [N3DSGameViewController.ControlGroup: CAShapeLayer] = [:]
    private let bar = UIStackView()
    private var dragging: N3DSGameViewController.ControlGroup?
    private var dragStart = N3DSGameViewController.Placement()
    private var pinching: N3DSGameViewController.ControlGroup?
    private var pinchStart: CGFloat = 1
    private var last: N3DSGameViewController.ControlGroup?

    init(owner: N3DSGameViewController) {
        self.owner = owner
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.3)
        for group in N3DSGameViewController.ControlGroup.allCases {
            let outline = CAShapeLayer()
            outline.fillColor = UIColor.white.withAlphaComponent(0.08).cgColor
            outline.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
            outline.lineDashPattern = [6, 4]
            outline.lineWidth = 1.5
            layer.addSublayer(outline)
            outlines[group] = outline
        }
        let hint = UILabel()
        hint.text = "Drag to move · pinch to resize"
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = .white
        [hint, button("Reset", #selector(reset), filled: false), button("Cancel", #selector(cancel), filled: false),
         button("Done", #selector(done), filled: true)].forEach { bar.addArrangedSubview($0) }
        bar.axis = .horizontal
        bar.spacing = 10
        bar.alignment = .center
        bar.isLayoutMarginsRelativeArrangement = true
        bar.layoutMargins = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 6)
        bar.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        bar.layer.cornerRadius = 20
        addSubview(bar)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pan.delegate = self
        pinch.delegate = self
        addGestureRecognizer(pan)
        addGestureRecognizer(pinch)
    }

    required init?(coder: NSCoder) { fatalError() }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private func button(_ title: String, _ action: Selector, filled: Bool) -> UIButton {
        var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        config.title = title
        config.cornerStyle = .capsule
        config.buttonSize = .small
        if filled { config.baseBackgroundColor = Theme.accentUIColor }
        let button = UIButton(configuration: config)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        bar.frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - 20, width: size.width, height: max(size.height, 40))
        refresh()
    }

    func refresh() {
        guard let owner else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (group, outline) in outlines {
            let box = owner.groupFrame(group)
            outline.path = box.isNull ? nil : UIBezierPath(roundedRect: box.insetBy(dx: -6, dy: -6), cornerRadius: 12).cgPath
            outline.strokeColor = (group == dragging || group == pinching ? Theme.accentUIColor : UIColor.white.withAlphaComponent(0.85)).cgColor
        }
        CATransaction.commit()
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard let owner else { return }
        switch recognizer.state {
        case .began:
            dragging = owner.group(at: recognizer.location(in: self))
            last = dragging ?? last
            if let dragging { dragStart = owner.placement(dragging) }
        case .changed:
            guard let dragging, pinching == nil else { return }
            let move = recognizer.translation(in: self)
            var placement = dragStart
            placement.dx += move.x / max(bounds.width, 1)
            placement.dy += move.y / max(bounds.height, 1)
            owner.setPlacement(placement, for: dragging)
        default:
            dragging = nil
        }
        refresh()
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        guard let owner else { return }
        switch recognizer.state {
        case .began:
            pinching = owner.group(at: recognizer.location(in: self)) ?? last
            if let pinching { pinchStart = owner.placement(pinching).scale }
        case .changed:
            guard let pinching else { return }
            var placement = owner.placement(pinching)
            placement.scale = min(max(pinchStart * recognizer.scale, 0.6), 1.8)
            owner.setPlacement(placement, for: pinching)
        default:
            pinching = nil
        }
        refresh()
    }

    @objc private func reset() {
        owner?.resetPlacements()
        refresh()
    }

    @objc private func cancel() { owner?.endEditingControls(save: false) }
    @objc private func done() { owner?.endEditingControls(save: true) }
}

/// The game's keyboard prompt: the game's own limits, applied while typing
extension N3DSGameViewController: UITextFieldDelegate {
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard let request = keyboardRequest else { return true }
        let proposed = ((textField.text ?? "") as NSString).replacingCharacters(in: range, with: string)
        if request.noAt && string.contains("@") { return false }
        if request.noPercent && string.contains("%") { return false }
        if request.noBackslash && string.contains("\\") { return false }
        // the 3DS counts UTF-16 units, like NSString
        if request.max > 0 && (proposed as NSString).length > request.max { return false }
        if request.digits >= 0 && proposed.filter({ $0.isASCII && $0.isWholeNumber }).count > request.digits { return false }
        return true
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard let alert = keyboardAlert, let request = keyboardRequest else { return true }
        finishKeyboard(button: request.buttons.count - 1, dismissing: alert)
        return false
    }
}
