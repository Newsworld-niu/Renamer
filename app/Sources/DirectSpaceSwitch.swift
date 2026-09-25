import AppKit
import ApplicationServices

/// Fast horizontal Dock gestures, without entering Mission Control.
/// Protocol researched from yabai / InstantSpaceSwitcher; see THIRD_PARTY_NOTICES.txt.
/// These event fields are private, so callers must confirm the resulting Space.
final class DirectSpaceSwitch {
    private var cursorRestore: (original: CGPoint, parked: CGPoint)?

    func send(target: Desktop, live: [Desktop]) -> Bool {
        restoreCursorIfUntouched()
        guard let steps = DirectSwitchPlan.steps(target: target, live: live), steps != 0,
              let event = CGEvent(source: nil) else { return false }
        let bounds = CGDisplayBounds(target.screenID)
        let original = event.location
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if !bounds.contains(original) {
            guard CGWarpMouseCursorPosition(center) == .success else { return false }
            cursorRestore = (original, center)
        }
        let direction: Double = steps > 0 ? 1 : -1
        // Dock swipe event: type, HID subtype, horizontal motion, progress,
        // velocity, and began/ended phases. Post a single synchronous batch.
        event.setIntegerValueField(CGEventField(rawValue: 55)!, value: 30)
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 23)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: 1)
        event.setDoubleValueField(CGEventField(rawValue: 124)!, value: direction)
        event.setDoubleValueField(CGEventField(rawValue: 129)!, value: direction * 9999)
        event.location = center
        for _ in 0..<abs(steps) {
            event.setIntegerValueField(CGEventField(rawValue: 132)!, value: 1)
            event.post(tap: .cgSessionEventTap)
            event.setIntegerValueField(CGEventField(rawValue: 132)!, value: 4)
            event.post(tap: .cgSessionEventTap)
        }
        return true
    }

    func restoreCursorIfUntouched() {
        guard let restore = cursorRestore else { return }
        cursorRestore = nil
        guard let point = CGEvent(source: nil)?.location,
              hypot(point.x - restore.parked.x, point.y - restore.parked.y) < 2 else { return }
        // Never pull back a pointer that the user has moved in the meantime.
        CGWarpMouseCursorPosition(restore.original)
    }
}
