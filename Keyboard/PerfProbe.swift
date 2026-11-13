import Foundation

/// 開発段階専用の軽量な処理時間計測。どの処理に何 ms かかっているかを
/// 実機で集計し、キーボード上部のオーバーレイに平均値を表示する。
/// 最適化は推測でなくこの数字で判断する。販売ビルドでは enabled を
/// false にする（計測コード自体は記録がロック付き配列操作のみで軽い）。
final class PerfProbe: @unchecked Sendable {
    static let shared = PerfProbe()
    // 2026-11-13 の実機計測で役割を終えたため既定は無効。数字が要る調査の
    // ときだけ true に戻す。その際、帯の表示は目障りにならない更新頻度と
    // 色にすること (毎打鍵で数字が変わる高コントラスト表示は使用者が不快)。
    static let enabled = false

    private struct Stat { var count = 0; var totalMs = 0.0; var maxMs = 0.0 }
    private let lock = NSLock()
    private var stats: [String: Stat] = [:]
    private var order: [String] = []

    static func stamp() -> Double { ProcessInfo.processInfo.systemUptime }

    func record(_ name: String, since stamp: Double) {
        recordElapsed(name, ms: (ProcessInfo.processInfo.systemUptime - stamp) * 1000)
    }

    /// 経過ミリ秒を直接記録する。別モジュール (SwiftPM の KeyboardConversion)
    /// から計測を引き渡すために使う — PerfProbe 本体は拡張モジュールにだけ置く。
    func recordElapsed(_ name: String, ms: Double) {
        guard Self.enabled else { return }
        lock.lock()
        var stat = stats[name] ?? Stat()
        if stats[name] == nil { order.append(name) }
        stat.count += 1; stat.totalMs += ms; stat.maxMs = max(stat.maxMs, ms)
        stats[name] = stat
        lock.unlock()
    }

    func measure<T>(_ name: String, _ body: () -> T) -> T {
        guard Self.enabled else { return body() }
        let stamp = Self.stamp()
        defer { record(name, since: stamp) }
        return body()
    }

    func reset() {
        lock.lock(); stats = [:]; order = []; lock.unlock()
    }

    /// オーバーレイ表示用: 「conv 24ms(max 61) · wait 7ms · strip 3ms · show 2ms · ctx 2ms×5」
    /// wait は変換のキュー待ち（await 全体 − 変換そのもの）の推定。
    func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        func avg(_ name: String) -> Double? {
            guard let s = stats[name], s.count > 0 else { return nil }
            return s.totalMs / Double(s.count)
        }
        var parts: [String] = []
        if let conv = avg("conv") {
            let maxMs = stats["conv"]?.maxMs ?? 0
            parts.append(String(format: "conv %.0fms(max %.0f)", conv, maxMs))
        }
        if let awaitAvg = avg("await"), let conv = avg("conv") {
            parts.append(String(format: "wait %.0fms", max(0, awaitAvg - conv)))
        }
        if let input = avg("input") { parts.append(String(format: "input %.0fms", input)) }
        if let show = avg("show") { parts.append(String(format: "show %.0fms", show)) }
        if let strip = avg("strip") { parts.append(String(format: "strip %.0fms", strip)) }
        if let ctx = avg("ctx"), let count = stats["ctx"]?.count {
            parts.append(String(format: "ctx %.1fms×%d", ctx, count))
        }
        return parts.joined(separator: " · ")
    }
}
