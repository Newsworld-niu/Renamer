import Foundation

enum SearchPreference {
    static let defaultsKey = "searchEnabled.v1"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}

struct SearchShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyName: String

    static let command: UInt32 = 256
    static let shift: UInt32 = 512
    static let option: UInt32 = 2048
    static let control: UInt32 = 4096
    static let modifierMask = command | shift | option | control
    static let defaultsKey = "searchShortcut.v1"
    static let functionKeys: [UInt32: String] = [122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
    static let legacy = [Self(keyCode: 49, modifiers: control | shift, keyName: "Space"),
                         Self(keyCode: 49, modifiers: option | shift, keyName: "Space"),
                         Self(keyCode: 15, modifiers: control | option, keyName: "R")]
    var isValid: Bool {
        keyCode <= 127 && ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode)
            && modifiers & ~Self.modifierMask == 0
            && (modifiers & (Self.command | Self.option | Self.control) != 0 || Self.functionKeys[keyCode] != nil)
            && !keyName.isEmpty
    }
    var label: String {
        Self.modifierLabel(modifiers) + keyName
    }
    static func modifierLabel(_ modifiers: UInt32) -> String {
        [(Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined()
    }
    static func load(from defaults: UserDefaults = .standard) -> Self {
        if let data = defaults.data(forKey: defaultsKey), let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid { return value }
        let choice = defaults.integer(forKey: "hotKeyChoice")
        return legacy[legacy.indices.contains(choice) ? choice : 0]
    }
    func save(to defaults: UserDefaults = .standard) {
        guard isValid, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
