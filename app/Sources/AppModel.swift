import AppKit
import SwiftUI
import Carbon

final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { owner.action?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }

    func register(_ shortcut: SearchShortcut) -> Bool {
        unregister()
        guard shortcut.isValid else { return false }
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x524E4D52, id: 1),
                                   GetApplicationEventTarget(), 0, &reference) == noErr
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

final class AppModel: ObservableObject {
    @Published var language = AppLanguage.current { didSet {
        guard language != oldValue else { return }
        AppLanguage.current = language
        language.save()
        status = ""
        if !recordingShortcut { configureHotKey() }
        revision += 1
        languageChanged?()
        renderCachedLabels()
    } }
    var languageChanged: (() -> Void)?
    @Published var spaces: [Desktop] = [] { didSet {
        let before = oldValue.filter(\.isCurrent).map { "\($0.screenID):\($0.position)" }.sorted()
        let after = spaces.filter(\.isCurrent).map { "\($0.screenID):\($0.position)" }.sorted()
        if before != after { traceFocus("Spaces \(before.joined(separator: ",")) -> \(after.joined(separator: ","))") }
    } }
    @Published var status = L("正在读取桌面…")
    @Published var permission = false
    @Published var appearance = BadgeAppearance.load() { didSet {
        appearance.save()
        renderCachedLabels()
    } }
    @Published var currentAppearance = CurrentBadgeAppearance.load() { didSet {
        currentAppearance.save()
        renderCachedLabels()
    } }
    @Published var showCurrent: Bool { didSet {
        UserDefaults.standard.set(showCurrent, forKey: "showCurrent")
        renderCachedLabels()
    } }
    @Published var searchEnabled: Bool { didSet {
        guard searchEnabled != oldValue else { return }
        SearchPreference.save(searchEnabled)
        if searchEnabled {
            if !recordingShortcut { configureHotKey() }
        } else {
            hotKey.unregister()
            hotKeyWarning = ""
            searchDisabled?()
        }
    } }
    @Published private(set) var searchShortcut: SearchShortcut
    @Published private(set) var recordingShortcut = false
    @Published var shortcutDraft = ""
    @Published var hotKeyWarning = ""
    @Published var revision = 0
    @Published var labelCount = 0
    @Published var switching = false
    let store: NameStore
    let system = SpaceSystem()
    let mission = MissionControl()
    private let directSwitch = DirectSpaceSwitch()
    private var usingDirectSwitch = false
    let overlays = OverlayManager()
    let hotKey = HotKey()
    var searchRequested: (() -> Void)?
    var searchDisabled: (() -> Void)?
    var statusMenuRequested: (() -> Void)?
    private var timer: Timer?
    private var fastPolling = false
    private var snapshotInFlight = false
    private var pendingTarget: Desktop?
    private var deadline = Date.distantPast
    private var didPress = false
    private var switchReadiness = SwitchReadiness()
    private var layoutCache = OverlayLayoutCache()
    private var thumbnailReveal: [UInt32: ThumbnailReveal] = [:]
    private var missionEntryAt: TimeInterval?
    private var visibility = MissionVisibility()
    private var observationGeneration = 0
    private var dismissal = OverlayDismissal()
    private var globalDismissMonitor: Any?
    private var localDismissMonitor: Any?
    private var clickActivity = ClickActivity()
    private var currentThumbnailPress = false
    private var exitMotionUntil: TimeInterval = 0
    private var lastOverlayTrace = ""
    private var lastPermission = false
    private var diagnostics: [String] = []
    private let focusTraceUntil = ProcessInfo.processInfo.systemUptime + 600
    private var sampleStartedAt: TimeInterval = 0
    private var sampleCount = 0
    private var sampleReadTime: TimeInterval = 0
    private let worker = DispatchQueue(label: "renamer.mission-control", qos: .userInitiated)
    private let logWriter = DispatchQueue(label: "renamer.diagnostics", qos: .utility)

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Renamer", isDirectory: true)
        store = NameStore(url: directory.appendingPathComponent("names.json"), bootID: SpaceSystem.bootID())
        showCurrent = UserDefaults.standard.bool(forKey: "showCurrent")
        searchEnabled = SearchPreference.load()
        searchShortcut = SearchShortcut.load()
        hotKey.action = { [weak self] in guard let self, self.searchEnabled, !self.recordingShortcut else { return }; self.logSearch("hotkey received"); self.searchRequested?() }
        configureHotKey()
        refresh()
        if let error = store.loadError { status = error }
    }

    func start() {
        setPolling(active: false)
        mission.onExit = { [weak self] in
            guard let self else { return }
            self.missionEntryAt = nil
            self.dismissPresentation(reason: "Mission Control exit notification", duration: 0.25)
        }
        mission.onEnter = { [weak self] in
            guard let self else { return }
            self.missionEntryAt = ProcessInfo.processInfo.systemUptime
            self.observationGeneration += 1
            self.exitMotionUntil = 0
            self.currentThumbnailPress = false
            self.overlays.hide()
            self.overlays.cancelExitMotion()
            self.dismissal.reopen()
            self.setPolling(active: true)
            self.tick()
        }
        // Observe only; never intercept input or activate a Renamer window.
        let mask: NSEvent.EventTypeMask = [.keyDown]
        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleDismissalInput(event)
        }
        localDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleDismissalInput(event)
            return event
        }
        traceFocus("Focus tracing started; expires after 10 minutes")
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] event in
            let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.traceFocus("Activated \(app?.bundleIdentifier ?? "unknown")")
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.recover() }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.traceFocus("Space change notification")
            self?.refresh()
        }
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.observationGeneration += 1
            self?.clearPresentation(reason: "screens sleeping")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.recover() }
    }

    deinit {
        if let globalDismissMonitor { NSEvent.removeMonitor(globalDismissMonitor) }
        if let localDismissMonitor { NSEvent.removeMonitor(localDismissMonitor) }
    }

    private func handleDismissalInput(_ event: NSEvent) {
        guard visibility.visible else { return }
        if event.type == .keyDown && event.keyCode == 53 {
            dismissPresentation(reason: "Mission Control Escape; labels moving with collapse", duration: 0.65, animate: true)
        }
    }

    private func pollDismissalClick() {
        // Dock may consume Mission Control mouse events, so sample Window
        // Server button state and classify a release as a click or drag.
        // Keep the baseline fresh even outside Mission Control; never intercept
        // or replay events, and never wait on the AX worker to detect a click.
        let count = CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown)
        let pressed = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let point = CGEvent(source: nil)?.location
        let gesture = clickActivity.observe(count: count, pressed: pressed, point: point)
        if let began = gesture.began, visibility.visible, isCurrentThumbnail(at: began) {
            currentThumbnailPress = true
            exitMotionUntil = ProcessInfo.processInfo.systemUptime + OverlayManager.exitDuration
            overlays.animateExitUp()
        }
        if gesture.startedDragging && currentThumbnailPress {
            currentThumbnailPress = false
            exitMotionUntil = 0
            overlays.cancelExitMotion()
            renderCachedLabels()
        }
        guard gesture.ended else { return }
        let wasCurrentThumbnailPress = currentThumbnailPress
        currentThumbnailPress = false
        if let clicked = gesture.clicked, visibility.visible {
            if wasCurrentThumbnailPress {
                dismissPresentation(reason: "Current desktop selected; labels moving with collapse", duration: 0.65, animate: true,
                                    motionAlreadyStarted: true)
            } else {
                dismissForClick(at: clicked, source: "Window Server click state")
            }
        } else if wasCurrentThumbnailPress {
            exitMotionUntil = 0
            overlays.cancelExitMotion()
            renderCachedLabels()
        }
    }

    private func isCurrentThumbnail(at point: CGPoint) -> Bool {
        spaces.contains { space in
            space.isCurrent && CGDisplayBounds(space.screenID).contains(point)
                && (layoutCache.entries[space.sessionID]?.geometry.frame.contains(point) ?? false)
        }
    }

    private func dismissForClick(at point: CGPoint, source: String) {
        guard visibility.visible else { return }
        for screenID in Set(layoutCache.entries.values.map(\.screenID)) {
            let frames = layoutCache.entries.values.filter { $0.screenID == screenID }.map { $0.geometry.frame }
            if MissionExitIntent.isExitClick(point: point, screen: CGDisplayBounds(screenID), frames: frames) {
                dismissPresentation(reason: "Mission Control dismissal via \(source); labels moving with collapse", duration: 0.65,
                                    animate: true)
                return
            }
        }
    }

    private func dismissPresentation(reason: String, duration: TimeInterval, animate: Bool = false,
                                     motionAlreadyStarted: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        observationGeneration += 1
        dismissal.begin(now: now, duration: duration)
        if animate {
            if !motionAlreadyStarted {
                exitMotionUntil = now + OverlayManager.exitDuration
                overlays.animateExitUp()
            }
            clearPresentation(reason: reason, hideOverlays: false)
        } else if now >= exitMotionUntil {
            clearPresentation(reason: reason)
        } else {
            log(reason)
        }
    }

    private func setPolling(active: Bool) {
        guard timer == nil || fastPolling != active else { return }
        fastPolling = active
        timer?.invalidate()
        // High cadence only while Mission Control is open. A slow Dock read
        // never queues another request: snapshotInFlight keeps one in flight.
        let interval: TimeInterval = active ? 1.0 / 60 : 0.1
        timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = active ? 0.001 : 0.02
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func configureHotKey() {
        guard searchEnabled else { hotKey.unregister(); hotKeyWarning = ""; return }
        hotKeyWarning = hotKey.register(searchShortcut) ? "" : L("快捷键无法注册，可能已被占用。请点击快捷键重新设置。")
    }

    func beginShortcutRecording() {
        guard searchEnabled else { return }
        shortcutDraft = ""
        recordingShortcut = true
        hotKeyWarning = ""
        hotKey.unregister()
    }

    func cancelShortcutRecording() {
        guard recordingShortcut else { return }
        recordingShortcut = false
        shortcutDraft = ""
        configureHotKey()
    }

    @discardableResult
    func saveShortcut(_ shortcut: SearchShortcut) -> Bool {
        guard searchEnabled, recordingShortcut else { return false }
        guard shortcut.isValid else {
            hotKeyWarning = L("请搭配 ⌘、⌥、⌃ 中的至少一个键，或使用 F1–F20。Esc 取消。")
            return false
        }
        guard hotKey.register(shortcut) else {
            hotKeyWarning = L("这个快捷键无法注册，可能已被占用，请换一个。Esc 取消并保留原设置。")
            return false
        }
        searchShortcut = shortcut
        shortcut.save()
        recordingShortcut = false
        shortcutDraft = ""
        hotKeyWarning = ""
        return true
    }

    func refresh() {
        do {
            let latest = try system.read()
            try store.reconcile(latest)
            if spaces != latest { spaces = latest }
        } catch {
            status = error.localizedDescription
            layoutCache.expire(now: ProcessInfo.processInfo.systemUptime)
            renderCachedLabels()
        }
    }

    @discardableResult
    func rename(_ desktop: Desktop, name: String) -> Bool {
        do {
            let live = try system.read()
            guard live.contains(where: { $0.identity(bootID: store.bootID) == desktop.identity(bootID: store.bootID) }) else {
                throw RenamerError.message(L("这个桌面已不存在，未保存修改。"))
            }
            try store.rename(desktop, to: name, among: live)
            revision += 1
            status = L("名称已保存")
            log("Saved name for desktop identity; position=\(desktop.position)")
            return true
        } catch { status = error.localizedDescription; return false }
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func recover() {
        observationGeneration += 1
        clearPresentation(reason: "recovery")
        switchReadiness.invalidateGeometry()
        overlays.reset()
        labelCount = 0
        refresh()
        status = L("已重新读取桌面，等待 Mission Control")
        log("Recovered overlay state")
    }

    func switchTo(_ desktop: Desktop) {
        traceFocus("Explicit switch request: screen=\(desktop.screenID) position=\(desktop.position)")
        guard AXIsProcessTrusted() else { status = L("请先在设置中允许 Renamer 使用辅助功能。"); return }
        guard !switching else { status = L("正在切换，请稍候。"); return }
        do {
            let live = try system.read()
            guard let target = live.first(where: { $0.identity(bootID: store.bootID) == desktop.identity(bootID: store.bootID) }) else {
                throw RenamerError.message(L("目标桌面已不存在或已断开。"))
            }
            if target.isCurrent { status = L("已经在 %@", store.name(target)); return }
            pendingTarget = target
            didPress = false
            switching = true
            switchReadiness.begin(now: ProcessInfo.processInfo.systemUptime)
            deadline = Date().addingTimeInterval(6)
            status = L("正在切换到 %@…", store.name(target))
            if case .active = mission.snapshot() {
                // If the user already opened Mission Control, select there.
                usingDirectSwitch = false
            } else {
                usingDirectSwitch = true
                if directSwitch.send(target: target, live: live) {
                    log("Sent direct horizontal desktop gestures; target=\(target.position); waiting for current desktop confirmation")
                } else {
                    finishSwitch(L("未能确认切换到 %@：快速切换暂不可用。", store.name(target)))
                }
            }
        } catch { status = error.localizedDescription }
    }

    private func finishSwitch(_ message: String) {
        status = message
        switching = false
        pendingTarget = nil
        switchReadiness.reset()
        directSwitch.restoreCursorIfUntouched()
        usingDirectSwitch = false
        didPress = false
        log(message)
    }

    private func tick() {
        pollDismissalClick()
        let trusted = AXIsProcessTrusted()
        if permission != trusted { permission = trusted }
        if permission != lastPermission {
            lastPermission = permission
            recover()
        }
        if let target = pendingTarget, Date() > deadline {
            finishSwitch(L("未能确认切换到 %@。请稍后重试。", store.name(target)))
        }
        guard permission else {
            clearPresentation(reason: "permission unavailable")
            labelCount = 0
            if !switching { status = L("需要辅助功能权限才能显示标签和切换；名称编辑可用。") }
            return
        }
        guard !snapshotInFlight else { return }
        mission.observe()
        snapshotInFlight = true
        let generation = observationGeneration
        worker.async { [weak self] in
            guard let self else { return }
            let startedAt = ProcessInfo.processInfo.systemUptime
            let snapshot = self.mission.snapshot()
            let readTime = ProcessInfo.processInfo.systemUptime - startedAt
            DispatchQueue.main.async {
                self.snapshotInFlight = false
                guard generation == self.observationGeneration else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if case .active = snapshot, now - startedAt > 0.1 {
                    self.log(String(format: "MC stale AX read %.0f ms; cached=%d; labels=%d", (now - startedAt) * 1000,
                                    self.layoutCache.entries.count, self.labelCount))
                }
                self.consume(snapshot)
                if case .active = snapshot { self.recordCadence(readTime: readTime) }
            }
        }
    }

    private func clearPresentation(reason: String, hideOverlays: Bool = true) {
        currentThumbnailPress = false
        switchReadiness.invalidateGeometry()
        setPolling(active: false)
        sampleStartedAt = 0
        sampleCount = 0
        sampleReadTime = 0
        visibility.exit()
        layoutCache.clear()
        thumbnailReveal.removeAll()
        if hideOverlays {
            exitMotionUntil = 0
            overlays.hide()
            overlays.cancelExitMotion()
        }
        labelCount = 0
        if lastOverlayTrace != reason { log(reason); lastOverlayTrace = reason }
    }

    private func renderCachedLabels() {
        if currentThumbnailPress { return }
        guard visibility.visible else { overlays.hide(); if labelCount != 0 { labelCount = 0 }; return }
        let hiddenThumbnails = Set(thumbnailReveal.filter { !$0.value.ready }.keys)
        let count = overlays.render(layouts: layoutCache.entries, spaces: spaces, names: store, showCurrent: showCurrent, appearance: appearance.normalized, currentAppearance: currentAppearance.normalized, hiddenThumbnailScreens: hiddenThumbnails)
        if labelCount != count { labelCount = count }
    }

    private func consume(_ observation: MissionObservation) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !dismissal.isSuppressed(now: now) else { return }
        // Verify a requested switch even after Mission Control has disappeared.
        let reading = Result { try system.read() }
        if case .success(let latest) = reading {
            if spaces != latest { spaces = latest }
            if let target = pendingTarget, let actual = latest.first(where: {
                $0.identity(bootID: store.bootID) == target.identity(bootID: store.bootID)
            }), actual.isCurrent {
                finishSwitch(L("已切换到 %@", store.name(actual)))
            }
        }
        let snapshot: MissionSnapshot
        switch observation {
        case .active(let value):
            setPolling(active: true)
            visibility.active(now: now)
            snapshot = value
        case .inactive, .unavailable:
            let failed: Bool
            if case .unavailable = observation { failed = true } else { failed = false }
            if !visibility.missing(now: now, readFailed: failed) {
                clearPresentation(reason: failed ? "AX read unavailable beyond grace" : "Mission Control absent")
            } else {
                layoutCache.expire(now: now)
                renderCachedLabels()
            }
            switchReadiness.invalidateGeometry()
            return
        }
        let live: [Desktop]
        do { live = try reading.get() }
        catch {
            layoutCache.expire(now: now); renderCachedLabels(); status = error.localizedDescription; return
        }
        if spaces != live { spaces = live }
        let screenIDs = Set(live.map(\.screenID))
        thumbnailReveal = thumbnailReveal.filter { screenIDs.contains($0.key) }
        layoutCache.retain(screens: screenIDs, liveIDs: Set(live.map(\.sessionID)), now: now)
        for screenID in screenIDs {
            let ordered = live.filter { $0.screenID == screenID }.sorted { $0.position < $1.position }
            let geometry = snapshot.groups[screenID]?.map { button -> ButtonGeometry? in
                button.rect.map { ButtonGeometry(frame: $0, title: button.textRect) }
            }
            if let geometry, geometry.count == ordered.count, geometry.allSatisfy({ $0 != nil }) {
                var reveal = thumbnailReveal[screenID] ?? ThumbnailReveal()
                let before = reveal.ready
                reveal.observe(frames: geometry.compactMap { $0?.frame }, now: now,
                               openingBeganAt: missionEntryAt.flatMap { now - $0 < 1 ? $0 : nil })
                thumbnailReveal[screenID] = reveal
                if before != reveal.ready {
                    log("Thumbnail reveal screen=\(screenID): \(reveal.ready ? "visible after opening" : "waiting for strip opening")")
                }
            }
            layoutCache.update(screenID: screenID, orderedIDs: ordered.map(\.sessionID), buttons: geometry,
                               sampledAt: snapshot.groups[screenID]?.map(\.sampledAt), now: now)
        }
        renderCachedLabels()
        let trace = "MC active; displays=\(snapshot.groups.count); cached=\(layoutCache.entries.count); labels=\(labelCount)"
        if trace != lastOverlayTrace { log(trace); lastOverlayTrace = trace }

        // Stable geometry is needed only before clicking a button. It must
        // never gate drawing during normal hover/expand animations.
        if snapshot.groups.isEmpty, !switching { status = L("已检测到 Mission Control，但无法定位桌面按钮。请导出诊断。") }
        guard pendingTarget != nil, !usingDirectSwitch else { switchReadiness.invalidateGeometry(); return }
        let fingerprint = live.map { "\($0.screenID):\($0.sessionID)" }.joined(separator: ",") + "|" + snapshot.groups.keys.sorted().map { id in
            "\(id):" + (snapshot.groups[id] ?? []).map { button in
                button.rect.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" } ?? "unreadable"
            }.joined(separator: ";")
        }.joined(separator: "|")
        guard switchReadiness.observe(fingerprint, now: now) else { return }
        if let target = pendingTarget, !didPress, !CGEventSource.buttonState(.combinedSessionState, button: .left) {
            let ordered = live.filter { $0.screenID == target.screenID }.sorted { $0.position < $1.position }
            if let index = ordered.firstIndex(where: { $0.identity(bootID: store.bootID) == target.identity(bootID: store.bootID) }),
               let buttons = snapshot.groups[target.screenID], buttons.count == ordered.count, buttons[index].rect != nil {
                let result = AXUIElementPerformAction(buttons[index].element, kAXPressAction as CFString)
                if result == .success { didPress = true; log("Sent AXPress; waiting for current desktop confirmation") }
                else { finishSwitch(L("系统未接受桌面切换，请重试（%d）。", result.rawValue)) }
            }
        }
    }

    private func recordCadence(readTime: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        if sampleStartedAt == 0 { sampleStartedAt = now; return }
        sampleCount += 1
        sampleReadTime += readTime
        let elapsed = now - sampleStartedAt
        guard elapsed >= 5 else { return }
        log(String(format: "MC sampling: %.1f updates/s; mean AX read %.1f ms; labels=%d; surfaces=%d",
                   Double(sampleCount) / elapsed, sampleReadTime * 1000 / Double(sampleCount), labelCount, overlays.visibleSurfaceCount))
        sampleStartedAt = now
        sampleCount = 0
        sampleReadTime = 0
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Renamer-diagnostics.txt"
        panel.begin { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            let lines = ["Renamer \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") technical preview", ProcessInfo.processInfo.operatingSystemVersionString,
                         "Accessibility=\(self.permission)", "Screens=\(NSScreen.screens.count)",
                         "Spaces=\(self.spaces.count)", "Missing UUIDs=\(self.spaces.filter { $0.persistentID == nil }.count)",
                         "Overlay count=\(self.labelCount)", "Status=\(self.status)"] + self.diagnostics
            do { try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) }
            catch { self.status = L("导出失败：%@", error.localizedDescription) }
        }
    }

    func traceFocus(_ event: String) {
        guard ProcessInfo.processInfo.systemUptime < focusTraceUntil else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        let ownWindows = NSApp.windows.filter { $0.isVisible && $0.level == .normal }.count
        log("FOCUS \(event); front=\(front); active=\(NSApp.isActive); normalWindows=\(ownWindows); switching=\(switching)")
    }

    func logSearch(_ event: String) { log("SEARCH \(event)") }

    private func log(_ text: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        diagnostics.append("\(formatter.string(from: Date())) \(text)")
        if diagnostics.count > 100 { diagnostics.removeFirst(diagnostics.count - 100) }
        let logURL = store.url.deletingLastPathComponent().appendingPathComponent("last-session.log")
        let text = diagnostics.joined(separator: "\n")
        logWriter.async {
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}
