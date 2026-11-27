import XCTest
@testable import PhraseStore

/// ソシャゲー辞書パックのスケール評価ベンチマーク (2026-11-27)。
/// AnimePackBenchmarkTests と同じ流儀で、パース時間と前方一致の応答を
/// 測る。判定は "BENCH " 行の数値で行い、アサートは桁違いの劣化を
/// 検出する緩い bound のみ。
final class SocialGamePackBenchmarkTests: XCTestCase {
    private var tsvURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Keyboard/dictionary_socialgame.tsv")
    }

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

    func testParseTime() throws {
        let data = try Data(contentsOf: tsvURL)
        let lines = String(data: data, encoding: .utf8)!.split(separator: "\n")
        var total = 0.0
        let reps = 30
        for _ in 0..<reps {
            let t0 = ProcessInfo.processInfo.systemUptime
            let pack = DictionaryPackData.parse(data)
            total += (ProcessInfo.processInfo.systemUptime - t0) * 1000
            withExtendedLifetime(pack) {}
        }
        let pack = DictionaryPackData.parse(data)
        let surfaces = pack.byReading.values.reduce(0) { $0 + $1.count } + pack.patterns.count
        print("BENCH socialgame entries=\(lines.count) parsed=\(surfaces) fileBytes=\(data.count)")
        print("BENCH socialgame parseMs avg=\(String(format: "%.2f", total / Double(reps)))")
        XCTAssertEqual(surfaces, 7_325)
        XCTAssertLessThan(total / Double(reps), 500, "パースが桁違いに遅い")
    }

    func testPrefixLookupLatency() throws {
        let data = try Data(contentsOf: tsvURL)
        let pack = DictionaryPackData.parse(data)
        let all = kanaReadings(in: data)
        let long = all.filter { $0.count >= 4 }
        var prefixes: [String] = []
        if !long.isEmpty {
            let stride = max(1, long.count / 40)
            var i = 0
            while prefixes.count < 40, i < long.count {
                prefixes.append(String(long[i].prefix(3)))
                i += stride
            }
        }
        XCTAssertFalse(prefixes.isEmpty, "サンプル prefix が無い")

        for p in prefixes { _ = pack.prefixSurfaces(forPrefix: p, limit: 10) }
        let reps = 200
        var totalResults = 0
        let t0 = ProcessInfo.processInfo.systemUptime
        for _ in 0..<reps {
            for p in prefixes {
                totalResults += pack.prefixSurfaces(forPrefix: p, limit: 10).count
            }
        }
        let calls = Double(reps * prefixes.count)
        let perCallMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000 / calls
        print("BENCH socialgame prefix readings=\(pack.byReading.count) prefixes=\(prefixes.count) avgResults=\(String(format: "%.2f", Double(totalResults) / calls)) perCallMs=\(String(format: "%.4f", perCallMs))")
        XCTAssertLessThan(perCallMs, 1.0, "前方一致がサブミリ秒級でない")
    }
}
