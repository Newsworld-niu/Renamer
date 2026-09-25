import AppKit
import QuartzCore

extension BadgeColor {
    var nsColor: NSColor {
        let c = normalized
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .white
        self.init(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
    }
}

extension BadgeAppearance {
    var backgroundColor: NSColor {
        let c = normalized
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
    var textColor: NSColor { foreground?.nsColor ?? (usesDarkText ? .black : .white) }
}

final class BadgeView: NSView {
    let label = NSTextField(labelWithString: "")
    static let horizontalInset: CGFloat = 7

    static func preferredWidth(for name: String, font: NSFont) -> CGFloat {
        let measurement = NSTextField(labelWithString: name)
        measurement.font = font
        measurement.maximumNumberOfLines = 1
        measurement.lineBreakMode = .byTruncatingTail
        measurement.alignment = .center
        // NSTextFieldCell includes internal text insets that NSString.size
        // does not. Keep an extra two points for fractional pixel rounding.
        return ceil(measurement.cell!.cellSize.width) + 2 * horizontalInset + 2
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.98).cgColor
        layer?.cornerRadius = 7
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.borderWidth = 0.5
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func apply(name: String, appearance: BadgeAppearance) {
        apply(name: name, fontSize: appearance.normalized.fontSize,
              background: appearance.backgroundColor, foreground: appearance.textColor)
    }
    func apply(name: String, fontSize: Double, background: NSColor, foreground: NSColor) {
        if label.stringValue != name { label.stringValue = name }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        if label.font != font { label.font = font }
        if label.textColor != foreground { label.textColor = foreground }
        if layer?.backgroundColor != background.cgColor { layer?.backgroundColor = background.cgColor }
    }
    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: Self.horizontalInset, dy: 3)
    }
}

/// All badges on one display share a single backing surface. Separate windows
/// commit their positions individually and can spread one layout across frames.
private final class OverlayCanvas: NSView {
    override var isFlipped: Bool { true }
}

private final class OverlaySurface {
    let panel: NSPanel
    let canvas = OverlayCanvas(frame: .zero)
    var badges: [String: BadgeView] = [:]

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        canvas.wantsLayer = true
        panel.contentView = canvas
    }
}

final class OverlayManager {
    static let exitDuration: TimeInterval = 0.16
    private struct Badge {
        let key: String
        let name: String
        let rect: CGRect
        let current: CurrentBadgeAppearance?
    }
    private var surfaces: [UInt32: OverlaySurface] = [:]
    private var measuredWidths: [String: (name: String, fontSize: Double, width: CGFloat)] = [:]
    private var exitMotionGeneration = 0

    var visibleSurfaceCount: Int { surfaces.values.filter { $0.panel.isVisible }.count }

    func hide() {
        for surface in surfaces.values { surface.panel.orderOut(nil) }
    }

    func animateExitUp(duration: TimeInterval = OverlayManager.exitDuration) {
        cancelExitMotion()
        let generation = exitMotionGeneration
        for surface in surfaces.values where surface.panel.isVisible {
            let bottom = surface.badges.values.filter { !$0.isHidden }.map { $0.frame.maxY }.max() ?? 0
            let distance = max(100, bottom + 20)
            let motion = CABasicAnimation(keyPath: "transform.translation.y")
            motion.fromValue = 0
            // OverlayCanvas is flipped; Core Animation's translation sign is
            // opposite the top-left view coordinates used by badge frames.
            motion.toValue = distance
            motion.duration = duration
            motion.timingFunction = CAMediaTimingFunction(name: .easeIn)
            motion.fillMode = .forwards
            motion.isRemovedOnCompletion = false
            surface.canvas.layer?.add(motion, forKey: "renamer-exit-up")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.exitMotionGeneration == generation else { return }
            self.hide()
            self.cancelExitMotion()
        }
    }

    func cancelExitMotion() {
        exitMotionGeneration += 1
        for surface in surfaces.values { surface.canvas.layer?.removeAnimation(forKey: "renamer-exit-up") }
    }

    func reset() {
        cancelExitMotion()
        for surface in surfaces.values { surface.panel.close() }
        surfaces.removeAll()
        measuredWidths.removeAll()
    }

    private func width(key: String, name: String, fontSize: Double) -> CGFloat {
        if measuredWidths[key]?.name != name || measuredWidths[key]?.fontSize != fontSize {
            measuredWidths[key] = (name, fontSize, BadgeView.preferredWidth(for: name,
                font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)))
        }
        return measuredWidths[key]!.width
    }

    private func present(_ badges: [Badge], screenID: UInt32, primaryHeight: CGFloat, appearance: BadgeAppearance) {
        guard !badges.isEmpty else { surfaces[screenID]?.panel.orderOut(nil); return }
        let surface = surfaces[screenID] ?? OverlaySurface()
        surfaces[screenID] = surface
        let screen = CGDisplayBounds(screenID)
        let windowFrame = NSRect(x: screen.minX, y: primaryHeight - screen.maxY, width: screen.width, height: screen.height)
        let visible = Set(badges.map(\.key))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if surface.panel.frame != windowFrame { surface.panel.setFrame(windowFrame, display: false, animate: false) }
        for badge in badges {
            let view = surface.badges[badge.key] ?? BadgeView(frame: .zero)
            if surface.badges[badge.key] == nil {
                surface.badges[badge.key] = view
                surface.canvas.addSubview(view)
            }
            if let style = badge.current {
                view.apply(name: badge.name, fontSize: style.fontSize, background: style.background.nsColor,
                           foreground: style.foreground.nsColor)
            } else { view.apply(name: badge.name, appearance: appearance) }
            // Canvas is flipped: local coordinates follow the AX top-left origin.
            view.frame = badge.rect.offsetBy(dx: -screen.minX, dy: -screen.minY)
            view.isHidden = false
            view.layoutSubtreeIfNeeded()
        }
        for (key, view) in surface.badges where !visible.contains(key) { view.isHidden = true }
        surface.canvas.layoutSubtreeIfNeeded()
        CATransaction.commit()
        if !surface.panel.isVisible { surface.panel.orderFrontRegardless() }
    }

    func render(layouts: [UInt64: OverlayLayoutCache.Entry], spaces: [Desktop], names: NameStore, showCurrent: Bool, appearance: BadgeAppearance, currentAppearance: CurrentBadgeAppearance, hiddenThumbnailScreens: Set<UInt32> = []) -> Int {
        guard let primary = NSScreen.screens.first else { hide(); return 0 }
        var badges: [UInt32: [Badge]] = [:]
        for space in spaces where space.isOrdinary && !hiddenThumbnailScreens.contains(space.screenID) {
            guard let entry = layouts[space.sessionID], let name = names.customName(space) else { continue }
            let key = "space:\(space.sessionID)"
            let preferredWidth = width(key: key, name: name, fontSize: appearance.fontSize)
            guard let rect = BadgeLayout.frame(geometry: entry.geometry, screen: CGDisplayBounds(space.screenID),
                                               preferredWidth: preferredWidth, position: appearance.position,
                                               preferredHeight: appearance.height) else { continue }
            badges[space.screenID, default: []].append(Badge(key: key, name: name, rect: rect, current: nil))
        }
        if showCurrent {
            for current in spaces where current.isCurrent && current.isOrdinary {
                guard layouts[current.sessionID] != nil else { continue }
                let name = names.name(current)
                let screen = CGDisplayBounds(current.screenID)
                let style = currentAppearance.normalized
                let key = "current:\(current.screenID)"
                let preferredWidth = width(key: key, name: name, fontSize: style.fontSize)
                let stripBottom = layouts.values.filter { $0.screenID == current.screenID }
                    .map { $0.geometry.frame.maxY }.max() ?? screen.minY
                guard let rect = CurrentBadgeLayout.frame(screen: screen, stripBottom: stripBottom,
                    preferredWidth: preferredWidth, appearance: style) else { continue }
                badges[current.screenID, default: []].append(Badge(key: key, name: name, rect: rect, current: style))
            }
        }
        for screenID in Set(surfaces.keys).union(badges.keys) {
            present(badges[screenID] ?? [], screenID: screenID, primaryHeight: primary.frame.height, appearance: appearance)
        }
        let screenIDs = Set(spaces.map(\.screenID))
        let possibleKeys = Set(spaces.map { "space:\($0.sessionID)" } + spaces.map { "current:\($0.screenID)" })
        for screenID in Array(surfaces.keys) {
            guard screenIDs.contains(screenID) else {
                surfaces.removeValue(forKey: screenID)?.panel.close()
                continue
            }
            if let surface = surfaces[screenID] {
                for key in Array(surface.badges.keys) where !possibleKeys.contains(key) {
                    surface.badges.removeValue(forKey: key)?.removeFromSuperview()
                }
            }
        }
        measuredWidths = measuredWidths.filter { possibleKeys.contains($0.key) }
        return badges.values.reduce(0) { $0 + $1.count }
    }
}
