import AppKit

var passed = 0
func check(_ condition: Bool, _ message: String) {
    precondition(condition, message)
    passed += 1
    print("PASS: \(message)")
}
func launchEvent(_ id: AEEventID = AEEventID(kAEOpenApplication)) -> NSAppleEventDescriptor {
    NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: id,
        targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
}
check(!LaunchContext.isLoginItem(nil), "ordinary launch without event shows settings")
check(!LaunchContext.isLoginItem(launchEvent()), "ordinary open-application event shows settings")
let login = launchEvent()
login.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
check(LaunchContext.isLoginItem(login), "login-item launch stays in background")
let service = launchEvent()
service.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsServiceItem)), forKeyword: AEKeyword(keyAEPropData))
check(!LaunchContext.isLoginItem(service), "unrelated launch property is not mistaken for login")
let direct = launchEvent()
direct.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: AEKeyword(keyAELaunchedAsLogInItem))
check(LaunchContext.isLoginItem(direct), "direct login-item property stays in background")
let reopen = launchEvent(AEEventID(kAEReopenApplication))
reopen.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
check(!LaunchContext.isLoginItem(reopen), "explicit reopen is not suppressed")
print("\(passed) launch checks passed")
