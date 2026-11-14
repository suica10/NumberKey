import Foundation

/// 一時的な実機診断 (build 51): キーボードの高さ交渉の検証用トレース。
/// ビルド47の診断で、ルートビューの実フレーム高さ (226) が高さ制約
/// (261/295) と乖離する場面が記録された。ホストが要求高さを与えず
/// システム既定に固定している疑いがあるため、viewDidLayoutSubviews の
/// 高さ関係の値だけを署名変化時に記録する。1イベントは短文のみ
/// (200文字以内) とし、祖先ダンプのような長文は出さない。
/// App Group の diag-probe.csv に `timestamp,event,detail` で書き出す。
/// 検証が終わったら KeyboardViewController の記録呼び出し・ホスト
/// アプリの診断セクションと一緒に削除すること。
final class DiagTrace {
    static let shared = DiagTrace()
    static let csvFileName = "diag-probe.csv"
    private static let maxEntries = 200

    private struct Entry {
        let date: Date
        let event: String
        let detail: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var persistScheduled = false
    private let persistQueue = DispatchQueue(label: "jp.onejpkey.NumberKey.DiagTrace")

    private init() {}

    func record(event: String, detail: String) {
        lock.lock()
        entries.append(Entry(date: Date(), event: event, detail: detail))
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        lock.unlock()
        schedulePersist()
    }

    // MARK: - 書き出し (短いデバウンスでまとめて書く)

    private func schedulePersist() {
        lock.lock()
        if persistScheduled { lock.unlock(); return }
        persistScheduled = true
        lock.unlock()
        persistQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.persistNow()
        }
    }

    private func persistNow() {
        lock.lock()
        persistScheduled = false
        let snapshot = entries
        lock.unlock()
        guard let dir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: KeyboardSettings.appGroupIdentifier) else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = ["timestamp,event,detail"]
        for entry in snapshot {
            lines.append("\(formatter.string(from: entry.date)),\(entry.event),\(entry.detail)")
        }
        let csv = lines.joined(separator: "\n") + "\n"
        try? csv.write(to: dir.appendingPathComponent(Self.csvFileName),
                       atomically: true, encoding: .utf8)
    }
}
