import AppKit
import Modeling
import SwiftUI

/// Blender's default dark theme (4.x): its greys, the blue of active widgets and the orange of selection, its widget
/// shapes; and the controls the modelling window builds its panels from (number fields you drag or type into, toggle
/// rows, panels that fold).
enum BlenderTheme {
    static func c(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    static let window = c(0x181818)
    static let header = c(0x303030)
    static let region = c(0x303030)
    static let panel = c(0x3D3D3D)
    static let panelHeader = c(0x353535)
    static let widget = c(0x545454)
    static let widgetDark = c(0x282828)
    static let widgetHover = c(0x656565)
    static let active = c(0x4772B3)
    static let selectedRow = c(0x334D80)
    static let text = c(0xE6E6E6)
    static let textDim = c(0x9A9A9A)
    static let orange = c(0xFFA000)
    static let outline = c(0x1D1D1D)
    static let axisX = c(0xFF3352)
    static let axisY = c(0x8BDC00)
    static let axisZ = c(0x2890FF)
    static let font = Font.system(size: 11)
    static let small = Font.system(size: 10)
}

/// A Blender button: dark grey, rounded, blue when on.
struct BButton: View {
    var title: String = ""
    var symbol: String?
    var on = false
    var width: CGFloat?
    var help = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
                if !title.isEmpty { Text(title).font(BlenderTheme.font).lineLimit(1) }
            }
            .foregroundColor(BlenderTheme.text)
            .padding(.horizontal, title.isEmpty ? 4 : 7)
            .frame(width: width, height: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(on ? BlenderTheme.active : BlenderTheme.widget))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(BlenderTheme.outline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help.isEmpty ? title : help)
    }
}

/// Buttons joined into one row (Blender's aligned rows: the select modes, the shading modes).
struct BSegmented<T: Hashable>: View {
    let items: [(value: T, symbol: String, help: String)]
    @Binding var selection: T
    var multi: Set<T>? = nil

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let on = selection == item.value
                Button { selection = item.value } label: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 11))
                        .foregroundColor(BlenderTheme.text)
                        .frame(width: 24, height: 20)
                        .background(on ? BlenderTheme.active : BlenderTheme.widget)
                }
                .buttonStyle(.plain)
                .help(item.help)
                .clipShape(UnevenRoundedRect(left: i == 0, right: i == items.count - 1))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(BlenderTheme.outline, lineWidth: 0.5))
    }
}

/// A rectangle rounded on the left, the right, both or neither.
struct UnevenRoundedRect: Shape {
    var left: Bool
    var right: Bool
    func path(in r: CGRect) -> Path {
        let k: CGFloat = 4
        var p = Path()
        p.move(to: CGPoint(x: r.minX + (left ? k : 0), y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - (right ? k : 0), y: r.minY))
        if right { p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + k), control: CGPoint(x: r.maxX, y: r.minY)) }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - (right ? k : 0)))
        if right { p.addQuadCurve(to: CGPoint(x: r.maxX - k, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY)) }
        p.addLine(to: CGPoint(x: r.minX + (left ? k : 0), y: r.maxY))
        if left { p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - k), control: CGPoint(x: r.minX, y: r.maxY)) }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + (left ? k : 0)))
        if left { p.addQuadCurve(to: CGPoint(x: r.minX + k, y: r.minY), control: CGPoint(x: r.minX, y: r.minY)) }
        p.closeSubpath()
        return p
    }
}

/// Blender's number field: the label left, the value right; drag sideways to change it, click to type it.
struct BNumber: View {
    var label: String
    @Binding var value: Float
    var step: Float = 0.01
    var range: ClosedRange<Float> = -1e9...1e9
    var format = "%.3f"
    var unit = ""
    @State private var editing = false
    @State private var text = ""
    @State private var dragStart: Float?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(BlenderTheme.widgetDark)
            RoundedRectangle(cornerRadius: 4).stroke(BlenderTheme.outline, lineWidth: 0.5)
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(BlenderTheme.font)
                    .foregroundColor(BlenderTheme.text)
                    .padding(.horizontal, 6)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { editing = false }
                    .onAppear { focused = true }
            } else {
                HStack {
                    Text(label).foregroundColor(BlenderTheme.textDim)
                    Spacer(minLength: 4)
                    Text(String(format: format, value) + unit).foregroundColor(BlenderTheme.text)
                }
                .font(BlenderTheme.font)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { g in
                        if dragStart == nil { dragStart = value }
                        let precise: Float = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1
                        var v = dragStart! + Float(g.translation.width) * step * precise
                        if NSEvent.modifierFlags.contains(.control) { v = (v / (step * 10)).rounded() * step * 10 }
                        value = min(range.upperBound, max(range.lowerBound, v))
                    }
                    .onEnded { _ in dragStart = nil })
                .onTapGesture {
                    text = String(format: format, value)
                    editing = true
                }
            }
        }
        .frame(height: 20)
    }

    private func commit() {
        if let v = NumericInput.evaluate(text) { value = min(range.upperBound, max(range.lowerBound, v)) }
        editing = false
    }
}

/// Three number fields in a column (Location X, Y, Z …).
struct BVector: View {
    var title: String
    @Binding var value: SIMD3<Float>
    var step: Float = 0.01
    var format = "%.3f"
    var unit = ""
    var labels = ["X", "Y", "Z"]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(BlenderTheme.font).foregroundColor(BlenderTheme.textDim)
            VStack(spacing: 1) {
                ForEach(0..<3, id: \.self) { i in
                    BNumber(label: labels[i], value: Binding(get: { value[i] }, set: { value[i] = $0 }), step: step, format: format, unit: unit)
                }
            }
        }
    }
}

/// A checkbox row.
struct BCheck: View {
    var title: String
    @Binding var on: Bool
    var body: some View {
        Button { on.toggle() } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(on ? BlenderTheme.active : BlenderTheme.widgetDark)
                    .frame(width: 13, height: 13)
                    .overlay(Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundColor(.white).opacity(on ? 1 : 0))
                Text(title).font(BlenderTheme.font).foregroundColor(BlenderTheme.text)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A pop-up of choices, as Blender's dropdowns.
struct BPicker<T: Hashable>: View {
    var title: String = ""
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                Button(o.1) { selection = o.0 }
            }
        } label: {
            HStack(spacing: 4) {
                if !title.isEmpty { Text(title).foregroundColor(BlenderTheme.textDim) }
                Text(options.first { $0.0 == selection }?.1 ?? "").foregroundColor(BlenderTheme.text)
                Image(systemName: "chevron.down").font(.system(size: 8)).foregroundColor(BlenderTheme.textDim)
            }
            .font(BlenderTheme.font)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(BlenderTheme.widget))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// A panel that folds (Blender's panels in the sidebar and the properties).
struct BPanel<Content: View>: View {
    var title: String
    @State var open = true
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8)).foregroundColor(BlenderTheme.textDim)
                Text(title).font(BlenderTheme.font.weight(.medium)).foregroundColor(BlenderTheme.text)
                Spacer()
                if let trailing { trailing }
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(BlenderTheme.panelHeader)
            .contentShape(Rectangle())
            .onTapGesture { open.toggle() }
            if open {
                VStack(alignment: .leading, spacing: 4) { content() }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(BlenderTheme.panel)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
