import Foundation

/// 一時的な実機診断 (DiagProbe の続き): ライブ変換パスのトレース。
/// ビルド 42 のプローブで変換器・辞書・リランクは正常と確定したのに、
/// 打鍵時の候補欄は空のまま。プローブは世代管理を通らない別経路だったため、
/// 今度は本番経路 (VC の scheduleConversion → ConversionService.candidates →
/// 候補欄の再描画) の各段で何が起きたかを記録する。
/// actor (ConversionService) と MainActor (VC) の両方から呼ばれるので
/// ロックで保護したリングバッファに貯め、App Group へ
/// diag-probe.txt (表示用) と diag-probe.csv (共有用) の2形式で書き出す。
/// txt の前半は DiagProbe の結果をそのまま引き継ぐ (単一の書き手に統一し、
/// 互いの内容を消し合わないようにするため)。原因が判明したら
/// DiagProbe と一緒に削除すること。
final class DiagTrace {
    static let shared = DiagTrace()
    static let textFileName = "diag-probe.txt"
    static let csvFileName = "diag-probe.csv"
    private static let maxEntries = 200

    private struct Entry {
        let date: Date
        let event: String
        let detail: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var probeLines: [String] = []
    private var probeDate: Date?
    private var persistScheduled = false
    private let persistQueue = DispatchQueue(label: "jp.onejpkey.NumberKey.DiagTrace")

    private init() {}

    // MARK: - 記録

    func record(event: String, detail: String) {
        lock.lock()
        entries.append(Entry(date: Date(), event: event, detail: detail))
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        lock.unlock()
        schedulePersist()
    }

    /// DiagProbe の結果を取り込む (diag-probe.txt の従来部分)。
    func setProbe(lines: [String]) {
        lock.lock()
        probeLines = lines
        probeDate = Date()
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
        let probe = probeLines
        let probeAt = probeDate
        let trace = entries
        lock.unlock()
        guard let dir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: KeyboardSettings.appGroupIdentifier) else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // txt: 従来のプローブ結果 + ライブトレース (本体アプリの「診断」が表示)
        var text = probe
        if !trace.isEmpty {
            if !text.isEmpty { text.append("") }
            text.append("=== live trace (last \(trace.count)) ===")
            for entry in trace {
                text.append("\(formatter.string(from: entry.date)) \(entry.event) \(entry.detail)")
            }
        }
        try? text.joined(separator: "\n").write(
            to: dir.appendingPathComponent(Self.textFileName), atomically: true, encoding: .utf8)

        // csv: timestamp,event,detail (プローブは event=probe で1行ずつ)
        var rows = ["timestamp,event,detail"]
        let probeStamp = probeAt.map { formatter.string(from: $0) } ?? ""
        for line in probe {
            rows.append([probeStamp, "probe", line].map(Self.csvEscape).joined(separator: ","))
        }
        for entry in trace {
            rows.append([formatter.string(from: entry.date), entry.event, entry.detail]
                .map(Self.csvEscape).joined(separator: ","))
        }
        try? rows.joined(separator: "\n").write(
            to: dir.appendingPathComponent(Self.csvFileName), atomically: true, encoding: .utf8)
    }

    private static func csvEscape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
