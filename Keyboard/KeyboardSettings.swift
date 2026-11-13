import Foundation

func japaneseFullWidth(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
        switch scalar.value {
        case 0x21...0x7E: UnicodeScalar(scalar.value + 0xFEE0)!
        case 0x00A5: UnicodeScalar(0xFFE5)!
        default: scalar
        }
    }))
}

struct LayoutSettings: Codable, Equatable {
    var version = 1
    var rows: [[String]] = ["1234567890", "qwertyuiop", "asdfghjkl-", "zxcvbnm"].map { line in
        line.map { character in String(character) }
    }
    var keyHeight: Double = 0
    var theme = 2
    var japanese = true
    // 定型文はこの共有設定には含めない。キーボード拡張自身の PhraseStore が持ち、
    // App Group の署名状態に左右されないようにするため（旧データの phrases キーは
    // デコード時に無視される。移行は PhraseStore の legacyPhrases が担う）。

    static let defaults = LayoutSettings()
    static let prefix = "NUMBERKEY_LAYOUT_V1:"

    private enum CodingKeys: String, CodingKey { case version, rows, keyHeight, theme, japanese }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        rows = try values.decodeIfPresent([[String]].self, forKey: .rows) ?? LayoutSettings.defaults.rows
        keyHeight = try values.decodeIfPresent(Double.self, forKey: .keyHeight) ?? 0
        theme = try values.decodeIfPresent(Int.self, forKey: .theme) ?? 2
        japanese = try values.decodeIfPresent(Bool.self, forKey: .japanese) ?? true
    }

    var isValid: Bool {
        version == 1 && (rows.map { $0.count } == [10, 10, 10, 7] || rows.map { $0.count } == [10, 10, 9, 7])
        && rows.joined().allSatisfy { $0.count == 1 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
        && Set(rows.joined()).count == rows.reduce(0) { $0 + $1.count }
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
    static let appGroupIdentifier = "group.jp.suica10.NumberKey"
    static var sharedContainerAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) != nil
    }
    let defaults: UserDefaults
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.appGroupIdentifier) ?? .standard
    }

    static func migrateLegacyAppPreferences() {
        guard let shared = UserDefaults(suiteName: appGroupIdentifier),
              !shared.bool(forKey: "layout.v1.migratedFromApp") else { return }
        let legacy = UserDefaults.standard
        for key in ["layout.v1", "japanese", "topKeys", "theme"] {
            if let value = legacy.object(forKey: key) { shared.set(value, forKey: key) }
        }
        shared.set(true, forKey: "layout.v1.migratedFromApp")
    }

    static func migrateLegacyExtensionPreferences() {
        guard let shared = UserDefaults(suiteName: appGroupIdentifier) else { return }
        let legacy = UserDefaults.standard
        for key in ["layout.v1", "japanese", "topKeys", "theme"] {
            if shared.object(forKey: key) == nil, let value = legacy.object(forKey: key) {
                shared.set(value, forKey: key)
            }
        }
    }
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
