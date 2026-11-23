// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

// On-screen PS Vita controls, drawn over the game window. Each control feeds the SDL virtual gamepad
// in controls/virtual_pad.cpp, which Vita3K sees like a physical controller. Touches that miss every
// control fall through to the game, so the Vita touchscreen keeps working.

import GameController
import UIKit

// SDL_GamepadButton / SDL_GamepadAxis values
private enum Pad {
    static let cross: Int32 = 0, circle: Int32 = 1, square: Int32 = 2, triangle: Int32 = 3
    static let select: Int32 = 4, start: Int32 = 6
    static let l3: Int32 = 7, r3: Int32 = 8
    static let l: Int32 = 9, r: Int32 = 10
    static let up: Int32 = 11, down: Int32 = 12, left: Int32 = 13, right: Int32 = 14
    static let leftX: Int32 = 0, leftY: Int32 = 1, rightX: Int32 = 2, rightY: Int32 = 3
}

private func color(_ hex: UInt32) -> UIColor {
    UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// Looks of the on-screen controller (Settings > Touch controls > Theme). Only the looks change:
/// a face button always sends the Vita button in its position.
enum ControllerTheme: String, CaseIterable, Identifiable {
    case classic, playstation, xbox, nintendo, neon, minimal

    var id: String { rawValue }

    var name: String {
        switch self {
        case .classic: "Classic"
        case .playstation: "PlayStation colours"
        case .xbox: "Xbox style (A B X Y)"
        case .nintendo: "Nintendo style (A B X Y)"
        case .neon: "Neon"
        case .minimal: "Minimal"
        }
    }

    /// Label and colour of the face button at the top, right, bottom and left
    func face(_ position: Int) -> (String, UIColor) {
        switch self {
        case .classic, .minimal: return [("△", .white), ("○", .white), ("✕", .white), ("□", .white)][position]
        case .playstation: return [("△", color(0x2FD5A0)), ("○", color(0xFF5A5F)), ("✕", color(0x6FA8FF)), ("□", color(0xF48FD0))][position]
        case .xbox: return [("Y", color(0xF7C51E)), ("B", color(0xE2382F)), ("A", color(0x5BB531)), ("X", color(0x2C82E0))][position]
        case .nintendo: return [("X", color(0x3D5BD9)), ("A", color(0xE0303A)), ("B", color(0xF2C230)), ("Y", color(0x3BAA55))][position]
        case .neon: return [("△", color(0x39FFB0)), ("○", color(0xFF3FA4)), ("✕", color(0x3FD8FF)), ("□", color(0xC77DFF))][position]
        }
    }

    /// Colour of the d-pad, shoulders, sticks and small buttons
    var tint: UIColor {
        switch self {
        case .neon: color(0x3FD8FF)
        default: .white
        }
    }

    var filled: Bool { self != .minimal }
    var coloredFill: Bool { self == .playstation || self == .xbox || self == .nintendo }

    static var current: ControllerTheme {
        ControllerTheme(rawValue: UserDefaults.standard.string(forKey: "v3k.controllerTheme") ?? "") ?? .classic
    }
}

/// Touch buttons send whichever physical button the user mapped to their Vita button (Settings >
/// Controller mapping), so an on-screen ✕ is always Vita ✕
enum TouchMapping {
    static var physical: [Int32] = Array(0..<15)

    static func load() {
        if let pointer = v3k_controller_binds_json() {
            let json = String(cString: pointer)
            v3k_free_string(pointer)
            if let data = json.data(using: .utf8), let binds = try? JSONDecoder().decode([Int32].self, from: data), binds.count >= 15 {
                physical = binds
            }
        }
    }

    static func button(for slot: Int32) -> Int32 {
        slot >= 0 && Int(slot) < physical.count ? physical[Int(slot)] : slot
    }
}

/// The colour mixed towards black, for button fills that stay readable on bright backgrounds
func darkened(_ color: UIColor, by brightness: CGFloat) -> UIColor {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return UIColor(red: red * brightness, green: green * brightness, blue: blue * brightness, alpha: alpha)
}

final class PadButtonView: UIView {
    let button: Int32
    /// Set for L2 / R2 (PS TV mode): the trigger axis this button pushes all the way
    var axis: Int32?
    private let label = UILabel()
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    private var baseFill = UIColor.black.withAlphaComponent(0.62)
    private var pressedFill = UIColor.white.withAlphaComponent(0.45)
    private let haptics = UserDefaults.standard.object(forKey: "v3k.touchHaptics") as? Bool ?? true

    init(button: Int32, title: String, fontSize: CGFloat = 18, tint: UIColor = .white) {
        self.button = button
        super.init(frame: .zero)
        label.text = title
        label.font = .systemFont(ofSize: fontSize, weight: .bold)
        label.textAlignment = .center
        // A soft dark halo keeps the symbol readable over bright scenes
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.7
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = .zero
        addSubview(label)
        style(color: tint, theme: ControllerTheme.current, faceButton: false)
        layer.borderWidth = 1.5
    }

    /// Applies a controller theme: face buttons get their own colour, the rest the theme tint
    func style(title: String? = nil, color: UIColor, theme: ControllerTheme, faceButton: Bool) {
        if let title { label.text = title }
        label.textColor = color
        // Dark fills on every theme: the controls stay visible over bright scenes (skies, menus)
        if theme.coloredFill && faceButton {
            baseFill = darkened(color, by: 0.22).withAlphaComponent(0.7)
            pressedFill = color.withAlphaComponent(0.7)
        } else {
            baseFill = UIColor.black.withAlphaComponent(theme.filled ? 0.62 : 0.45)
            pressedFill = color.withAlphaComponent(0.5)
        }
        backgroundColor = baseFill
        layer.borderColor = color.withAlphaComponent(theme == .neon ? 0.9 : 0.55).cgColor
        if theme == .neon {
            layer.shadowColor = color.cgColor
            layer.shadowRadius = 6
            layer.shadowOpacity = 0.8
            layer.shadowOffset = .zero
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    private func setPressed(_ pressed: Bool) {
        if let axis {
            PadPress.trigger(axis, pressed)
        } else {
            PadPress.button(TouchMapping.button(for: button), pressed)
        }
        backgroundColor = pressed ? pressedFill : baseFill
        if pressed && haptics { feedback.impactOccurred() }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { setPressed(true) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { setPressed(false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { setPressed(false) }
}

final class StickView: UIView {
    private let xAxis: Int32
    private let yAxis: Int32
    private let base = UIView()
    private let knob = UIView()
    private var tracking = false
    /// Floating and screen-half sticks: the view is the area a thumb can land in, and the stick is
    /// drawn where it lands (fixed: the view is the stick)
    private(set) var style = StickStyle.fixed
    /// Size of the drawn stick (floating, screen halves)
    private var stickSize: CGFloat = 0
    /// Where the stick rests, in this view (floating)
    private var restCenter = CGPoint.zero
    private var origin: CGPoint?
    /// Advanced touch › mouse-style turning: the push follows the finger's speed and drops back the
    /// moment it stops (nil: a normal stick)
    private lazy var mouse: MouseLookStick? = {
        guard TouchTuning.usesMouse(rightStick: xAxis == Pad.rightX) else { return nil }
        return MouseLookStick { [weak self] x, y in
            guard let self else { return }
            v3k_pad_set_axis(self.xAxis, Float(x))
            v3k_pad_set_axis(self.yAxis, Float(y))
            self.showKnob(x, y)
        }
    }()

    init(xAxis: Int32, yAxis: Int32) {
        self.xAxis = xAxis
        self.yAxis = yAxis
        super.init(frame: .zero)
        backgroundColor = .clear
        base.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        base.layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor
        base.layer.borderWidth = 1.5
        base.isUserInteractionEnabled = false
        addSubview(base)
        knob.backgroundColor = UIColor(white: 0.32, alpha: 0.85)
        knob.layer.borderColor = UIColor.white.withAlphaComponent(0.45).cgColor
        knob.layer.borderWidth = 1
        knob.isUserInteractionEnabled = false
        addSubview(knob)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setTint(_ color: UIColor) {
        base.layer.borderColor = color.withAlphaComponent(0.35).cgColor
    }

    /// Fixed: the stick fills the view. Otherwise the view is the landing area and `stick` (in the
    /// superview) is where the stick rests.
    func configure(style: StickStyle, stick: CGRect) {
        self.style = style
        stickSize = stick.width
        restCenter = CGPoint(x: stick.midX - frame.minX, y: stick.midY - frame.minY)
        setNeedsLayout()
    }

    /// The drawn stick, in the superview (the layout editor outlines this)
    var stickFrame: CGRect {
        style == .fixed ? frame : base.frame.offsetBy(dx: frame.minX, dy: frame.minY)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = style == .fixed ? bounds.width : stickSize
        let center = origin ?? (style == .fixed ? CGPoint(x: bounds.midX, y: bounds.midY) : restCenter)
        base.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        base.center = center
        base.layer.cornerRadius = size / 2
        let knobSize = size * 0.45
        knob.bounds = CGRect(x: 0, y: 0, width: knobSize, height: knobSize)
        knob.layer.cornerRadius = knobSize / 2
        if !tracking { knob.center = center }
        // Screen halves: nothing drawn until a thumb lands
        let shown = style != .zones || tracking
        base.alpha = shown ? 1 : 0
        knob.alpha = shown ? 1 : 0
    }

    private func update(_ touch: UITouch) {
        let point = touch.location(in: self)
        if origin == nil {
            if style == .fixed {
                origin = CGPoint(x: bounds.midX, y: bounds.midY)
            } else {
                // The stick comes to the thumb, kept inside the area
                let half = stickSize / 2
                origin = CGPoint(x: min(max(point.x, half), max(bounds.width - half, half)),
                                 y: min(max(point.y, half), max(bounds.height - half, half)))
            }
            tracking = true
            setNeedsLayout()
            layoutIfNeeded()
        }
        tracking = true
        guard let center = origin else { return }
        if let mouse {
            mouse.move(to: point, time: touch.timestamp)
            return
        }
        let radius = (style == .fixed ? bounds.width : stickSize) / 2
        var dx = point.x - center.x
        var dy = point.y - center.y
        let length = sqrt(dx * dx + dy * dy)
        if length > radius {
            dx *= radius / length
            dy *= radius / length
        }
        knob.center = CGPoint(x: center.x + dx, y: center.y + dy)
        // Advanced touch › dead-zone skip (none by default)
        let (x, y) = TouchTuning.shaped(dx / radius, dy / radius)
        v3k_pad_set_axis(xAxis, Float(x))
        v3k_pad_set_axis(yAxis, Float(y))
    }

    /// Mouse-style: the knob shows the push (it isn't where the finger is)
    private func showKnob(_ x: CGFloat, _ y: CGFloat) {
        guard let center = origin else { return }
        let radius = (style == .fixed ? bounds.width : stickSize) / 2
        knob.center = CGPoint(x: center.x + x * radius, y: center.y + y * radius)
    }

    func reset() {
        mouse?.end()
        tracking = false
        origin = nil
        setNeedsLayout()
        layoutIfNeeded()
        v3k_pad_set_axis(xAxis, 0)
        v3k_pad_set_axis(yAxis, 0)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        update(t)
        mouse?.begin(at: t.location(in: self), time: t.timestamp)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { if let t = touches.first { update(t) } }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { reset() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { reset() }
}

/// Groups of touch controls the player can move and resize (in-game menu › Edit control layout)
enum ControlGroup: String, CaseIterable {
    case l, r, dpad, face, leftStick, rightStick, startSelect
    // PS TV mode only
    case l2, r2, l3, r3
    // Macro buttons the player set up
    case macro1, macro2, macro3, macro4
    // Advanced touch › move buttons one by one: each d-pad, face, Start and Select button on its own.
    // After the clusters, so a cluster's own move (made before) still applies and these add to it
    case dpadUp, dpadDown, dpadLeft, dpadRight, triangle, circle, cross, square, select, start

    /// Moved one by one (shown in the editor instead of their cluster when that's on)
    var isSingleButton: Bool {
        switch self {
        case .dpadUp, .dpadDown, .dpadLeft, .dpadRight, .triangle, .circle, .cross, .square, .select, .start: true
        default: false
        }
    }

    /// The cluster a single button belongs to
    var isCluster: Bool { self == .dpad || self == .face || self == .startSelect }
}

struct GroupPlacement: Codable, Equatable {
    /// Offset from the default position, as a fraction of the screen's width and height
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    var scale: CGFloat = 1
}

enum TouchLayout {
    private static let key = "v3k.touchLayout"
    // Portrait mode has a layout of its own; the landscape one keeps its original key
    private static func key(portrait: Bool) -> String { portrait ? key + ".portrait" : key }

    static func load(portrait: Bool = false) -> [String: GroupPlacement] {
        guard let data = UserDefaults.standard.data(forKey: key(portrait: portrait)),
              let decoded = try? JSONDecoder().decode([String: GroupPlacement].self, from: data) else { return [:] }
        return decoded
    }

    static func save(_ placements: [String: GroupPlacement], portrait: Bool = false) {
        if placements.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(portrait: portrait))
        } else if let data = try? JSONEncoder().encode(placements) {
            UserDefaults.standard.set(data, forKey: key(portrait: portrait))
        }
    }

    static var isCustomized: Bool { !load().isEmpty || !load(portrait: true).isEmpty }

    static func resetAll() {
        save([:])
        save([:], portrait: true)
    }
}

/// Settings › Controls › Portrait mode: holding the phone upright puts the game on top and the
/// controls below. Landscape is unaffected.
enum PortraitMode {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "v3k.portraitMode") as? Bool ?? true }
    /// Games boot in landscape and portrait opens up once the game is on screen: starting upright
    /// stalled the GPU at boot (device lost), while turning the phone during play works
    static var unlocked = false
    static var allowed: Bool { enabled && unlocked && !TVMode.active }
}

@_cdecl("v3k_set_portrait_unlocked")
public func v3kSetPortraitUnlocked(_ unlocked: Bool) {
    MainActor.assumeIsolated {
        PortraitMode.unlocked = unlocked
        // keeps UIDevice.orientation up to date by the time portrait opens up (balanced calls not needed)
        if !UIDevice.current.isGeneratingDeviceOrientationNotifications {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        for scene in UIApplication.shared.connectedScenes {
            // the TV's scene (TV mode) has no orientation to change
            guard let windowScene = scene as? UIWindowScene, !PhoneScene.isExternal(windowScene) else { continue }
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            // Held upright already: turn to portrait now rather than waiting for the phone to move
            if unlocked && PortraitMode.enabled && UIDevice.current.orientation == .portrait {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
            }
        }
    }
}

final class ControlsOverlayView: UIView {
    private let l = PadButtonView(button: Pad.l, title: "L")
    private let r = PadButtonView(button: Pad.r, title: "R")
    private let up = PadButtonView(button: Pad.up, title: "▲", fontSize: 16)
    private let down = PadButtonView(button: Pad.down, title: "▼", fontSize: 16)
    private let left = PadButtonView(button: Pad.left, title: "◀", fontSize: 16)
    private let right = PadButtonView(button: Pad.right, title: "▶", fontSize: 16)
    private let triangle = PadButtonView(button: Pad.triangle, title: "△", fontSize: 22)
    private let circle = PadButtonView(button: Pad.circle, title: "○", fontSize: 22)
    private let cross = PadButtonView(button: Pad.cross, title: "✕", fontSize: 20)
    private let square = PadButtonView(button: Pad.square, title: "□", fontSize: 22)
    private let select = PadButtonView(button: Pad.select, title: "SELECT", fontSize: 10)
    private let start = PadButtonView(button: Pad.start, title: "START", fontSize: 10)
    private let leftStick = StickView(xAxis: Pad.leftX, yAxis: Pad.leftY)
    private let rightStick = StickView(xAxis: Pad.rightX, yAxis: Pad.rightY)
    // PS TV mode only (a PS TV controller's extra buttons): shown while the running game uses it
    private let l2 = PadButtonView(button: -1, title: "L2", fontSize: 15)
    private let r2 = PadButtonView(button: -1, title: "R2", fontSize: 15)
    private let l3 = PadButtonView(button: Pad.l3, title: "L3", fontSize: 12)
    private let r3 = PadButtonView(button: Pad.r3, title: "R3", fontSize: 12)
    private var pstvActive = false
    private var pstvButtons: [PadButtonView] { [l2, r2, l3, r3] }
    // Settings › Controls › Macro buttons
    private let macroButtons: [MacroButtonView]
    // Settings › Controls › Sticks and Touch reach
    private let stickStyle = StickStyle.current
    private let touchReach = TouchReach.current
    private let separateButtons = TouchTuning.separateButtons
    private let zoneSplit = min(max(TouchTuning.zoneSplit, 0.25), 0.75)
    private let zoneTop = min(max(TouchTuning.zoneTop, 0), 0.6)
    private let exitButton = UIButton(type: .system)
    private let hideButton = UIButton(type: .system)
    private let pauseButton = UIButton(type: .system)
    private let rearButton = UIButton(type: .system)
    private let pausedBanner = UIButton(type: .system)
    // The last button of the top row tucks the row away (swiping up on it works too); a small button in
    // the screen's top-left corner, outside the controls (beside the camera in landscape), brings it back
    private let collapseButton = UIButton(type: .system)
    private let topHandle = UIButton(type: .system)
    private var topRowHidden = UserDefaults.standard.bool(forKey: "v3k.topButtonsHidden") {
        didSet {
            UserDefaults.standard.set(topRowHidden, forKey: "v3k.topButtonsHidden")
            applyTopRow()
        }
    }
    private let toastLabel = UILabel()
    private var toastGeneration = 0
    private let showRearButton = UserDefaults.standard.object(forKey: "v3k.touchRearButton") as? Bool ?? true
    private var landscapePlacements = TouchLayout.load()
    private var portraitPlacements = TouchLayout.load(portrait: true)
    private var isPortrait: Bool { bounds.height > bounds.width }
    private var placements: [String: GroupPlacement] {
        get { isPortrait ? portraitPlacements : landscapePlacements }
        set { if isPortrait { portraitPlacements = newValue } else { landscapePlacements = newValue } }
    }
    private var portraitControlsArea = CGRect.zero
    private var editor: LayoutEditorView?
    private var hiddenBeforeEditing = false

    private var controls: [UIView] {
        [l, r, up, down, left, right, triangle, circle, cross, square, select, start, leftStick, rightStick, l2, r2, l3, r3] + macroButtons
    }

    private var controlsHidden = UserDefaults.standard.bool(forKey: "v3k.touchControlsHidden") {
        didSet {
            UserDefaults.standard.set(controlsHidden, forKey: "v3k.touchControlsHidden")
            applyVisibility()
        }
    }

    // Settings > Touch controls
    private let opacity = CGFloat(UserDefaults.standard.object(forKey: "v3k.touchOpacity") as? Double ?? 0.6)
    private let scale = CGFloat(UserDefaults.standard.object(forKey: "v3k.touchScale") as? Double ?? 1.0)
    private let hideWithController = UserDefaults.standard.object(forKey: "v3k.touchHideWithController") as? Bool ?? true
    private var controllerConnected = !GCController.controllers().isEmpty {
        didSet { applyVisibility() }
    }
    // Controller shortcut: hold Select + Start to open the game menu (polled, so SDL keeps its input handlers)
    private var shortcutTimer: Timer?
    private var shortcutHeldSince: Date?
    private weak var menuAlert: UIAlertController?
    // Settings › Performance overlay (or the game menu, mid-game); stays visible when the controls are hidden
    private let hud = PerformanceHUDView(frame: .zero)

    override init(frame: CGRect) {
        macroButtons = TouchMacro.load().map { MacroButtonView(macro: $0, tint: ControllerTheme.current.tint) }
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        l2.axis = 4 // SDL left trigger
        r2.axis = 5
        controls.forEach { addSubview($0) }
        // Under every button: a floating stick's landing area may reach behind them
        insertSubview(rightStick, at: 0)
        insertSubview(leftStick, at: 0)

        exitButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        exitButton.tintColor = UIColor.white.withAlphaComponent(0.85)
        exitButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        exitButton.addTarget(self, action: #selector(exitTapped), for: .touchUpInside)
        addSubview(exitButton)

        hideButton.tintColor = UIColor.white.withAlphaComponent(0.85)
        hideButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        hideButton.addTarget(self, action: #selector(hideTapped), for: .touchUpInside)
        addSubview(hideButton)

        pauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        pauseButton.tintColor = UIColor.white.withAlphaComponent(0.85)
        pauseButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        pauseButton.addTarget(self, action: #selector(pauseTapped), for: .touchUpInside)
        pauseButton.accessibilityLabel = "Pause"
        addSubview(pauseButton)

        // Covers the screen while the player has paused the game; tapping it resumes
        var bannerConfig = UIButton.Configuration.plain()
        bannerConfig.image = UIImage(systemName: "play.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 56))
        bannerConfig.title = "Paused"
        bannerConfig.subtitle = "Tap to resume"
        bannerConfig.imagePlacement = .top
        bannerConfig.imagePadding = 10
        bannerConfig.titleAlignment = .center
        bannerConfig.baseForegroundColor = .white
        pausedBanner.configuration = bannerConfig
        pausedBanner.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        pausedBanner.addTarget(self, action: #selector(pauseTapped), for: .touchUpInside)
        pausedBanner.isHidden = true
        addSubview(pausedBanner)

        rearButton.setImage(UIImage(systemName: "hand.point.up.left"), for: .normal)
        rearButton.tintColor = UIColor.white.withAlphaComponent(0.85)
        rearButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        rearButton.addTarget(self, action: #selector(rearTapped), for: .touchUpInside)
        rearButton.accessibilityLabel = "Rear touchpad"
        rearButton.isHidden = !showRearButton
        addSubview(rearButton)

        collapseButton.setImage(UIImage(systemName: "chevron.up"), for: .normal)
        collapseButton.tintColor = UIColor.white.withAlphaComponent(0.85)
        collapseButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        collapseButton.accessibilityLabel = "Hide these buttons"
        collapseButton.addTarget(self, action: #selector(hideTopRow), for: .touchUpInside)
        addSubview(collapseButton)

        topHandle.setImage(UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)), for: .normal)
        topHandle.tintColor = UIColor.white.withAlphaComponent(0.7)
        topHandle.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        topHandle.accessibilityLabel = "Show buttons"
        topHandle.addTarget(self, action: #selector(showTopRow), for: .touchUpInside)
        addSubview(topHandle)
        let handleSwipe = UISwipeGestureRecognizer(target: self, action: #selector(showTopRow))
        handleSwipe.direction = .down
        topHandle.addGestureRecognizer(handleSwipe)
        for button in [exitButton, pauseButton, hideButton, rearButton, collapseButton] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(hideTopRow))
            swipe.direction = .up
            button.addGestureRecognizer(swipe)
        }
        applyTopRow()

        toastLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        toastLabel.textColor = .white
        toastLabel.textAlignment = .center
        toastLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        toastLabel.layer.cornerRadius = 16
        toastLabel.clipsToBounds = true
        toastLabel.alpha = 0
        toastLabel.isUserInteractionEnabled = false
        addSubview(toastLabel)
        addSubview(hud)
        hud.setActive(HUDSettings.enabled)
        updateRearButton()

        // Controller theme
        let theme = ControllerTheme.current
        for (position, button) in [triangle, circle, cross, square].enumerated() {
            let (title, faceColor) = theme.face(position)
            button.style(title: title, color: faceColor, theme: theme, faceButton: true)
        }
        for button in [l, r, up, down, left, right, select, start, l2, r2, l3, r3] {
            button.style(color: theme.tint, theme: theme, faceButton: false)
        }
        for stick in [leftStick, rightStick] {
            stick.setTint(theme.tint)
        }

        controls.forEach { $0.alpha = opacity }
        applyVisibility()

        let center = NotificationCenter.default
        center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.controllerConnected = !GCController.controllers().isEmpty
        }
        center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.controllerConnected = !GCController.controllers().isEmpty
        }

        shortcutTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkControllerShortcut()
            self?.checkPSTVMode()
        }
    }

    deinit {
        shortcutTimer?.invalidate()
    }

    /// The running game's PS TV mode (known once it has started): L2, R2, L3 and R3 appear with it
    private func checkPSTVMode() {
        let active = v3k_pstv_mode()
        guard active != pstvActive else { return }
        pstvActive = active
        applyVisibility()
        setNeedsLayout()
    }

    private func checkControllerShortcut() {
        let held = GCController.controllers().contains { controller in
            guard let pad = controller.extendedGamepad else { return false }
            return pad.buttonMenu.isPressed && (pad.buttonOptions?.isPressed ?? false)
        }
        guard held else {
            shortcutHeldSince = nil
            return
        }
        if let since = shortcutHeldSince {
            if Date().timeIntervalSince(since) > 1.2 && menuAlert == nil {
                shortcutHeldSince = .distantFuture // fire once per hold
                releaseAll()
                showMenu(fromController: true)
            }
        } else {
            shortcutHeldSince = Date()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Touches that miss every control go to the game (Vita touchscreen). With the game on a TV the
    // game window isn't under this one any more, so this view takes them and passes them on.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // Touch reach: a tap just outside a button (or in a floating stick's area, near a button)
        // presses the nearest button
        let inStickArea = (hit as? StickView).map { $0.style != .fixed } ?? false
        if editor == nil, touchReach != .exact, hit === self || inStickArea, let near = nearestControl(to: point) {
            return near
        }
        return hit === self ? (forwardsTouches ? self : nil) : hit
    }

    private func nearestControl(to point: CGPoint) -> UIView? {
        var best: (view: UIView, distance: CGFloat)?
        for view in controls where !view.isHidden && view.alpha > 0.01 && view.isUserInteractionEnabled {
            if let stick = view as? StickView, stick.style != .fixed { continue }
            let frame = view.frame
            let reach = min(frame.width, frame.height) * touchReach.share
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            let distance = sqrt(dx * dx + dy * dy)
            guard distance <= reach else { continue }
            if best == nil || distance < best!.distance { best = (view, distance) }
        }
        return best?.view
    }

    /// The game is on a TV: this phone is only the controller (black behind the controls, touches on
    /// empty space go to the game's touchscreen)
    var forwardsTouches = false {
        didSet {
            guard forwardsTouches != oldValue else { return }
            backgroundColor = forwardsTouches ? .black : .clear
            if forwardsTouches { showToast(L("Playing on the TV: this phone is the controller")) }
        }
    }

    private func forward(_ touches: Set<UITouch>, phase: Int32) {
        guard forwardsTouches, bounds.width > 0, bounds.height > 0 else { return }
        for touch in touches {
            let point = touch.location(in: self)
            let finger = UInt64(UInt(bitPattern: ObjectIdentifier(touch).hashValue))
            v3k_touch_inject(phase, finger, Float(point.x / bounds.width), Float(point.y / bounds.height))
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, phase: 0) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, phase: 1) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, phase: 2) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, phase: 3) }

    private func applyVisibility() {
        let hidden = editor == nil && (controlsHidden || (hideWithController && controllerConnected))
        controls.forEach { $0.isHidden = hidden }
        pstvButtons.forEach { $0.isHidden = hidden || !pstvActive }
        hideButton.setImage(UIImage(systemName: controlsHidden ? "gamecontroller" : "eye.slash"), for: .normal)
        if hidden { releaseAll() }
        updateRearButton()
    }

    @objc private func exitTapped() {
        showMenu(fromController: false)
    }

    /// Every on-screen and macro press let go
    private func releaseAll() {
        macroButtons.forEach { $0.releaseIfHeld() }
        leftStick.reset()
        rightStick.reset()
        PadPress.releaseAll()
    }

    @objc private func pauseTapped() {
        setUserPaused(!v3k_game_paused_by_user())
    }

    /// The pause button: the game stops (CPU, GPU and sound) until resumed; Quit works while paused
    func setUserPaused(_ paused: Bool) {
        releaseAll()
        v3k_set_game_paused(1, paused)
        let isPaused = v3k_game_paused_by_user()
        pauseButton.setImage(UIImage(systemName: isPaused ? "play.fill" : "pause.fill"), for: .normal)
        pauseButton.accessibilityLabel = isPaused ? "Resume" : "Pause"
        pausedBanner.isHidden = !isPaused
        if isPaused {
            pausedBanner.frame = bounds
            insertSubview(pausedBanner, belowSubview: exitButton)
        }
    }

    /// While the game menu is open the game is paused too; it resumes when the menu closes
    private func menuClosed() {
        menuAlert = nil
        v3k_set_game_paused(2, false)
    }

    func showMenu(fromController: Bool) {
        guard menuAlert == nil, editor == nil, let root = window?.rootViewController else { return }
        releaseAll()
        v3k_set_game_paused(2, true)
        let alert = UIAlertController(title: L("Game menu"), message: fromController
            ? L("Press the controller's Home/PS button, or hold Select + Start, to open this menu. The game is paused while it is open.")
            : L("The game is paused while this menu is open."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("Take screenshot"), style: .default) { [weak self] _ in
            self?.menuClosed()
            v3k_request_screenshot()
        })
        let paused = v3k_game_paused_by_user()
        alert.addAction(UIAlertAction(title: paused ? L("Resume game") : L("Pause game"), style: .default) { [weak self] _ in
            self?.menuClosed()
            self?.setUserPaused(!paused)
        })
        alert.addAction(UIAlertAction(title: v3k_rear_touch() ? L("Touch the front screen") : L("Touch the rear touchpad"), style: .default) { [weak self] _ in
            self?.menuClosed()
            self?.rearTapped()
        })
        alert.addAction(UIAlertAction(title: L("Edit control layout"), style: .default) { [weak self] _ in
            self?.menuClosed()
            self?.beginEditing()
        })
        alert.addAction(UIAlertAction(title: controlsHidden ? L("Show touch controls") : L("Hide touch controls"), style: .default) { [weak self] _ in
            self?.menuClosed()
            self?.controlsHidden.toggle()
        })
        alert.addAction(UIAlertAction(title: hud.active ? L("Hide performance overlay") : L("Show performance overlay"), style: .default) { [weak self] _ in
            self?.menuClosed()
            self?.togglePerformanceOverlay()
        })
        alert.addAction(UIAlertAction(title: L("Quit game"), style: .destructive) { [weak self] _ in
            self?.menuClosed()
            self?.confirmQuit()
        })
        alert.addAction(UIAlertAction(title: L("Keep playing"), style: .cancel) { [weak self] _ in
            self?.menuClosed()
        })
        menuAlert = alert
        (root.presentedViewController ?? root).present(alert, animated: true)
    }

    /// Same switch as Settings › Performance overlay, so the choice sticks for the next game
    private func togglePerformanceOverlay() {
        let on = !hud.active
        UserDefaults.standard.set(on, forKey: "v3k.hud.enabled")
        hud.setActive(on)
        setNeedsLayout()
    }

    private func confirmQuit() {
        guard let root = window?.rootViewController else { return }
        v3k_set_game_paused(2, true)
        let alert = UIAlertController(title: L("Quit game?"), message: L("Unsaved progress will be lost."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("Quit"), style: .destructive) { [weak self] _ in
            self?.releaseAll()
            // the game closes faster running than paused
            self?.menuAlert = nil
            v3k_set_game_paused(2, false)
            v3k_set_game_paused(1, false)
            v3k_pad_request_exit()
        })
        alert.addAction(UIAlertAction(title: L("Keep playing"), style: .cancel) { [weak self] _ in
            self?.menuClosed()
        })
        menuAlert = alert
        (root.presentedViewController ?? root).present(alert, animated: true)
    }

    @objc private func rearTapped() {
        let rear = !v3k_rear_touch()
        v3k_set_rear_touch(rear)
        updateRearButton()
        showToast(rear ? "Touches go to the rear touchpad" : "Touches go to the front screen")
    }

    private func updateRearButton() {
        let rear = v3k_rear_touch()
        rearButton.backgroundColor = rear ? Theme.accentUIColor.withAlphaComponent(0.85) : UIColor.black.withAlphaComponent(0.6)
        rearButton.isHidden = !(showRearButton || rear) || editor != nil || topRowHidden
    }

    private func applyTopRow() {
        let editing = editor != nil
        [exitButton, pauseButton, hideButton, collapseButton].forEach { $0.isHidden = editing || topRowHidden }
        topHandle.isHidden = editing || !topRowHidden
        updateRearButton()
    }

    /// The button that brings the top row back: a small dot in the screen's top-left corner. In landscape it
    /// sits in the strip beside the camera (outside the game picture's controls); in portrait, left of
    /// the camera in the status bar's band, above the game picture.
    private func layoutTopHandle() {
        let size: CGFloat = 26
        let insets = safeAreaInsets
        let x = insets.left >= size + 8 ? (insets.left - size) / 2 : 4
        let y = isPortrait ? max((insets.top - size) / 2, 4) : 6
        topHandle.frame = CGRect(x: bounds.minX + x, y: bounds.minY + y, width: size, height: size)
        topHandle.layer.cornerRadius = size / 2
    }

    @objc private func hideTopRow() { topRowHidden = true }
    @objc private func showTopRow() { topRowHidden = false }

    func showToast(_ message: String) {
        toastGeneration += 1
        let generation = toastGeneration
        toastLabel.text = message
        let size = toastLabel.sizeThatFits(CGSize(width: bounds.width - 80, height: 40))
        toastLabel.bounds = CGRect(x: 0, y: 0, width: size.width + 32, height: 32)
        toastLabel.center = CGPoint(x: bounds.midX, y: safeAreaInsets.top + 70)
        bringSubviewToFront(toastLabel)
        UIView.animate(withDuration: 0.2) { self.toastLabel.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, self.toastGeneration == generation else { return }
            UIView.animate(withDuration: 0.3) { self.toastLabel.alpha = 0 }
        }
    }

    // MARK: Layout editing

    func beginEditing() {
        guard editor == nil else { return }
        releaseAll()
        hiddenBeforeEditing = controlsHidden
        if controlsHidden { controlsHidden = false }
        controls.forEach { $0.isHidden = false; $0.isUserInteractionEnabled = false }
        pstvButtons.forEach { $0.isHidden = !pstvActive }
        [exitButton, pauseButton, hideButton, rearButton].forEach { $0.isHidden = true }
        let newEditor = LayoutEditorView(overlay: self)
        newEditor.frame = bounds
        newEditor.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(newEditor)
        editor = newEditor
        applyTopRow()
        setNeedsLayout()
        layoutIfNeeded()
        newEditor.refresh()
    }

    func endEditing(save: Bool) {
        guard let editor else { return }
        if save {
            TouchLayout.save(placements, portrait: isPortrait)
        } else {
            placements = TouchLayout.load(portrait: isPortrait)
        }
        editor.removeFromSuperview()
        self.editor = nil
        controls.forEach { $0.isUserInteractionEnabled = true }
        controlsHidden = hiddenBeforeEditing
        applyTopRow()
        setNeedsLayout()
    }

    var layoutArea: CGRect { isPortrait ? portraitControlsArea : bounds.inset(by: safeAreaInsets).insetBy(dx: 12, dy: 10) }

    func views(of group: ControlGroup) -> [UIView] {
        switch group {
        case .l: [l]
        case .r: [r]
        case .dpad: [up, down, left, right]
        case .face: [triangle, circle, cross, square]
        case .leftStick: [leftStick]
        case .rightStick: [rightStick]
        case .startSelect: [select, start]
        case .l2: [l2]
        case .r2: [r2]
        case .l3: [l3]
        case .r3: [r3]
        case .macro1, .macro2, .macro3, .macro4:
            macroIndex(group).map { $0 < macroButtons.count ? [macroButtons[$0] as UIView] : [] } ?? []
        case .dpadUp: [up]
        case .dpadDown: [down]
        case .dpadLeft: [left]
        case .dpadRight: [right]
        case .triangle: [triangle]
        case .circle: [circle]
        case .cross: [cross]
        case .square: [square]
        case .select: [select]
        case .start: [start]
        }
    }

    private func macroIndex(_ group: ControlGroup) -> Int? {
        switch group {
        case .macro1: 0
        case .macro2: 1
        case .macro3: 2
        case .macro4: 3
        default: nil
        }
    }

    /// Groups on screen now (PS TV buttons only in PS TV mode, macros only when set up; the sticks
    /// can't be moved in screen-halves style)
    func isShown(_ group: ControlGroup) -> Bool {
        let members = views(of: group)
        if members.isEmpty || members.allSatisfy(\.isHidden) { return false }
        if stickStyle == .zones && (group == .leftStick || group == .rightStick) { return false }
        // Advanced touch › move buttons one by one: the single buttons instead of their clusters
        if group.isSingleButton && !separateButtons { return false }
        if group.isCluster && separateButtons { return false }
        return true
    }

    func frame(of group: ControlGroup) -> CGRect {
        views(of: group).map { ($0 as? StickView)?.stickFrame ?? $0.frame }.reduce(CGRect.null) { $0.union($1) }
    }

    func group(at point: CGPoint) -> ControlGroup? {
        // Smallest group under the finger, so the sticks can sit inside a cluster's box
        ControlGroup.allCases
            .filter { isShown($0) && frame(of: $0).insetBy(dx: -12, dy: -12).contains(point) }
            .min { frame(of: $0).width * frame(of: $0).height < frame(of: $1).width * frame(of: $1).height }
    }

    func placement(of group: ControlGroup) -> GroupPlacement {
        placements[group.rawValue] ?? GroupPlacement()
    }

    func setPlacement(_ placement: GroupPlacement, of group: ControlGroup) {
        placements[group.rawValue] = placement == GroupPlacement() ? nil : placement
        setNeedsLayout()
        layoutIfNeeded()
    }

    func resetPlacements() {
        placements = [:]
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// Moves and scales each group from its default place, kept on screen
    private func applyPlacements(in area: CGRect) {
        for group in ControlGroup.allCases {
            // single-button moves count only while Advanced touch › Move buttons one by one is on (off,
            // the editor shows the groups and couldn't undo them)
            if group.isSingleButton && !separateButtons { continue }
            let placement = self.placement(of: group)
            guard placement != GroupPlacement() else { continue }
            let members = views(of: group)
            let box = frame(of: group)
            let center = CGPoint(x: box.midX, y: box.midY)
            var moved = members.map { view -> CGRect in
                let f = view.frame
                return CGRect(x: center.x + (f.minX - center.x) * placement.scale + placement.dx * area.width,
                              y: center.y + (f.minY - center.y) * placement.scale + placement.dy * area.height,
                              width: f.width * placement.scale, height: f.height * placement.scale)
            }
            let newBox = moved.reduce(CGRect.null) { $0.union($1) }
            let shiftX = max(bounds.minX - newBox.minX, 0) + min(bounds.maxX - newBox.maxX, 0)
            let shiftY = max(bounds.minY - newBox.minY, 0) + min(bounds.maxY - newBox.maxY, 0)
            moved = moved.map { $0.offsetBy(dx: shiftX, dy: shiftY) }
            for (view, frame) in zip(members, moved) { view.frame = frame }
        }
    }

    @objc private func hideTapped() {
        controlsHidden.toggle()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pausedBanner.frame = bounds
        if isPortrait {
            layoutPortrait()
            return
        }
        v3k_set_portrait_top(-1)
        let area = layoutArea
        let unit = min(max(min(area.width, area.height) * 0.13, 40), 64) * scale // button size

        // Shoulder buttons
        l.frame = CGRect(x: area.minX, y: area.minY, width: unit * 1.9, height: unit * 0.8)
        r.frame = CGRect(x: area.maxX - unit * 1.9, y: area.minY, width: unit * 1.9, height: unit * 0.8)
        l.layer.cornerRadius = unit * 0.4
        r.layer.cornerRadius = unit * 0.4

        // D-pad (left) and face buttons (right), vertically centred
        let clusterSize = unit * 3
        let clusterY = area.midY - clusterSize / 2 - unit * 0.4
        layoutDiamond(top: up, right: right, bottom: down, left: left,
                      in: CGRect(x: area.minX, y: clusterY, width: clusterSize, height: clusterSize), unit: unit)
        layoutDiamond(top: triangle, right: circle, bottom: cross, left: square,
                      in: CGRect(x: area.maxX - clusterSize, y: clusterY, width: clusterSize, height: clusterSize), unit: unit)

        // Sticks below the clusters, pulled towards the centre
        let stickSize = unit * 2
        leftStick.frame = CGRect(x: area.minX + clusterSize * 0.75, y: area.maxY - stickSize, width: stickSize, height: stickSize)
        rightStick.frame = CGRect(x: area.maxX - clusterSize * 0.75 - stickSize, y: area.maxY - stickSize, width: stickSize, height: stickSize)

        // Select / Start, bottom centre
        let smallWidth = unit * 1.4, smallHeight = unit * 0.55
        select.frame = CGRect(x: area.midX - smallWidth - 8, y: area.maxY - smallHeight, width: smallWidth, height: smallHeight)
        start.frame = CGRect(x: area.midX + 8, y: area.maxY - smallHeight, width: smallWidth, height: smallHeight)

        // PS TV: L2 / R2 beside the shoulder buttons, L3 / R3 in the bottom corners
        l2.frame = CGRect(x: l.frame.maxX + 8, y: area.minY, width: unit * 1.4, height: unit * 0.8)
        r2.frame = CGRect(x: r.frame.minX - 8 - unit * 1.4, y: area.minY, width: unit * 1.4, height: unit * 0.8)
        l3.frame = CGRect(x: area.minX, y: area.maxY - unit * 0.6, width: unit * 1.1, height: unit * 0.6)
        r3.frame = CGRect(x: area.maxX - unit * 1.1, y: area.maxY - unit * 0.6, width: unit * 1.1, height: unit * 0.6)

        // Macros: a column beside the face buttons
        let macroSize = unit * 0.9
        let columnHeight = CGFloat(macroButtons.count) * macroSize + CGFloat(max(macroButtons.count - 1, 0)) * unit * 0.12
        for (index, macro) in macroButtons.enumerated() {
            macro.frame = CGRect(x: area.maxX - clusterSize - unit * 0.25 - macroSize,
                                 y: clusterY + clusterSize / 2 - columnHeight / 2 + CGFloat(index) * macroSize * 1.13,
                                 width: macroSize, height: macroSize)
            macro.lookRadius = unit * 1.3
        }

        applyPlacements(in: area)
        applyStickStyle(zones: stickZones(top: area.minY + unit))

        // Menu, show/hide, rear touchpad and the button that tucks them away, top centre
        let topButtons = showRearButton ? [exitButton, pauseButton, hideButton, rearButton, collapseButton] : [exitButton, pauseButton, hideButton, collapseButton]
        let rowWidth = CGFloat(topButtons.count) * 36 + CGFloat(topButtons.count - 1) * 8
        for (index, button) in topButtons.enumerated() {
            button.frame = CGRect(x: area.midX - rowWidth / 2 + CGFloat(index) * 44, y: area.minY, width: 36, height: 36)
            button.layer.cornerRadius = 18
        }
        if !showRearButton {
            rearButton.frame = CGRect(x: hideButton.frame.maxX + 8, y: area.minY, width: 36, height: 36)
            rearButton.layer.cornerRadius = 18
        }
        layoutTopHandle()
        if let editor { bringSubviewToFront(editor); editor.refresh() }

        if !hud.isHidden {
            let size = hud.sizeThatFits(bounds.size)
            // Below the shoulder buttons at the top, above the screen edge at the bottom
            let top = max(l.frame.maxY, r.frame.maxY, area.minY + 36) + 8
            let bottom = area.maxY - size.height
            let origin: CGPoint
            switch hud.corner {
            case 1: origin = CGPoint(x: area.maxX - size.width, y: top)
            case 2: origin = CGPoint(x: area.minX, y: bottom)
            case 3: origin = CGPoint(x: area.maxX - size.width, y: bottom)
            default: origin = CGPoint(x: area.minX, y: top)
            }
            hud.frame = CGRect(origin: origin, size: size)
        }
    }

    /// Portrait mode: the game picture sits at the top (the renderer is told where) and the controls
    /// share the space below it. Same controls and groups as landscape, laid out for a tall screen.
    private func layoutPortrait() {
        let insets = safeAreaInsets
        let scaleFactor = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        v3k_set_portrait_top(Float(insets.top * scaleFactor))
        let gameBottom = insets.top + bounds.width * 544 / 960
        let area = bounds.inset(by: insets).insetBy(dx: 12, dy: 8)
        let controls = CGRect(x: area.minX, y: gameBottom + 10, width: area.width, height: max(area.maxY - gameBottom - 10, 120))
        portraitControlsArea = controls
        let unit = min(max(area.width * 0.15, 44), 70) * scale

        // Shoulder buttons along the top of the controls, the menu buttons between them
        l.frame = CGRect(x: controls.minX, y: controls.minY, width: unit * 1.7, height: unit * 0.75)
        r.frame = CGRect(x: controls.maxX - unit * 1.7, y: controls.minY, width: unit * 1.7, height: unit * 0.75)
        let topButtons = showRearButton ? [exitButton, pauseButton, hideButton, rearButton, collapseButton] : [exitButton, pauseButton, hideButton, collapseButton]
        let rowWidth = CGFloat(topButtons.count) * 36 + CGFloat(topButtons.count - 1) * 8
        for (index, button) in topButtons.enumerated() {
            button.frame = CGRect(x: controls.midX - rowWidth / 2 + CGFloat(index) * 44, y: controls.minY + (unit * 0.75 - 36) / 2, width: 36, height: 36)
            button.layer.cornerRadius = 18
        }
        if !showRearButton {
            rearButton.frame = CGRect(x: hideButton.frame.maxX + 8, y: hideButton.frame.minY, width: 36, height: 36)
            rearButton.layer.cornerRadius = 18
        }
        layoutTopHandle()

        // Select / Start at the bottom, d-pad and face buttons above, sticks between them
        let smallWidth = unit * 1.4, smallHeight = unit * 0.55
        select.frame = CGRect(x: controls.midX - smallWidth - 8, y: controls.maxY - smallHeight, width: smallWidth, height: smallHeight)
        start.frame = CGRect(x: controls.midX + 8, y: controls.maxY - smallHeight, width: smallWidth, height: smallHeight)

        // PS TV: L2 / R2 under L / R (the clusters move down to make room), L3 / R3 in the bottom corners
        l2.frame = CGRect(x: controls.minX, y: l.frame.maxY + 4, width: unit * 1.7, height: unit * 0.6)
        r2.frame = CGRect(x: controls.maxX - unit * 1.7, y: r.frame.maxY + 4, width: unit * 1.7, height: unit * 0.6)
        l3.frame = CGRect(x: controls.minX, y: controls.maxY - smallHeight, width: unit * 1.0, height: smallHeight)
        r3.frame = CGRect(x: controls.maxX - unit * 1.0, y: controls.maxY - smallHeight, width: unit * 1.0, height: smallHeight)
        let shouldersBottom = pstvActive ? l2.frame.maxY : l.frame.maxY

        let clusterSize = unit * 3
        let free = select.frame.minY - shouldersBottom
        let clusterY = shouldersBottom + max((free - clusterSize - unit * 1.9) / 3, 8)
        layoutDiamond(top: up, right: right, bottom: down, left: left,
                      in: CGRect(x: controls.minX, y: clusterY, width: clusterSize, height: clusterSize), unit: unit)
        layoutDiamond(top: triangle, right: circle, bottom: cross, left: square,
                      in: CGRect(x: controls.maxX - clusterSize, y: clusterY, width: clusterSize, height: clusterSize), unit: unit)

        let stickSize = unit * 1.9
        let stickY = min(clusterY + clusterSize + max((free - clusterSize - stickSize) / 3, 6), select.frame.minY - stickSize - 6)
        leftStick.frame = CGRect(x: controls.minX + unit * 0.6, y: stickY, width: stickSize, height: stickSize)
        rightStick.frame = CGRect(x: controls.maxX - unit * 0.6 - stickSize, y: stickY, width: stickSize, height: stickSize)

        // Macros: a row at the bottom of the game picture, from the right
        let macroSize = unit * 0.8
        for (index, macro) in macroButtons.enumerated() {
            macro.frame = CGRect(x: controls.maxX - CGFloat(index + 1) * macroSize - CGFloat(index) * 8,
                                 y: gameBottom - macroSize - 8, width: macroSize, height: macroSize)
            macro.lookRadius = unit * 1.3
        }

        applyPlacements(in: controls)
        applyStickStyle(zones: stickZones(top: controls.minY + unit))

        if !hud.isHidden {
            // Over the game picture, in the chosen corner
            let size = hud.sizeThatFits(bounds.size)
            let left = area.minX, rightEdge = area.maxX - size.width
            let top = insets.top + 8, bottom = gameBottom - size.height - 8
            let origin: CGPoint
            switch hud.corner {
            case 1: origin = CGPoint(x: rightEdge, y: top)
            case 2: origin = CGPoint(x: left, y: bottom)
            case 3: origin = CGPoint(x: rightEdge, y: bottom)
            default: origin = CGPoint(x: left, y: top)
            }
            hud.frame = CGRect(origin: origin, size: size)
        }
        if let editor { bringSubviewToFront(editor); editor.refresh() }
    }

    /// Screen halves: the two stick areas below `top`. Advanced touch can move the split between them and
    /// keep more of the top of the screen for the game's touchscreen (defaults: halves, nothing more)
    private func stickZones(top: CGFloat) -> (left: CGRect, right: CGRect) {
        let zoneTopY = max(top, bounds.minY + bounds.height * zoneTop)
        let height = max(bounds.maxY - zoneTopY, 0)
        let split = bounds.minX + bounds.width * zoneSplit
        return (CGRect(x: bounds.minX, y: zoneTopY, width: split - bounds.minX, height: height),
                CGRect(x: split, y: zoneTopY, width: bounds.maxX - split, height: height))
    }

    /// Floating sticks get a landing area around where they're drawn; screen halves make each half of
    /// the screen (below the top buttons) a stick. Fixed sticks, and every stick while the layout is
    /// being edited, stay as drawn.
    private func applyStickStyle(zones: (left: CGRect, right: CGRect)) {
        let style = editor == nil ? stickStyle : .fixed
        for (stick, zone) in [(leftStick, zones.left), (rightStick, zones.right)] {
            let drawn = stick.frame
            switch style {
            case .fixed:
                stick.configure(style: .fixed, stick: drawn)
            case .floating:
                stick.frame = drawn.insetBy(dx: -drawn.width * 0.6, dy: -drawn.width * 0.6).intersection(bounds)
                stick.configure(style: .floating, stick: drawn)
            case .zones:
                stick.frame = zone
                stick.configure(style: .zones, stick: drawn)
            }
        }
    }

    private func layoutDiamond(top: UIView, right: UIView, bottom: UIView, left: UIView, in rect: CGRect, unit: CGFloat) {
        top.frame = CGRect(x: rect.midX - unit / 2, y: rect.minY, width: unit, height: unit)
        bottom.frame = CGRect(x: rect.midX - unit / 2, y: rect.maxY - unit, width: unit, height: unit)
        left.frame = CGRect(x: rect.minX, y: rect.midY - unit / 2, width: unit, height: unit)
        right.frame = CGRect(x: rect.maxX - unit, y: rect.midY - unit / 2, width: unit, height: unit)
    }
}

/// Root of the controls window: landscape like the game, and transparent to touches it doesn't use
final class ControlsViewController: UIViewController {
    override func loadView() {
        view = ControlsOverlayView(frame: .zero) // the window sizes it (a foldable's displays differ)
    }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { PortraitMode.allowed ? [.landscape, .portrait] : .landscape }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

/// A window above the game's: touches that miss every control fall through to the game window
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === rootViewController?.view, TVMode.active { return hit }
        return (hit === self || hit === rootViewController?.view) ? nil : hit
    }
}

/// The phone's own scene (role "application"). A connected TV has a scene of its own, so anything
/// meant for the phone (library, controls, the game window when not on the TV) must be put here
/// explicitly: "the first connected scene" can be the TV's.
@MainActor
enum PhoneScene {
    static func isExternal(_ scene: UIWindowScene) -> Bool {
        if #available(iOS 16.0, *) {
            if scene.session.role == .windowExternalDisplayNonInteractive { return true }
        }
        return scene.session.role.rawValue == "UIWindowSceneSessionRoleExternalDisplay"
    }

    static var current: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.session.role == .windowApplication }
            ?? scenes.first { !isExternal($0) && $0.screen === UIScreen.main }
            ?? scenes.first { !isExternal($0) }
    }

    static var external: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { isExternal($0) }
    }
}

/// TV mode (Settings, on by default): while a TV is connected (AirPlay / Screen Mirroring or a cable)
/// the game's window moves onto the TV's own scene, full screen, and the phone keeps only the controls
/// on black. Disconnecting brings the game back. The TV's scene comes from ios_platform.mm
/// (V3KExternalDisplaySceneDelegate); with TV mode off it gives the scene back so iOS mirrors the phone.
@MainActor
enum TVMode {
    nonisolated(unsafe) private(set) static var active = false
    private static weak var gameWindow: UIWindow?
    private static var observers: [NSObjectProtocol] = []

    private static var mirroringNoticeShown = false

    /// Inside LiveContainer (or a similar app container), the container's own app settings decide
    /// whether a TV gets a scene of its own
    private static var inContainer: Bool {
        ProcessInfo.processInfo.environment["LC_HOME_PATH"] != nil || Bundle.main.bundlePath.contains("/Documents/Applications/")
    }

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "v3k.tvMode") as? Bool ?? true
    }

    static func start(gameWindow window: UIWindow) {
        stop()
        gameWindow = window
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let roles = scenes.map { "\($0.session.role.rawValue.replacingOccurrences(of: "UIWindowSceneSessionRole", with: ""))\($0.screen === UIScreen.main ? "" : " (other screen)")" }
        v3k_log_ui("TV: TV mode \(enabled ? "on" : "off"), \(UIScreen.screens.count) screen(s), scenes: \(roles.joined(separator: ", "))")
        guard enabled else { return }
        let center = NotificationCenter.default
        let check: (Notification) -> Void = { _ in MainActor.assumeIsolated { update() } }
        observers = [
            center.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main, using: check),
            center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main, using: check),
            center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main, using: check),
            center.addObserver(forName: UIScreen.didConnectNotification, object: nil, queue: .main, using: check),
            center.addObserver(forName: UIScreen.didDisconnectNotification, object: nil, queue: .main, using: check),
        ]
        update()
        // a TV scene can finish connecting a moment after the notifications
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { update() }
    }

    /// On the TV when it has a scene, otherwise on the phone
    private static func update() {
        guard gameWindow != nil else { return }
        if let scene = PhoneScene.external, scene.activationState != .unattached {
            if !active || gameWindow?.windowScene !== scene { enter(scene) }
        } else if active {
            leave()
        } else if UIScreen.screens.count > 1 {
            v3k_log_ui("TV: a second screen is connected but iOS gave it no scene of its own, so it mirrors the phone\(inContainer ? " (Hinoki runs inside an app container, whose settings decide this)" : "")")
            if !mirroringNoticeShown {
                mirroringNoticeShown = true
                let message = inContainer
                    ? "The TV only mirrors the phone inside LiveContainer: install Hinoki on its own for TV mode"
                    : "The TV only mirrors the phone: stop and restart Screen Mirroring for TV mode"
                (ControlsHost.window?.rootViewController?.view as? ControlsOverlayView)?.showToast(message)
            }
        }
    }

    /// The game is ending: forget the window (it is being destroyed), nothing to move back
    static func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if active {
            setOverlay(tv: false)
            v3k_set_tv_mode(false)
            v3k_tv_placeholder(true)
        }
        active = false
        gameWindow = nil
    }

    private static func enter(_ scene: UIWindowScene) {
        guard let window = gameWindow else { return }
        let screen = scene.screen
        // Lower latency: the stream to the TV is encoded at the display's mode, so a 4K mode costs a
        // much bigger encode per frame than 1080p; prefer a mode no larger than 1080p when the TV offers one
        if let mode = screen.availableModes.filter({ $0.size.width <= 1920 && $0.size.height <= 1080 })
            .max(by: { $0.size.width * $0.size.height < $1.size.width * $1.size.height }),
            mode != screen.currentMode {
            screen.currentMode = mode
        }
        screen.overscanCompensation = .none
        v3k_tv_placeholder(false)
        window.windowScene = scene
        window.frame = scene.coordinateSpace.bounds
        // shown, not made key: the TV's scene takes no input, and keyboard events go to the key window
        window.isHidden = false
        window.setNeedsLayout()
        window.layoutIfNeeded()
        active = true
        v3k_set_tv_mode(true)
        PadPress.releaseAll()
        setOverlay(tv: true)
        v3k_log_ui("TV: the game moved to a \(Int(screen.nativeBounds.width))x\(Int(screen.nativeBounds.height)) display (mode \(Int(screen.currentMode?.size.width ?? 0))x\(Int(screen.currentMode?.size.height ?? 0))), the phone is the controller")
    }

    private static func leave() {
        guard active, let window = gameWindow else { return }
        if let phone = PhoneScene.current {
            window.windowScene = phone
            window.frame = phone.coordinateSpace.bounds
        }
        window.isHidden = false
        window.setNeedsLayout()
        window.layoutIfNeeded()
        active = false
        v3k_set_tv_mode(false)
        PadPress.releaseAll()
        setOverlay(tv: false)
        v3k_tv_placeholder(true)
        v3k_log_ui("TV: disconnected, the game is back on the phone")
    }

    private static func setOverlay(tv: Bool) {
        guard let overlayWindow = ControlsHost.window else { return }
        (overlayWindow.rootViewController?.view as? ControlsOverlayView)?.forwardsTouches = tv
        overlayWindow.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if tv, let scene = overlayWindow.windowScene, scene.interfaceOrientation.isPortrait {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in }
        }
    }
}

@MainActor
enum ControlsHost {
    static var window: UIWindow?

    static func attach(over gameWindow: UIWindow) {
        detach()
        TouchMapping.load()
        // SDL creates its window on whichever scene is active: with a TV connected that can be the TV's.
        // The game starts on the phone; TV mode moves it if it should be on the TV
        if let window = gameWindow.windowScene, PhoneScene.isExternal(window), let phone = PhoneScene.current {
            gameWindow.windowScene = phone
            gameWindow.frame = phone.coordinateSpace.bounds
        }
        let overlay: PassthroughWindow
        if let scene = PhoneScene.current ?? gameWindow.windowScene {
            overlay = PassthroughWindow(windowScene: scene)
        } else {
            overlay = PassthroughWindow(frame: gameWindow.bounds)
        }
        overlay.windowLevel = gameWindow.windowLevel + 1
        overlay.backgroundColor = .clear
        overlay.rootViewController = ControlsViewController()
        overlay.isHidden = false // shown but not key: the game window keeps keyboard/gamepad focus
        window = overlay
        TVMode.start(gameWindow: gameWindow)
    }

    static func detach() {
        TVMode.stop()
        window?.isHidden = true
        window = nil
    }
}

// Called from C++ (main_ios.cpp) when the game window is created and destroyed
@_cdecl("v3k_controls_attach")
public func v3kControlsAttach(_ uiWindow: UnsafeMutableRawPointer?) {
    guard let uiWindow else { return }
    let window = Unmanaged<UIWindow>.fromOpaque(uiWindow).takeUnretainedValue()
    MainActor.assumeIsolated { ControlsHost.attach(over: window) }
}

@_cdecl("v3k_controls_detach")
public func v3kControlsDetach() {
    MainActor.assumeIsolated { ControlsHost.detach() }
}

/// Controller guide / PS button pressed in game
@_cdecl("v3k_controls_show_menu")
public func v3kControlsShowMenu() {
    MainActor.assumeIsolated {
        PadPress.releaseAll()
        (ControlsHost.window?.rootViewController?.view as? ControlsOverlayView)?.showMenu(fromController: true)
    }
}

/// Shown over the controls while the player rearranges them: drag a group to move it, pinch to
/// resize it. Done saves, Reset goes back to the default layout.
final class LayoutEditorView: UIView {
    private weak var overlay: ControlsOverlayView?
    private var outlines: [ControlGroup: CAShapeLayer] = [:]
    private let bar = UIStackView()
    private var activeGroup: ControlGroup?
    private var dragStart = CGPoint.zero
    private var placementAtStart = GroupPlacement()
    private var pinchGroup: ControlGroup?
    private var lastGroup: ControlGroup?
    private var scaleAtStart: CGFloat = 1

    init(overlay: ControlsOverlayView) {
        self.overlay = overlay
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.35)
        isMultipleTouchEnabled = true

        for group in ControlGroup.allCases {
            let outline = CAShapeLayer()
            outline.fillColor = UIColor.white.withAlphaComponent(0.06).cgColor
            outline.strokeColor = UIColor.white.withAlphaComponent(0.8).cgColor
            outline.lineDashPattern = [6, 4]
            outline.lineWidth = 1.5
            layer.addSublayer(outline)
            outlines[group] = outline
        }

        let hint = UILabel()
        hint.text = "Drag to move · pinch to resize"
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = UIColor.white.withAlphaComponent(0.9)
        let reset = makeButton("Reset", action: #selector(resetTapped), filled: false)
        let cancel = makeButton("Cancel", action: #selector(cancelTapped), filled: false)
        let done = makeButton("Done", action: #selector(doneTapped), filled: true)
        [hint, reset, cancel, done].forEach { bar.addArrangedSubview($0) }
        bar.axis = .horizontal
        bar.spacing = 10
        bar.alignment = .center
        bar.isLayoutMarginsRelativeArrangement = true
        bar.layoutMargins = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 6)
        bar.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        bar.layer.cornerRadius = 20
        addSubview(bar)

        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func makeButton(_ title: String, action: Selector, filled: Bool) -> UIButton {
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
        bar.frame = CGRect(x: bounds.midX - size.width / 2, y: safeAreaInsets.top + 8, width: size.width, height: max(size.height, 40))
        refresh()
    }

    func refresh() {
        guard let overlay else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (group, outline) in outlines {
            guard overlay.isShown(group) else {
                outline.path = nil
                continue
            }
            let box = overlay.frame(of: group).insetBy(dx: -6, dy: -6)
            outline.path = UIBezierPath(roundedRect: box, cornerRadius: 12).cgPath
            outline.strokeColor = (group == activeGroup || group == pinchGroup ? Theme.accentUIColor : UIColor.white.withAlphaComponent(0.8)).cgColor
        }
        CATransaction.commit()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeGroup == nil, let touch = touches.first, let overlay else { return }
        let point = touch.location(in: self)
        guard let group = overlay.group(at: point) else { return }
        activeGroup = group
        lastGroup = group
        dragStart = point
        placementAtStart = overlay.placement(of: group)
        refresh()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let group = activeGroup, pinchGroup == nil, let touch = touches.first, let overlay else { return }
        let point = touch.location(in: self)
        let area = overlay.layoutArea
        var placement = placementAtStart
        placement.dx += (point.x - dragStart.x) / max(area.width, 1)
        placement.dy += (point.y - dragStart.y) / max(area.height, 1)
        overlay.setPlacement(placement, of: group)
        refresh()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { endDrag() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { endDrag() }

    private func endDrag() {
        activeGroup = nil
        refresh()
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        guard let overlay else { return }
        switch recognizer.state {
        case .began:
            pinchGroup = overlay.group(at: recognizer.location(in: self)) ?? lastGroup
            if let pinchGroup { scaleAtStart = overlay.placement(of: pinchGroup).scale }
        case .changed:
            guard let pinchGroup else { return }
            var placement = overlay.placement(of: pinchGroup)
            placement.scale = min(max(scaleAtStart * recognizer.scale, 0.6), 1.8)
            overlay.setPlacement(placement, of: pinchGroup)
        default:
            pinchGroup = nil
            activeGroup = nil
        }
        refresh()
    }

    @objc private func resetTapped() {
        overlay?.resetPlacements()
        refresh()
    }

    @objc private func cancelTapped() { overlay?.endEditing(save: false) }
    @objc private func doneTapped() { overlay?.endEditing(save: true) }
}

/// A short message over the game (from C++: screenshot saved, ...)
@_cdecl("v3k_controls_toast")
public func v3kControlsToast(_ message: UnsafePointer<CChar>?) {
    guard let message else { return }
    let text = String(cString: message)
    MainActor.assumeIsolated {
        (ControlsHost.window?.rootViewController?.view as? ControlsOverlayView)?.showToast(text)
    }
}
