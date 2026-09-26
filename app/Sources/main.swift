import AppKit
import SwiftUI

final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel!
    var statusMenu: StatusMenuController!
    var settingsWindow: NSWindow?
    var searchPanel: SearchPanel?
    private var searchPresentation = 0
    private var searchLocalMonitor: Any?
    private var searchGlobalMonitor: Any?
    private var dismissingSearch = false
    private var pendingRaycastTarget: String?
    private var receivedRaycastURL = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: L("桌面菜单"), action: #selector(openDesktopMenu), keyEquivalent: "").target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: L("退出 Renamer"), action: #selector(quit), keyEquivalent: "q").target = self
        let menuRoot = NSMenuItem()
        menuRoot.submenu = applicationMenu
        mainMenu.addItem(menuRoot)
        NSApp.mainMenu = mainMenu
        model = AppModel()
        model.searchRequested = { [weak self] in self?.showSearch() }
        model.searchDisabled = { [weak self] in self?.hideSearch() }
        statusMenu = StatusMenuController(model: model, showSettings: { [weak self] in self?.showSettings() },
                                          showSearch: { [weak self] in self?.showSearch() })
        model.statusMenuRequested = { [weak self] in self?.statusMenu.showMenu() }
        model.languageChanged = { [weak self] in
            guard let self else { return }
            self.statusMenu.languageDidChange()
            self.searchPanel?.title = L("搜索桌面")
            let menu = NSApp.mainMenu?.items.first?.submenu
            menu?.items.first?.title = L("桌面菜单")
            menu?.items.last?.title = L("退出 Renamer")
        }
        model.start()
        if model.searchEnabled { prepareSearchPanel() }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = LaunchContext.isLoginItem(event)
        let urlLaunch = event?.eventID == AEEventID(kAEGetURL)
        model.traceFocus("Launch at login=\(loginLaunch)")
        if !loginLaunch && !urlLaunch && pendingRaycastTarget == nil {
            // URL launches arrive around applicationDidFinishLaunching. Give the
            // URL handler one turn before deciding whether to show Settings.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, !self.receivedRaycastURL else { return }
                self.showSettings()
            }
        }
        handlePendingRaycastTarget()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let id = urls.compactMap(RaycastBridge.targetID(from:)).first else { return }
        receivedRaycastURL = true
        pendingRaycastTarget = id
        handlePendingRaycastTarget()
    }

    private func handlePendingRaycastTarget() {
        guard let model, let id = pendingRaycastTarget else { return }
        pendingRaycastTarget = nil
        model.refresh()
        guard let target = model.spaces.first(where: { $0.isOrdinary && $0.identity(bootID: model.store.bootID) == id }) else {
            model.status = L("目标桌面已不存在或已断开。")
            return
        }
        model.switchTo(target)
    }

    @objc func showSettings() {
        model.traceFocus("showSettings requested")
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Renamer"
            window.delegate = self
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 640, height: 700)
            window.contentView = NSHostingView(rootView: SettingsView(model: model) { [weak self] in self?.showSearch() })
            window.center()
            settingsWindow = window
        }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func prepareSearchPanel() {
        guard searchPanel == nil else { return }
        let panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 550, height: 410),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = L("搜索桌面")
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        // Nonactivating panels do not share the application's active state.
        // Dismiss explicitly instead of leaving an automatically hidden panel
        // whose isVisible flag can still make the next shortcut toggle it off.
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: SearchView(model: model) { [weak self] in self?.hideSearch() })
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 16
        panel.contentView?.layer?.masksToBounds = true
        panel.contentView?.layoutSubtreeIfNeeded()
        searchPanel = panel
    }

    @objc func showSearch() {
        guard model.searchEnabled else { return }
        let started = ProcessInfo.processInfo.systemUptime
        prepareSearchPanel()
        guard let panel = searchPanel else { return }
        searchPresentation += 1
        if let host = panel.contentView as? NSHostingView<SearchView> {
            host.rootView = SearchView(model: model, presentation: searchPresentation) { [weak self] in self?.hideSearch() }
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 275, y: frame.midY - 120))
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        if searchLocalMonitor == nil {
            searchLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if let self, event.window !== self.searchPanel { self.hideSearch() }
                return event
            }
            searchGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.hideSearch() }
        }
        model.logSearch(String(format: "presented; key=%@; show call=%.1fms", panel.isKeyWindow.description,
                               (ProcessInfo.processInfo.systemUptime - started) * 1000))
        // Show from the existing snapshot first; do not block input on refresh.
        DispatchQueue.main.async { [weak self] in self?.model.refresh() }
    }

    private func hideSearch() {
        guard !dismissingSearch else { return }
        dismissingSearch = true
        defer { dismissingSearch = false }
        let visible = searchPanel?.isVisible == true
        if let searchLocalMonitor { NSEvent.removeMonitor(searchLocalMonitor); self.searchLocalMonitor = nil }
        if let searchGlobalMonitor { NSEvent.removeMonitor(searchGlobalMonitor); self.searchGlobalMonitor = nil }
        searchPanel?.orderOut(nil)
        if visible { model.logSearch("dismissed") }
    }

    func applicationDidBecomeActive(_ notification: Notification) { model?.traceFocus("Renamer became active") }
    func applicationDidResignActive(_ notification: Notification) { model?.traceFocus("Renamer resigned active") }
    func windowWillClose(_ notification: Notification) { model?.traceFocus("Own window closed") }
    func windowDidBecomeKey(_ notification: Notification) { model?.traceFocus("Own window became key") }
    func windowDidResignKey(_ notification: Notification) {
        if let panel = notification.object as? SearchPanel, !panel.isKeyWindow { hideSearch() }
    }
    @objc func recover() { model.recover() }
    @objc func openDesktopMenu() {
        DispatchQueue.main.async { [weak self] in self?.statusMenu.showMenu(focus: true) }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { model?.overlays.reset() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.traceFocus("App reopen request; hasVisibleWindows=\(flag)")
        showSettings(); return true
    }
}

if CommandLine.arguments.contains("--raycast-list") {
    do {
        FileHandle.standardOutput.write(try RaycastBridge.list())
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
} else if CommandLine.arguments.contains("--diagnose") {
    let system = SpaceSystem()
    do {
        let spaces = try system.read()
        let report: [String: Any] = ["system": ProcessInfo.processInfo.operatingSystemVersionString,
                                   "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                                   "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                                   "screens": NSScreen.screens.count, "spaces": spaces.count,
                                   "missingPersistentIDs": spaces.filter { $0.persistentID == nil }.count,
                                   "accessibility": AXIsProcessTrusted()]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(json)
    } catch {
        print(error.localizedDescription)
        exit(1)
    }
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if let bundleID = Bundle.main.bundleIdentifier,
       let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
        other.activate(options: [])
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
