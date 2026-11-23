// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

// Extras for the on-screen PS Vita controls (TouchControls.swift): buttons held by more than one
// control at once, the stick styles (fixed, floating, screen zones), the touch reach around buttons,
// and macro buttons the player sets up (one button that holds several, optionally steering a stick
// while held: aim and look around with one thumb).

import SwiftUI
import UIKit

// MARK: - Presses shared between controls

/// A button that two controls hold at once (a macro and the button itself) stays down until both let
/// go. Buttons are SDL gamepad buttons; L2/R2 are the trigger axes.
@MainActor
enum PadPress {
    private static var buttons: [Int32: Int] = [:]
    private static var triggers: [Int32: Int] = [:]

    static func button(_ button: Int32, _ pressed: Bool) {
        let count = max((buttons[button] ?? 0) + (pressed ? 1 : -1), 0)
        buttons[button] = count
        v3k_pad_set_button(button, count > 0)
    }

    static func trigger(_ axis: Int32, _ pressed: Bool) {
        let count = max((triggers[axis] ?? 0) + (pressed ? 1 : -1), 0)
        triggers[axis] = count
        v3k_pad_set_axis(axis, count > 0 ? 1 : 0)
    }

    /// Everything up (menu opened, controls hidden, game paused)
    static func releaseAll() {
        buttons.removeAll()
        triggers.removeAll()
        v3k_pad_release_all()
    }
}

/// The Vita's inputs a macro can hold
enum VitaInput: Int, CaseIterable, Codable, Identifiable {
    case cross, circle, square, triangle, l, r, up, down, left, right, start, select, l2, r2, l3, r3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .cross: "✕"
        case .circle: "○"
        case .square: "□"
        case .triangle: "△"
        case .l: "L"
        case .r: "R"
        case .up: "▲"
        case .down: "▼"
        case .left: "◀"
        case .right: "▶"
        case .start: "Start"
        case .select: "Select"
        case .l2: "L2"
        case .r2: "R2"
        case .l3: "L3"
        case .r3: "R3"
        }
    }

    /// L2, R2, L3 and R3 only reach the game in PS TV mode
    var pstvOnly: Bool { self == .l2 || self == .r2 || self == .l3 || self == .r3 }

    /// SDL gamepad button (before the player's mapping), or nil for the triggers
    private var sdlButton: Int32? {
        switch self {
        case .cross: 0
        case .circle: 1
        case .square: 2
        case .triangle: 3
        case .select: 4
        case .start: 6
        case .l3: 7
        case .r3: 8
        case .l: 9
        case .r: 10
        case .up: 11
        case .down: 12
        case .left: 13
        case .right: 14
        case .l2, .r2: nil
        }
    }

    @MainActor
    func send(_ pressed: Bool) {
        if let button = sdlButton {
            PadPress.button(TouchMapping.button(for: button), pressed)
        } else {
            PadPress.trigger(self == .l2 ? 4 : 5, pressed) // SDL left / right trigger
        }
    }
}

// MARK: - Settings

/// Settings › Controls › Sticks
enum StickStyle: String, CaseIterable, Identifiable {
    /// The sticks stay where they are drawn
    case fixed
    /// The stick starts wherever the thumb lands near it
    case floating
    /// No sticks drawn: the left and right halves of the screen are the sticks (drag from anywhere)
    case zones

    var id: String { rawValue }

    var name: String {
        switch self {
        case .fixed: "Fixed"
        case .floating: "Floating"
        case .zones: "Screen halves"
        }
    }

    static var current: StickStyle {
        StickStyle(rawValue: UserDefaults.standard.string(forKey: "v3k.touchStickStyle") ?? "") ?? .fixed
    }
}

/// Settings › Controls › Touch reach: how far outside a button a tap still presses it, as a share of
/// the button's size (the nearest button wins)
enum TouchReach: String, CaseIterable, Identifiable {
    case exact, larger, largest

    var id: String { rawValue }

    var name: String {
        switch self {
        case .exact: "On the button"
        case .larger: "Near the button"
        case .largest: "Generous"
        }
    }

    var share: CGFloat {
        switch self {
        case .exact: 0
        case .larger: 0.35
        case .largest: 0.6
        }
    }

    static var current: TouchReach {
        TouchReach(rawValue: UserDefaults.standard.string(forKey: "v3k.touchReach") ?? "") ?? .exact
    }
}

// MARK: - Advanced touch (Settings › Controls › Advanced touch)

/// Opt-in tuning for the sticks and macro buttons. Every default keeps the controls as they were.
enum TouchTuning {
    /// Which sticks turn like a mouse: they move only while the finger moves, by how fast it moves, and
    /// go back to neutral the moment it stops (no lifting needed). Macro buttons that steer a stick
    /// follow the stick they steer.
    enum MouseLook: String, CaseIterable, Identifiable {
        case off, rightStick, bothSticks
        var id: String { rawValue }
        var name: String {
            switch self {
            case .off: "Off"
            case .rightStick: "Right stick (camera)"
            case .bothSticks: "Both sticks"
            }
        }
    }

    private static let defaults = UserDefaults.standard

    static var mouseLook: MouseLook {
        MouseLook(rawValue: defaults.string(forKey: "v3k.touchMouseLook") ?? "") ?? .off
    }

    /// Mouse-style turning speed (1 = a 900 pt/s swipe is a full stick push)
    static var mouseSensitivity: CGFloat {
        CGFloat(defaults.object(forKey: "v3k.touchMouseSensitivity") as? Double ?? 1)
    }

    /// 0: turning follows finger speed one to one. Up to 1: slow drags turn finely, fast ones much more
    static var mouseAcceleration: CGFloat {
        CGFloat(defaults.object(forKey: "v3k.touchMouseAcceleration") as? Double ?? 0)
    }

    /// Share of a stick push the smallest movement already gives (0: none). Games ignore a small push
    /// (their dead zone): with this, aiming answers from the first millimetre of a drag
    static var deadZoneSkip: CGFloat {
        CGFloat(defaults.object(forKey: "v3k.touchDeadZoneSkip") as? Double ?? 0)
    }

    /// Screen-halves sticks: where the left stick's area ends (share of the width) and how much of the
    /// top of the screen stays for the game's touchscreen (share of the height)
    static var zoneSplit: CGFloat {
        CGFloat(defaults.object(forKey: "v3k.touchZoneSplit") as? Double ?? 0.5)
    }

    static var zoneTop: CGFloat {
        CGFloat(defaults.object(forKey: "v3k.touchZoneTop") as? Double ?? 0)
    }

    /// The layout editor moves each d-pad, face, Start and Select button on its own
    static var separateButtons: Bool {
        defaults.bool(forKey: "v3k.touchSeparateButtons")
    }

    static func usesMouse(rightStick: Bool) -> Bool {
        switch mouseLook {
        case .off: false
        case .rightStick: rightStick
        case .bothSticks: true
        }
    }

    /// A stick push with the dead-zone skip applied (direction kept, at most a full push)
    static func shaped(_ x: CGFloat, _ y: CGFloat, skip: CGFloat = deadZoneSkip) -> (CGFloat, CGFloat) {
        let length = sqrt(x * x + y * y)
        guard length > 0.001 else { return (0, 0) }
        let clamped = min(length, 1)
        let out = skip > 0 ? skip + (1 - skip) * clamped : clamped
        return (x / length * out, y / length * out)
    }
}

/// A stick steered like a mouse: the push follows how fast the finger moves, and drops to neutral as
/// soon as it stops moving (the finger can stay down)
@MainActor
final class MouseLookStick {
    private let send: (CGFloat, CGFloat) -> Void
    private var last: CGPoint?
    private var lastTime: TimeInterval = 0
    private var value = CGVector.zero
    private var stop: DispatchWorkItem?
    private let sensitivity = max(TouchTuning.mouseSensitivity, 0.1)
    private let acceleration = min(max(TouchTuning.mouseAcceleration, 0), 1)
    private let skip = TouchTuning.deadZoneSkip
    /// The push now (the on-screen knob shows it)
    private(set) var current = CGVector.zero

    init(send: @escaping (CGFloat, CGFloat) -> Void) {
        self.send = send
    }

    func begin(at point: CGPoint, time: TimeInterval) {
        last = point
        lastTime = time
        value = .zero
        output(.zero)
    }

    func move(to point: CGPoint, time: TimeInterval) {
        guard let previous = last else {
            begin(at: point, time: time)
            return
        }
        // A resting finger still reports sub-point jitter: below this it counts as still (the stop timer
        // brings the stick back), and the movement adds up until it is real
        let travel = hypot(point.x - previous.x, point.y - previous.y)
        guard travel >= 0.75 else { return }
        // touches come every 8-16 ms; a longer gap means the finger had stopped
        let dt = min(max(time - lastTime, 1.0 / 240), 0.05)
        last = point
        lastTime = time
        let fullSpeed = 900 / sensitivity // points per second for a full push
        var vx = (point.x - previous.x) / dt / fullSpeed
        var vy = (point.y - previous.y) / dt / fullSpeed
        let speed = sqrt(vx * vx + vy * vy)
        if speed > 0.0001, acceleration > 0 {
            let curved = pow(min(speed, 4), 1 + acceleration)
            vx *= curved / speed
            vy *= curved / speed
        }
        // a little smoothing: touch samples are uneven
        value = CGVector(dx: value.dx * 0.35 + vx * 0.65, dy: value.dy * 0.35 + vy * 0.65)
        output(value)
        // no movement for a moment: back to neutral, the finger's spot is the new centre
        stop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.value = .zero
            self.output(.zero)
        }
        stop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func end() {
        stop?.cancel()
        stop = nil
        last = nil
        value = .zero
        output(.zero)
    }

    private func output(_ push: CGVector) {
        let (x, y) = TouchTuning.shaped(push.dx, push.dy, skip: skip)
        current = CGVector(dx: x, dy: y)
        send(x, y)
    }
}

// MARK: - Macro buttons

struct TouchMacro: Codable, Identifiable, Equatable {
    enum Look: Int, Codable, CaseIterable, Identifiable {
        case none, rightStick, leftStick
        var id: Int { rawValue }
        var name: String {
            switch self {
            case .none: "Nothing"
            case .rightStick: "Right stick (camera)"
            case .leftStick: "Left stick"
            }
        }
    }

    var id = UUID()
    var name = "M1"
    var inputs: [VitaInput] = []
    /// A tap turns it on, the next tap off (otherwise held while touched)
    var toggle = false
    /// Dragging the finger while it is held steers this stick
    var look: Look = .none
    /// Also touches the game's screen here while held (0...1 across the game picture). Optional so
    /// macros saved before it existed still load
    var touchX: Double?
    var touchY: Double?

    var touchPoint: CGPoint? {
        get {
            guard let touchX, let touchY else { return nil }
            return CGPoint(x: touchX, y: touchY)
        }
        set {
            touchX = newValue.map { Double(min(max($0.x, 0), 1)) }
            touchY = newValue.map { Double(min(max($0.y, 0), 1)) }
        }
    }

    static let limit = 4
    private static let key = "v3k.touchMacros"

    static func load() -> [TouchMacro] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let macros = try? JSONDecoder().decode([TouchMacro].self, from: data) else { return [] }
        return Array(macros.prefix(limit))
    }

    static func save(_ macros: [TouchMacro]) {
        if let data = try? JSONEncoder().encode(Array(macros.prefix(limit))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// What it does, in a few words (settings list)
    var summary: String {
        var text = inputs.isEmpty ? (touchPoint == nil ? "No buttons" : "Touch only") : inputs.map(\.title).joined(separator: " + ")
        if toggle { text += " · toggle" }
        if let point = touchPoint { text += " · touch \(Int(point.x * 100))%, \(Int(point.y * 100))%" }
        if look != .none { text += " · drag: \(look == .rightStick ? "camera" : "left stick")" }
        return text
    }
}

/// A macro on screen: holds its buttons while touched (or until tapped again), and steers a stick when
/// the finger drags
final class MacroButtonView: UIView {
    let macro: TouchMacro
    private let label = UILabel()
    private var touch: UITouch?
    private var origin = CGPoint.zero
    private var latched = false
    private var baseFill = UIColor.black.withAlphaComponent(0.62)
    private var pressedFill = UIColor.white.withAlphaComponent(0.45)
    private let haptics = UserDefaults.standard.object(forKey: "v3k.touchHaptics") as? Bool ?? true
    private let feedback = UIImpactFeedbackGenerator(style: .medium)
    /// Finger travel for a full stick push
    var lookRadius: CGFloat = 60
    /// Advanced touch › mouse-style turning, for the stick this macro steers
    private lazy var mouse: MouseLookStick? = {
        guard macro.look != .none, TouchTuning.usesMouse(rightStick: macro.look == .rightStick) else { return nil }
        return MouseLookStick { [weak self] x, y in self?.steer(x, y) }
    }()
    /// A finger id of its own for the touch it places on the game's screen
    private lazy var touchFinger: UInt64 = 0x4D41_4352_4F00 | UInt64(UInt(bitPattern: macro.id.hashValue) & 0xFF)
    private var touching = false

    init(macro: TouchMacro, tint: UIColor) {
        self.macro = macro
        super.init(frame: .zero)
        isMultipleTouchEnabled = false
        label.text = macro.name
        label.font = .systemFont(ofSize: 14, weight: .heavy)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.textAlignment = .center
        label.textColor = tint
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.7
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = .zero
        addSubview(label)
        backgroundColor = baseFill
        pressedFill = Theme.accentUIColor.withAlphaComponent(0.6)
        layer.borderWidth = 1.5
        layer.borderColor = Theme.accentUIColor.withAlphaComponent(0.8).cgColor
        accessibilityLabel = "Macro \(macro.name)"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 4, dy: 2)
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    private var holding = false

    private func hold(_ on: Bool) {
        guard on != holding else { return }
        holding = on
        for input in macro.inputs { input.send(on) }
        if let point = macro.touchPoint, on != touching {
            touching = on
            v3k_touch_inject_game(on ? 0 : 2, touchFinger, Float(point.x), Float(point.y))
        }
        backgroundColor = on ? pressedFill : baseFill
        if on && haptics { feedback.impactOccurred() }
    }

    private func steer(_ x: CGFloat, _ y: CGFloat) {
        switch macro.look {
        case .none: return
        case .rightStick:
            v3k_pad_set_axis(2, Float(x))
            v3k_pad_set_axis(3, Float(y))
        case .leftStick:
            v3k_pad_set_axis(0, Float(x))
            v3k_pad_set_axis(1, Float(y))
        }
    }

    /// Lets go of everything (controls hidden, menu opened)
    func releaseIfHeld() {
        latched = false
        hold(false)
        if touch != nil {
            mouse?.end()
            steer(0, 0)
        }
        touch = nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touch == nil, let first = touches.first else { return }
        touch = first
        origin = first.location(in: superview)
        mouse?.begin(at: origin, time: first.timestamp)
        if macro.toggle {
            latched.toggle()
            hold(latched)
        } else {
            hold(true)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch), macro.look != .none else { return }
        let point = touch.location(in: superview)
        if let mouse {
            mouse.move(to: point, time: touch.timestamp)
            return
        }
        // tracked from where the finger landed (on the button itself); Advanced touch › dead-zone skip
        // makes the first millimetres count
        let (dx, dy) = TouchTuning.shaped((point.x - origin.x) / lookRadius, (point.y - origin.y) / lookRadius)
        steer(dx, dy)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        self.touch = nil
        if macro.look != .none {
            mouse?.end()
            steer(0, 0)
        }
        if !macro.toggle { hold(false) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchesEnded(touches, with: event) }
}

// MARK: - Settings › Controls › Macro buttons

struct MacroButtonsView: View {
    @State private var macros = TouchMacro.load()

    var body: some View {
        Form {
            Section {
                ForEach($macros) { $macro in
                    NavigationLink {
                        MacroEditorView(macro: $macro)
                    } label: {
                        HStack(spacing: 12) {
                            Text(macro.name)
                                .font(.system(size: 13, weight: .heavy))
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Color.black.opacity(0.75)))
                                .overlay(Circle().stroke(Theme.accent, lineWidth: 1.5))
                                .foregroundStyle(.white)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(macro.inputs.isEmpty && macro.touchPoint == nil ? "Not set up yet"
                                     : macro.inputs.isEmpty ? "Touches the screen" : "Holds \(macro.inputs.map(\.title).joined(separator: " + "))")
                                Text(macro.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { macros.remove(atOffsets: $0) }
                .onMove { macros.move(fromOffsets: $0, toOffset: $1) }
                if macros.count < TouchMacro.limit {
                    Button {
                        macros.append(TouchMacro(name: "M\(macros.count + 1)"))
                    } label: {
                        Label("Add a macro button", systemImage: "plus.circle.fill")
                    }
                    Button {
                        macros.append(TouchMacro(name: "AIM", inputs: [.l], look: .rightStick))
                    } label: {
                        Label("Add \"aim and look\" (holds L, drag to turn the camera)", systemImage: "scope")
                    }
                }
            } footer: {
                Text("Up to four buttons that hold several Vita buttons at once. One can also steer a stick while you hold it: hold to aim and drag the same finger to look around. They appear on screen the next time a game starts; move and resize them with Edit control layout in the game menu.")
            }
        }
        .navigationTitle("Macro buttons")
        .toolbar { if !macros.isEmpty { EditButton() } }
        .onChange(of: macros) { _, updated in TouchMacro.save(updated) }
    }
}

struct MacroEditorView: View {
    @Binding var macro: TouchMacro

    var body: some View {
        Form {
            Section {
                TextField("Label", text: Binding(get: { macro.name }, set: { macro.name = String($0.prefix(4)) }))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            } header: {
                Text("Label")
            } footer: {
                Text("Up to four letters, shown on the button.")
            }
            Section {
                ForEach(VitaInput.allCases) { input in
                    Button {
                        if let index = macro.inputs.firstIndex(of: input) {
                            macro.inputs.remove(at: index)
                        } else {
                            macro.inputs.append(input)
                        }
                    } label: {
                        HStack {
                            Text(input.title).foregroundStyle(.primary)
                            if input.pstvOnly {
                                Text("PS TV mode").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if macro.inputs.contains(input) {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
            } header: {
                Text("Buttons it holds")
            }
            Section {
                Toggle("Tap to turn on, tap again to turn off", isOn: $macro.toggle)
                Picker("Dragging while held moves", selection: $macro.look) {
                    ForEach(TouchMacro.Look.allCases) { look in
                        Text(look.name).tag(look)
                    }
                }
            } footer: {
                Text("Example for shooters: hold L and set dragging to the right stick. Press to aim, and slide the same thumb to look around while aiming.")
            }
            Section {
                Toggle("Touch the game's screen", isOn: Binding(get: { macro.touchPoint != nil },
                                                                set: { macro.touchPoint = $0 ? CGPoint(x: 0.5, y: 0.5) : nil }))
                if let point = macro.touchPoint {
                    TouchSpotPicker(point: Binding(get: { point }, set: { macro.touchPoint = $0 }))
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                }
            } footer: {
                Text("While the macro is held, the game feels a finger on this spot of its touchscreen: for corner taps and other touch controls, even with screen-halves sticks. Tap or drag in the box to place it.")
            }
        }
        .navigationTitle(macro.name.isEmpty ? "Macro" : macro.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The Vita's screen in small: tap or drag to place the spot a macro touches
struct TouchSpotPicker: View {
    @Binding var point: CGPoint

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.85))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.accent.opacity(0.6), lineWidth: 1))
                // thirds, to aim at corners and edges
                Path { path in
                    for i in 1...2 {
                        let x = size.width * CGFloat(i) / 3, y = size.height * CGFloat(i) / 3
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                Circle()
                    .fill(Theme.accent)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .frame(width: 22, height: 22)
                    .position(x: point.x * size.width, y: point.y * size.height)
                Text("\(Int(point.x * 960)), \(Int(point.y * 544))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(6)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                point = CGPoint(x: min(max(value.location.x / max(size.width, 1), 0), 1),
                                y: min(max(value.location.y / max(size.height, 1), 0), 1))
            })
        }
        .aspectRatio(960.0 / 544.0, contentMode: .fit)
        .accessibilityLabel("Touch spot")
    }
}

// MARK: - Settings › Controls › Advanced touch

struct AdvancedTouchView: View {
    @AppStorage("v3k.touchMouseLook") private var mouseLook = TouchTuning.MouseLook.off.rawValue
    @AppStorage("v3k.touchMouseSensitivity") private var sensitivity = 1.0
    @AppStorage("v3k.touchMouseAcceleration") private var acceleration = 0.0
    @AppStorage("v3k.touchDeadZoneSkip") private var deadZoneSkip = 0.0
    @AppStorage("v3k.touchZoneSplit") private var zoneSplit = 0.5
    @AppStorage("v3k.touchZoneTop") private var zoneTop = 0.0
    @AppStorage("v3k.touchSeparateButtons") private var separateButtons = false

    var body: some View {
        Form {
            Section {
                Picker("Mouse-style turning", selection: $mouseLook) {
                    ForEach(TouchTuning.MouseLook.allCases) { mode in
                        Text(LocalizedStringKey(mode.name)).tag(mode.rawValue)
                    }
                }
                if mouseLook != TouchTuning.MouseLook.off.rawValue {
                    VStack(alignment: .leading) {
                        Text("Sensitivity: \(sensitivity, specifier: "%.2f")×")
                        Slider(value: $sensitivity, in: 0.25...3, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text("Acceleration: \(Int(acceleration * 100))%")
                        Slider(value: $acceleration, in: 0...1, step: 0.05)
                    }
                }
            } header: {
                Text("Camera")
            } footer: {
                Text("Like a mouse: the stick moves only while your finger moves, by how fast it moves, and the camera stops the moment your finger stops, without lifting it. Aim macros follow the stick they steer. Acceleration makes slow drags finer and fast ones turn further.")
            }
            Section {
                VStack(alignment: .leading) {
                    if deadZoneSkip == 0 {
                        Text("Skip the game's dead zone: off")
                    } else {
                        Text("Skip the game's dead zone: \(Int(deadZoneSkip * 100))%")
                    }
                    Slider(value: $deadZoneSkip, in: 0...0.4, step: 0.05)
                }
            } footer: {
                Text("Games ignore a small stick push. With this, the smallest drag already pushes the stick this far, so aiming answers from the first millimetre (also with aim macros). Around 20% suits most games; too much makes small moves jumpy.")
            }
            Section {
                VStack(alignment: .leading) {
                    Text("Left stick area: \(Int(zoneSplit * 100))% of the width")
                    Slider(value: $zoneSplit, in: 0.25...0.75, step: 0.05)
                }
                VStack(alignment: .leading) {
                    if zoneTop == 0 {
                        Text("Top kept for the touchscreen: only the buttons' row")
                    } else {
                        Text("Top kept for the touchscreen: \(Int(zoneTop * 100))% of the height")
                    }
                    Slider(value: $zoneTop, in: 0...0.6, step: 0.05)
                }
            } header: {
                Text("Screen-halves sticks")
            } footer: {
                Text("Where the left and right stick areas meet, and how much of the top of the screen still touches the game's touchscreen. Only with Sticks set to Screen halves.")
            }
            Section {
                Toggle("Move buttons one by one", isOn: $separateButtons)
            } footer: {
                Text("Edit control layout moves and resizes each d-pad, face, Start and Select button on its own instead of as a group. Where you already moved a group, the buttons start from there.")
            }
            Section {
                Button("Back to the defaults", role: .destructive) {
                    mouseLook = TouchTuning.MouseLook.off.rawValue
                    sensitivity = 1
                    acceleration = 0
                    deadZoneSkip = 0
                    zoneSplit = 0.5
                    zoneTop = 0
                    separateButtons = false
                }
            } footer: {
                Text("Changes take effect the next time a game starts.")
            }
        }
        .navigationTitle("Advanced touch")
    }
}
