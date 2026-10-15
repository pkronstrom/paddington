import AppKit
import PadctlCore
import SwiftUI

public final class LegendModel: ObservableObject {
    @Published public var path = ""
    @Published public var layerColor = "#888888"
    @Published public var frameStyle = FrameStyle.base
    @Published public var controls: [String: Appearance] = [:]
    @Published public var layout = DeviceLayout()
    @Published public var buttonLabels: [String: String] = [:]
    @Published public var connection = ""
    @Published public var connected = false
    @Published public var footer = ""
    @Published public var pressed: Set<String> = []
    @Published public var picker: PickerState?
    @Published public var scale: CGFloat = 1
    @Published public var lights: [String: LegendLight] = [:]
    public init() {}

    public enum FrameStyle { case base, temporary, held, modal }
}

extension Color {
    init(hex: String?, fallback: Color = .gray) {
        guard let hex, hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16), hex.count == 7 else { self = fallback; return }
        self = Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

struct Blinking: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                content.opacity(Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0.35)
            }
        } else { content }
    }
}

/// Legend size: every metric is multiplied by `[legend] scale` (config.toml).
struct LegendScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var legendScale: CGFloat {
        get { self[LegendScaleKey.self] }
        set { self[LegendScaleKey.self] = newValue }
    }
}

/// What a control's light shows (same as the pad LEDs): LED colour + level.
public struct LegendLight: Equatable {
    public var hex: String
    public var level: Double
    public init(hex: String, level: Double) { self.hex = hex; self.level = level }
}

/// Top-down dark-grey hardware: charcoal enclosure, frosted pads and printed legends.
enum Hw {
    static let body = Color(white: 0.20)
    static let print = Color(white: 0.90)
    static let frost = Color(red: 0.65, green: 0.65, blue: 0.69)
    static let frostEdge = Color.white.opacity(0.28)
    static let key = Color(white: 0.27)
    static let keyEdge = Color.black.opacity(0.65)

    /// Pure LED hues → softer screen tones of the same hue; other colours as they are.
    static let tones: [String: (Double, Double, Double)] = [
        "#0000ff": (0.27, 0.52, 0.96), "#ffff00": (0.98, 0.85, 0.24), "#00ff00": (0.30, 0.80, 0.40),
        "#ff00ff": (0.88, 0.36, 0.84), "#ff0000": (0.93, 0.29, 0.29), "#00ffff": (0.26, 0.82, 0.90),
        "#ffffff": (0.99, 0.99, 0.99),
    ]
    static func rgb(_ hex: String) -> (Double, Double, Double)? {
        if let t = tones[hex.lowercased()] { return t }
        guard hex.hasPrefix("#"), hex.count == 7, let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
    static func tone(_ l: LegendLight?) -> Color? { l.flatMap { rgb($0.hex) }.map { Color(red: $0.0, green: $0.1, blue: $0.2) } }
    /// Dark text on light tones, white on dark ones.
    static func ink(_ l: LegendLight?) -> Color {
        guard let (r, g, b) = l.flatMap({ rgb($0.hex) }) else { return Color.black.opacity(0.82) }
        return 0.299 * r + 0.587 * g + 0.114 * b > 0.55 ? Color.black.opacity(0.82) : Color.white
    }
}

/// Both bank labels share the pad face: active action above, alternate action below.
struct PadView: View {
    let a: Appearance?
    let light: LegendLight?
    let pressed: Bool
    @Environment(\.legendScale) var k
    var body: some View {
        let bound = a?.bound ?? false
        let selected = a?.selected ?? false
        ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4 * k).fill(Hw.frost)
                if let c = Hw.tone(light) {
                    // lit: dimmer for other windows' pads, like the LEDs
                    RoundedRectangle(cornerRadius: 4 * k).fill(c.opacity(0.40 + 0.48 * max(0, min(1, light?.level ?? 1))))
                }
                RoundedRectangle(cornerRadius: 4 * k)
                    .strokeBorder(selected ? Color.white.opacity(0.95) : Hw.frostEdge, lineWidth: selected ? 2.5 * k : 0.8)
                RoundedRectangle(cornerRadius: 4 * k)
                    .fill(LinearGradient(colors: [.white.opacity(0.18), .clear, .black.opacity(0.10)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                if pressed { RoundedRectangle(cornerRadius: 4 * k).fill(Color.black.opacity(0.18)) }
                VStack(alignment: .leading, spacing: 3 * k) {
                    Text(a?.label ?? "").font(.system(size: 10 * k, weight: .bold))
                        .lineLimit(2).minimumScaleFactor(0.7)
                        .foregroundStyle(bound ? Hw.ink(light) : Color.black.opacity(0.35))
                    Spacer(minLength: 0)
                    if let alt = a?.altLabel, !alt.isEmpty {
                        Text(alt).font(.system(size: 7.5 * k, weight: .medium))
                            .lineLimit(2).minimumScaleFactor(0.8)
                            .foregroundStyle(Hw.ink(light).opacity(0.75))
                    }
                }
                .padding(5 * k)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: 60 * k, height: 60 * k)
            .compositingGroup()
            .shadow(color: .black.opacity(0.55), radius: 1 * k, y: 1 * k)
            .scaleEffect(pressed ? 0.96 : 1)
            .modifier(Blinking(on: a?.blink ?? false))
    }
}

/// A knob cell, as tall as a pad cell so knob rows line up with pad rows like on the device.
struct KnobView: View {
    let number: Int
    let a: Appearance?
    let light: LegendLight?
    let pressed: Bool
    @Environment(\.legendScale) var k
    var body: some View {
        let bound = a?.bound ?? false
        let accent = Hw.tone(light) ?? Color.white.opacity(0.85)
        VStack(spacing: 2 * k) {
            // printed above: the knob-bank-B action, else the knob's number (lighter)
            let alt = a?.altLabel ?? ""
            Text(alt.isEmpty ? "\(number)" : alt)
                .font(.system(size: 7.5 * k, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(Hw.print.opacity(alt.isEmpty ? 0.55 : 0.70)).frame(height: 9 * k)
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(white: 0.19), Color(white: 0.045)], startPoint: .top, endPoint: .bottom))
                Circle().strokeBorder(Color(white: 0.02), style: StrokeStyle(lineWidth: 2.5 * k, dash: [1.4 * k, 1.4 * k]))   // knurled edge
                if pressed { Circle().strokeBorder(accent, lineWidth: 2.5 * k) }
                Capsule().fill(bound ? accent : Color(white: 0.4))                      // pointer
                    .frame(width: 2.5 * k, height: 8 * k).offset(y: -6.5 * k)
            }
            .frame(width: 33 * k, height: 33 * k)
            .shadow(color: .black.opacity(0.25), radius: 1.5 * k, y: 1 * k)
            Text(a?.label ?? "").font(.system(size: 8 * k, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(Hw.print.opacity(bound ? 0.95 : 0.35))
                .padding(.horizontal, 3 * k).padding(.vertical, 1 * k)
                .overlay(RoundedRectangle(cornerRadius: 2 * k).strokeBorder(Hw.print.opacity(bound ? 0.6 : 0.2), lineWidth: 0.8))
                .opacity((a?.label ?? "").isEmpty ? 0 : 1)
                .frame(width: 58 * k)
        }
        .frame(height: 60 * k, alignment: .center)
    }
}

/// A side button: the key as on the device, its action printed next to it.
struct ButtonRow: View {
    let key: String
    let a: Appearance?
    let light: LegendLight?
    let pressed: Bool
    var lit = false
    var layer: String? = nil
    var layerColor: String = "#888888"
    @Environment(\.legendScale) var k
    var body: some View {
        let bound = a?.bound ?? false
        let glyph = key.contains(" ") && key.count > 6 ? key.replacingOccurrences(of: " ", with: "\n") : key
        let tint = Hw.tone(light) ?? (lit ? Color(red: 0.66, green: 0.48, blue: 0.92) : nil)
        HStack(spacing: 6 * k) {
            Text(glyph).font(.system(size: (glyph.contains("\n") ? 5 : 8) * k, weight: .bold)).multilineTextAlignment(.center)
                .lineLimit(2).minimumScaleFactor(0.6)
                .frame(width: 28 * k, height: 18 * k)
                .foregroundStyle(tint == nil ? Hw.print : Color.black.opacity(0.85))
                .background(RoundedRectangle(cornerRadius: 3 * k)
                    .fill(tint ?? Hw.key))
                .overlay(RoundedRectangle(cornerRadius: 3 * k)
                    .fill(LinearGradient(colors: [.white.opacity(0.12), .black.opacity(0.10)],
                                         startPoint: .top, endPoint: .bottom)))
                .overlay(RoundedRectangle(cornerRadius: 3 * k)
                    .strokeBorder(Color.white.opacity(tint == nil ? 0.18 : 0.30), lineWidth: 0.7 * k))
                .overlay(RoundedRectangle(cornerRadius: 3 * k).fill(.black.opacity(pressed ? 0.22 : 0)))
                .scaleEffect(pressed ? 0.96 : 1)

            if let layer {
                HStack(spacing: 3 * k) {
                    Circle().fill(lit ? Color.green : Color.red)
                        .frame(width: 4 * k, height: 4 * k)
                    Text(layer.replacingOccurrences(of: " › ", with: "\n"))
                        .font(.system(size: 9 * k, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2).minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 5 * k).padding(.vertical, 4 * k)
                .background(RoundedRectangle(cornerRadius: 4 * k)
                    .fill(Color(hex: layerColor).opacity(0.28)))
                .overlay(RoundedRectangle(cornerRadius: 4 * k)
                    .strokeBorder(Color(hex: layerColor).opacity(0.7), lineWidth: 0.8 * k))
            } else if bound {
                VStack(alignment: .leading, spacing: 0) {
                    Text(a?.label ?? "").font(.system(size: 9 * k, weight: .semibold)).lineLimit(1).foregroundStyle(Hw.print)
                    if let alt = a?.altLabel, !alt.isEmpty {
                        Text(alt).font(.system(size: 7 * k)).lineLimit(1).foregroundStyle(Hw.print.opacity(0.5))
                    }
                }
            }
        }
        .frame(width: 94 * k, alignment: .leading)
        .modifier(Blinking(on: a?.blink ?? false))
    }
}

struct PickerList: View {
    let p: PickerState
    @Environment(\.legendScale) var k
    var body: some View {
        let lo = max(0, min(p.index - 4, p.items.count - 9)), hi = min(p.items.count, lo + 9)
        VStack(alignment: .leading, spacing: 2 * k) {
            Text(p.title).font(.system(size: 10.5 * k, weight: .bold)).foregroundStyle(.white.opacity(0.7))
            ForEach(lo..<hi, id: \.self) { i in
                Text(p.items[i].label).font(.system(size: 11.5 * k, weight: i == p.index ? .bold : .regular)).lineLimit(1)
                    .padding(.horizontal, 5 * k).padding(.vertical, 1.5 * k)
                    .frame(width: 160 * k, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4 * k).fill(i == p.index ? Color.white.opacity(0.9) : .clear))
                    .foregroundStyle(i == p.index ? Color.black : Color.white.opacity(0.85))
            }
            Text("turn · ▶ choose · ⏸ cancel").font(.system(size: 9 * k)).foregroundStyle(.white.opacity(0.5))
        }
        .padding(7 * k)
        .background(RoundedRectangle(cornerRadius: 8 * k).fill(Color.white.opacity(0.06)))
    }
}

public struct LegendView: View {
    @ObservedObject var m: LegendModel
    public init(model: LegendModel) { m = model }

    public var body: some View {
        let k = m.scale, L = m.layout
        let rowH: CGFloat = 60 * k, rowGap: CGFloat = 6 * k
        let gridH = CGFloat(L.padRows) * rowH + CGFloat(max(0, L.padRows - 1)) * rowGap
        VStack(alignment: .leading, spacing: 6 * k) {
            HStack(alignment: .top, spacing: 10 * k) {
                Grid(horizontalSpacing: 0, verticalSpacing: rowGap) {
                    ForEach((0..<L.knobRows).reversed(), id: \.self) { r in
                        GridRow {
                            ForEach(0..<L.knobCols, id: \.self) { c in
                                let n = r * L.knobCols + c + 1
                                KnobView(number: n, a: m.controls["knob\(n)"], light: m.lights["knob\(n)"], pressed: m.pressed.contains("knob\(n)"))
                            }
                        }
                    }
                }
                Grid(horizontalSpacing: 6 * k, verticalSpacing: rowGap) {
                    ForEach((0..<L.padRows).reversed(), id: \.self) { r in
                        GridRow {
                            ForEach(0..<L.padCols, id: \.self) { c in
                                let n = r * L.padCols + c + 1
                                PadView(a: m.controls["pad\(n)"], light: m.lights["pad\(n)"], pressed: m.pressed.contains("pad\(n)"))
                            }
                        }
                    }
                }
                // all side buttons in their places on the device, evenly down the right edge
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(L.buttons, id: \.self) { b in
                        ButtonRow(key: m.buttonLabels[b] ?? b, a: m.controls[b], light: m.lights[b], pressed: m.pressed.contains(b),
                                  lit: b == "bt" && m.connected, layer: b == "bt" ? m.path : nil, layerColor: m.layerColor)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(height: gridH)
            }
            if !m.footer.isEmpty {
                Text(m.footer).font(.system(size: 9 * k))
                    .foregroundStyle(Hw.print.opacity(0.75)).lineLimit(2)
            }
        }
        .padding(.leading, 12 * k).padding(.trailing, 7 * k).padding(.vertical, 10 * k)
        .background(RoundedRectangle(cornerRadius: 14 * k)
            .fill(LinearGradient(colors: [Color(white: 0.25), Hw.body], startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 14 * k)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.25), .black.opacity(0.65)],
                                         startPoint: .top, endPoint: .bottom), lineWidth: 1.5 * k))
        .overlay(frame.padding(2 * k))
        .environment(\.legendScale, k)
        .fixedSize()
    }

    @ViewBuilder var frame: some View {
        let c = Color(hex: m.layerColor), k = m.scale, r = 14 * k
        switch m.frameStyle {
        case .base: RoundedRectangle(cornerRadius: r).strokeBorder(c.opacity(0.5), lineWidth: 1)
        // calm, solid frames only: thicker = a temporary layer or menu is on top (no dashes, no motion)
        case .temporary: RoundedRectangle(cornerRadius: r).strokeBorder(c, lineWidth: 2)
        case .held: RoundedRectangle(cornerRadius: r).strokeBorder(Hw.print, lineWidth: 2)
        case .modal: RoundedRectangle(cornerRadius: r).strokeBorder(c, lineWidth: 3)
        }
    }
}

/// A floating, non-activating, click-through panel on every Space.
public final class FloatingPanel<Content: View>: NSPanel {
    public init(@ViewBuilder content: () -> Content) {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: content())
        contentView = host
    }
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public func place(_ position: String, margin: CGFloat = 24) {
        guard let v = contentView else { return }
        let size = v.fittingSize
        setContentSize(size)
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let f = screen.visibleFrame
        var o = CGPoint(x: f.maxX - size.width - margin, y: f.minY + margin)
        switch position {
        case "bottom-left": o = CGPoint(x: f.minX + margin, y: f.minY + margin)
        case "top-right": o = CGPoint(x: f.maxX - size.width - margin, y: f.maxY - size.height - margin)
        case "top-left": o = CGPoint(x: f.minX + margin, y: f.maxY - size.height - margin)
        case "center": o = CGPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2)
        default: break
        }
        setFrameOrigin(o)
    }
}

public final class ToastModel: ObservableObject {
    @Published public var text = ""
    public init() {}
}

struct ToastView: View {
    @ObservedObject var m: ToastModel
    var body: some View {
        Text(m.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(Color(white: 0.1).opacity(0.92)))
            .fixedSize()
    }
}

/// Legend + toast windows and their show/hide rules (hold to show, tap to pin).
public final class PickerModel: ObservableObject {
    @Published public var picker: PickerState?
    @Published public var scale: CGFloat = 1
    public init() {}
}

struct PickerOverlay: View {
    @ObservedObject var m: PickerModel
    var body: some View {
        if let p = m.picker {
            PickerList(p: p)
                .background(RoundedRectangle(cornerRadius: 9 * m.scale).fill(Color(white: 0.07).opacity(0.95)))
                .overlay(RoundedRectangle(cornerRadius: 9 * m.scale).strokeBorder(Color.white.opacity(0.25), lineWidth: 1.5))
                .environment(\.legendScale, m.scale)
                .fixedSize()
        }
    }
}

public final class LegendController {
    public let model = LegendModel()
    public let pickerModel = PickerModel()
    lazy var pickerPanel = FloatingPanel { PickerOverlay(m: self.pickerModel) }
    let toastModel = ToastModel()
    lazy var panel = FloatingPanel { LegendView(model: self.model) }
    lazy var toastPanel = FloatingPanel { ToastView(m: self.toastModel) }
    public var position = "bottom-right"
    public var pinSeconds = 8.0
    private var held = false
    private var pinned = false
    private var pinTimer: Timer?
    private var toastTimer: Timer?

    public init() {}

    public var forced = false   // e.g. a picker or a modal layer is open
    public var headless = false // test mode: never put windows on screen
    public var visible: Bool { held || pinned || forced }

    @MainActor public func renderPNG(to path: String) -> Bool {
        let r = ImageRenderer(content: LegendView(model: model))
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    public func apply(_ cmd: LegendCommand) {
        switch cmd {
        case .showHeld: held = true
        case .hideHeld: held = false
        case .togglePin:
            pinned.toggle()
            pinTimer?.invalidate()
            if pinned {
                pinTimer = Timer.scheduledTimer(withTimeInterval: pinSeconds, repeats: false) { [weak self] _ in
                    self?.pinned = false; self?.update()
                }
            }
        }
        update()
    }

    public func showBriefly(_ seconds: Double = 2.5) {
        if !pinned { apply(.togglePin); pinTimer?.invalidate()
            pinTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.pinned = false; self?.update() }
        }
    }

    public func update() {
        if visible && !headless {
            panel.place(position)
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    /// Small list overlay for pickers, separate from the legend.
    public func showPicker(_ p: PickerState?) {
        if pickerModel.picker != p { pickerModel.picker = p }
        if p == nil || headless { pickerPanel.orderOut(nil); return }
        pickerPanel.place(position, margin: visible ? 24 + (panel.contentView?.fittingSize.height ?? 0) + 12 : 24)
        pickerPanel.orderFrontRegardless()
    }

    public func toast(_ s: String) {
        toastModel.text = s
        if headless { return }
        toastPanel.place(position == "center" ? "top-right" : position.replacingOccurrences(of: "bottom", with: "top"), margin: 40)
        toastPanel.orderFrontRegardless()
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 2.8, repeats: false) { [weak self] _ in self?.toastPanel.orderOut(nil) }
    }
}
