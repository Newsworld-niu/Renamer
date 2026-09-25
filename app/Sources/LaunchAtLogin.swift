import AppKit
import ServiceManagement
import SwiftUI

final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var errorMessage = ""
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var requested: Bool { status == .enabled || status == .requiresApproval }
    func refresh() { status = SMAppService.mainApp.status }
    func setEnabled(_ enabled: Bool) {
        errorMessage = ""
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch { errorMessage = error.localizedDescription }
        refresh()
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

enum LaunchContext {
    // Launch Services supplies this property for a login-item launch. A normal
    // Finder launch still opens Settings; an explicit reopen also does so.
    static func isLoginItem(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?
            .enumCodeValue == OSType(keyAELaunchedAsLogInItem)
            || event.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
    }
}
