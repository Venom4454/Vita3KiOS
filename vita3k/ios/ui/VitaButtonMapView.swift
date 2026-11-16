// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import GameController
import SwiftUI

/// Button mapping on a drawing of a PS Vita: tap a button to see which controller button triggers it and
/// change it (from a list, or by pressing the controller button). Pressing buttons on a connected
/// controller lights up the Vita button they trigger, so the mapping can be tested right here.
struct VitaButtonMapView: View {
    /// Vita buttons by mapping slot (the SDL gamepad button number the slot stands for)
    struct VitaButton: Identifiable, Hashable {
        let id: Int32
        let name: String
        let glyph: String
    }

    static let buttons: [Int32: VitaButton] = [
        0: VitaButton(id: 0, name: "Cross", glyph: "✕"), 1: VitaButton(id: 1, name: "Circle", glyph: "○"),
        2: VitaButton(id: 2, name: "Square", glyph: "□"), 3: VitaButton(id: 3, name: "Triangle", glyph: "△"),
        4: VitaButton(id: 4, name: "Select", glyph: "SELECT"), 5: VitaButton(id: 5, name: "PS button", glyph: "PS"),
        6: VitaButton(id: 6, name: "Start", glyph: "START"), 7: VitaButton(id: 7, name: "L3 (PS TV)", glyph: "L3"),
        8: VitaButton(id: 8, name: "R3 (PS TV)", glyph: "R3"), 9: VitaButton(id: 9, name: "L", glyph: "L"),
        10: VitaButton(id: 10, name: "R", glyph: "R"), 11: VitaButton(id: 11, name: "D-pad up", glyph: "▲"),
        12: VitaButton(id: 12, name: "D-pad down", glyph: "▼"), 13: VitaButton(id: 13, name: "D-pad left", glyph: "◀"),
        14: VitaButton(id: 14, name: "D-pad right", glyph: "▶"),
    ]

    static let physicalNames: [Int32: String] = [
        0: "Bottom face (A / ✕)", 1: "Right face (B / ○)", 2: "Left face (X / □)", 3: "Top face (Y / △)",
        4: "View / Select / Share", 5: "Home / PS", 6: "Menu / Start / Options",
        7: "Left stick press", 8: "Right stick press", 9: "Left shoulder", 10: "Right shoulder",
        11: "D-pad up", 12: "D-pad down", 13: "D-pad left", 14: "D-pad right",
    ]

    @State private var binds: [Int32] = Array(0..<15)
    @State private var selected: Int32? = 0
    @State private var side = 0 // 0 front, 1 back
    @State private var listening = false
    @StateObject private var pad = PadWatcher()

    /// Vita buttons lit by what's held on the controller right now (through the mapping)
    private var lit: Set<Int32> {
        var out = Set<Int32>()
        for physical in pad.held {
            for (slot, bound) in binds.enumerated() where bound == physical { out.insert(Int32(slot)) }
        }
        return out
    }

    var body: some View {
        Form {
            Section {
                Picker("Side", selection: $side) {
                    Text("Front").tag(0)
                    Text("Back").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                VitaDrawing(side: side, selected: selected, lit: lit) { slot in
                    selected = slot
                    listening = false
                }
                .aspectRatio(2.2, contentMode: .fit)
                .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
                .listRowBackground(Color.clear)
            } footer: {
                Text(pad.connected ? "Press buttons on \(pad.name): the PS Vita button each one triggers lights up." : "Connect a controller to test the mapping here. Tap a button on the PS Vita to change it.")
            }

            if let slot = selected, let button = Self.buttons[slot] {
                Section {
                    LabeledContent("PS Vita button", value: "\(button.glyph == button.name ? "" : button.glyph + "  ")\(button.name)")
                    Picker("Controller button", selection: Binding(
                        get: { binds[Int(slot)] },
                        set: { assign(slot, $0) })) {
                        ForEach(0..<15, id: \.self) { physical in
                            Text(Self.physicalNames[Int32(physical)] ?? "Button \(physical)").tag(Int32(physical))
                        }
                    }
                    if pad.connected {
                        Button {
                            listening.toggle()
                        } label: {
                            Label(listening ? "Press a controller button…" : "Assign by pressing a button", systemImage: listening ? "dot.radiowaves.left.and.right" : "hand.tap")
                        }
                    }
                } header: {
                    Text("Selected")
                }
            }

            Section {
                Button("Swap ✕ and ○ (Japanese style)") {
                    let cross = binds[0]
                    assign(0, binds[1])
                    assign(1, cross)
                }
                Button("Reset to default", role: .destructive) {
                    v3k_reset_controller_binds()
                    load()
                }
                NavigationLink("List view") { ControllerMappingView() }
            } footer: {
                Text("Applies to physical controllers; the on-screen buttons follow it automatically. The touch screen and rear touchpad work by touch (rear touch has its own on-screen buttons in games).")
            }
        }
        .navigationTitle("Button mapping")
        .onAppear {
            load()
            pad.start()
        }
        .onDisappear { pad.stop() }
        .onChange(of: pad.lastPressed) { _, pressed in
            guard listening, let pressed, let slot = selected else { return }
            assign(slot, pressed)
            listening = false
        }
    }

    private func assign(_ slot: Int32, _ physical: Int32) {
        binds[Int(slot)] = physical
        _ = v3k_set_controller_bind(slot, physical)
    }

    private func load() {
        guard let pointer = v3k_controller_binds_json() else { return }
        let json = String(cString: pointer)
        v3k_free_string(pointer)
        if let data = json.data(using: .utf8), let decoded = try? JSONDecoder().decode([Int32].self, from: data), decoded.count >= 15 {
            binds = decoded
        }
    }
}

/// Watches the current controller and reports held buttons as SDL gamepad button numbers
final class PadWatcher: ObservableObject {
    @Published var held = Set<Int32>()
    @Published var lastPressed: Int32?
    @Published var connected = false
    @Published var name = "your controller"
    private var observers: [NSObjectProtocol] = []

    func start() {
        attach()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.attach() })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.attach() })
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        GCController.controllers().forEach { $0.extendedGamepad?.valueChangedHandler = nil }
    }

    private func attach() {
        guard let controller = GCController.current ?? GCController.controllers().first, let gamepad = controller.extendedGamepad else {
            connected = false
            held = []
            return
        }
        connected = true
        name = controller.vendorName ?? "your controller"
        gamepad.valueChangedHandler = { [weak self] gp, _ in
            var now = Set<Int32>()
            let pairs: [(GCControllerButtonInput?, Int32)] = [
                (gp.buttonA, 0), (gp.buttonB, 1), (gp.buttonX, 2), (gp.buttonY, 3),
                (gp.buttonOptions, 4), (gp.buttonHome, 5), (gp.buttonMenu, 6),
                (gp.leftThumbstickButton, 7), (gp.rightThumbstickButton, 8),
                (gp.leftShoulder, 9), (gp.rightShoulder, 10),
                (gp.dpad.up, 11), (gp.dpad.down, 12), (gp.dpad.left, 13), (gp.dpad.right, 14),
            ]
            for (input, id) in pairs where input?.isPressed == true { now.insert(id) }
            DispatchQueue.main.async {
                guard let self else { return }
                let fresh = now.subtracting(self.held)
                self.held = now
                if let first = fresh.sorted().first { self.lastPressed = first }
            }
        }
    }
}

/// A PS Vita drawn from shapes, front or back; every mappable button is tappable
struct VitaDrawing: View {
    let side: Int
    let selected: Int32?
    let lit: Set<Int32>
    let tap: (Int32) -> Void

    private let body1 = Color(white: 0.13)
    private let edge = Color(white: 0.28)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // shell
                RoundedRectangle(cornerRadius: h * 0.42, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.2), body1], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: h * 0.42, style: .continuous).stroke(edge, lineWidth: 1.5))
                    .frame(width: w * 0.96, height: h * 0.86)
                    .position(x: w / 2, y: h * 0.53)
                // shoulders
                shoulder(9, x: w * 0.17, w: w, h: h)
                shoulder(10, x: w * 0.83, w: w, h: h)
                if side == 0 { front(w: w, h: h) } else { back(w: w, h: h) }
            }
        }
    }

    @ViewBuilder private func front(w: CGFloat, h: CGFloat) -> some View {
        // screen
        RoundedRectangle(cornerRadius: 6)
            .fill(LinearGradient(colors: [Color(red: 0.08, green: 0.1, blue: 0.16), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Text("Touch screen").font(.system(size: h * 0.06, weight: .medium)).foregroundStyle(.white.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(white: 0.3), lineWidth: 1))
            .frame(width: w * 0.5, height: w * 0.5 * 544 / 960)
            .position(x: w / 2, y: h * 0.52)
        // D-pad
        let dx = w * 0.135, dy = h * 0.38, ds = h * 0.105
        key(11, x: dx, y: dy - ds, size: ds)
        key(12, x: dx, y: dy + ds, size: ds)
        key(13, x: dx - ds, y: dy, size: ds)
        key(14, x: dx + ds, y: dy, size: ds)
        // face buttons
        let fx = w * 0.865, fy = h * 0.38, fs = h * 0.105
        round(3, x: fx, y: fy - fs, size: fs, color: Color(red: 0.35, green: 0.85, blue: 0.7))
        round(0, x: fx, y: fy + fs, size: fs, color: Color(red: 0.55, green: 0.65, blue: 1))
        round(2, x: fx - fs, y: fy, size: fs, color: Color(red: 0.95, green: 0.55, blue: 0.85))
        round(1, x: fx + fs, y: fy, size: fs, color: Color(red: 1, green: 0.42, blue: 0.42))
        // sticks (L3/R3 exist on a PS TV)
        stick(7, x: w * 0.165, y: h * 0.7, size: h * 0.15)
        stick(8, x: w * 0.835, y: h * 0.7, size: h * 0.15)
        // PS, Select, Start
        pill(5, x: w * 0.12, y: h * 0.86, w: h * 0.12, h: h * 0.08)
        pill(4, x: w * 0.82, y: h * 0.86, w: h * 0.2, h: h * 0.06)
        pill(6, x: w * 0.9, y: h * 0.86, w: h * 0.2, h: h * 0.06)
    }

    @ViewBuilder private func back(w: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(white: 0.17))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.32), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .overlay(VStack(spacing: 4) {
                Text("Rear touchpad").font(.system(size: h * 0.07, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                Text("Used by touch: on-screen rear-touch buttons in games").font(.system(size: h * 0.045)).foregroundStyle(.white.opacity(0.35))
            })
            .frame(width: w * 0.56, height: h * 0.46)
            .position(x: w / 2, y: h * 0.52)
        Text("Back of the PS Vita: L and R are the shoulder buttons above.")
            .font(.system(size: h * 0.045))
            .foregroundStyle(.white.opacity(0.4))
            .position(x: w / 2, y: h * 0.86)
    }

    private func state(_ id: Int32) -> (fill: Color, ring: Color) {
        if lit.contains(id) { return (Color.accentColor, .white) }
        if selected == id { return (Color.accentColor.opacity(0.45), Color.accentColor) }
        return (Color(white: 0.22), Color(white: 0.38))
    }

    private func label(_ id: Int32, size: CGFloat) -> some View {
        Text(VitaButtonMapView.buttons[id]?.glyph ?? "").font(.system(size: size, weight: .bold)).foregroundStyle(.white)
            .minimumScaleFactor(0.4).lineLimit(1)
    }

    private func key(_ id: Int32, x: CGFloat, y: CGFloat, size: CGFloat) -> some View {
        let s = state(id)
        return RoundedRectangle(cornerRadius: size * 0.2).fill(s.fill)
            .overlay(RoundedRectangle(cornerRadius: size * 0.2).stroke(s.ring, lineWidth: 1.5))
            .overlay(label(id, size: size * 0.42))
            .frame(width: size, height: size).position(x: x, y: y)
            .contentShape(Rectangle()).onTapGesture { tap(id) }
            .accessibilityLabel(VitaButtonMapView.buttons[id]?.name ?? "")
    }

    private func round(_ id: Int32, x: CGFloat, y: CGFloat, size: CGFloat, color: Color) -> some View {
        let s = state(id)
        return Circle().fill(s.fill)
            .overlay(Circle().stroke(selected == id || lit.contains(id) ? s.ring : color.opacity(0.8), lineWidth: 1.8))
            .overlay(Text(VitaButtonMapView.buttons[id]?.glyph ?? "").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(color))
            .frame(width: size, height: size).position(x: x, y: y)
            .contentShape(Circle()).onTapGesture { tap(id) }
            .accessibilityLabel(VitaButtonMapView.buttons[id]?.name ?? "")
    }

    private func stick(_ id: Int32, x: CGFloat, y: CGFloat, size: CGFloat) -> some View {
        let s = state(id)
        return Circle().fill(RadialGradient(colors: [Color(white: 0.3), s.fill], center: .center, startRadius: 1, endRadius: size / 2))
            .overlay(Circle().stroke(s.ring, lineWidth: 1.5))
            .overlay(label(id, size: size * 0.26).opacity(0.8))
            .frame(width: size, height: size).position(x: x, y: y)
            .contentShape(Circle()).onTapGesture { tap(id) }
            .accessibilityLabel(VitaButtonMapView.buttons[id]?.name ?? "")
    }

    private func pill(_ id: Int32, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        let s = state(id)
        return Capsule().fill(s.fill).overlay(Capsule().stroke(s.ring, lineWidth: 1.2))
            .overlay(label(id, size: h * 0.55))
            .frame(width: w, height: h).position(x: x, y: y)
            .contentShape(Capsule()).onTapGesture { tap(id) }
            .accessibilityLabel(VitaButtonMapView.buttons[id]?.name ?? "")
    }

    private func shoulder(_ id: Int32, x: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        let s = state(id)
        return RoundedRectangle(cornerRadius: h * 0.06).fill(s.fill)
            .overlay(RoundedRectangle(cornerRadius: h * 0.06).stroke(s.ring, lineWidth: 1.5))
            .overlay(label(id, size: h * 0.07))
            .frame(width: w * 0.2, height: h * 0.12).position(x: x, y: h * 0.07)
            .contentShape(Rectangle()).onTapGesture { tap(id) }
            .accessibilityLabel(VitaButtonMapView.buttons[id]?.name ?? "")
    }
}
