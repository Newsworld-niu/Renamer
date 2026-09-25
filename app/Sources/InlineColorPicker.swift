import SwiftUI
import AppKit

/// Keeps editing next to its setting instead of opening the shared NSColorPanel.
struct InlineColorPicker: View {
    let title: String
    @Binding var selection: Color
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 9) {
                Text(title)
                RoundedRectangle(cornerRadius: 6).fill(selection)
                    .frame(width: 34, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.18)))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("调整%@", title))
        .help(L("在此处调整%@", title))
        .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            InlineColorEditor(title: title, selection: $selection) { isPresented = false }
        }
    }
}

private struct InlineColorEditor: View {
    let title: String
    @Binding var selection: Color
    var close: () -> Void
    @State private var hue: Double = 0
    @State private var saturation: Double = 0
    @State private var brightness: Double = 1
    @State private var hex = ""
    @State private var invalidHex = false
    private let presets: [(String, BadgeColor)] = [
        (L("白色"), .white), (L("灰色"), BadgeColor(red: 0.42, green: 0.42, blue: 0.42)),
        (L("黑色"), .black), (L("靛蓝"), BadgeColor(red: 0.24, green: 0.32, blue: 0.82)),
        (L("湖蓝"), BadgeColor(red: 0.05, green: 0.49, blue: 0.67)),
        (L("紫色"), BadgeColor(red: 0.57, green: 0.28, blue: 0.75)),
        (L("珊瑚"), BadgeColor(red: 0.92, green: 0.38, blue: 0.30)),
        (L("金黄"), BadgeColor(red: 0.98, green: 0.76, blue: 0.22))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                RoundedRectangle(cornerRadius: 5).fill(selection).frame(width: 32, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.18)))
            }
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Color(hue: hue, saturation: 1, brightness: 1)
                    LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    Circle().stroke(.black.opacity(0.6), lineWidth: 4)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .position(x: max(6, min(geometry.size.width - 6, saturation * geometry.size.width)),
                                  y: max(6, min(geometry.size.height - 6, (1 - brightness) * geometry.size.height)))
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    saturation = min(1, max(0, Double(value.location.x / geometry.size.width)))
                    brightness = min(1, max(0, 1 - Double(value.location.y / geometry.size.height)))
                    applyHSB()
                })
            }.frame(height: 132)
                .accessibilityLabel(L("颜色区域；可用下方色调、饱和度和亮度滑块调整"))
            VStack(spacing: 7) {
                component(L("色调"), value: $hue)
                component(L("饱和度"), value: $saturation)
                component(L("亮度"), value: $brightness)
            }
            HStack(spacing: 7) {
                ForEach(presets, id: \.0) { preset in
                    Button {
                        selection = Color(nsColor: preset.1.nsColor)
                        readSelection()
                    } label: {
                        Circle().fill(Color(nsColor: preset.1.nsColor)).frame(width: 23, height: 23)
                            .overlay(Circle().stroke(Color.primary.opacity(0.2)))
                    }.buttonStyle(.plain).accessibilityLabel(preset.0).help(preset.0)
                }
            }
            HStack {
                Text(L("色值")).foregroundStyle(.secondary)
                TextField("#RRGGBB", text: $hex).textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced)).onSubmit { applyHex() }
                    .accessibilityLabel(L("十六进制颜色"))
                Button(L("应用")) { applyHex() }
            }
            if invalidHex {
                Text(L("请输入六位色值，例如 #3478F6")).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text(L("调整后自动保存")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("完成")) { close() }
            }
        }.padding(18).frame(width: 272)
        .onAppear { readSelection() }
    }

    private func component(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 72, alignment: .leading)
            Slider(value: Binding(get: { value.wrappedValue }, set: {
                value.wrappedValue = $0
                applyHSB()
            }), in: 0...1).labelsHidden().accessibilityLabel(label)
        }
    }

    private func readSelection() {
        guard let c = NSColor(selection).usingColorSpace(.sRGB) else { return }
        hue = c.hueComponent; saturation = c.saturationComponent; brightness = c.brightnessComponent
        updateHex(c)
    }

    private func updateHex(_ color: NSColor) {
        hex = String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()),
                     Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
        invalidHex = false
    }

    private func applyHSB() {
        let c = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let chosen = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
            .usingColorSpace(.sRGB) ?? c
        selection = Color(nsColor: chosen)
        updateHex(chosen)
    }

    private func applyHex() {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, raw.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let rgb = UInt32(raw, radix: 16) else { invalidHex = true; return }
        selection = Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                          green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        readSelection()
    }
}
