import AppKit
import SwiftUI
import Carbon

extension SearchShortcut {
    init(event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode), modifiers: Self.modifiers(event.modifierFlags), keyName: Self.name(for: event))
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= Self.command }
        if flags.contains(.option) { modifiers |= Self.option }
        if flags.contains(.control) { modifiers |= Self.control }
        if flags.contains(.shift) { modifiers |= Self.shift }
        return modifiers
    }

    private static func name(for event: NSEvent) -> String {
        let code = UInt32(event.keyCode)
        if let name = functionKeys[code] { return name }
        let special: [UInt32: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "⌫", 53: "Esc", 76: "Enter",
            117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down"]
        if let name = special[code] { return name }
        // Translate without Option/Shift so ⌥R is labelled R, not ®.
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        if let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            if let bytes = CFDataGetBytePtr(data) {
                let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
                var state: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 8)
                let result = UCKeyTranslate(layout, event.keyCode, UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &state,
                    chars.count, &length, &chars)
                if result == noErr, length > 0 { return String(utf16CodeUnits: chars, count: length).uppercased() }
            }
        }
        return event.charactersIgnoringModifiers?.uppercased().nonempty ?? L("键 %d", code)
    }
}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}

struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var model: AppModel
    func makeNSView(context: Context) -> ShortcutRecordButton {
        let button = ShortcutRecordButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.font = .systemFont(ofSize: 12)
        button.target = button
        button.action = #selector(ShortcutRecordButton.toggleRecording)
        button.model = model
        return button
    }
    func updateNSView(_ button: ShortcutRecordButton, context: Context) {
        button.model = model
        button.title = model.recordingShortcut ? (model.shortcutDraft.isEmpty ? L("请按组合键…（Esc 取消）") : model.shortcutDraft) : model.searchShortcut.label
        button.setAccessibilityLabel(L("搜索快捷键"))
        button.setAccessibilityValue(model.recordingShortcut ? L("正在录入 %@，按 Esc 取消", model.shortcutDraft) : model.searchShortcut.label)
        button.toolTip = L("点击后直接按下新的快捷键")
    }
    static func dismantleNSView(_ button: ShortcutRecordButton, coordinator: ()) { button.stopRecording() }
}

final class ShortcutRecordButton: NSButton {
    weak var model: AppModel?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    @objc func toggleRecording() {
        if monitor != nil { stopRecording(); return }
        guard let model else { return }
        model.beginShortcutRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            guard let self, let model = self.model else { return event }
            if event.type == .leftMouseDown {
                if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.stopRecording()
                }
                return event
            }
            if event.type == .flagsChanged {
                let symbols = SearchShortcut.modifierLabel(SearchShortcut.modifiers(event.modifierFlags))
                model.shortcutDraft = symbols.isEmpty ? "" : symbols + "…"
                return event
            }
            if event.isARepeat { return nil }
            let shortcut = SearchShortcut(event: event)
            if event.keyCode == 53 && shortcut.modifiers == 0 { self.stopRecording(); return nil }
            model.shortcutDraft = shortcut.label
            if model.saveShortcut(shortcut) { self.stopRecording() }
            return nil
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.stopRecording() })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.stopRecording() })
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        model?.cancelShortcutRecording()
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
