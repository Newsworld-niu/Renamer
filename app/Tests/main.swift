import Foundation
import CoreGraphics
AppLanguage.current = .chinese

var passed = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAILED: " + message) }
    passed += 1
    print("PASS: " + message)
}
func desktop(id: UInt64, uuid: String?, position: Int = 1, display: String = "A") -> Desktop {
    Desktop(sessionID: id, persistentID: uuid, displayID: display, screenID: display == "A" ? 1 : 2,
            screenName: display, position: position, isCurrent: false, isOrdinary: true)
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("renamer-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let url = directory.appendingPathComponent("names.json")
let store = NameStore(url: url, bootID: "boot1")
let music = desktop(id: 1, uuid: "AAA", position: 1)
let game = desktop(id: 2, uuid: "BBB", position: 2)
try store.rename(music, to: " music ")
try store.rename(game, to: "game")
check(store.customName(music) == "music", "trim and save name")

let reorderedMusic = desktop(id: 1, uuid: "AAA", position: 2)
let reorderedGame = desktop(id: 2, uuid: "BBB", position: 1)
check(store.customName(reorderedMusic) == "music" && store.customName(reorderedGame) == "game", "reordering never swaps names")
let replacement = desktop(id: 3, uuid: "CCC", position: 1)
check(store.customName(replacement) == nil, "replacement at same position does not inherit deleted name")
let otherDisplay = desktop(id: 4, uuid: "DDD", position: 1, display: "B")
check(store.customName(otherDisplay) == nil, "same position on another display does not inherit name")
let moved = desktop(id: 1, uuid: "AAA", position: 3, display: "B")
check(store.customName(moved) == "music", "same UUID follows desktop across displays")

let reloaded = NameStore(url: url, bootID: "boot2")
let recycledID = desktop(id: 1, uuid: "BBB")
check(reloaded.customName(recycledID) == "game", "new boot recycled numeric ID cannot override UUID")
let temporary = desktop(id: 7, uuid: nil)
let temporary2 = desktop(id: 8, uuid: "")
try store.rename(temporary, to: "temporary")
check(store.customName(temporary2) == nil, "empty UUIDs do not share a name")
let newBoot = NameStore(url: url, bootID: "boot2")
check(newBoot.customName(temporary) == nil, "missing UUID name is not guessed after reboot")
check(NameStore(url: url, bootID: "boot1").customName(temporary) == "temporary", "missing UUID persists across app relaunch in same boot")
check(store.unmatchedCount([music, game]) == 1, "unmatched names retained and counted")

let anchoredURL = directory.appendingPathComponent("anchored.json")
let oldLayout = [desktop(id: 20, uuid: "LEFT", position: 5),
                 desktop(id: 1, uuid: nil, position: 6),
                 desktop(id: 21, uuid: "RIGHT", position: 7)]
let anchored = NameStore(url: anchoredURL, bootID: "old")
try anchored.rename(oldLayout[1], to: "Research", among: oldLayout)
let newLayout = [desktop(id: 30, uuid: "LEFT", position: 5, display: "B"),
                 desktop(id: 1, uuid: nil, position: 6, display: "B"),
                 desktop(id: 31, uuid: "RIGHT", position: 7, display: "B")]
let afterRestart = NameStore(url: anchoredURL, bootID: "new")
check(afterRestart.customName(newLayout[1]) == nil, "UUID-less name waits for verified neighbors")
try afterRestart.reconcile(newLayout)
check(afterRestart.customName(newLayout[1]) == "Research", "two stable neighbors restore UUID-less name across boot and display change")
check(NameStore(url: anchoredURL, bootID: "new").customName(newLayout[1]) == "Research", "restored name survives app relaunch")
check(afterRestart.unmatchedCount(newLayout) == 0, "restored record replaces old boot identity")

let uncertainURL = directory.appendingPathComponent("uncertain.json")
let beforeUncertain = NameStore(url: uncertainURL, bootID: "old")
try beforeUncertain.rename(oldLayout[1], to: "private", among: oldLayout)
let changedNeighbors = [newLayout[0], newLayout[1], desktop(id: 32, uuid: "OTHER", position: 7, display: "B")]
let uncertain = NameStore(url: uncertainURL, bootID: "new")
try uncertain.reconcile(changedNeighbors)
check(uncertain.customName(changedNeighbors[1]) == nil, "changed neighbor never receives old name")
check(uncertain.unmatchedCount(changedNeighbors) == 1, "uncertain name remains available for manual recovery")

let legacyURL = directory.appendingPathComponent("legacy.json")
let legacy = NameStore(url: legacyURL, bootID: "new")
try legacy.rename(newLayout[1], to: "existing")
try legacy.reconcile(newLayout)
check(NameStore(url: legacyURL, bootID: "new").data.records[newLayout[1].identity(bootID: "new")]?.neighbors != nil,
      "existing current-boot name gains neighbor anchors")
check(store.filtered([music, game], query: "GAME").first?.sessionID == 2, "case-insensitive search")
check(store.filtered([music, game], query: "usi").first?.sessionID == 1, "partial search")
try store.rename(music, to: "音乐")
check(store.filtered([music, game], query: "音乐").first?.sessionID == 1, "Chinese search")
try store.rename(game, to: "音乐")
check(store.filtered([music, game], query: "音乐").count == 2, "duplicate names retain both choices")
try store.rename(game, to: "  ")
check(store.customName(game) == nil, "empty name resets only selected desktop")
do { try store.rename(music, to: String(repeating: "x", count: 81)); fatalError("accepted long name") }
catch { check(store.customName(music) == "音乐", "invalid name leaves old value unchanged") }

let corruptURL = directory.appendingPathComponent("corrupt.json")
try Data("broken".utf8).write(to: corruptURL)
let corrupt = NameStore(url: corruptURL, bootID: "boot1")
check(corrupt.loadError != nil, "corrupt name file reported")
do { try corrupt.rename(music, to: "new"); fatalError("overwrote corrupt file") }
catch {
    let original = try String(contentsOf: corruptURL, encoding: .utf8)
    check(original == "broken", "corrupt original preserved")
}

let readOnly = NameStore(url: URL(fileURLWithPath: "/dev/null/names.json"), bootID: "boot1")
do { try readOnly.rename(music, to: "new"); fatalError("saved to impossible path") }
catch { check(readOnly.customName(music) == nil, "failed disk write never claims in-memory success") }
let compact = ButtonGeometry(frame: CGRect(x: 10, y: 0, width: 100, height: 28), title: nil)
let large = ButtonGeometry(frame: CGRect(x: 8, y: 12, width: 120, height: 100), title: nil)
var cache = OverlayLayoutCache()
cache.update(screenID: 1, orderedIDs: [1, 2], buttons: [compact, compact], now: 0)
cache.update(screenID: 1, orderedIDs: [1, 2], buttons: [compact, compact], now: 0.1)
check(cache.entries.count == 2, "initial identity mapping settles without depending on geometry")
var animationRetainedEveryFrame = true
for step in 1...100 {
    let moving = ButtonGeometry(frame: CGRect(x: 10 + step, y: 0, width: 100 + step, height: 28 + step), title: nil)
    cache.update(screenID: 1, orderedIDs: [1, 2], buttons: [moving, large], now: 0.1 + Double(step) * 0.1)
    animationRetainedEveryFrame = animationRetainedEveryFrame && cache.entries.count == 2
}
check(animationRetainedEveryFrame, "100 consecutive hover/expand frames retain both labels")
cache.update(screenID: 1, orderedIDs: [1, 2], buttons: [nil, large], now: 10.3)
check(cache.entries.count == 2, "one unreadable geometry does not hide its display")
cache.update(screenID: 1, orderedIDs: [1, 2], buttons: nil, now: 10.4)
check(cache.entries.count == 2, "brief missing group retains last verified positions")
cache.update(screenID: 2, orderedIDs: [3], buttons: [large], now: 10.4)
cache.update(screenID: 2, orderedIDs: [3], buttons: [large], now: 10.5)
cache.update(screenID: 1, orderedIDs: [2, 1], buttons: [large, compact], now: 10.5)
check(cache.entries[3] != nil && cache.entries[1] == nil, "reorder invalidates only affected display")
cache.update(screenID: 1, orderedIDs: [2, 1], buttons: [large, compact], now: 10.6)
check(cache.entries[2]?.geometry.frame == large.frame, "reordered identity takes its verified new position")
cache.expire(now: 11.6)
check(cache.entries.isEmpty, "persistent read failure never leaves permanent stale labels")
var timedCache = OverlayLayoutCache()
timedCache.update(screenID: 1, orderedIDs: [1, 2], buttons: [compact, compact], now: 1)
timedCache.update(screenID: 1, orderedIDs: [1, 2], buttons: [compact, compact], now: 1.01)
timedCache.update(screenID: 1, orderedIDs: [1, 2], buttons: [large, large],
                  sampledAt: [1.00, 1.15], now: 1.17)
check(timedCache.entries[1]?.geometry.frame == compact.frame && timedCache.entries[2]?.geometry.frame == large.frame,
      "a slow whole-tree read still keeps its fresh per-button position")
timedCache.update(screenID: 1, orderedIDs: [1, 2], buttons: [large, compact],
                  sampledAt: [1.18, 1.14], now: 1.20)
check(timedCache.entries[1]?.geometry.frame == large.frame && timedCache.entries[2]?.geometry.frame == large.frame,
      "an older button sample cannot move a label back")

var lifecycle = MissionVisibility()
lifecycle.active(now: 0)
check(lifecycle.missing(now: 0.1, readFailed: true), "AX timeout is not treated as Mission Control exit")
lifecycle.active(now: 0.2)
check(lifecycle.missing(now: 0.3, readFailed: false), "one temporarily absent tree does not flash labels off")
lifecycle.active(now: 0.4)
check(lifecycle.visible, "successful observation resumes without hiding")
lifecycle.exit()
check(!lifecycle.visible, "confirmed exit hides immediately")
lifecycle.active(now: 1)
_ = lifecycle.missing(now: 1.1, readFailed: false)
check(!lifecycle.missing(now: 1.3, readFailed: false), "missing exit notification has bounded fallback")
lifecycle.active(now: 2)
check(!lifecycle.missing(now: 3, readFailed: true), "long AX outage expires visibility")

var dismiss = OverlayDismissal()
var reveal = ThumbnailReveal()
reveal.observe(frames: [compact.frame], now: 0)
check(reveal.ready, "compact title row remains available before expanding")
reveal.observe(frames: [large.frame], now: 1)
check(!reveal.ready, "expanded AX geometry cannot reveal names ahead of opening animation")
reveal.observe(frames: [large.frame.offsetBy(dx: 20, dy: 0)], now: 1.05)
check(!reveal.ready, "moving opening frames stay hidden during initial reveal interval")
reveal.observe(frames: [large.frame.offsetBy(dx: 40, dy: 0)], now: 1.12)
check(reveal.ready, "opening completes even if pointer keeps moving horizontally")
reveal.observe(frames: [CGRect(x: 745.3, y: 46.8, width: 93.3, height: 52.5)], now: 1.3)
check(reveal.ready, "reverse hover on 16-space display does not restart reveal delay")
reveal.observe(frames: [compact.frame], now: 2)
reveal.observe(frames: [large.frame], now: 2.1)
check(reveal.ready, "an already revealed strip does not hide names on the next expansion")
reveal.observe(frames: [], now: 3)
check(reveal.ready, "failed geometry cannot reset an already revealed strip")
var secondReveal = ThumbnailReveal()
secondReveal.observe(frames: [large.frame], now: 5)
check(!secondReveal.ready, "another screen starts its own reveal timing")
var eventTimedReveal = ThumbnailReveal()
eventTimedReveal.observe(frames: [large.frame], now: 6.10, openingBeganAt: 6)
check(eventTimedReveal.ready, "late AX geometry does not add a second opening delay")
var earlyGeometryReveal = ThumbnailReveal()
earlyGeometryReveal.observe(frames: [large.frame], now: 7.02, openingBeganAt: 7)
check(!earlyGeometryReveal.ready, "early AX geometry still waits for the opening strip")
var click = ClickActivity()
let clickPoint = CGPoint(x: 800, y: 300)
check(click.observe(count: 100, pressed: false, point: clickPoint).clicked == nil, "click history before startup cannot dismiss labels")
check(click.observe(count: 101, pressed: false, point: clickPoint).clicked == clickPoint,
      "trackpad tap released between polling ticks is still detected")
check(click.observe(count: 101, pressed: false, point: clickPoint).clicked == nil, "one tap cannot repeatedly hide new labels")
check(click.observe(count: 101, pressed: true, point: clickPoint).began == clickPoint,
      "mouse-down is observable before release")
check(click.observe(count: 102, pressed: true, point: CGPoint(x: 820, y: 300)).startedDragging,
      "dragging is reported as soon as movement crosses threshold")
check(click.observe(count: 102, pressed: false, point: CGPoint(x: 850, y: 300)).clicked == nil,
      "releasing a dragged window does not count as a click")
check(click.observe(count: 103, pressed: true, point: clickPoint).clicked == nil, "stationary press waits for release")
check(click.observe(count: 103, pressed: false, point: clickPoint).clicked == clickPoint,
      "stationary release dismisses names before Mission Control exit")
check(click.observe(count: 0, pressed: false, point: clickPoint).clicked == nil, "counter reset is not mistaken for a click")
dismiss.begin(now: 10, duration: 0.65)
dismiss.begin(now: 10.1, duration: 0.25)
check(dismiss.isSuppressed(now: 10.5), "late Dock exit notification cannot shorten click dismissal protection")
check(!dismiss.isSuppressed(now: 10.7), "click that leaves Mission Control open can recover without permanent disappearance")
dismiss.begin(now: 11, duration: 0.65)
dismiss.reopen()
check(!dismiss.isSuppressed(now: 11.1), "explicit new Mission Control entry is not hidden by previous exit")
let stripFrames = [CGRect(x: 73, y: 47, width: 93, height: 52), CGRect(x: 746, y: 28, width: 160, height: 90)]
let clickScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
check(MissionExitIntent.isExitClick(point: CGPoint(x: 800, y: 240), screen: clickScreen, frames: stripFrames),
      "click below the enlarged thumbnail clears labels before collapse")
check(MissionExitIntent.isExitClick(point: CGPoint(x: 800, y: 100), screen: clickScreen, frames: stripFrames),
      "click inside enlarged thumbnail hides labels before desktop switch")
check(!MissionExitIntent.isExitClick(point: CGPoint(x: 800, y: 130), screen: clickScreen, frames: stripFrames),
      "click in strip gap does not hide labels")
check(!MissionExitIntent.isExitClick(point: CGPoint(x: 2200, y: 300), screen: clickScreen, frames: stripFrames),
      "click on another monitor cannot use this monitor's strip boundary")
check(!MissionExitIntent.isExitClick(point: CGPoint(x: 800, y: 300), screen: clickScreen, frames: []),
      "no exit guess without verified strip geometry")

// Recorded 16-space reverse-hover geometry: the entire row reflows in X,
// while the image centres remain on the same horizontal line.
var reverseHoverAligned = true
for rect in [CGRect(x: 743, y: 28, width: 160, height: 90),
             CGRect(x: 714.8, y: 34.3, width: 137.5, height: 77.3),
             CGRect(x: 745.4, y: 46.5, width: 94.2, height: 53),
             CGRect(x: 745.3, y: 46.8, width: 93.3, height: 52.5)] {
    let badge = BadgeLayout.frame(geometry: ButtonGeometry(frame: rect, title: nil), screen: clickScreen,
                                 preferredWidth: 70, position: .center)!
    reverseHoverAligned = reverseHoverAligned && abs(badge.midX - rect.midX) < 0.01
        && abs(badge.midY - 73) < 0.1 && badge.width == 70 && badge.height == 24
}
check(reverseHoverAligned, "recorded reverse hover keeps label centred and fixed-size throughout whole-row reflow")

let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
let expandedBadge = BadgeLayout.frame(geometry: large, screen: screen)!
check(large.frame.contains(expandedBadge), "expanded name remains inside its miniature")
let collapsedBadge = BadgeLayout.frame(geometry: compact, screen: screen)!
check(compact.frame.contains(collapsedBadge), "collapsed name stays inside title strip")
let negativeScreen = CGRect(x: -1600, y: -200, width: 1600, height: 1000)
let secondFrame = ButtonGeometry(frame: CGRect(x: -1550, y: -195, width: 120, height: 85), title: nil)
check(negativeScreen.contains(BadgeLayout.frame(geometry: secondFrame, screen: negativeScreen)!), "offset secondary display has bounded label")
check(expandedBadge.height <= 24 && expandedBadge.width <= 260, "label size has a hard upper bound")
var steadySize = true
for step in 0...100 {
    let hover = ButtonGeometry(frame: CGRect(x: 20 + Double(step) / 5, y: 12,
                                             width: 120 + Double(step), height: 90 + Double(step) / 2), title: nil)
    let badge = BadgeLayout.frame(geometry: hover, screen: screen, preferredWidth: 74)!
    steadySize = steadySize && badge.width == 74 && badge.height == 24 && hover.frame.contains(badge)
}
check(steadySize, "hover magnification keeps the name badge fixed-size and inside the thumbnail")
let beforeBoundary = BadgeLayout.frame(geometry: ButtonGeometry(frame: CGRect(x: 10, y: 0, width: 120, height: 59.9), title: nil), screen: screen)!
let afterBoundary = BadgeLayout.frame(geometry: ButtonGeometry(frame: CGRect(x: 10, y: 0, width: 120, height: 60.1), title: nil), screen: screen)!
check(abs(beforeBoundary.midY - afterBoundary.midY) < 0.3 && beforeBoundary.width == afterBoundary.width,
      "crossing the compact/expanded boundary does not jump position or size")
let clippedLongName = BadgeLayout.frame(geometry: large, screen: screen, preferredWidth: 700)!
check(large.frame.contains(clippedLongName) && clippedLongName.width <= 260, "long names stay bounded in small thumbnails")
var allAppearanceFramesContained = true
for position in BadgePosition.allCases {
    for size in 11...20 {
        let rect = BadgeLayout.frame(geometry: large, screen: screen, position: position, preferredHeight: CGFloat(size + 12))!
        allAppearanceFramesContained = allAppearanceFramesContained && large.frame.contains(rect)
    }
}
check(allAppearanceFramesContained, "all appearance positions and sizes remain inside expanded thumbnail")
let top = BadgeLayout.frame(geometry: large, screen: screen, position: .top)!
let center = BadgeLayout.frame(geometry: large, screen: screen, position: .center)!
check(top.midY < center.midY && center.midY < expandedBadge.midY, "top center and bottom follow screen coordinates")
let suite = "renamer-appearance-test-" + UUID().uuidString
let settings = UserDefaults(suiteName: suite)!
defer { settings.removePersistentDomain(forName: suite) }
check(SearchPreference.load(from: settings), "desktop search stays enabled for existing users")
SearchPreference.save(false, to: settings)
check(!SearchPreference.load(from: settings), "disabled desktop search survives reload")
SearchPreference.save(true, to: settings)
check(SearchPreference.load(from: settings), "desktop search can be enabled again")
check(AppLanguage.load(from: settings) == .chinese, "existing installations keep Chinese by default")
AppLanguage.english.save(to: settings)
check(AppLanguage.load(from: settings) == .english, "English language choice survives reload")
settings.set("unsupported", forKey: AppLanguage.defaultsKey)
check(AppLanguage.load(from: settings) == .chinese, "invalid language preference has a supported fallback")
let namedForLocale = desktop(id: 77, uuid: "LANGUAGE", position: 8)
try store.rename(namedForLocale, to: "音乐 Music")
let namesBeforeLanguageChange = try Data(contentsOf: url)
AppLanguage.current = .english
check(L("搜索桌面") == "Search Desktops", "English static interface text is translated")
check(store.name(replacement) == "Desktop 1", "unnamed desktop follows the selected language")
check(store.name(namedForLocale) == "音乐 Music", "user-defined names are never translated")
check(store.filtered([replacement], query: "desktop").count == 1, "search matches localized default desktop names")
check(L("%@ · 桌面 %d", "Display", 16) == "Display · Desktop 16", "translated dynamic strings preserve argument order and values")
check(L("未能确认切换到 %@。请稍后重试。", "Music").hasPrefix(L("未能确认切换")), "English switch errors remain visible in the desktop menu")
let namesAfterLanguageChange = try Data(contentsOf: url)
check(namesAfterLanguageChange == namesBeforeLanguageChange, "language switching does not rewrite saved names")
AppLanguage.current = .chinese
check(store.name(replacement) == "桌面 1", "switching back to Chinese restores default labels")
let placeholdersMatch = Localization.english.allSatisfy { key, value in
    func placeholders(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%[@d]")
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range, in: text)!])
        }
    }
    return placeholders(key) == placeholders(value)
}
check(placeholdersMatch, "all translations preserve format argument types and ordering")
for choice in 0..<3 {
    settings.set(choice, forKey: "hotKeyChoice")
    check(SearchShortcut.load(from: settings) == SearchShortcut.legacy[choice], "legacy shortcut \(choice) migrates without changing keys")
}
let customShortcut = SearchShortcut(keyCode: 16, modifiers: SearchShortcut.command | SearchShortcut.shift, keyName: "Y")
customShortcut.save(to: settings)
check(SearchShortcut.load(from: settings) == customShortcut, "custom shortcut survives reload and overrides legacy choice")
SearchPreference.save(false, to: settings)
check(SearchShortcut.load(from: settings) == customShortcut, "turning search off preserves the chosen shortcut")
SearchPreference.save(true, to: settings)
check(customShortcut.label == "⇧⌘Y", "recorded shortcut displays conventional modifier order")
check(!SearchShortcut(keyCode: 0, modifiers: 0, keyName: "A").isValid, "plain typing key cannot become a global shortcut")
check(!SearchShortcut(keyCode: 0, modifiers: SearchShortcut.shift, keyName: "A").isValid, "Shift-only typing is preserved")
check(SearchShortcut(keyCode: 111, modifiers: 0, keyName: "F12").isValid, "function key can be assigned without modifiers")
check(!SearchShortcut(keyCode: 55, modifiers: SearchShortcut.command, keyName: "Command").isValid, "modifier by itself cannot be registered")
SearchShortcut(keyCode: 0, modifiers: 0, keyName: "A").save(to: settings)
check(SearchShortcut.load(from: settings) == customShortcut, "invalid input cannot overwrite the saved shortcut")
settings.set(Data("broken".utf8), forKey: SearchShortcut.defaultsKey)
check(SearchShortcut.load(from: settings) == SearchShortcut.legacy[2], "damaged shortcut settings fall back to previous valid legacy choice")
var chosen = BadgeAppearance(red: 0.9, green: 0.7, blue: 0.2, fontSize: 19, position: .center)
chosen.save(to: settings)
check(BadgeAppearance.load(from: settings) == chosen, "appearance survives reload without affecting names")
settings.set(Data("broken".utf8), forKey: BadgeAppearance.defaultsKey)
check(BadgeAppearance.load(from: settings) == BadgeAppearance(), "corrupt appearance falls back to visible defaults")
chosen.fontSize = 900
chosen.red = -2
chosen.save(to: settings)
check(BadgeAppearance.load(from: settings).fontSize == 20 && BadgeAppearance.load(from: settings).red == 0, "invalid appearance cannot create giant labels")
check(BadgeAppearance(red: 1, green: 1, blue: 1).usesDarkText && !BadgeAppearance(red: 0, green: 0, blue: 0).usesDarkText,
      "text contrast adapts to light and dark backgrounds")

let legacyAppearance = Data("{\"red\":0.05,\"green\":0.49,\"blue\":0.67,\"fontSize\":14,\"position\":\"center\"}".utf8)
settings.set(legacyAppearance, forKey: BadgeAppearance.defaultsKey)
let migrated = BadgeAppearance.load(from: settings)
check(migrated.red == 0.05 && migrated.position == .center && migrated.foreground == nil, "legacy thumbnail appearance keeps its color and automatic text")
var thumbnail = migrated
thumbnail.foreground = BadgeColor(red: 0.8, green: 0.2, blue: 0.1)
thumbnail.save(to: settings)
var currentStyle = CurrentBadgeAppearance()
currentStyle.fontSize = 48
currentStyle.foreground = .black
currentStyle.background = .white
currentStyle.horizontal = 0.2
currentStyle.vertical = 0.7
currentStyle.save(to: settings)
check(CurrentBadgeAppearance.load(from: settings) == currentStyle, "independent current label settings persist")
check(BadgeAppearance.load(from: settings) == thumbnail, "current label edits do not overwrite thumbnail colors")
check(BadgeAppearance.load(from: settings).foreground == thumbnail.foreground, "custom thumbnail text color persists")
settings.set(Data("bad".utf8), forKey: CurrentBadgeAppearance.defaultsKey)
check(CurrentBadgeAppearance.load(from: settings) == CurrentBadgeAppearance(), "damaged current settings fall back independently")
var invalidCurrent = CurrentBadgeAppearance()
invalidCurrent.fontSize = .infinity
invalidCurrent.horizontal = -3
invalidCurrent.vertical = 4
invalidCurrent.background.red = .nan
check(invalidCurrent.normalized.fontSize == 28 && invalidCurrent.normalized.horizontal == 0 && invalidCurrent.normalized.vertical == 1 && invalidCurrent.normalized.background.red == 0, "invalid current label dimensions and colors are bounded")
var currentFramesValid = true
for display in [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: -1440, y: -900, width: 1440, height: 900)] {
    for size in [16.0, 28, 64] {
        for x in [0.0, 0.5, 1] {
            for y in [0.0, 0.96, 1] {
                var style = CurrentBadgeAppearance()
                style.fontSize = size; style.horizontal = x; style.vertical = y
                let rect = CurrentBadgeLayout.frame(screen: display, stripBottom: display.minY + 180, preferredWidth: 2000, appearance: style)!
                currentFramesValid = currentFramesValid && display.contains(rect) && rect.minY >= display.minY + 208 && rect.width <= 680 && rect.height <= 96
            }
        }
    }
}
check(currentFramesValid, "current label stays below thumbnails and inside both screen coordinate systems at all sizes and positions")
check(CurrentBadgeLayout.frame(screen: CGRect(x: 0, y: 0, width: 100, height: 150), stripBottom: 140, preferredWidth: 80, appearance: CurrentBadgeAppearance()) == nil, "no current label is drawn when the remaining region is too small")

var switchGate = SwitchReadiness()
check(!switchGate.observe("A", now: 0), "no switch readiness without an explicit request")
switchGate.begin(now: 10)
check(!switchGate.observe("A", now: 10.01), "first geometry sample cannot click a desktop")
check(!switchGate.observe("A", now: 10.03), "two matching early frames do not bypass opening animation")
check(!switchGate.observe("A", now: 10.4), "stable early geometry still waits for opening to settle")
check(switchGate.observe("A", now: 10.56), "settled opening and stable geometry permit a single action")
check(!switchGate.observe("B", now: 10.57), "moving thumbnail invalidates switch readiness")
check(!switchGate.observe("B", now: 10.65), "changed geometry needs sustained stability")
check(switchGate.observe("B", now: 10.71), "settled changed geometry becomes ready")
switchGate.invalidateGeometry()
check(!switchGate.observe("B", now: 11), "missing or exited Mission Control invalidates stale geometry")
switchGate.begin(now: 12)
check(!switchGate.observe("B", now: 12.02), "new request cannot reuse the previous settling interval")
switchGate.reset()
check(!switchGate.observe("B", now: 20), "finished or failed switch cannot trigger a later action")


func switchSpace(_ id: UInt64, _ position: Int, current: Bool = false, screen: UInt32 = 1, ordinary: Bool = true) -> Desktop {
    Desktop(sessionID: id, persistentID: "space-\(id)", displayID: "screen-\(screen)", screenID: screen,
            screenName: "screen", position: position, isCurrent: current, isOrdinary: ordinary)
}
let fastSpaces = [switchSpace(11, 1), switchSpace(12, 2, current: true), switchSpace(13, 3, ordinary: false), switchSpace(14, 4), switchSpace(21, 1, current: true, screen: 2)]
check(DirectSwitchPlan.steps(target: fastSpaces[0], live: fastSpaces) == -1, "direct switch computes leftward steps")
check(DirectSwitchPlan.steps(target: fastSpaces[3], live: fastSpaces) == 2, "direct switch includes intermediate fullscreen Spaces")
check(DirectSwitchPlan.steps(target: fastSpaces[1], live: fastSpaces) == 0, "direct switch does nothing for current Space")
check(DirectSwitchPlan.steps(target: fastSpaces[4], live: fastSpaces) == 0, "direct switch uses the target display current Space")
check(DirectSwitchPlan.steps(target: fastSpaces[3], live: Array(fastSpaces.reversed())) == 2, "direct switch uses desktop order rather than input array order")
check(DirectSwitchPlan.steps(target: switchSpace(99, 4), live: fastSpaces) == nil, "direct switch rejects a removed target")
check(DirectSwitchPlan.steps(target: fastSpaces[3], live: fastSpaces.filter { !$0.isCurrent }) == nil, "direct switch rejects missing current Space")
check(DirectSwitchPlan.steps(target: fastSpaces[3], live: fastSpaces + [switchSpace(15, 5, current: true)]) == nil, "direct switch rejects ambiguous current Space")

print("\(passed) checks passed")
