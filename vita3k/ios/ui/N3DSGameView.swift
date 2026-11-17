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
        "enable_audio_stretching": "1", "shaders_accurate_mul": "1", "custom_textures": "0",
        "async_presentation": "1", "disable_right_eye_render": "1",
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
        v3k_n3ds_set_setting("layout_option", landscapeLayout == "hinoki" ? "6" : landscapeLayout)
    }

    /// Landscape screen layout: "hinoki" (the screens between two columns of controls), or one of
    /// Azahar's: "0" stacked, "1" one screen, "2" large top screen, "3" side by side, "5" hybrid
    static var landscapeLayout: String {
        get {
            if let chosen = UserDefaults.standard.string(forKey: "n3ds.screenLayout") { return chosen }
            // Before Hinoki's layout: the Azahar layout picked in Settings (4 was a wrong value for hybrid)
            if let old = UserDefaults.standard.string(forKey: "n3ds.layout_option") { return old == "4" ? "5" : old }
            return "hinoki"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "n3ds.screenLayout")
            UserDefaults.standard.set(newValue == "hinoki" ? "6" : newValue, forKey: "n3ds.layout_option")
            v3k_n3ds_set_setting("layout_option", newValue == "hinoki" ? "6" : newValue)
        }
    }

    static let landscapeLayouts: [(String, String)] = [
        ("hinoki", "Screens between the controls"), ("2", "Large top screen"), ("3", "Side by side"),
        ("0", "Stacked"), ("5", "Hybrid"), ("1", "One screen"),
    ]

    private static func double(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    static var controlsOpacity: Double { double("n3ds.controlsOpacity", 0.9) }
    static var controlsScale: Double { double("n3ds.controlsScale", 1.0) }
    static var hideControlsWithController: Bool { bool("n3ds.hideWithController", true) }
    static var haptics: Bool { bool("n3ds.haptics", true) }
    static var motionControls: Bool { bool("n3ds.motion", true) }
    static var floatingStick: Bool { bool("n3ds.floatingStick", false) }
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

    private func mask(at point: CGPoint) -> UInt32 {
        let dx = point.x - bounds.midX, dy = point.y - bounds.midY
        let dead = min(bounds.width, bounds.height) * 0.1
        if hypot(dx, dy) < dead { return 0 }
        let angle = atan2(dy, dx) // 0 = right, pi/2 = down
        let sector = Int(((angle + .pi * 2 + .pi / 8).truncatingRemainder(dividingBy: .pi * 2)) / (.pi / 4))
        switch sector {
        case 0: return N3DSKey.right.rawValue
        case 1: return N3DSKey.right.rawValue | N3DSKey.down.rawValue
        case 2: return N3DSKey.down.rawValue
        case 3: return N3DSKey.down.rawValue | N3DSKey.left.rawValue
        case 4: return N3DSKey.left.rawValue
        case 5: return N3DSKey.left.rawValue | N3DSKey.up.rawValue
        case 6: return N3DSKey.up.rawValue
        default: return N3DSKey.up.rawValue | N3DSKey.right.rawValue
        }
    }

    private var current: UInt32 = 0

    private func report(_ value: UInt32) {
        if value != current, value != 0, N3DSSettings.haptics { UISelectionFeedbackGenerator().selectionChanged() }
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
    private var hinokiLayout: Bool { !isPortrait && N3DSSettings.landscapeLayout == "hinoki" }

    // MARK: Layout

    /// Hinoki's landscape layout: the big screen centred between the two columns of controls, the
    /// other small in the right column (phones), or both stacked in the middle when there's height for
    /// it (iPad). In the view's points.
    private struct ScreenPlan {
        var top: CGRect
        var bottom: CGRect
        var mini: CGRect? // the small screen (tap to swap), phones only
        var gutter: CGFloat
    }

    private func screenPlan(bounds: CGRect, safe: UIEdgeInsets, unit: CGFloat) -> ScreenPlan {
        let width = bounds.width, height = bounds.height
        let gutter = min(max(width * 0.19, 118), 210) * CGFloat(min(max(N3DSSettings.controlsScale, 0.8), 1.25))
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
            if hinokiLayout { plan = screenPlan(bounds: bounds, safe: safe, unit: controlUnit) }
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

    /// Landscape: a column of controls on each side (outside the screens in Hinoki's layout). Portrait:
    /// everything below the screens.
    private func layoutControls(plan: ScreenPlan?) {
        let bounds = view.bounds, safe = view.safeAreaInsets
        let u = controlUnit
        let newMode = N3DSSettings.value("is_new_3ds") == "1"
        var circleFrame = CGRect.zero

        if isPortrait {
            let left = safe.left + 16 * u, right = bounds.width - safe.right - 16 * u
            let bottom = bounds.height - max(safe.bottom, 10) - 8 * u
            let top = gameView.frame.maxY + 8 * u
            let face = 54 * u, stick = 108 * u, dpadSize = 124 * u, small = 30 * u
            let shoulderW = 62 * u, shoulderH = 36 * u // room for the icon buttons between them
            place(.l, CGRect(x: left, y: top, width: shoulderW, height: shoulderH))
            place(.zl, CGRect(x: left + shoulderW + 8 * u, y: top, width: shoulderW * 0.75, height: shoulderH))
            place(.r, CGRect(x: right - shoulderW, y: top, width: shoulderW, height: shoulderH))
            place(.zr, CGRect(x: right - shoulderW * 1.75 - 8 * u, y: top, width: shoulderW * 0.75, height: shoulderH))

            let rowY = bottom - small
            let smallW = 70 * u
            place(.select, CGRect(x: bounds.midX - smallW * 1.6, y: rowY, width: smallW, height: small))
            place(.home, CGRect(x: bounds.midX - smallW / 2, y: rowY, width: smallW, height: small))
            place(.start, CGRect(x: bounds.midX + smallW * 0.6, y: rowY, width: smallW, height: small))

            let area = CGRect(x: left, y: top + shoulderH + 10 * u, width: right - left, height: rowY - 10 * u - (top + shoulderH + 10 * u))
            // left: Circle Pad above the D-pad; right: face buttons above the C-stick
            let gap = max((area.height - stick - dpadSize) / 3, 4)
            circleFrame = CGRect(x: left + 4 * u, y: area.minY + gap, width: stick, height: stick)
            dpad.frame = CGRect(x: left, y: circleFrame.maxY + gap, width: dpadSize, height: dpadSize)
            let faceCenter = CGPoint(x: right - face * 1.55, y: area.minY + gap + face * 1.55)
            layoutFace(center: faceCenter, size: face)
            let cSize = 56 * u
            cstick.frame = CGRect(x: right - face * 1.55 - cSize / 2, y: min(faceCenter.y + face * 1.6 + gap, rowY - cSize - 8 * u), width: cSize, height: cSize)
            // the icon buttons between the shoulder buttons
            layoutIconRow(center: CGPoint(x: bounds.midX, y: top + shoulderH / 2))
            miniScreenButton.isHidden = true
        } else {
            let gutter = plan?.gutter ?? min(max(bounds.width * 0.19, 118), 210) * CGFloat(min(max(N3DSSettings.controlsScale, 0.8), 1.25))
            let leftX = max(safe.left * 0.45, 10), rightEdge = bounds.width - max(safe.right * 0.45, 10)
            let column = gutter - leftX - 8
            let top = max(safe.top, 8)
            let bottom = bounds.height - max(safe.bottom, 8)
            let shoulderH = 34 * u
            let small = 28 * u

            // shoulders: L | ZL on the left, ZR | R on the right (ZL/ZR only on a New 3DS)
            let shoulderW = newMode ? column * 0.56 : column
            place(.l, CGRect(x: leftX, y: top, width: shoulderW, height: shoulderH))
            place(.zl, CGRect(x: leftX + shoulderW + 6, y: top, width: column - shoulderW - 6, height: shoulderH))
            place(.r, CGRect(x: rightEdge - shoulderW, y: top, width: shoulderW, height: shoulderH))
            place(.zr, CGRect(x: rightEdge - column, y: top, width: column - shoulderW - 6, height: shoulderH))

            // bottom rows: SELECT and HOME on the left, START (and the C-stick) on the right
            let pillW = (column - 6) / 2
            place(.select, CGRect(x: leftX, y: bottom - small, width: pillW, height: small))
            place(.home, CGRect(x: leftX + pillW + 6, y: bottom - small, width: pillW, height: small))

            // left column: Circle Pad over the D-pad, in the space between
            let leftSpace = CGRect(x: leftX, y: top + shoulderH + 8, width: column, height: bottom - small - 8 - (top + shoulderH + 8))
            let stick = min(column * 0.95, 112 * u, leftSpace.height * 0.47)
            let dpadSize = min(column, 118 * u, leftSpace.height * 0.5)
            let leftGap = max((leftSpace.height - stick - dpadSize) / 3, 2)
            circleFrame = CGRect(x: leftX + (column - stick) / 2, y: leftSpace.minY + leftGap, width: stick, height: stick)
            dpad.frame = CGRect(x: leftX + (column - dpadSize) / 2, y: circleFrame.maxY + leftGap, width: dpadSize, height: dpadSize)

            // right column: (the small screen,) the face buttons, START with the C-stick
            var rightTop = top + shoulderH + 8
            if let mini = plan?.mini {
                miniScreenButton.isHidden = false
                miniScreenButton.frame = mini
                miniScreenButton.viewWithTag(1)?.frame = CGRect(x: mini.width - 20, y: 2, width: 18, height: 18)
                rightTop = mini.maxY + 8
            } else {
                miniScreenButton.isHidden = true
            }
            let cSize = newMode ? min(small * 1.6, column * 0.4) : 0
            let startW = newMode ? column - cSize - 8 : column * 0.6
            place(.start, CGRect(x: rightEdge - startW, y: bottom - small, width: startW, height: small))
            cstick.frame = CGRect(x: rightEdge - column, y: bottom - cSize, width: cSize, height: cSize)
            let faceBottom = bottom - max(small, cSize) - 6
            let faceSpace = faceBottom - rightTop
            let face = min(column / 3.1, 50 * u, faceSpace / 3.1)
            layoutFace(center: CGPoint(x: rightEdge - column / 2, y: rightTop + faceSpace / 2), size: face)

            // menu, fast forward and swap above the screens, in the middle
            var rowY = top + 13
            if let plan {
                let centralTop = plan.mini == nil ? min(plan.top.minY, plan.bottom.minY) : (bottomScreenBig ? plan.bottom.minY : plan.top.minY)
                if centralTop > 30 { rowY = centralTop / 2 }
            }
            layoutIconRow(center: CGPoint(x: bounds.midX, y: max(rowY, 15)))
        }

        // floating Circle Pad: a landing area around where it's drawn
        if N3DSSettings.floatingStick {
            circle.frame = circleFrame.insetBy(dx: -circleFrame.width * 0.55, dy: -circleFrame.width * 0.55).intersection(bounds)
            circle.configure(floating: true, pad: circleFrame)
        } else {
            circle.frame = circleFrame
            circle.configure(floating: false, pad: circleFrame)
        }
    }

    private func layoutFace(center: CGPoint, size face: CGFloat) {
        let offsets: [(N3DSKey, CGFloat, CGFloat)] = [(.x, 0, -1), (.a, 1, 0), (.b, 0, 1), (.y, -1, 0)]
        for (key, dx, dy) in offsets {
            place(key, CGRect(x: center.x + dx * face * 1.05 - face / 2, y: center.y + dy * face * 1.05 - face / 2, width: face, height: face))
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
        let newMode = N3DSSettings.value("is_new_3ds") == "1"
        cstick.isHidden = !newMode
        button(.zl)?.isHidden = !newMode
        button(.zr)?.isHidden = !newMode
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

    @objc private func tick() {
        let (padMask, padLeft, padRight) = controllerState()
        v3k_n3ds_set_buttons(touchMask | dpadMask | padMask)
        let circleX = abs(padLeft.x) + abs(padLeft.y) > 0.05 ? padLeft : circleStick
        v3k_n3ds_set_stick(0, Float(circleX.x), Float(circleX.y))
        let c = abs(padRight.x) + abs(padRight.y) > 0.05 ? padRight : cStickTouch
        v3k_n3ds_set_stick(1, Float(c.x), Float(c.y))

        if !fpsLabel.isHidden {
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
        showToast(N3DSSettings.landscapeLayouts.first { $0.0 == next }?.1 ?? "")
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
            showToast("The phone is hot: lower resolution until it cools down")
        } else if !hot && cooledDown && ProcessInfo.processInfo.thermalState == .nominal {
            cooledDown = false
            v3k_n3ds_set_setting("resolution_factor", chosen)
            showToast("Cooled down: resolution back to \(chosen)×")
        }
    }

    // MARK: Session

    private func boot() {
        guard !booted else { return }
        booted = true
        startedAt = Date()
        N3DSSettings.sendAll()
        // no JIT: the interpreter (slow, but it runs)
        v3k_n3ds_set_setting("use_cpu_jit", jit && N3DSSettings.value("use_cpu_jit") == "1" ? "1" : "0")
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
            finish(message: "The game could not start.")
            return
        }
        let link = CADisplayLink(target: self, selector: #selector(tick))
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
            UIView.animate(withDuration: 0.25) {
                self.loadingLabel.alpha = 0
                self.loadingSpinner.alpha = 0
            }
            applyThermalState()
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
        default:
            break
        }
    }

    private var lastError: String?

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
                alert.addAction(UIAlertAction(title: "OK", style: .default))
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
        let sheet = UIAlertController(title: app.title, message: "Paused", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Resume", style: .cancel) { [weak self] _ in self?.closeMenu() })
        if running {
            sheet.addAction(UIAlertAction(title: "Quick save", style: .default) { [weak self] _ in
                _ = v3k_n3ds_save_state(0)
                self?.closeMenu()
            })
            let quick = saveStates().first { $0.slot == 0 }
            let quickLoad = UIAlertAction(title: "Quick load", style: .default) { [weak self] _ in
                _ = v3k_n3ds_load_state(0)
                self?.closeMenu()
            }
            quickLoad.isEnabled = quick != nil
            sheet.addAction(quickLoad)
            sheet.addAction(UIAlertAction(title: "Save state…", style: .default) { [weak self] _ in self?.showStates(saving: true) })
            sheet.addAction(UIAlertAction(title: "Load state…", style: .default) { [weak self] _ in self?.showStates(saving: false) })
            sheet.addAction(UIAlertAction(title: fastForward ? "Normal speed" : "Fast forward", style: .default) { [weak self] _ in
                self?.closeMenu()
                self?.toggleFastForward()
            })
        }
        sheet.addAction(UIAlertAction(title: "Swap screens", style: .default) { [weak self] _ in
            self?.swapScreens()
            self?.closeMenu()
        })
        if !isPortrait {
            sheet.addAction(UIAlertAction(title: "Next screen layout", style: .default) { [weak self] _ in
                self?.nextLayout()
                self?.closeMenu()
            })
        }
        sheet.addAction(UIAlertAction(title: controlsHidden ? "Show touch controls" : "Hide touch controls", style: .default) { [weak self] _ in
            guard let self else { return }
            setControlsHidden(!controlsHidden)
            closeMenu()
        })
        sheet.addAction(UIAlertAction(title: "HOME Menu button", style: .default) { [weak self] _ in
            guard let self else { return }
            closeMenu()
            touchMask |= N3DSKey.home.rawValue
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.touchMask &= ~N3DSKey.home.rawValue }
        })
        sheet.addAction(UIAlertAction(title: "Quit game", style: .destructive) { [weak self] _ in
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
        let sheet = UIAlertController(title: saving ? "Save state" : "Load state",
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
        sheet.addAction(UIAlertAction(title: "Back", style: .cancel) { [weak self] _ in
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
