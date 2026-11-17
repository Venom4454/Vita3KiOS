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
        var text = inputs.isEmpty ? "No buttons" : inputs.map(\.title).joined(separator: " + ")
        if toggle { text += " · toggle" }
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
        if touch != nil { steer(0, 0) }
        touch = nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touch == nil, let first = touches.first else { return }
        touch = first
        origin = first.location(in: superview)
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
        var dx = (point.x - origin.x) / lookRadius, dy = (point.y - origin.y) / lookRadius
        let length = sqrt(dx * dx + dy * dy)
        if length > 1 {
            dx /= length
            dy /= length
        }
        steer(dx, dy)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        self.touch = nil
        if macro.look != .none { steer(0, 0) }
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
                                Text(macro.inputs.isEmpty ? "Not set up yet" : "Holds \(macro.inputs.map(\.title).joined(separator: " + "))")
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
        }
        .navigationTitle(macro.name.isEmpty ? "Macro" : macro.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
