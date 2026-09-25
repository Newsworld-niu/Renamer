import AppKit
import ApplicationServices
import Darwin

final class SpaceSystem {
    private let library: UnsafeMutableRawPointer?
    private typealias Connection = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private var connection: Connection?
    private var copySpaces: CopySpaces?

    init() {
        library = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
        if let library, let a = dlsym(library, "_CGSDefaultConnection"),
           let b = dlsym(library, "CGSCopyManagedDisplaySpaces") {
            connection = unsafeBitCast(a, to: Connection.self)
            copySpaces = unsafeBitCast(b, to: CopySpaces.self)
        }
    }

    deinit { if let library { dlclose(library) } }

    static func bootID() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
            return "unverified-" + UUID().uuidString
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else {
            return "unverified-" + UUID().uuidString
        }
        return String(cString: buffer)
    }

    func read() throws -> [Desktop] {
        guard let connection, let copySpaces else {
            throw RenamerError.message(L("当前 macOS 的桌面读取接口不可用。"))
        }
        guard let raw = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]], !raw.isEmpty else {
            throw RenamerError.message(L("暂时无法读取桌面，已保留名称；请尝试恢复显示。"))
        }
        let screens = NSScreen.screens
        var screenMap: [String: (UInt32, String)] = [:]
        for screen in screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { continue }
            screenMap[(CFUUIDCreateString(nil, uuid) as String).uppercased()] = (id, screen.localizedName)
        }
        var result: [Desktop] = []
        for display in raw {
            guard let rawID = display["Display Identifier"] as? String,
                  let entries = display["Spaces"] as? [[String: Any]], !entries.isEmpty else {
                throw RenamerError.message(L("桌面数据不完整，暂不更新标签。"))
            }
            var displayID = rawID.uppercased()
            if displayID == "MAIN", let primary = screens.first,
               let id = primary.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
               let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
                displayID = (CFUUIDCreateString(nil, uuid) as String).uppercased()
            }
            guard let screen = screenMap[displayID] else {
                throw RenamerError.message(L("屏幕布局正在变化，等待系统稳定后恢复。"))
            }
            let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber
            for (index, entry) in entries.enumerated() {
                guard let id = entry["ManagedSpaceID"] as? NSNumber else {
                    throw RenamerError.message(L("桌面身份缺失，暂不更新标签。"))
                }
                let uuid = (entry["uuid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let type = (entry["type"] as? NSNumber)?.intValue ?? (entry["Space Type"] as? NSNumber)?.intValue
                result.append(Desktop(sessionID: id.uint64Value,
                                      persistentID: uuid?.isEmpty == false ? uuid : nil,
                                      displayID: displayID, screenID: screen.0, screenName: screen.1,
                                      position: index + 1, isCurrent: id == current, isOrdinary: type == 0))
            }
        }
        guard Set(result.map(\.sessionID)).count == result.count else {
            throw RenamerError.message(L("桌面身份重复，暂不更新标签。"))
        }
        let uuids = result.compactMap(\.persistentID)
        guard Set(uuids).count == uuids.count else { throw RenamerError.message(L("桌面 UUID 重复，暂不更新标签。")) }
        return result
    }
}

enum AXRead {
    static func checkedChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &result) == .success else { return nil }
        return result as? [AXUIElement]
    }
    static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }
    static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    static func identifier(_ element: AXUIElement) -> String {
        value(element, kAXIdentifierAttribute) as? String ?? ""
    }
    static func child(_ element: AXUIElement, id: String) -> AXUIElement? {
        children(element).first { identifier($0) == id }
    }
    static func rect(_ element: AXUIElement) -> CGRect? {
        // One Dock round trip for both fields, instead of two for every desktop.
        var result: CFArray?
        let attributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &result) == .success,
              let values = result as? [CFTypeRef], values.count == 2 else { return nil }
        let p = values[0], s = values[1]
        guard
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size),
              point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }
}

struct SpaceButton {
    let element: AXUIElement
    let rect: CGRect?
    let textRect: CGRect?
    let sampledAt: TimeInterval
}

struct MissionSnapshot {
    let groups: [UInt32: [SpaceButton]]
}

enum MissionObservation {
    case active(MissionSnapshot)
    case inactive
    case unavailable
}

final class MissionControl {
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    // The list elements survive hover animation. Keep their references while
    // periodically rechecking the hierarchy for display changes.
    private var cachedMC: AXUIElement?
    private var cachedLists: [UInt32: AXUIElement] = [:]
    private var cachedListsAt: TimeInterval = 0
    var onExit: (() -> Void)?
    var onEnter: (() -> Void)?

    // Main run loop notifications clear labels immediately on confirmed exit.
    // Polling remains a fallback when notifications are unsupported or lost.
    func observe() {
        guard AXIsProcessTrusted(), let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              dock.processIdentifier != observedPID else { return }
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        var created: AXObserver?
        guard AXObserverCreate(dock.processIdentifier, { _, _, notification, context in
            guard let context else { return }
            let instance = Unmanaged<MissionControl>.fromOpaque(context).takeUnretainedValue()
            if notification as String == "AXExposeExit" { instance.onExit?() }
            if notification as String == "AXExposeShowAllWindows" { instance.onEnter?() }
        }, &created) == .success, let created else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let exitStatus = AXObserverAddNotification(created, root, "AXExposeExit" as CFString, context)
        _ = AXObserverAddNotification(created, root, "AXExposeShowAllWindows" as CFString, context)
        guard exitStatus == .success else { return }
        observedPID = dock.processIdentifier
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    func snapshot() -> MissionObservation {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return .unavailable }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        guard let rootChildren = AXRead.checkedChildren(root) else { return .unavailable }
        guard let mc = rootChildren.first(where: { AXRead.identifier($0) == "mc" }) else {
            cachedMC = nil
            cachedLists.removeAll()
            return .inactive
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let cachedMC, CFEqual(cachedMC, mc), !cachedLists.isEmpty, now - cachedListsAt < 0.5 {
            var cachedGroups: [UInt32: [SpaceButton]] = [:]
            var valid = true
            for (screenID, list) in cachedLists {
                guard let children = AXRead.checkedChildren(list) else { valid = false; break }
                cachedGroups[screenID] = readButtons(children)
            }
            if valid { return .active(MissionSnapshot(groups: cachedGroups)) }
        }
        guard let displays = AXRead.checkedChildren(mc) else { return .unavailable }
        var groups: [UInt32: [SpaceButton]] = [:]
        var lists: [UInt32: AXUIElement] = [:]
        for display in displays where AXRead.identifier(display) == "mc.display" {
            guard let screenID = AXRead.value(display, "AXDisplayID") as? NSNumber,
                  let spaces = AXRead.child(display, id: "mc.spaces"),
                  let list = AXRead.child(spaces, id: "mc.spaces.list") else { continue }
            guard let children = AXRead.checkedChildren(list) else { continue }
            let buttons = readButtons(children)
            // Preserve every slot even if an individual geometry read fails.
            groups[screenID.uint32Value] = buttons
            lists[screenID.uint32Value] = list
        }
        cachedMC = mc
        cachedLists = lists
        cachedListsAt = now
        return .active(MissionSnapshot(groups: groups))
    }

    private func readButtons(_ children: [AXUIElement]) -> [SpaceButton] {
        children.map { element in
            let rect = AXRead.rect(element)
            let sampledAt = ProcessInfo.processInfo.systemUptime
            // Expanded labels are anchored inside the thumbnail. Its native
            // title is not needed, so avoid traversing that subtree at 60 Hz.
            let text = (rect?.height ?? 0) <= 32 ? AXRead.children(element).first {
                AXRead.value($0, kAXRoleAttribute) as? String == kAXStaticTextRole
            } : nil
            let textRect = text.flatMap(AXRead.rect)
            return SpaceButton(element: element, rect: rect, textRect: textRect,
                               sampledAt: sampledAt)
        }
    }

    func open() {
        if case .active = snapshot() { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"),
                                           configuration: config) { _, _ in }
    }
}
