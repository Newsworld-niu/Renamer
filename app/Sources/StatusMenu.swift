import AppKit
import Combine

// Becoming key lets the inline field receive text without activating Renamer
// or asking macOS to reveal its settings window on another Space.
final class DesktopMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

private final class MenuDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class DesktopMenuRow: NSView, NSTextFieldDelegate {
    private let checkmark = NSTextField(labelWithString: "")
    private let nameButton = NSButton()
    private let editButton = NSButton()
    private let field = NSTextField(string: "")
    let desktop: Desktop
    private(set) var editing = false
    private var storedName = ""
    private let onSwitch: () -> Void
    private let onBegin: (DesktopMenuRow) -> Bool
    private let onSave: (String) -> Bool
    private let onCancel: () -> Void

    init(desktop: Desktop, onSwitch: @escaping () -> Void,
         onBegin: @escaping (DesktopMenuRow) -> Bool, onSave: @escaping (String) -> Bool,
         onCancel: @escaping () -> Void) {
        self.desktop = desktop
        self.onSwitch = onSwitch
        self.onBegin = onBegin
        self.onSave = onSave
        self.onCancel = onCancel
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        autoresizingMask = [.width]
        checkmark.font = .systemFont(ofSize: 13, weight: .semibold)
        checkmark.alignment = .center
        nameButton.font = .menuFont(ofSize: 0)
        nameButton.alignment = .left
        nameButton.isBordered = false
        nameButton.setButtonType(.momentaryChange)
        nameButton.cell?.lineBreakMode = .byTruncatingTail
        nameButton.target = self
        nameButton.action = #selector(switchPressed)
        editButton.imagePosition = .imageOnly
        editButton.isBordered = false
        editButton.setButtonType(.momentaryChange)
        editButton.contentTintColor = .secondaryLabelColor
        editButton.isHidden = !desktop.isOrdinary
        editButton.target = self
        editButton.action = #selector(editPressed)
        field.font = .menuFont(ofSize: 0)
        field.isHidden = true
        field.delegate = self
        field.focusRingType = .exterior
        field.placeholderString = L("桌面 %d", desktop.position)
        field.toolTip = L("回车或点到别处保存，Esc 取消；留空恢复默认名称")
        addSubview(checkmark)
        addSubview(nameButton)
        addSubview(editButton)
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(name: String, customName: String?, current: Bool, canSwitch: Bool) {
        storedName = customName ?? ""
        checkmark.stringValue = current ? "✓" : ""
        nameButton.title = "\(desktop.position). \(name)"
        nameButton.isEnabled = canSwitch
        nameButton.toolTip = L("切换到 %@", name)
        nameButton.setAccessibilityLabel(L("切换到 %@%@", name, current ? L("（当前桌面）") : ""))
        field.setAccessibilityLabel(L("桌面 %d 名称", desktop.position))
        updateEditButton(name: name)
    }

    private func updateEditButton(name: String? = nil) {
        editButton.image = NSImage(systemSymbolName: editing ? "checkmark" : "pencil", accessibilityDescription: editing ? L("保存名称") : L("重命名"))
        let label = editing ? L("保存名称") : L("重命名 %@", name ?? nameButton.title)
        editButton.toolTip = label
        editButton.setAccessibilityLabel(label)
    }

    override func layout() {
        super.layout()
        checkmark.frame = NSRect(x: 3, y: 5, width: 19, height: 18)
        nameButton.frame = NSRect(x: 26, y: 0, width: max(0, bounds.width - 65), height: bounds.height)
        field.frame = NSRect(x: 26, y: 3, width: max(0, bounds.width - 68), height: 22)
        editButton.frame = NSRect(x: bounds.width - 34, y: 0, width: 28, height: bounds.height)
    }

    @objc private func switchPressed() { onSwitch() }
    @objc private func editPressed() {
        if editing { _ = finishEditing(); return }
        guard onBegin(self) else { return }
        editing = true
        field.stringValue = storedName
        nameButton.isHidden = true
        field.isHidden = false
        updateEditButton()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(field)
        // Re-select the existing field editor; selectText would begin another
        // editing session and can send an end-editing notification immediately.
        field.currentEditor()?.selectAll(nil)
    }

    @discardableResult
    func finishEditing(cancel: Bool = false) -> Bool {
        guard editing else { return true }
        if !cancel, field.stringValue != storedName, !onSave(field.stringValue) { return false }
        editing = false
        // Clear the flag before ending field editing to avoid recursive saves.
        window?.makeFirstResponder(nil)
        field.isHidden = true
        nameButton.isHidden = false
        updateEditButton()
        if cancel { onCancel() }
        return true
    }

    // Save on explicit click-away/panel dismissal instead of AppKit's field
    // editor end notification, which can arrive while moving between rows.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.cancelOperation(_:)) { _ = finishEditing(cancel: true); return true }
        if command == #selector(NSResponder.insertNewline(_:)) { _ = finishEditing(); return true }
        if command == #selector(NSResponder.insertTab(_:)) || command == #selector(NSResponder.insertBacktab(_:)) {
            _ = finishEditing(); return true
        }
        return false
    }
}

/// A nonactivating menu panel supports inline text entry on the current Space.
final class StatusMenuController: NSObject, NSWindowDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let showSettings: () -> Void
    private let showSearch: () -> Void
    private var subscriptions = Set<AnyCancellable>()
    private var tracking: NSTrackingArea?
    private var hoverWork: DispatchWorkItem?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var spaceObserver: NSObjectProtocol?
    private var rows: [DesktopMenuRow] = []
    private var headers: [(String, NSTextField)] = []
    private let panel = DesktopMenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let errorLabel = NSTextField(labelWithString: "")
    private var closing = false
    private var switchQueued = false

    init(model: AppModel, showSettings: @escaping () -> Void, showSearch: @escaping () -> Void) {
        self.model = model
        self.showSettings = showSettings
        self.showSearch = showSearch
        super.init()
        panel.title = L("Renamer 桌面菜单")
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.onEscape = { [weak self] in _ = self?.closeMenu() }
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Renamer")
            button.imagePosition = .imageLeading
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            button.addTrackingArea(area)
            tracking = area
        }
        model.$spaces.combineLatest(model.$revision, model.$permission, model.$switching).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateSummary() }.store(in: &subscriptions)
        model.$status.receive(on: DispatchQueue.main).sink { [weak self] status in
            guard let self, !self.rows.contains(where: \.editing) else { return }
            self.errorLabel.stringValue = self.model.switching || status.hasPrefix(L("未能确认切换")) || status.hasPrefix(L("系统未接受")) ? status : ""
            self.errorLabel.toolTip = self.errorLabel.stringValue
            self.errorLabel.textColor = self.model.switching ? .secondaryLabelColor : .systemRed
        }.store(in: &subscriptions)
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in _ = self?.closeMenu() }
        updateSummary()
    }

    private var displays: [(id: String, spaces: [Desktop])] {
        var seen = Set<String>()
        return model.spaces.compactMap { desktop in
            guard seen.insert(desktop.displayID).inserted else { return nil }
            return (desktop.displayID, model.spaces.filter { $0.displayID == desktop.displayID }.sorted { $0.position < $1.position })
        }
    }

    func languageDidChange() {
        _ = closeMenu()
        panel.title = L("Renamer 桌面菜单")
        updateSummary()
    }

    private func name(_ desktop: Desktop) -> String { model.store.name(desktop).replacingOccurrences(of: "\n", with: " ") }

    private func updateSummary() {
        let screenID = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?
            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        let current = model.spaces.first { $0.isCurrent && $0.screenID == screenID } ?? model.spaces.first { $0.isCurrent }
        let title = current.map(name) ?? "Renamer"
        item.button?.title = " " + (title.count > 18 ? String(title.prefix(17)) + "…" : title)
        item.button?.setAccessibilityLabel(L("Renamer，当前桌面：%@", title))
        item.button?.toolTip = L("点击或悬停展开桌面；点名称切换，点铅笔直接编辑")
        for row in rows {
            let live = model.spaces.first { $0.sessionID == row.desktop.sessionID } ?? row.desktop
            row.update(name: name(live), customName: model.store.customName(live), current: live.isCurrent,
                       canSwitch: model.permission && !model.switching)
        }
        for (displayID, header) in headers {
            let spaces = model.spaces.filter { $0.displayID == displayID }
            header.stringValue = L("%@ · 当前：%@", spaces.first?.screenName ?? L("屏幕"), spaces.first(where: \.isCurrent).map(name) ?? L("未识别"))
        }
    }

    @objc func mouseEntered(_ event: NSEvent) {
        hoverWork?.cancel()
        guard !panel.isVisible, !model.switching, !switchQueued else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.panel.isVisible, !self.model.switching, !self.switchQueued, NSApp.modalWindow == nil,
                  NSApp.keyWindow?.attachedSheet == nil, let bounds = self.statusBounds,
                  bounds.contains(NSEvent.mouseLocation) else { return }
            self.showMenu()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    @objc func mouseExited(_ event: NSEvent) { hoverWork?.cancel(); hoverWork = nil }
    private var statusBounds: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func showMenu(focus: Bool = false) {
        hoverWork?.cancel(); hoverWork = nil
        guard !switchQueued else { return }
        if panel.isVisible {
            if focus && !model.switching { panel.makeKeyAndOrderFront(nil) }
            return
        }
        guard let anchor = statusBounds else { return }
        model.refresh()
        buildPanel(anchor: anchor)
        updateSummary()
        item.button?.highlight(true)
        panel.orderFrontRegardless()
        if focus && !model.switching { panel.makeKeyAndOrderFront(nil) }
        model.traceFocus("Inline desktop menu opened")
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53, !self.rows.contains(where: \.editing) { _ = self.closeMenu(); return nil }
            } else if self.statusBounds?.contains(NSEvent.mouseLocation) == true {
                // Clicking the entry keeps the same panel and any draft open.
                return event
            } else if event.window !== self.panel, !self.panel.frame.contains(NSEvent.mouseLocation) {
                _ = self.closeMenu()
            } else if !self.rows.contains(where: { row in
                row.editing && row.convert(row.bounds, to: nil).contains(self.panel.mouseLocationOutsideOfEventStream)
            }) {
                _ = self.finishEdits()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            _ = self?.closeMenu()
        }
    }

    private func buildPanel(anchor: NSRect) {
        rows.removeAll(); headers.removeAll()
        let width: CGFloat = 350
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        let available = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        // Set width before adding autoresizing rows, otherwise the final
        // document size would expand every row and push its pencil offscreen.
        let content = MenuDocumentView(frame: NSRect(x: 0, y: 0, width: width - 24, height: 0))
        var y: CGFloat = 0
        for display in displays {
            let header = NSTextField(labelWithString: "")
            header.font = .systemFont(ofSize: 12, weight: .medium)
            header.textColor = .secondaryLabelColor
            header.lineBreakMode = .byTruncatingTail
            header.frame = NSRect(x: 12, y: y + 7, width: width - 48, height: 18)
            content.addSubview(header); headers.append((display.id, header)); y += 32
            for desktop in display.spaces {
                let row = DesktopMenuRow(desktop: desktop, onSwitch: { [weak self] in
                    guard let self, self.model.permission, !self.model.switching, !self.switchQueued,
                          self.closeMenu() else { return }
                    self.hoverWork?.cancel(); self.hoverWork = nil
                    self.switchQueued = true
                    // Let the button event and panel key-window teardown finish
                    // before Mission Control begins its own transition.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                        guard let self else { return }
                        self.switchQueued = false
                        self.model.switchTo(desktop)
                    }
                }, onBegin: { [weak self] row in
                    guard let self else { return false }
                    return self.finishEdits(except: row)
                }, onSave: { [weak self] text in
                    guard let self else { return false }
                    let saved = self.model.rename(desktop, name: text)
                    self.errorLabel.stringValue = saved ? "" : self.model.status
                    if saved { self.updateSummary() }
                    return saved
                }, onCancel: { [weak self] in self?.errorLabel.stringValue = "" })
                row.frame = NSRect(x: 0, y: y, width: width - 24, height: 28)
                content.addSubview(row); rows.append(row); y += 28
            }
        }
        if rows.isEmpty {
            let label = NSTextField(labelWithString: L("暂未读取到桌面，请刷新"))
            label.frame = NSRect(x: 12, y: 8, width: width - 40, height: 22)
            content.addSubview(label); y = 40
        }
        content.frame = NSRect(x: 0, y: 0, width: width - 24, height: y)
        let footerHeight: CGFloat = (model.permission ? 136 : 164) - (model.searchEnabled ? 0 : 28)
        let height = min(y + footerHeight + 16, min(720, max(240, anchor.minY - available.minY - 12)))
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.material = .popover
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        let scroll = NSScrollView(frame: NSRect(x: 8, y: footerHeight + 8, width: width - 16, height: height - footerHeight - 16))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = content
        root.addSubview(scroll)
        let divider = NSBox(frame: NSRect(x: 10, y: footerHeight + 3, width: width - 20, height: 1))
        divider.boxType = .separator; root.addSubview(divider)
        var footerY = footerHeight - 27
        if !model.permission { addAction(L("需要辅助功能权限…"), action: #selector(openPermission), y: footerY, to: root); footerY -= 28 }
        var actions: [(String, Selector)] = []
        if model.searchEnabled { actions.append((L("搜索桌面…"), #selector(search))) }
        actions += [(L("桌面名称与外观设置…"), #selector(settings)),
                    (L("刷新桌面与名称显示"), #selector(refresh)), (L("退出 Renamer"), #selector(quit))]
        for (title, action) in actions {
            addAction(title, action: action, y: footerY, to: root); footerY -= 28
        }
        errorLabel.frame = NSRect(x: 14, y: 5, width: width - 28, height: 18)
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.stringValue = model.switching || model.status.hasPrefix(L("未能确认切换")) || model.status.hasPrefix(L("系统未接受")) ? model.status : ""
        errorLabel.toolTip = errorLabel.stringValue
        errorLabel.textColor = model.switching ? .secondaryLabelColor : .systemRed
        root.addSubview(errorLabel)
        panel.contentView = root
        let x = min(max(anchor.minX, available.minX + 5), available.maxX - width - 5)
        panel.setFrame(NSRect(x: x, y: anchor.minY - 5 - height, width: width, height: height), display: false)
    }

    private func addAction(_ title: String, action: Selector, y: CGFloat, to view: NSView) {
        let button = NSButton(title: title, target: self, action: action)
        button.frame = NSRect(x: 17, y: y, width: view.bounds.width - 34, height: 26)
        button.isBordered = false
        button.alignment = .left
        button.font = .menuFont(ofSize: 0)
        view.addSubview(button)
    }

    private func finishEdits(except excluded: DesktopMenuRow? = nil) -> Bool {
        for row in rows where row !== excluded {
            if !row.finishEditing() { return false }
        }
        return true
    }

    @discardableResult private func closeMenu() -> Bool {
        guard !closing else { return true }
        closing = true
        defer { closing = false }
        guard finishEdits() else { return false }
        panel.orderOut(nil)
        item.button?.highlight(false)
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor); localMonitor = nil }
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor); globalMonitor = nil }
        return true
    }

    func windowDidResignKey(_ notification: Notification) { _ = closeMenu() }
    @objc private func statusItemClicked() {
        hoverWork?.cancel(); hoverWork = nil
        showMenu(focus: true)
    }
    @objc private func settings() { if closeMenu() { showSettings() } }
    @objc private func search() { if closeMenu(), model.searchEnabled { showSearch() } }
    @objc private func refresh() {
        guard closeMenu() else { return }
        model.recover(); showMenu()
    }
    @objc private func openPermission() { if closeMenu() { model.requestPermission() } }
    @objc private func quit() { if closeMenu() { NSApp.terminate(nil) } }
    deinit {
        hoverWork?.cancel()
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        if let observer = spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
