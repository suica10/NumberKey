import Foundation

// MARK: - PhraseBook
//
// 定型文はキーボード拡張自身の領域に保存する。
//
// 以前の実装は本体アプリと拡張で App Group の共有 UserDefaults を使っていたため、
// 再署名で App Group を含むプロファイルが外れると、本体で編集した定型文が
// キーボードへ届かなくなり、しかも双方が黙って各自の .standard へフォールバックして
// 食い違うのが見えなかった。
// 定型文の登録・編集をキーボード内で完結させ、拡張自身の UserDefaults.standard に
// 保存すれば、署名方法に依存する共有経路がそもそも存在しない。再署名しても壊れない。

struct PhraseBook: Codable, Equatable {
    var phrases: [String] = []

    static let maxCount = 20
    static let maxLength = 100

    static func isValidPhrase(_ text: String) -> Bool {
        !text.isEmpty
            && text.count <= maxLength
            && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    /// 保存前に通す正規化。空文字と不正な文字列を落とし、上限件数で切る。
    var sanitized: PhraseBook {
        PhraseBook(phrases: Array(phrases.filter(Self.isValidPhrase).prefix(Self.maxCount)))
    }
}

// MARK: - TextBuffer
//
// 定型文の入力先になるテキストバッファの中核（UIKit非依存）。
// 変換中の未確定文字列（marked）と確定済み文字列を分けて持ち、
// BufferDocument が KeyboardDocument プロトコルへ橋渡しする。

struct TextBuffer: Equatable {
    private(set) var committed = ""
    private(set) var marked = ""

    /// 画面表示用（確定済み＋未確定）。
    var displayText: String { committed + marked }
    var isEmpty: Bool { committed.isEmpty && marked.isEmpty }

    mutating func setMarked(_ text: String) { marked = text }

    /// 未確定文字列を確定側へ畳む（unmarkText の意味）。
    mutating func unmark() {
        committed += marked
        marked = ""
    }

    mutating func insert(_ text: String) {
        if !marked.isEmpty { unmark() }
        committed += text
    }

    mutating func deleteBackward() {
        if !marked.isEmpty { marked.removeLast() }
        else if !committed.isEmpty { committed.removeLast() }
    }

    /// 保存用に未確定を畳んだ最終文字列。
    func finalText() -> String { committed + marked }
}

// MARK: - PhraseStore

final class PhraseStore {
    static let storageKey = "phrases.v2"
    private static let legacyImportedKey = "phrases.v2.legacyImported"
    /// 初回起動時のサンプル（旧実装のデフォルトと同じ）。
    static let seedPhrases = [
        "よろしくお願いします。",
        "ありがとうございます。",
        "お世話になっております。",
        "確認しました。",
        "後ほどご連絡します。"
    ]

    private let defaults: UserDefaults
    private(set) var book: PhraseBook

    /// - Parameters:
    ///   - defaults: 拡張自身の保存領域。呼び出し側は必ず `.standard`（拡張自身の
    ///     コンテナ）を渡すこと。App Group の suite は使わない。
    ///   - legacyPhrases: 旧実装（共有 LayoutSettings）からの移行用に、旧定型文を
    ///     一度だけ読み出すクロージャ。読めなければ nil を返してよい（その場合は
    ///     サンプルで初期化する。全削除済みの場合は空の配列が返るので尊重される）。
    init(defaults: UserDefaults = .standard, legacyPhrases: () -> [String]? = { nil }) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(PhraseBook.self, from: data) {
            book = decoded.sanitized
        } else {
            book = PhraseBook()
            if !defaults.bool(forKey: Self.legacyImportedKey) {
                book = legacyPhrases().map { PhraseBook(phrases: $0).sanitized }
                    ?? PhraseBook(phrases: Self.seedPhrases)
                persist()
                defaults.set(true, forKey: Self.legacyImportedKey)
            }
        }
    }

    var phrases: [String] { book.phrases }

    func reload() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(PhraseBook.self, from: data) else { return }
        book = decoded.sanitized
    }

    @discardableResult
    func add(_ text: String) -> Bool {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PhraseBook.isValidPhrase(candidate), book.phrases.count < PhraseBook.maxCount else { return false }
        book.phrases.append(candidate)
        persist()
        return true
    }

    @discardableResult
    func update(at index: Int, _ text: String) -> Bool {
        guard book.phrases.indices.contains(index) else { return false }
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PhraseBook.isValidPhrase(candidate) else { return false }
        book.phrases[index] = candidate
        persist()
        return true
    }

    func remove(at index: Int) {
        guard book.phrases.indices.contains(index) else { return }
        book.phrases.remove(at: index)
        persist()
    }

    private func persist() {
        book = book.sanitized
        if let data = try? JSONEncoder().encode(book) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
