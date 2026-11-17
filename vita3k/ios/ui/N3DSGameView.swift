// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

// Playing a 3DS game: a full-screen view the Azahar core draws into (CAMetalLayer through MoltenVK),
// with on-screen controls laid out like a 3DS, the touch screen under your finger, controllers and
// the phone's motion sensors.

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
        "resolution_factor": "2", "layout_option": "0", "portrait_layout_option": "0", "swap_screen": "0",
        "large_screen_proportion": "4", "async_shader_compilation": "1", "use_disk_shader_cache": "1",
        "use_vsync": "1", "is_new_3ds": "1", "region_value": "-1", "cpu_clock_percentage": "100",
        "use_cpu_jit": "1", "volume": "1", "filter_mode": "1", "texture_filter": "0",
        "enable_audio_stretching": "1", "shaders_accurate_mul": "1", "custom_textures": "0",
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
        for key in defaults.keys { v3k_n3ds_set_setting(key, value(key)) }
    }

    static var controlsOpacity: Double {
        UserDefaults.standard.object(forKey: "n3ds.controlsOpacity") as? Double ?? 0.55
    }
    static var hideControlsWithController: Bool {
        UserDefaults.standard.object(forKey: "n3ds.hideWithController") as? Bool ?? true
    }
    static var haptics: Bool {
        UserDefaults.standard.object(forKey: "n3ds.haptics") as? Bool ?? true
    }
    static var motionControls: Bool {
        UserDefaults.standard.object(forKey: "n3ds.motion") as? Bool ?? true
    }
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

/// A round or pill button that reports pressed / released
final class N3DSPadButton: UIView {
    let key: N3DSKey
    var changed: ((N3DSKey, Bool) -> Void)?
    private let label = UILabel()
    private var touchCount = 0
    private let fill: UIColor

    init(_ key: N3DSKey, title: String, color: UIColor = .white, fontSize: CGFloat = 18) {
        self.key = key
        fill = color
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        label.text = title
        label.font = .systemFont(ofSize: fontSize, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        addSubview(label)
        layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        layer.borderWidth = 1.5
        update(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    private func update(_ pressed: Bool) {
        backgroundColor = pressed ? fill.withAlphaComponent(0.85) : fill.withAlphaComponent(fill == .white ? 0.12 : 0.35)
        transform = pressed ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
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

/// The D-pad: one touch area, eight directions
final class N3DSDpad: UIView {
    var changed: ((UInt32) -> Void)?
    private var touch: UITouch?
    private var arms: [CAShapeLayer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        for _ in 0..<4 {
            let arm = CAShapeLayer()
            arm.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
            arm.lineWidth = 1.5
            layer.addSublayer(arm)
            arms.append(arm)
        }
        highlight(0)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = bounds.width, w = s / 3
        let rects = [CGRect(x: w, y: 0, width: w, height: w * 1.05), CGRect(x: w, y: s - w * 1.05, width: w, height: w * 1.05),
                     CGRect(x: 0, y: w, width: w * 1.05, height: w), CGRect(x: s - w * 1.05, y: w, width: w * 1.05, height: w)]
        for (arm, rect) in zip(arms, rects) {
            arm.path = UIBezierPath(roundedRect: rect, cornerRadius: 6).cgPath
        }
    }

    private func highlight(_ mask: UInt32) {
        let keys: [N3DSKey] = [.up, .down, .left, .right]
        for (arm, key) in zip(arms, keys) {
            arm.fillColor = UIColor.white.withAlphaComponent(mask & key.rawValue != 0 ? 0.8 : 0.12).cgColor
        }
    }

    private func mask(at point: CGPoint) -> UInt32 {
        let dx = point.x - bounds.midX, dy = point.y - bounds.midY
        let dead = bounds.width * 0.12
        var mask: UInt32 = 0
        if hypot(dx, dy) < dead { return 0 }
        let angle = atan2(dy, dx) // 0 = right, pi/2 = down
        let sector = Int(((angle + .pi * 2 + .pi / 8).truncatingRemainder(dividingBy: .pi * 2)) / (.pi / 4))
        switch sector {
        case 0: mask = N3DSKey.right.rawValue
        case 1: mask = N3DSKey.right.rawValue | N3DSKey.down.rawValue
        case 2: mask = N3DSKey.down.rawValue
        case 3: mask = N3DSKey.down.rawValue | N3DSKey.left.rawValue
        case 4: mask = N3DSKey.left.rawValue
        case 5: mask = N3DSKey.left.rawValue | N3DSKey.up.rawValue
        case 6: mask = N3DSKey.up.rawValue
        default: mask = N3DSKey.up.rawValue | N3DSKey.right.rawValue
        }
        return mask
    }

    private func report(_ value: UInt32) {
        highlight(value)
        changed?(value)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touch == nil, let first = touches.first else { return }
        touch = first
        report(mask(at: first.location(in: self)))
        if N3DSSettings.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
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

/// The Circle Pad (or the C-stick): drag anywhere inside, the knob follows
final class N3DSStick: UIView {
    var changed: ((CGFloat, CGFloat) -> Void)?
    private let knob = UIView()
    private var touch: UITouch?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.white.withAlphaComponent(0.08)
        layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
        layer.borderWidth = 1.5
        knob.backgroundColor = UIColor.white.withAlphaComponent(0.35)
        knob.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        knob.layer.borderWidth = 1.5
        knob.isUserInteractionEnabled = false
        addSubview(knob)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        let size = bounds.width * 0.5
        if touch == nil {
            knob.frame = CGRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
        }
        knob.layer.cornerRadius = size / 2
    }

    private func move(to point: CGPoint) {
        let radius = bounds.width / 2
        var dx = point.x - bounds.midX, dy = point.y - bounds.midY
        let distance = hypot(dx, dy)
        if distance > radius {
            dx *= radius / distance
            dy *= radius / distance
        }
        knob.center = CGPoint(x: bounds.midX + dx, y: bounds.midY + dy)
        changed?(dx / radius, -dy / radius)
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
        UIView.animate(withDuration: 0.12) { self.knob.center = CGPoint(x: self.bounds.midX, y: self.bounds.midY) }
        changed?(0, 0)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}

/// Passes touches that miss every control through to the game view below (the touch screen)
final class N3DSOverlay: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

// MARK: - The game screen

final class N3DSGameViewController: UIViewController {
    private let app: GameApp
    private let jit: Bool
    private let onEnd: () -> Void

    private let gameView = N3DSMetalView()
    private let overlay = N3DSOverlay()
    private let menuButton = UIButton(type: .system)
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
        view.addSubview(overlay)
        buildControls()

        menuButton.setImage(UIImage(systemName: "line.3.horizontal.circle.fill"), for: .normal)
        menuButton.tintColor = UIColor.white.withAlphaComponent(0.8)
        menuButton.addTarget(self, action: #selector(showMenu), for: .touchUpInside)
        view.addSubview(menuButton)

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

        NotificationCenter.default.addObserver(self, selector: #selector(appInactive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllersChanged), name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllersChanged), name: .GCControllerDidDisconnect, object: nil)
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        if isPortrait {
            // the two screens stacked at the top (400x240 over 320x240), the controls below
            let height = min(bounds.width * 480 / 400, bounds.height * 0.62)
            gameView.frame = CGRect(x: 0, y: safe.top, width: bounds.width, height: height)
        } else {
            gameView.frame = bounds
        }
        overlay.frame = bounds
        layoutControls()
        // the menu: between the shoulder buttons in portrait, beside HOME in landscape
        if isPortrait {
            menuButton.frame = CGRect(x: bounds.midX - 22, y: gameView.frame.maxY + 6, width: 44, height: 32)
        } else if let home = button(.home)?.frame {
            menuButton.frame = CGRect(x: home.maxX + 6, y: home.midY - 16, width: 44, height: 32)
        }
        fpsLabel.frame = CGRect(x: safe.left + 8, y: max(safe.top, 6), width: 160, height: 16)
        loadingLabel.frame = CGRect(x: 20, y: gameView.frame.midY + 30, width: bounds.width - 40, height: 44)
        loadingSpinner.center = CGPoint(x: gameView.frame.midX, y: gameView.frame.midY - 10)

        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        gameView.metalLayer.contentsScale = scale
        let size = CGSize(width: gameView.bounds.width * scale, height: gameView.bounds.height * scale)
        gameView.metalLayer.drawableSize = size
        if booted && (size != lastSize || isPortrait != lastPortrait) {
            v3k_n3ds_surface_changed(Int32(size.width), Int32(size.height), Float(scale), isPortrait)
        }
        lastSize = size
        lastPortrait = isPortrait
    }

    // MARK: Controls

    private func buildControls() {
        let faceColors: [(N3DSKey, String, UIColor)] = [
            (.x, "X", UIColor(red: 0.25, green: 0.4, blue: 0.95, alpha: 1)),
            (.a, "A", UIColor(red: 0.9, green: 0.2, blue: 0.25, alpha: 1)),
            (.b, "B", UIColor(red: 0.95, green: 0.78, blue: 0.2, alpha: 1)),
            (.y, "Y", UIColor(red: 0.25, green: 0.7, blue: 0.35, alpha: 1)),
        ]
        for (key, title, color) in faceColors {
            buttons.append(N3DSPadButton(key, title: title, color: color, fontSize: 20))
        }
        for (key, title) in [(N3DSKey.l, "L"), (.r, "R"), (.zl, "ZL"), (.zr, "ZR")] {
            buttons.append(N3DSPadButton(key, title: title, fontSize: 15))
        }
        for (key, title) in [(N3DSKey.start, "START"), (.select, "SELECT"), (.home, "HOME")] {
            buttons.append(N3DSPadButton(key, title: title, fontSize: 10))
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
        overlay.addSubview(circle)
        overlay.addSubview(cstick)
        applyControlsVisibility()
    }

    private func button(_ key: N3DSKey) -> N3DSPadButton? { buttons.first { $0.key == key } }

    private func layoutControls() {
        let bounds = view.bounds, safe = view.safeAreaInsets
        let unit = min(bounds.width, bounds.height) / 390 // sized for a 390-point-wide phone
        let face = 56 * unit, stick = 112 * unit, dpadSize = 132 * unit, small = 30 * unit
        let shoulderW = 70 * unit, shoulderH = 36 * unit
        let left = safe.left + 18 * unit, right = bounds.width - safe.right - 18 * unit
        let bottom = bounds.height - max(safe.bottom, 10) - 10 * unit

        let faceCenter: CGPoint
        let dpadCenter: CGPoint
        let circleCenter: CGPoint
        if isPortrait {
            let area = gameView.frame.maxY + 40 * unit
            faceCenter = CGPoint(x: right - face * 1.6, y: max(area + face * 2.2, bottom - face * 2.4))
            circleCenter = CGPoint(x: left + stick / 2 + 6 * unit, y: max(area + stick / 2 + 4 * unit, faceCenter.y - face * 1.4))
            dpadCenter = CGPoint(x: left + dpadSize / 2 + 2 * unit, y: min(bottom - dpadSize / 2, circleCenter.y + stick / 2 + dpadSize / 2 + 8 * unit))
        } else {
            faceCenter = CGPoint(x: right - face * 1.6, y: bottom - face * 1.6)
            dpadCenter = CGPoint(x: left + dpadSize / 2, y: bottom - dpadSize / 2)
            circleCenter = CGPoint(x: left + stick / 2 + 4 * unit, y: dpadCenter.y - dpadSize / 2 - stick / 2 - 6 * unit)
        }
        let offsets: [(N3DSKey, CGFloat, CGFloat)] = [(.x, 0, -1), (.a, 1, 0), (.b, 0, 1), (.y, -1, 0)]
        for (key, dx, dy) in offsets {
            button(key)?.frame = CGRect(x: faceCenter.x + dx * face * 1.05 - face / 2, y: faceCenter.y + dy * face * 1.05 - face / 2, width: face, height: face)
        }
        dpad.frame = CGRect(x: dpadCenter.x - dpadSize / 2, y: dpadCenter.y - dpadSize / 2, width: dpadSize, height: dpadSize)
        circle.frame = CGRect(x: circleCenter.x - stick / 2, y: circleCenter.y - stick / 2, width: stick, height: stick)
        let cSize = stick * 0.55
        cstick.frame = CGRect(x: faceCenter.x - cSize / 2, y: faceCenter.y - face * 2.9 - cSize / 2, width: cSize, height: cSize)

        let top = isPortrait ? gameView.frame.maxY + 8 * unit : max(safe.top, 8) + 6 * unit
        button(.l)?.frame = CGRect(x: left, y: top, width: shoulderW, height: shoulderH)
        button(.zl)?.frame = CGRect(x: left + shoulderW + 8 * unit, y: top, width: shoulderW * 0.8, height: shoulderH)
        button(.r)?.frame = CGRect(x: right - shoulderW, y: top, width: shoulderW, height: shoulderH)
        button(.zr)?.frame = CGRect(x: right - shoulderW * 1.8 - 8 * unit, y: top, width: shoulderW * 0.8, height: shoulderH)

        let smallW = 64 * unit
        let rowY = bottom - small
        if isPortrait {
            button(.select)?.frame = CGRect(x: bounds.midX - smallW * 1.6, y: rowY, width: smallW, height: small)
            button(.home)?.frame = CGRect(x: bounds.midX - smallW / 2, y: rowY, width: smallW, height: small)
            button(.start)?.frame = CGRect(x: bounds.midX + smallW * 0.6, y: rowY, width: smallW, height: small)
        } else {
            // in the margins beside the screens: Start and Select under R, HOME under L
            let below = top + shoulderH + 12 * unit
            button(.start)?.frame = CGRect(x: right - smallW, y: below, width: smallW, height: small)
            button(.select)?.frame = CGRect(x: right - smallW, y: below + small + 8 * unit, width: smallW, height: small)
            button(.home)?.frame = CGRect(x: left, y: below, width: smallW, height: small)
        }
    }

    private var controllerConnected: Bool { GCController.current?.extendedGamepad != nil || GCController.controllers().contains { $0.extendedGamepad != nil } }

    private func applyControlsVisibility() {
        let hidden = controllerConnected && N3DSSettings.hideControlsWithController
        overlay.isHidden = hidden
        overlay.alpha = CGFloat(N3DSSettings.controlsOpacity)
        cstick.isHidden = N3DSSettings.value("is_new_3ds") != "1"
        button(.zl)?.isHidden = N3DSSettings.value("is_new_3ds") != "1"
        button(.zr)?.isHidden = N3DSSettings.value("is_new_3ds") != "1"
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
            fpsLabel.text = String(format: "%.0f FPS · %.0f%%", fps, speed)
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

    // MARK: Session

    private func boot() {
        guard !booted else { return }
        booted = true
        startedAt = Date()
        N3DSSettings.sendAll()
        // no JIT: the interpreter (slow, but it runs)
        v3k_n3ds_set_setting("use_cpu_jit", jit && N3DSSettings.value("use_cpu_jit") == "1" ? "1" : "0")
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
        case 3:
            if let text, !errorShown {
                errorShown = true
                lastError = text
                if !running {
                    // a boot failure: STOPPED follows with the reason shown then
                } else {
                    showToast(text)
                }
            }
        case 4:
            finish(message: a == 0 ? nil : lastError)
        default:
            break
        }
    }

    private var lastError: String?

    private func showToast(_ text: String) {
        let label = PaddedLabel()
        label.text = text
        label.numberOfLines = 0
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        let width = min(view.bounds.width - 40, 420)
        let size = label.sizeThatFits(CGSize(width: width, height: 200))
        label.frame = CGRect(x: (view.bounds.width - size.width) / 2, y: view.safeAreaInsets.top + 44, width: size.width, height: size.height)
        view.addSubview(label)
        UIView.animate(withDuration: 0.3, delay: 5, options: []) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
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
    }

    @objc private func appActive() {
        if running && !menuOpen { v3k_n3ds_set_paused(false) }
    }

    // MARK: Menu

    @objc private func showMenu() {
        guard !menuOpen else { return }
        menuOpen = true
        if running { v3k_n3ds_set_paused(true) }
        let sheet = UIAlertController(title: app.title, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Resume", style: .cancel) { [weak self] _ in self?.closeMenu() })
        sheet.addAction(UIAlertAction(title: "Swap screens", style: .default) { [weak self] _ in
            N3DSSettings.set("swap_screen", N3DSSettings.value("swap_screen") == "1" ? "0" : "1")
            self?.closeMenu()
        })
        sheet.addAction(UIAlertAction(title: "Next screen layout", style: .default) { [weak self] _ in
            let order = ["0", "2", "3", "1", "4"] // stacked, large, side by side, single, hybrid
            let current = N3DSSettings.value("layout_option")
            let next = order[((order.firstIndex(of: current) ?? 0) + 1) % order.count]
            N3DSSettings.set("layout_option", next)
            self?.closeMenu()
        })
        sheet.addAction(UIAlertAction(title: overlay.isHidden ? "Show touch controls" : "Hide touch controls", style: .default) { [weak self] _ in
            guard let self else { return }
            overlay.isHidden.toggle()
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
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = menuButton
            popover.sourceRect = menuButton.bounds
        }
        present(sheet, animated: true)
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
