import Foundation

enum DirectSwitchPlan {
    static func steps(target: Desktop, live: [Desktop]) -> Int? {
        let spaces = live.filter { $0.displayID == target.displayID && $0.screenID == target.screenID }
            .sorted { $0.position < $1.position }
        guard spaces.filter(\.isCurrent).count == 1,
              let current = spaces.firstIndex(where: \.isCurrent),
              let destination = spaces.firstIndex(where: { $0.sessionID == target.sessionID }),
              spaces.count <= 64 else { return nil }
        return destination - current
    }
}

/// Two equal samples can occur before the opening animation has begun.
/// Require both an initial settling interval and sustained geometry stability.
struct SwitchReadiness {
    private var requestTime: TimeInterval?
    private var stableSince: TimeInterval?
    private var fingerprint: String?

    mutating func begin(now: TimeInterval) {
        requestTime = now
        invalidateGeometry()
    }
    mutating func invalidateGeometry() { stableSince = nil; fingerprint = nil }
    mutating func reset() { requestTime = nil; invalidateGeometry() }
    mutating func observe(_ value: String, now: TimeInterval) -> Bool {
        guard let requestTime else { return false }
        if fingerprint != value { fingerprint = value; stableSince = now }
        return now - requestTime >= 0.55 && now - (stableSince ?? now) >= 0.12
    }
}
import CoreGraphics

enum BadgePosition: String, Codable, CaseIterable {
    case top, center, bottom
    var label: String { switch self { case .top: return L("上方"); case .center: return L("居中"); case .bottom: return L("下方") } }
}

struct BadgeColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var normalized: Self {
        func clamp(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 0 }
        return Self(red: clamp(red), green: clamp(green), blue: clamp(blue))
    }
    static let white = Self(red: 1, green: 1, blue: 1)
    static let black = Self(red: 0, green: 0, blue: 0)
}

struct BadgeAppearance: Codable, Equatable {
    var red: Double = 0.24
    var green: Double = 0.32
    var blue: Double = 0.82
    var fontSize: Double = 14
    var position: BadgePosition = .top
    // Optional preserves decoding of appearance settings written before 0.4.0.
    var foreground: BadgeColor? = nil

    var normalized: Self {
        var result = self
        func bound(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        result.red = bound(red, 0...1, fallback: 0.24)
        result.green = bound(green, 0...1, fallback: 0.32)
        result.blue = bound(blue, 0...1, fallback: 0.82)
        result.fontSize = bound(fontSize, 11...20, fallback: 14)
        result.foreground = foreground?.normalized
        return result
    }
    var height: CGFloat { CGFloat(normalized.fontSize) + 12 }
    var usesDarkText: Bool {
        let c = normalized
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
        return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05)
    }
    static let defaultsKey = "badgeAppearance.v1"
    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey), let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return decoded.normalized
    }
    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(normalized) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

struct ButtonGeometry {
    let frame: CGRect
    let title: CGRect?
}

enum MissionExitIntent {
    /// A completed click below the strip selects a window; one inside a
    /// thumbnail selects a desktop. Drag gestures are filtered beforehand.
    static func isExitClick(point: CGPoint, screen: CGRect, frames: [CGRect]) -> Bool {
        guard screen.contains(point), let bottom = frames.map(\.maxY).max() else { return false }
        return frames.contains { $0.contains(point) } || point.y > max(screen.minY + 40, bottom + 24)
    }
}

struct OverlayDismissal {
    private var until: TimeInterval = 0
    mutating func begin(now: TimeInterval, duration: TimeInterval) { until = max(until, now + duration) }
    mutating func reopen() { until = 0 }
    func isSuppressed(now: TimeInterval) -> Bool { now < until }
}

/// Distinguishes a click that selects a window from a drag that starts there.
/// Counts retain even a short trackpad tap completed between two timer ticks.
struct ClickObservation {
    var began: CGPoint? = nil
    var ended = false
    var startedDragging = false
    var clicked: CGPoint? = nil
}

struct ClickActivity {
    private var previousCount: UInt32?
    private var wasPressed = false
    private var downPoint: CGPoint?
    private var dragged = false
    private static let dragDistance: CGFloat = 8

    private func moved(from start: CGPoint, to end: CGPoint) -> Bool {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return dx * dx + dy * dy >= Self.dragDistance * Self.dragDistance
    }

    mutating func observe(count: UInt32, pressed: Bool, point: CGPoint?) -> ClickObservation {
        defer { previousCount = count; wasPressed = pressed }
        guard let previousCount else { return ClickObservation() }
        if wasPressed && !pressed {
            let movedOnRelease = downPoint.flatMap { start in point.map { moved(from: start, to: $0) } } ?? false
            let click = dragged || movedOnRelease ? nil : (downPoint ?? point)
            downPoint = nil
            dragged = false
            return ClickObservation(ended: true, clicked: click)
        }
        if pressed && !wasPressed {
            downPoint = point
            dragged = false
            return ClickObservation(began: point)
        }
        if pressed, let downPoint, let point {
            let startedDragging = !dragged && moved(from: downPoint, to: point)
            if startedDragging { dragged = true }
            return ClickObservation(startedDragging: startedDragging)
        }
        // The button went down and up between two samples.
        return ClickObservation(ended: count > previousCount,
                                clicked: count > previousCount ? point : nil)
    }
}

/// Dock publishes expanded AX rectangles before its opening animation finishes.
/// Delay only the first compact -> expanded reveal in this Mission Control
/// session. Repeated hover/collapse must keep the already visible labels.
struct ThumbnailReveal {
    private var initialRevealStarted = false
    private var initialRevealCompleted = false
    private var revealAt: TimeInterval = 0
    private(set) var ready = true
    static let openingDelay: TimeInterval = 0.07

    mutating func observe(frames: [CGRect], now: TimeInterval, openingBeganAt: TimeInterval? = nil) {
        guard !frames.isEmpty else { return }
        let isExpanded = frames.contains { $0.height > 32 }
        if isExpanded && !initialRevealStarted {
            revealAt = (openingBeganAt ?? now) + Self.openingDelay
            initialRevealStarted = true
        }
        if isExpanded && now >= revealAt { initialRevealCompleted = true }
        ready = !isExpanded || initialRevealCompleted
    }
}

/// Retains individually verified geometry across short AX read gaps. Geometry
/// movement is an update, never a reason to hide an entire display.
struct OverlayLayoutCache {
    struct Entry {
        let screenID: UInt32
        let geometry: ButtonGeometry
        let updatedAt: TimeInterval
    }
    private(set) var entries: [UInt64: Entry] = [:]
    private var orders: [UInt32: [UInt64]] = [:]
    private var candidates: [UInt32: [UInt64]] = [:]
    static let grace: TimeInterval = 0.9

    mutating func clear() { entries.removeAll(); orders.removeAll(); candidates.removeAll() }

    mutating func update(screenID: UInt32, orderedIDs: [UInt64], buttons: [ButtonGeometry?]?,
                         sampledAt: [TimeInterval]? = nil, now: TimeInterval) {
        if orders[screenID] != orderedIDs {
            // An identity/order change really can invalidate positional matching.
            entries = entries.filter { $0.value.screenID != screenID }
            guard candidates[screenID] == orderedIDs else {
                candidates[screenID] = orderedIDs
                return
            }
            orders[screenID] = orderedIDs
            candidates.removeValue(forKey: screenID)
        }
        guard let buttons, buttons.count == orderedIDs.count,
              sampledAt == nil || sampledAt?.count == orderedIDs.count else { expire(now: now); return }
        for (index, id) in orderedIDs.enumerated() {
            let sample = sampledAt?[index] ?? now
            if let geometry = buttons[index], now - sample <= 0.16,
               sample >= (entries[id]?.updatedAt ?? -TimeInterval.infinity) {
                entries[id] = Entry(screenID: screenID, geometry: geometry, updatedAt: sample)
            }
        }
        expire(now: now)
    }

    mutating func retain(screens: Set<UInt32>, liveIDs: Set<UInt64>, now: TimeInterval) {
        entries = entries.filter { screens.contains($0.value.screenID) && liveIDs.contains($0.key) }
        orders = orders.filter { screens.contains($0.key) }
        candidates = candidates.filter { screens.contains($0.key) }
        expire(now: now)
    }

    mutating func expire(now: TimeInterval) {
        entries = entries.filter { now - $0.value.updatedAt <= Self.grace }
    }
}

/// A successful empty tree and a failed read are different observations.
struct MissionVisibility {
    private(set) var visible = false
    private var absentSince: TimeInterval?
    private var activeAt = -TimeInterval.infinity

    mutating func active(now: TimeInterval) {
        visible = true
        absentSince = nil
        activeAt = now
    }
    mutating func missing(now: TimeInterval, readFailed: Bool) -> Bool {
        if readFailed {
            if now - activeAt > OverlayLayoutCache.grace { visible = false }
        } else {
            if absentSince == nil { absentSince = now }
            if now - (absentSince ?? now) >= 0.05 { visible = false }
        }
        return visible
    }
    mutating func exit() { visible = false; absentSince = nil; activeAt = -.infinity }
}

enum BadgeLayout {
    static func frame(geometry: ButtonGeometry, screen: CGRect, preferredWidth: CGFloat = 88,
                      position: BadgePosition = .bottom, preferredHeight: CGFloat = 24) -> CGRect? {
        let thumbnail = geometry.frame.intersection(screen)
        guard !thumbnail.isNull, thumbnail.width >= 24, thumbnail.height >= 16 else { return nil }
        // Blend by the actual expansion geometry, not by a delayed animation.
        // A hard height threshold made the badge jump while the strip expanded.
        let progress = min(1, max(0, (thumbnail.height - 32) / 28))
        let expanded = progress * progress * (3 - 2 * progress)
        let margin = 2 + 8 * expanded
        let width = min(260, max(22, preferredWidth), thumbnail.width - margin)
        let height = min(max(16, preferredHeight), 40, thumbnail.height)
        let centerX = thumbnail.midX
        let title = geometry.title?.intersection(screen)
        let compactY = title?.isNull == false ? title!.midY : thumbnail.midY
        let expandedY: CGFloat
        switch position {
        case .top: expandedY = thumbnail.minY + height / 2 + 7
        case .center: expandedY = thumbnail.midY
        case .bottom: expandedY = thumbnail.maxY - height / 2 - 7
        }
        let centerY = compactY + (expandedY - compactY) * expanded
        let x = min(max(centerX - width / 2, screen.minX), screen.maxX - width)
        let y = min(max(centerY - height / 2, screen.minY), screen.maxY - height)
        guard width >= 22, height >= 16 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}


/// Independent settings for the large current-desktop label below the strip.
struct CurrentBadgeAppearance: Codable, Equatable {
    var background = BadgeColor(red: 0.16, green: 0.18, blue: 0.23)
    var foreground = BadgeColor.white
    var fontSize: Double = 28
    var horizontal: Double = 0.5
    var vertical: Double = 0.96
    var normalized: Self {
        var value = self
        func bound(_ n: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            n.isFinite ? min(range.upperBound, max(range.lowerBound, n)) : fallback
        }
        value.background = background.normalized
        value.foreground = foreground.normalized
        value.fontSize = bound(fontSize, 16...64, 28)
        value.horizontal = bound(horizontal, 0...1, 0.5)
        value.vertical = bound(vertical, 0...1, 0.96)
        return value
    }
    var height: CGFloat { ceil(normalized.fontSize * 1.3) + 12 }
    static let defaultsKey = "currentBadgeAppearance.v1"
    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value.normalized
    }
    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(normalized) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

enum CurrentBadgeLayout {
    /// Coordinates are normalized within the area below the desktop strip.
    /// The default bottom-centre anchor keeps the label away from the former
    /// fixed right-side position. Users can place it in their own empty area.
    static func frame(screen: CGRect, stripBottom: CGFloat, preferredWidth: CGFloat,
                      appearance: CurrentBadgeAppearance) -> CGRect? {
        let style = appearance.normalized
        let top = max(screen.minY + 100, stripBottom + 28)
        let height = style.height
        let availableHeight = screen.maxY - 36 - top
        guard screen.width >= 88, availableHeight >= height, preferredWidth.isFinite else { return nil }
        let area = CGRect(x: screen.minX + 24, y: top, width: screen.width - 48,
                          height: availableHeight)
        let width = min(area.width, 680, max(40, preferredWidth))
        return CGRect(x: area.minX + (area.width - width) * style.horizontal,
                      y: area.minY + (area.height - height) * style.vertical,
                      width: width, height: height)
    }
}
