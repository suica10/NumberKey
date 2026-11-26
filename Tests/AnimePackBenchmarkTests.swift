import XCTest
import Darwin
import KanaKanjiConverterModuleWithDefaultDictionary
@testable import KeyboardConversion
@testable import PhraseStore

/// アニメ辞書パックのスケール評価ベンチマーク (2026-11-26)。
/// 計測対象の TSV は環境変数 ANIME_TSV_PATH で差し替え可能 (未指定なら
/// 同梱の Keyboard/dictionary_anime.tsv)。結果は "BENCH " 行で出力する。
/// 判定は出力数値で行うため、アサートは桁違いの劣化を検出する緩い bound のみ。
final class AnimePackBenchmarkTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AnimePackBenchmark.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - パスとデータ

    private var keyboardDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Keyboard")
    }

    private var animeTSVPath: String {
        if let p = ProcessInfo.processInfo.environment["ANIME_TSV_PATH"], !p.isEmpty {
            return p
        }
        return keyboardDir.appendingPathComponent("dictionary_anime.tsv").path
    }

    private func tsvData(_ id: DictionaryPackID) throws -> Data {
        if id == .anime {
            return try Data(contentsOf: URL(fileURLWithPath: animeTSVPath))
        }
        return try Data(contentsOf: keyboardDir.appendingPathComponent("\(id.resourceName).tsv"))
    }

    private func makeLibrary() throws -> DictionaryPackLibrary {
        var cache: [DictionaryPackID: Data] = [:]
        for id in DictionaryPackID.allCases { cache[id] = try tsvData(id) }
        return DictionaryPackLibrary { id in DictionaryPackData.parse(cache[id] ?? Data()) }
    }

    private func physFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// TSV から かな読み (パターンでない行) をファイル順に集める。
    private func kanaReadings(in data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let r = String(parts[0])
            if r.allSatisfy({ $0.isASCII }) { continue }
            if seen.insert(r).inserted { out.append(r) }
        }
        return out
    }

    // MARK: - ロード時間とメモリ

    func testLoadTimeAndMemory() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: animeTSVPath))
        let lines = String(data: data, encoding: .utf8)!.split(separator: "\n")
        let entries = lines.count
        // 旧規模 (371件) との比較用: 先頭371行。
        let headData = Data(lines.prefix(371).joined(separator: "\n").utf8)

        func avgParseMs(_ d: Data, reps: Int) -> Double {
            var total = 0.0
            for _ in 0..<reps {
                let t0 = ProcessInfo.processInfo.systemUptime
                let pack = DictionaryPackData.parse(d)
                total += (ProcessInfo.processInfo.systemUptime - t0) * 1000
                withExtendedLifetime(pack) {}
            }
            return total / Double(reps)
        }

        let fullMs = avgParseMs(data, reps: 30)
        let headMs = avgParseMs(headData, reps: 30)

        // メモリ: parse 前後の phys_footprint 差分 (参考値) と構造からの見積り。
        let before = physFootprintMB()
        let pack = DictionaryPackData.parse(data)
        let after = physFootprintMB()
        let readings = pack.byReading
        let uniqueReadings = readings.count
        let totalSurfaces = readings.values.reduce(0) { $0 + $1.count } + pack.patterns.count
        var charBytes = 0
        for (r, ss) in readings {
            charBytes += r.utf8.count
            for s in ss { charBytes += s.utf8.count }
        }
        // 見積り: Swift String は非ASCIIを概ね UTF-16 (2B/字) で保持 +
        // 文字列ヘッダ・辞書/配列オーバーヘッドを 1 エントリ ~120B と仮定。
        let estMB = Double(charBytes * 2 + totalSurfaces * 120 + uniqueReadings * 80) / 1_048_576

        print("BENCH load entries=\(entries) fileBytes=\(data.count)")
        print("BENCH load parseMs full=\(String(format: "%.2f", fullMs)) head371=\(String(format: "%.2f", headMs))")
        print("BENCH memory uniqueReadings=\(uniqueReadings) surfaces=\(totalSurfaces) footprintDeltaMB=\(String(format: "%.1f", after - before)) estHeapMB=\(String(format: "%.1f", estMB))")
        withExtendedLifetime(pack) {}
        XCTAssertLessThan(fullMs, 500, "パースが桁違いに遅い")
    }

    // MARK: - パック統合部分の応答 (候補生成の後段)

    func testPackMergeResponse() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: animeTSVPath))
        let all = kanaReadings(in: data)
        // ヒット: ファイル全体から等間隔に 40 件。ミス: パックに無い一般語 10 件。
        var hits: [String] = []
        if !all.isEmpty {
            let stride = max(1, all.count / 40)
            var i = 0
            while hits.count < 40, i < all.count { hits.append(all[i]); i += stride }
        }
        let misses = ["ありがとう", "おはよう", "ただいま", "すみません", "いただきます",
                      "ごちそうさま", "おつかれさま", "よろしく", "ほんとうに", "だいじょうぶ"]
        let readings = hits + misses

        let library = try makeLibrary()
        let store = DictionaryPackStore(defaults: defaults)
        let dummy = ["候補A", "候補B", "候補C", "候補D", "候補E", "候補F",
                     "候補G", "候補H", "候補I", "候補J", "候補K", "候補L"]

        func runRound() -> Double {
            let t0 = ProcessInfo.processInfo.systemUptime
            for r in readings {
                let pinned = library.pinnedSurfaces(forKana: r, store: store)
                let appended = library.appendedSurfaces(forKana: r, store: store)
                let merged = DictionaryPackLibrary.mergingPacks(into: dummy, pinned: pinned, appended: appended)
                withExtendedLifetime(merged) {}
            }
            return (ProcessInfo.processInfo.systemUptime - t0) * 1000 / Double(readings.count)
        }

        // OFF: 既定 (工業+SNS のみ)。ON: アニメ追加。
        _ = runRound()
        let offMs = (0..<100).map { _ in runRound() }.reduce(0, +) / 100
        store.setEnabled(.anime, true)
        _ = runRound()
        let onMs = (0..<100).map { _ in runRound() }.reduce(0, +) / 100

        print("BENCH merge readings=\(readings.count) hits=\(hits.count)")
        print("BENCH merge perReadingMs off=\(String(format: "%.4f", offMs)) on=\(String(format: "%.4f", onMs))")
        XCTAssertLessThan(onMs, 0.5, "パック統合が桁違いに遅い")
    }

    // MARK: - 変換込みのエンドツーエンド応答

    func testEndToEndResponse() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: animeTSVPath))
        let all = kanaReadings(in: data)
        var hits: [String] = []
        if !all.isEmpty {
            let stride = max(1, all.count / 40)
            var i = 0
            while hits.count < 40, i < all.count { hits.append(all[i]); i += stride }
        }
        let misses = ["ありがとう", "おはよう", "ただいま", "すみません", "いただきます",
                      "ごちそうさま", "おつかれさま", "よろしく", "ほんとうに", "だいじょうぶ"]
        let readings = hits + misses

        let library = try makeLibrary()
        let store = DictionaryPackStore(defaults: defaults)
        let service = ConversionService()
        var generation = 0
        func convert(_ kana: String) async -> [String] {
            generation += 1
            var c = ComposingText()
            c.insertAtCursorPosition(kana, inputStyle: .direct)
            let base = await service.candidates(for: c, generation: generation) ?? []
            let pinned = library.pinnedSurfaces(forKana: kana, store: store)
            let appended = library.appendedSurfaces(forKana: kana, store: store)
            return DictionaryPackLibrary.mergingPacks(into: base, pinned: pinned, appended: appended)
        }

        // ウォームアップ (変換器の生成と辞書ロードを含む)。
        _ = await convert("にほんご")
        for r in readings { _ = await convert(r) }

        // サニティ: パック ON で既知のヒットが候補に入る (ファイルに存在する場合)。
        store.setEnabled(.anime, true)
        if all.contains("わんぴーす") {
            let res = await convert("わんぴーす")
            XCTAssertTrue(res.contains("ONE PIECE"), "アニメパックの候補が統合されていない: \(res)")
        }

        func timedRound() async -> Double {
            let t0 = ProcessInfo.processInfo.systemUptime
            for r in readings { _ = await convert(r) }
            return (ProcessInfo.processInfo.systemUptime - t0) * 1000 / Double(readings.count)
        }

        store.setEnabled(.anime, false)
        var offTotal = 0.0
        for _ in 0..<3 { offTotal += await timedRound() }
        store.setEnabled(.anime, true)
        var onTotal = 0.0
        for _ in 0..<3 { onTotal += await timedRound() }
        let offMs = offTotal / 3, onMs = onTotal / 3

        print("BENCH e2e readings=\(readings.count)")
        print("BENCH e2e perReadingMs off=\(String(format: "%.3f", offMs)) on=\(String(format: "%.3f", onMs)) ratio=\(String(format: "%.2f", onMs / max(offMs, 0.001)))")
        XCTAssertLessThan(onMs, offMs * 1.5 + 1.0, "ON で桁違いに遅くなっている")
    }
}
