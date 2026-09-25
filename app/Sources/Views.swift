import SwiftUI
import AppKit

private let accent = Color(red: 0.28, green: 0.65, blue: 0.55)

struct DesktopRow: View {
    @ObservedObject var model: AppModel
    let desktop: Desktop
    @State private var draft = ""
    @State private var loaded = false
    @State private var savedName = ""

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(desktop.isCurrent ? accent.opacity(0.18) : Color.secondary.opacity(0.08))
                Text(String(desktop.position)).font(.system(size: 16, weight: .semibold, design: .rounded))
            }.frame(width: 42, height: 38)
            VStack(alignment: .leading, spacing: 5) {
                TextField(L("为这个桌面命名"), text: $draft)
                    .textFieldStyle(.plain).font(.system(size: 15, weight: .medium))
                    .onSubmit { save() }
                Text(desktop.isCurrent ? L("当前桌面") : L("桌面 %d", desktop.position))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if draft != (model.store.customName(desktop) ?? "") {
                Button(L("保存")) { save() }.buttonStyle(.borderedProminent).tint(accent)
            }
            Button { model.switchTo(desktop) } label: {
                Image(systemName: "arrow.up.right")
            }.buttonStyle(.borderless).help(L("切换到这个桌面")).disabled(!model.permission || model.switching)
        }
        .padding(.vertical, 10).padding(.horizontal, 13)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            if !loaded { draft = model.store.customName(desktop) ?? ""; savedName = draft; loaded = true }
        }
        .onChange(of: model.revision) { _, _ in
            let latest = model.store.customName(desktop) ?? ""
            if draft == savedName { draft = latest }
            savedName = latest
        }
    }
    private func save() {
        model.rename(desktop, name: draft)
        draft = model.store.customName(desktop) ?? ""
        savedName = draft
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    var search: () -> Void
    @State private var showAppearance = false
    @State private var showCurrentAppearance = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L("给桌面一个名字")).font(.system(size: 27, weight: .bold, design: .rounded))
                    Text(L("按名字找到你的工作、音乐与游戏空间。"))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(L("技术预览 %@", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")).font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(accent.opacity(0.13), in: Capsule()).foregroundStyle(accent)
            }.padding(.bottom, 22)

            if !model.permission {
                HStack(spacing: 12) {
                    Image(systemName: "hand.raised").font(.title3).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("先允许辅助功能")).font(.system(size: 13, weight: .semibold))
                        Text(L("用于读取 Mission Control 和选择桌面。你可以先编辑名称。"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("打开设置")) { model.requestPermission() }
                }.padding(14).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 16)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(displayIDs, id: \.self) { displayID in
                        let desktops = model.spaces.filter { $0.displayID == displayID && $0.isOrdinary }
                        HStack {
                            Image(systemName: "display")
                            Text(desktops.first?.screenName ?? L("屏幕"))
                            Spacer()
                            Text(L("%d 个桌面", desktops.count))
                        }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.top, 10).padding(.horizontal, 3)
                        ForEach(desktops, id: \.sessionID) { desktop in
                            DesktopRow(model: model, desktop: desktop)
                        }
                    }
                    if model.spaces.isEmpty {
                        Text(L("暂未读取到桌面，请在菜单栏选择“刷新桌面与名称显示”。"))
                            .foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                    let unmatched = model.store.unmatchedCount(model.spaces)
                    if unmatched > 0 {
                        Text(L("已保留 %d 条未匹配名称，可能来自已断开的屏幕或旧桌面；不会自动分配给其他桌面。", unmatched))
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                }.padding(.trailing, 5)
            }
            .frame(minHeight: 200)

            Divider().padding(.vertical, 17)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L("缩略图名称")).font(.system(size: 12))
                    Text(L("%@ · %d 号字", model.appearance.position.label, Int(model.appearance.fontSize)))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("调整颜色、位置和大小…")) { showAppearance = true }
                }
                HStack {
                    Toggle(L("在空白区域显示当前桌面名称"), isOn: $model.showCurrent)
                        .toggleStyle(.switch).font(.system(size: 12))
                    Spacer()
                    Button(L("单独设置外观与位置…")) { showCurrentAppearance = true }
                }
                Text(L("独立设置大小和颜色；关闭后，顶部缩略图名称仍会显示。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, -7)
                HStack {
                    Toggle(L("启用桌面搜索"), isOn: $model.searchEnabled)
                        .toggleStyle(.switch).font(.system(size: 12))
                    Spacer()
                    Button(L("预览名称")) { model.mission.open() }.disabled(!model.permission)
                }
                if model.searchEnabled {
                    HStack {
                        Text(L("搜索快捷键")).font(.system(size: 12))
                        ShortcutRecorder(model: model).frame(width: 185, height: 26)
                            .help(L("点击后按下新的快捷键；按 Esc 取消"))
                        Spacer()
                        Button(L("搜索桌面")) { search() }
                    }
                    if !model.hotKeyWarning.isEmpty { Text(model.hotKeyWarning).font(.caption).foregroundStyle(.orange) }
                }
                HStack {
                    Text(L("语言")).font(.system(size: 12))
                    Picker(L("语言"), selection: $model.language) {
                        ForEach(AppLanguage.allCases) { language in Text(language.name).tag(language) }
                    }.labelsHidden().frame(width: 185)
                    Spacer()
                    Toggle(L("开机自动运行"), isOn: Binding(get: { launchAtLogin.requested },
                        set: { launchAtLogin.setEnabled($0) }))
                        .toggleStyle(.switch).font(.system(size: 12))
                        .help(L("进入 Mac 桌面后在后台运行，不弹出主窗口。"))
                }
                if launchAtLogin.status == .requiresApproval {
                    HStack {
                        Text(L("请在系统设置中允许 Renamer 自动运行。"))
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button(L("打开设置")) { launchAtLogin.openSettings() }
                    }
                }
                if !launchAtLogin.errorMessage.isEmpty {
                    Text(L("自动运行设置失败：%@", launchAtLogin.errorMessage))
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(26).frame(minWidth: 620, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showAppearance) { AppearanceSettingsView(model: model) }
        .sheet(isPresented: $showCurrentAppearance) { CurrentAppearanceSettingsView(model: model) }
    }
    private var displayIDs: [String] {
        var seen = Set<String>()
        return model.spaces.compactMap { seen.insert($0.displayID).inserted ? $0.displayID : nil }
    }
}

private struct AppearanceSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private let presets: [(String, Double, Double, Double)] = [
        (L("靛蓝"), 0.24, 0.32, 0.82), (L("湖蓝"), 0.05, 0.49, 0.67),
        (L("紫色"), 0.57, 0.28, 0.75), (L("珊瑚"), 0.92, 0.38, 0.30),
        (L("金黄"), 0.98, 0.76, 0.22), (L("浅白"), 0.94, 0.95, 0.98),
        (L("灰色"), 0.42, 0.42, 0.42), (L("黑色"), 0, 0, 0)
    ]
    private var selectedColor: Binding<Color> {
        Binding(get: { Color(nsColor: model.appearance.backgroundColor) }, set: { value in
            guard let c = NSColor(value).usingColorSpace(.sRGB) else { return }
            var next = model.appearance
            next.red = c.redComponent; next.green = c.greenComponent; next.blue = c.blueComponent
            model.appearance = next
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("缩略图名称外观")).font(.system(size: 24, weight: .bold))
            Text(L("只调整顶部缩略图名称，设置自动保存。"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 28) {
                VStack(spacing: 12) {
                    BadgePreview(appearance: model.appearance)
                        .frame(width: 245, height: 145)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text(L("桌面缩略图预览")).font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 18) {
                    InlineColorPicker(title: L("背景颜色"), selection: selectedColor)
                    HStack(spacing: 9) {
                        ForEach(presets, id: \.0) { preset in
                            Button {
                                var next = model.appearance
                                next.red = preset.1; next.green = preset.2; next.blue = preset.3
                                model.appearance = next
                            } label: {
                                Circle().fill(Color(red: preset.1, green: preset.2, blue: preset.3))
                                    .frame(width: 24, height: 24)
                                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                            }.buttonStyle(.plain).accessibilityLabel(preset.0).help(preset.0)
                        }
                    }
                    Toggle(L("自动选择字体颜色"), isOn: Binding(
                        get: { model.appearance.foreground == nil },
                        set: { model.appearance.foreground = $0 ? nil : BadgeColor(model.appearance.textColor) }))
                    InlineColorPicker(title: L("字体颜色"), selection: Binding(
                        get: { Color(nsColor: model.appearance.textColor) },
                        set: { model.appearance.foreground = BadgeColor(NSColor($0)) }))
                        .disabled(model.appearance.foreground == nil)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("缩略图内的位置"))
                        Picker(L("位置"), selection: $model.appearance.position) {
                            ForEach(BadgePosition.allCases, id: \.self) { position in
                                Text(position.label).tag(position)
                            }
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(L("大小")); Spacer(); Text("\(Int(model.appearance.fontSize))").monospacedDigit() }
                        Slider(value: $model.appearance.fontSize, in: 11...20, step: 1) { Text(L("名称框大小")) }
                            .labelsHidden()
                        Text(L("文字与底框一起调整，宽度随名称自动适配。"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(width: 260).font(.system(size: 13))
            }
            Text(L("位置设置用于展开的桌面缩略图；顶部收起时仍对齐系统标题。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("恢复默认外观")) { model.appearance = BadgeAppearance() }
                Spacer()
                Button(L("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 590)
    }
}

private struct BadgePreview: NSViewRepresentable {
    let appearance: BadgeAppearance
    func makeNSView(context: Context) -> BadgePreviewView { BadgePreviewView(frame: .zero) }
    func updateNSView(_ view: BadgePreviewView, context: Context) {
        view.badgeStyle = appearance.normalized
        view.needsLayout = true
    }
}

private final class BadgePreviewView: NSView {
    let badge = BadgeView(frame: .zero)
    var badgeStyle = BadgeAppearance()
    var currentStyle: CurrentBadgeAppearance?
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(badge)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: NSColor(srgbRed: 0.22, green: 0.43, blue: 0.59, alpha: 1),
                   ending: NSColor(srgbRed: 0.71, green: 0.83, blue: 0.85, alpha: 1))?.draw(in: bounds, angle: 90)
    }
    override func layout() {
        super.layout()
        if let current = currentStyle?.normalized {
            badge.apply(name: "Chatgpt", fontSize: current.fontSize,
                        background: current.background.nsColor, foreground: current.foreground.nsColor)
            let width = min(bounds.width - 12, BadgeView.preferredWidth(for: "Chatgpt",
                font: NSFont.systemFont(ofSize: current.fontSize, weight: .semibold)))
            let height = current.height
            badge.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
            badge.layoutSubtreeIfNeeded()
            return
        }
        badge.apply(name: "Chatgpt", appearance: badgeStyle)
        let width = BadgeView.preferredWidth(for: "Chatgpt", font: NSFont.systemFont(ofSize: badgeStyle.fontSize, weight: .semibold))
        guard let rect = BadgeLayout.frame(geometry: ButtonGeometry(frame: bounds, title: nil), screen: bounds,
                                           preferredWidth: width, position: badgeStyle.position, preferredHeight: badgeStyle.height) else { return }
        badge.frame = NSRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
        badge.layoutSubtreeIfNeeded()
    }
}

private struct CurrentAppearanceSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private func color(_ key: WritableKeyPath<CurrentBadgeAppearance, BadgeColor>) -> Binding<Color> {
        Binding(get: { Color(nsColor: model.currentAppearance[keyPath: key].nsColor) }, set: {
            model.currentAppearance[keyPath: key] = BadgeColor(NSColor($0))
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("当前桌面名称")).font(.system(size: 24, weight: .bold))
            Text(L("与顶部缩略图分开设置，调整后自动保存。"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            CurrentBadgePreview(appearance: model.currentAppearance)
                .frame(height: 100).clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 30) {
                InlineColorPicker(title: L("背景颜色"), selection: color(\.background))
                InlineColorPicker(title: L("字体颜色"), selection: color(\.foreground))
            }
            HStack {
                Text(L("大小"))
                Slider(value: $model.currentAppearance.fontSize, in: 16...64, step: 1) { Text(L("当前桌面名称大小")) }
                    .labelsHidden()
                Text(L("%d 号", Int(model.currentAppearance.fontSize))).monospacedDigit().frame(width: 48)
            }
            Divider()
            Text(L("放到空白处")).font(.system(size: 13, weight: .semibold))
            Text(L("默认在画面下方。点击或拖动下面的示意图，选择适合你窗口排列的位置。"))
                .font(.caption).foregroundStyle(.secondary)
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08))
                    HStack(spacing: 7) {
                        ForEach(0..<5) { _ in RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.22)) }
                    }.frame(height: 22).padding(8)
                    Text(L("名称")).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundStyle(Color(nsColor: model.currentAppearance.foreground.nsColor))
                        .background(Color(nsColor: model.currentAppearance.background.nsColor), in: RoundedRectangle(cornerRadius: 5))
                        .position(x: 28 + (proxy.size.width - 56) * model.currentAppearance.horizontal,
                                  y: 51 + (proxy.size.height - 70) * model.currentAppearance.vertical)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    model.currentAppearance.horizontal = min(1, max(0, (value.location.x - 28) / (proxy.size.width - 56)))
                    model.currentAppearance.vertical = min(1, max(0, (value.location.y - 51) / (proxy.size.height - 70)))
                })
            }.frame(height: 135).accessibilityLabel(L("当前名称位置示意图；也可使用下方滑块调整"))
            HStack {
                Text(L("左右"))
                Slider(value: $model.currentAppearance.horizontal, in: 0...1) { Text(L("名称左右位置")) }
                    .labelsHidden()
                Text(L("上下"))
                Slider(value: $model.currentAppearance.vertical, in: 0...1) { Text(L("名称上下位置")) }
                    .labelsHidden()
            }
            Text(L("位置按屏幕比例保存，会避开顶部缩略图区域；窗口排列变化后可再次调整。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("恢复当前名称默认外观")) { model.currentAppearance = CurrentBadgeAppearance() }
                Spacer()
                Button(L("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 570)
    }
}

private struct CurrentBadgePreview: NSViewRepresentable {
    let appearance: CurrentBadgeAppearance
    func makeNSView(context: Context) -> BadgePreviewView { BadgePreviewView(frame: .zero) }
    func updateNSView(_ view: BadgePreviewView, context: Context) {
        view.currentStyle = appearance.normalized
        view.needsLayout = true
    }
}

struct SearchView: View {
    @ObservedObject var model: AppModel
    var presentation = 0
    var dismiss: () -> Void
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool
    private var results: [Desktop] { model.store.filtered(model.spaces, query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundStyle(accent)
                TextField(L("输入桌面名称…"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 22)).focused($focused)
                    .onSubmit { choose() }
                Text("esc").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(23)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(results.enumerated()), id: \.element.sessionID) { index, desktop in
                            Button {
                                selected = index
                                choose()
                            } label: {
                                HStack {
                                    Image(systemName: desktop.isCurrent ? "circle.inset.filled" : "rectangle.on.rectangle")
                                        .frame(width: 25).foregroundStyle(accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(model.store.name(desktop)).font(.system(size: 15, weight: .medium))
                                        Text(L("%@ · 桌面 %d", desktop.screenName, desktop.position))
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if index == selected { Image(systemName: "return").foregroundStyle(.secondary) }
                                }.padding(13).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .background(index == selected ? accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                                .id(desktop.sessionID)
                        }
                        if results.isEmpty { Text(L("没有匹配的桌面")).foregroundStyle(.secondary).padding(32) }
                    }.padding(10)
                }.frame(height: 286)
                .onChange(of: selected) { _, value in
                    if results.indices.contains(value) { proxy.scrollTo(results[value].sessionID) }
                }
            }
            Divider()
            HStack {
                Text(model.permission ? L("↑ ↓ 选择    ↵ 切换") : L("请先允许辅助功能，再按名称切换"))
                Spacer()
                Text("Renamer")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 12)
        }
        .frame(width: 550)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focused = true }
        .onChange(of: presentation) { _, _ in
            query = ""
            selected = 0
            focused = false
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: query) { _, _ in selected = 0 }
        .onChange(of: results.map(\.sessionID)) { _, _ in selected = min(selected, max(0, results.count - 1)) }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(0, results.count - 1)); return .handled }
        .onKeyPress(.upArrow) { selected = max(0, selected - 1); return .handled }
        .onExitCommand { dismiss() }
    }
    private func choose() {
        guard results.indices.contains(selected), model.permission, !model.switching else { NSSound.beep(); return }
        let target = results[selected]
        dismiss()
        model.switchTo(target)
    }
}
