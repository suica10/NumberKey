import Foundation

struct LayoutSettings: Codable, Equatable {
    var version = 1
    var rows = [Array("1234567890").map(String.init), Array("qwertyuiop").map(String.init),
                Array("asdfghjkl").map(String.init), Array("zxcvbnm").map(String.init)]
    var keyHeight: Double = 0
    var theme = 2
    var japanese = true
    static let defaults = LayoutSettings()
    static let prefix = "NUMBERKEY_LAYOUT_V1:"
    var isValid: Bool {
        version == 1 && rows.map(\.count) == [10, 10, 9, 7]
        && rows.joined().allSatisfy { $0.count == 1 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
        && keyHeight.isFinite && (keyHeight == 0 || (32...60).contains(keyHeight))
        && (0...2).contains(theme)
    }
    func exportString() -> String {
        Self.prefix + ((try? JSONEncoder().encode(self)) ?? Data()).base64EncodedString()
    }
    static func decode(_ text: String) -> LayoutSettings? {
        guard text.count < 16_384, text.hasPrefix(prefix),
              let data = Data(base64Encoded: String(text.dropFirst(prefix.count))),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return nil }
        return value
    }
}

struct KeyboardSettings {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var snapshot: LayoutSettings {
        get {
            if let data = defaults.data(forKey: "layout.v1"),
               let value = try? JSONDecoder().decode(LayoutSettings.self, from: data), value.isValid { return value }
            var value = LayoutSettings.defaults
            if let keys = defaults.stringArray(forKey: "topKeys"), keys.count == 10, keys.allSatisfy({ $0.count == 1 }) { value.rows[0] = keys }
            if defaults.object(forKey: "theme") != nil { value.theme = min(2, max(0, defaults.integer(forKey: "theme"))) }
            return value
        }
        nonmutating set {
            guard newValue.isValid, let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: "layout.v1")
        }
    }
    var japanese: Bool {
        get { defaults.object(forKey: "japanese") as? Bool ?? snapshot.japanese }
        nonmutating set { defaults.set(newValue, forKey: "japanese") }
    }
    func apply(_ value: LayoutSettings) { snapshot = value; japanese = value.japanese }
}
