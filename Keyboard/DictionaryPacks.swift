import Foundation

// MARK: - 辞書パック
//
// 工業・アニメ・推し活などの専門辞書。データは種リスト
// (docs/*-dictionary-seed.md) から scripts/build_dictionary_packs.py で生成した
// TSV (読み<TAB>表記) を拡張に同梱する。
//
// 設計 (ユーザーとの合意事項):
// - 辞書ごとに設定で ON/OFF でき、OFF の辞書はデータ自体を読み込まない。
// - 有効な辞書も初回利用時に遅延ロードする (起動経路に載せない)。
// - パックの候補は通常辞書より低優先 (候補列の末尾) で、変換学習の対象にしない。
// - 有効状態は定型文と同じく拡張自身の UserDefaults に持つ (App Group は使わない)。

enum DictionaryPackID: String, CaseIterable {
    case industrial
    case sns
    case anime
    case oshikatsuCommon
    case oshikatsuMale
    case oshikatsuFemale

    var displayName: String {
        switch self {
        case .industrial: return "工業"
        case .sns: return "SNS"
        case .anime: return "アニメ"
        case .oshikatsuCommon: return "推し活・共通"
        case .oshikatsuMale: return "推し活・男性"
        case .oshikatsuFemale: return "推し活・女性"
        }
    }

    var resourceName: String {
        switch self {
        case .industrial: return "dictionary_industrial"
        case .sns: return "dictionary_sns"
        case .anime: return "dictionary_anime"
        case .oshikatsuCommon: return "dictionary_oshikatsu_common"
        case .oshikatsuMale: return "dictionary_oshikatsu_male"
        case .oshikatsuFemale: return "dictionary_oshikatsu_female"
        }
    }

    /// 初期状態で有効なのは、本人の日常用途である工業と、全員が日常的に使う SNS。
    var defaultEnabled: Bool { self == .industrial || self == .sns }
}

struct DictionaryPackData {
    /// かな読み → 表記 (登録順を保持)。
    private(set) var byReading: [String: [String]] = [:]
    /// 英数字パターン (そのまま型)。入力は小文字化して保持する。
    private(set) var patterns: [(input: String, surface: String)] = []

    static func parse(_ data: Data) -> DictionaryPackData {
        guard let text = String(data: data, encoding: .utf8) else { return DictionaryPackData() }
        var result = DictionaryPackData()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let reading = String(parts[0])
            let surface = String(parts[1])
            guard !reading.isEmpty, !surface.isEmpty else { continue }
            if reading.allSatisfy({ $0.isASCII }) {
                let key = reading.lowercased()
                if !result.patterns.contains(where: { $0.input == key && $0.surface == surface }) {
                    result.patterns.append((input: key, surface: surface))
                }
            } else {
                if result.byReading[reading] == nil { result.byReading[reading] = [] }
                if result.byReading[reading]?.contains(surface) != true {
                    result.byReading[reading]?.append(surface)
                }
            }
        }
        return result
    }

    static func loadBundled(_ id: DictionaryPackID) -> DictionaryPackData {
        guard let url = Bundle(for: DictionaryBundleAnchor.self).url(forResource: id.resourceName, withExtension: "tsv"),
              let data = try? Data(contentsOf: url) else { return DictionaryPackData() }
        return parse(data)
    }

    func surfaces(forKana kana: String) -> [String] { byReading[kana] ?? [] }

    /// 英字入力へのパターン補完。前方一致する表記を登録順に返す。
    /// 入力済みの文字列そのもの (大文字小文字まで一致) は返さない。
    func patternCompletions(forTyped typed: String) -> [String] {
        let key = typed.lowercased()
        guard key.count >= 2 else { return [] }
        var result: [String] = []
        for pattern in patterns where pattern.input.hasPrefix(key) && pattern.surface != typed {
            if !result.contains(pattern.surface) { result.append(pattern.surface) }
        }
        return result
    }
}

private final class DictionaryBundleAnchor {}

// MARK: - 有効状態の保存

final class DictionaryPackStore {
    // v2: SNS パックを標準 ON で追加したため、保存済み設定がある端末にも
    // 初期状態を一度だけ再適用する (キーを上げると旧設定は読まれなくなる)。
    private static let storageKey = "dictionaryPacks.enabled.v2"
    private let defaults: UserDefaults
    private var enabled: Set<DictionaryPackID>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.stringArray(forKey: Self.storageKey) {
            enabled = Set(raw.compactMap(DictionaryPackID.init(rawValue:)))
        } else {
            enabled = Set(DictionaryPackID.allCases.filter { $0.defaultEnabled })
        }
    }

    func isEnabled(_ id: DictionaryPackID) -> Bool { enabled.contains(id) }

    func setEnabled(_ id: DictionaryPackID, _ value: Bool) {
        if value { enabled.insert(id) } else { enabled.remove(id) }
        defaults.set(enabled.map { $0.rawValue }.sorted(), forKey: Self.storageKey)
    }
}

// MARK: - 遅延ロードと候補の収集

final class DictionaryPackLibrary {
    private var cache: [DictionaryPackID: DictionaryPackData] = [:]
    private let loader: (DictionaryPackID) -> DictionaryPackData

    init(loader: @escaping (DictionaryPackID) -> DictionaryPackData = { DictionaryPackData.loadBundled($0) }) {
        self.loader = loader
    }

    /// 有効なパックだけを、初回利用時に読み込む。OFF のパックには触れない。
    func data(for id: DictionaryPackID) -> DictionaryPackData {
        if let cached = cache[id] { return cached }
        let loaded = loader(id)
        cache[id] = loaded
        return loaded
    }

    /// 有効な全パックから、かな読みに完全一致する表記をパック順に集める。
    func surfaces(forKana kana: String, store: DictionaryPackStore) -> [String] {
        guard !kana.isEmpty else { return [] }
        var result: [String] = []
        for id in DictionaryPackID.allCases where store.isEnabled(id) {
            for surface in data(for: id).surfaces(forKana: kana) where !result.contains(surface) {
                result.append(surface)
            }
        }
        return result
    }

    /// 有効な全パックから、英字入力へのパターン補完をパック順に集める。
    func patternCompletions(forTyped typed: String, store: DictionaryPackStore) -> [String] {
        var result: [String] = []
        for id in DictionaryPackID.allCases where store.isEnabled(id) {
            for surface in data(for: id).patternCompletions(forTyped: typed) where !result.contains(surface) {
                result.append(surface)
            }
        }
        return result
    }
}
