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
                .aspectRatio(182.0 / 95.0, contentMode: .fit)
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

/// A PS Vita (PCH-1000) drawn to scale from its real measurements: 182 x 83.5 mm, 5" 960x544 screen,
/// controls where they sit on the real system. Everything is placed in millimetres and scaled to fit.
/// Front or back; every mappable button is tappable.
struct VitaDrawing: View {
    let side: Int
    let selected: Int32?
    let lit: Set<Int32>
    let tap: (Int32) -> Void

    static let bodyW: CGFloat = 182
    static let bodyH: CGFloat = 83.5

    /// The body: straight top and bottom edges, rounded ends (elliptical corners)
    static func bodyPath(in rect: CGRect) -> Path {
        let rx = rect.width * (38 / bodyW), ry = rect.height * (40.5 / bodyH)
        var path = Path()
        let r = rect
        path.move(to: CGPoint(x: r.minX + rx, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - rx, y: r.minY))
        path.addCurve(to: CGPoint(x: r.maxX, y: r.midY), control1: CGPoint(x: r.maxX - rx * 0.45, y: r.minY), control2: CGPoint(x: r.maxX, y: r.midY - ry * 0.55))
        path.addCurve(to: CGPoint(x: r.maxX - rx, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.midY + ry * 0.55), control2: CGPoint(x: r.maxX - rx * 0.45, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + rx, y: r.maxY))
        path.addCurve(to: CGPoint(x: r.minX, y: r.midY), control1: CGPoint(x: r.minX + rx * 0.45, y: r.maxY), control2: CGPoint(x: r.minX, y: r.midY + ry * 0.55))
        path.addCurve(to: CGPoint(x: r.minX + rx, y: r.minY), control1: CGPoint(x: r.minX, y: r.midY - ry * 0.55), control2: CGPoint(x: r.minX + rx * 0.45, y: r.minY))
        path.closeSubpath()
        return path
    }

    var body: some View {
        GeometryReader { geo in
            // millimetres -> points, the body centred and as large as fits (room above for L/R)
            let k = min(geo.size.width / (Self.bodyW + 4), geo.size.height / (Self.bodyH + 8))
            let ox = (geo.size.width - Self.bodyW * k) / 2, oy = (geo.size.height - Self.bodyH * k) / 2 + 2 * k
            let mm = { (x: CGFloat, y: CGFloat) in CGPoint(x: ox + x * k, y: oy + y * k) }
            let bodyRect = CGRect(x: ox, y: oy, width: Self.bodyW * k, height: Self.bodyH * k)
            ZStack {
                // shoulder buttons (top edge, at the corners; swapped on the back)
                shoulder(side == 0 ? 9 : 10, rect: CGRect(x: ox + 9 * k, y: oy - 2.2 * k, width: 34 * k, height: 5 * k), k: k)
                shoulder(side == 0 ? 10 : 9, rect: CGRect(x: ox + (Self.bodyW - 43) * k, y: oy - 2.2 * k, width: 34 * k, height: 5 * k), k: k)
                // shell
                Self.bodyPath(in: bodyRect)
                    .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.09)], startPoint: .top, endPoint: .bottom))
                Self.bodyPath(in: bodyRect).stroke(Color(white: 0.34), lineWidth: max(1, 0.35 * k))
                if side == 0 { front(mm: mm, k: k, body: bodyRect) } else { back(mm: mm, k: k, body: bodyRect) }
            }
        }
    }

    // MARK: front

    @ViewBuilder private func front(mm: @escaping (CGFloat, CGFloat) -> CGPoint, k: CGFloat, body: CGRect) -> some View {
        // glass front panel, just inside the edge
        Self.bodyPath(in: body.insetBy(dx: 1.4 * k, dy: 1.4 * k))
            .fill(LinearGradient(colors: [Color(white: 0.07), Color(white: 0.03)], startPoint: .top, endPoint: .bottom))
        // 5" OLED, 110.7 x 62.7 mm active area, centred
        RoundedRectangle(cornerRadius: 0.8 * k)
            .fill(LinearGradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.14), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Text("Touch screen").font(.system(size: 4 * k, weight: .medium)).foregroundStyle(.white.opacity(0.3)))
            .frame(width: 110.7 * k, height: 62.7 * k)
            .position(mm(91, 41.75))
        // D-pad: four arms around (21.5, 29)
        dpadArm(11, at: mm(21.5, 29 - 6.6), k: k, rotation: 0)
        dpadArm(12, at: mm(21.5, 29 + 6.6), k: k, rotation: 180)
        dpadArm(13, at: mm(21.5 - 6.6, 29), k: k, rotation: 270)
        dpadArm(14, at: mm(21.5 + 6.6, 29), k: k, rotation: 90)
        // face buttons around (160.5, 29)
        face(3, at: mm(160.5, 29 - 8.8), k: k, color: Color(red: 0.36, green: 0.84, blue: 0.68))
        face(0, at: mm(160.5, 29 + 8.8), k: k, color: Color(red: 0.56, green: 0.66, blue: 1))
        face(2, at: mm(160.5 - 8.8, 29), k: k, color: Color(red: 0.94, green: 0.56, blue: 0.84))
        face(1, at: mm(160.5 + 8.8, 29), k: k, color: Color(red: 1, green: 0.43, blue: 0.43))
        // analogue sticks (pressable on a PS TV: L3/R3)
        stick(7, at: mm(27, 55.5), k: k)
        stick(8, at: mm(155, 55.5), k: k)
        // PS button bottom left; Select and Start bottom right
        pill(5, at: mm(18.5, 69.5), size: CGSize(width: 8 * k, height: 6 * k), k: k, text: "PS")
        pill(4, at: mm(154, 69.5), size: CGSize(width: 7.5 * k, height: 3.6 * k), k: k, text: "SELECT")
        pill(6, at: mm(165, 69.5), size: CGSize(width: 7.5 * k, height: 3.6 * k), k: k, text: "START")
    }

    // MARK: back

    @ViewBuilder private func back(mm: @escaping (CGFloat, CGFloat) -> CGPoint, k: CGFloat, body: CGRect) -> some View {
        // finger grips
        Ellipse().fill(Color(white: 0.15)).overlay(Ellipse().stroke(Color(white: 0.26), lineWidth: max(1, 0.3 * k)))
            .frame(width: 24 * k, height: 46 * k).position(mm(24, 46))
        Ellipse().fill(Color(white: 0.15)).overlay(Ellipse().stroke(Color(white: 0.26), lineWidth: max(1, 0.3 * k)))
            .frame(width: 24 * k, height: 46 * k).position(mm(158, 46))
        // rear touchpad
        RoundedRectangle(cornerRadius: 3 * k)
            .fill(Color(white: 0.13))
            .overlay(RoundedRectangle(cornerRadius: 3 * k).stroke(Color(white: 0.3), lineWidth: max(1, 0.3 * k)))
            .overlay(VStack(spacing: 1.5 * k) {
                Text("Rear touchpad").font(.system(size: 4.2 * k, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                Text("Works by touch: games show on-screen rear-touch buttons").font(.system(size: 2.8 * k)).foregroundStyle(.white.opacity(0.35))
            })
            .frame(width: 98 * k, height: 50 * k)
            .position(mm(91, 46))
        // rear camera
        Circle().fill(Color.black).overlay(Circle().stroke(Color(white: 0.35), lineWidth: max(1, 0.3 * k)))
            .frame(width: 4 * k, height: 4 * k).position(mm(91, 11))
    }

    // MARK: pieces

    private func colors(_ id: Int32) -> (fill: Color, ring: Color, glow: Bool) {
        if lit.contains(id) { return (Color.accentColor, .white, true) }
        if selected == id { return (Color.accentColor.opacity(0.4), Color.accentColor, false) }
        return (Color(white: 0.17), Color(white: 0.36), false)
    }

    private func dpadArm(_ id: Int32, at p: CGPoint, k: CGFloat, rotation: Double) -> some View {
        let c = colors(id)
        // one arm: square end with a pointed inner end, 6.6 mm wide
        let arm = UnevenRoundedRectangle(topLeadingRadius: 1.2 * k, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 1.2 * k)
        return arm.fill(c.fill).overlay(arm.stroke(c.ring, lineWidth: max(1, 0.35 * k)))
            .overlay(Image(systemName: "triangle.fill").font(.system(size: 2.4 * k)).foregroundStyle(.white.opacity(0.6)).offset(y: -0.6 * k))
            .frame(width: 6.6 * k, height: 7.2 * k)
            .rotationEffect(.degrees(rotation))
            .shadow(color: c.glow ? Color.accentColor : .clear, radius: 3 * k)
            .position(p)
            .contentShape(Rectangle()).onTapGesture { tap(id) }
            .accessibilityLabel(VitaButtonMapView.buttons[id]?.name ?? "")
    }

    private func face(_ id: Int32, at p: CGPoint, k: CGFloat, color: Color) -> some View {
        let c = colors(id)
        return Circle().fill(c.fill)
            .overlay(Circle().stroke(c.glow || selected == id ? c.ring : Color(white: 0.36), lineWidth: max(1, 0.35 * k)))
            .overlay(Text(VitaButtonMapView.buttons[id]?.glyph ?? "").font(.system(size: 4 * k, weight: .semibold)).foregroundStyle(color))
            .frame(width: 7.6 * k, height: 7.6 * k)
            .shadow(color: c.glow ? Color.accentColor : .clear, radius: 3 * k)
            .position(p)
            .contentShape(Circle()).onTapGesture { tap(id) }
            .accessibilityLabel(VitaButtonMapView.buttons[id]?.name ?? "")
    }

    private func stick(_ id: Int32, at p: CGPoint, k: CGFloat) -> some View {
        let c = colors(id)
        return ZStack {
            Circle().fill(Color(white: 0.05)).frame(width: 13.5 * k, height: 13.5 * k)
            Circle().fill(RadialGradient(colors: [Color(white: 0.3), c.fill], center: .topLeading, startRadius: 0, endRadius: 8 * k))
                .overlay(Circle().stroke(c.ring, lineWidth: max(1, 0.35 * k)))
                .frame(width: 10.5 * k, height: 10.5 * k)
            Text(VitaButtonMapView.buttons[id]?.glyph ?? "").font(.system(size: 2.8 * k, weight: .bold)).foregroundStyle(.white.opacity(0.55))
        }
        .shadow(color: c.glow ? Color.accentColor : .clear, radius: 3 * k)
        .position(p)
        .contentShape(Circle()).onTapGesture { tap(id) }
        .accessibilityLabel(VitaButtonMapView.buttons[id]?.name ?? "")
    }

    private func pill(_ id: Int32, at p: CGPoint, size: CGSize, k: CGFloat, text: String) -> some View {
        let c = colors(id)
        return VStack(spacing: 0.6 * k) {
            Capsule().fill(c.fill).overlay(Capsule().stroke(c.ring, lineWidth: max(1, 0.35 * k)))
                .overlay(text == "PS" ? Text("PS").font(.system(size: 2.6 * k, weight: .heavy)).foregroundStyle(.white.opacity(0.8)) : nil)
                .frame(width: size.width, height: size.height)
            if text != "PS" {
                Text(text).font(.system(size: 1.9 * k, weight: .semibold)).foregroundStyle(.white.opacity(0.45)).fixedSize()
            }
        }
        .shadow(color: c.glow ? Color.accentColor : .clear, radius: 3 * k)
        .position(p)
        .contentShape(Rectangle()).onTapGesture { tap(id) }
        .accessibilityLabel(VitaButtonMapView.buttons[id]?.name ?? "")
    }

    private func shoulder(_ id: Int32, rect: CGRect, k: CGFloat) -> some View {
        let c = colors(id)
        let shape = UnevenRoundedRectangle(topLeadingRadius: 2.5 * k, bottomLeadingRadius: 0.5 * k, bottomTrailingRadius: 0.5 * k, topTrailingRadius: 2.5 * k)
        return shape.fill(c.fill).overlay(shape.stroke(c.ring, lineWidth: max(1, 0.35 * k)))
            .overlay(Text(VitaButtonMapView.buttons[id]?.glyph ?? "").font(.system(size: 3 * k, weight: .bold)).foregroundStyle(.white.opacity(0.7)).offset(y: -0.8 * k))
            .frame(width: rect.width, height: rect.height)
            .shadow(color: c.glow ? Color.accentColor : .clear, radius: 3 * k)
            .position(x: rect.midX, y: rect.midY)
            .contentShape(Rectangle()).onTapGesture { tap(id) }
            .accessibilityLabel(VitaButtonMapView.buttons[id]?.name ?? "")
    }
}
