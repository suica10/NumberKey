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

/// 全角→半角 (japaneseFullWidth の逆)。対象外の文字は nil。
func halfWidthForm(_ text: String) -> String? {
    guard text.count == 1, let scalar = text.unicodeScalars.first else { return nil }
    switch scalar.value {
    case 0xFF01...0xFF5E: return String(UnicodeScalar(scalar.value - 0xFEE0)!)
    case 0xFFE5: return "¥"
    default: return nil
    }
}

struct LayoutSettings: Codable, Equatable {
    var version = 1
    /// キー配列は固定 (入れ替え機能は 0.3.27 で廃止)。旧設定に残る rows は
    /// デコード時に無視される。
    static let standardRows: [[String]] = ["1234567890", "qwertyuiop", "asdfghjkl-", "zxcvbnm"].map { line in
        line.map { character in String(character) }
    }
    var keyHeight: Double = 0
    var theme = 2
    var japanese = true
    /// フリックモード (日本語入力を純正準拠のフリック配列にする)。false は
    /// 従来の QWERTY。英数に切り替えた場合は flickMode でも QWERTY 面を使う。
    var flickMode = false
    /// 着せ替えのマスター ON/OFF (2026-11-26 確定仕様)。デフォルト OFF で、
    /// OFF の間は背景画像・個別色のどちらも適用されず、従来どおり theme
    /// (システムのライト/ダーク追従) だけで描画する。
    var customizationEnabled = false
    /// 着せ替えの内容 (要素ごとの個別色＋背景画像まわり)。customizationEnabled
    /// が ON のときだけ効く。定義は KeyboardAppearance.swift。
    var customAppearance = CustomAppearance()
    // 定型文はこの共有設定には含めない。キーボード拡張自身の PhraseStore が持ち、
    // App Group の署名状態に左右されないようにするため（旧データの phrases キーは
    // デコード時に無視される。移行は PhraseStore の legacyPhrases が担う）。

    static let defaults = LayoutSettings()
    static let prefix = "NUMBERKEY_LAYOUT_V1:"

    private enum CodingKeys: String, CodingKey { case version, keyHeight, theme, japanese, flickMode, customizationEnabled, customAppearance }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        keyHeight = try values.decodeIfPresent(Double.self, forKey: .keyHeight) ?? 0
        theme = try values.decodeIfPresent(Int.self, forKey: .theme) ?? 2
        japanese = try values.decodeIfPresent(Bool.self, forKey: .japanese) ?? true
        flickMode = try values.decodeIfPresent(Bool.self, forKey: .flickMode) ?? false
        customizationEnabled = try values.decodeIfPresent(Bool.self, forKey: .customizationEnabled) ?? false
        customAppearance = try values.decodeIfPresent(CustomAppearance.self, forKey: .customAppearance) ?? CustomAppearance()
    }

    var isValid: Bool {
        version == 1
        && keyHeight.isFinite && (keyHeight == 0 || (32...60).contains(keyHeight))
        && (0...2).contains(theme)
        && customAppearance.isValid
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
    static let appGroupIdentifier = "group.jp.onejpkey.NumberKey"
    /// キーボードが最後に開かれた時刻（本体アプリのセットアップガイドが
    /// 「設定できたか」の判定に使う。書けるのはフルアクセス時だけなので、
    /// 値があること自体がフルアクセス許可済みの証拠になる）。
    static let lastActivatedKey = "keyboard.lastActivatedAt.v1"
    static func recordActivation() {
        UserDefaults(suiteName: appGroupIdentifier)?
            .set(Date().timeIntervalSince1970, forKey: lastActivatedKey)
    }
    static var lastActivatedAt: Date? {
        guard let t = UserDefaults(suiteName: appGroupIdentifier)?
            .object(forKey: lastActivatedKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: t)
    }
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
        for key in ["layout.v1", "japanese", "theme"] {
            if let value = legacy.object(forKey: key) { shared.set(value, forKey: key) }
        }
        shared.set(true, forKey: "layout.v1.migratedFromApp")
    }

    static func migrateLegacyExtensionPreferences() {
        guard let shared = UserDefaults(suiteName: appGroupIdentifier) else { return }
        let legacy = UserDefaults.standard
        for key in ["layout.v1", "japanese", "theme"] {
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
