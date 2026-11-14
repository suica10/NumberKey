import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// The converter and its caches are confined to one actor; no text is sent off-device.
actor ConversionService {
    /// 変換時間の計測フック (名前, 経過ミリ秒)。PerfProbe は拡張モジュール側に
    /// あるため、このファイル単体でビルドされる SwiftPM 検証ターゲットからは
    /// 直接参照できない。アプリ側が起動時に sink を差し込む (未設定なら無計測)。
    static var perfSink: ((String, Double) -> Void)?
    /// 検証ターゲット用のスコアラ差し込み口 (perfSink と同じ事情):
    /// SwiftPM テストでは重みが Bundle.main に無いため RerankScorer.shared
    /// が nil になる。本番では常に nil で、shared が使われる。
    static var scorerOverride: RerankScorer?
    /// 実機診断用トレースフック（DiagTrace へ中継される）。perfSink と同じ
    /// 事情でアプリ側が起動時に差し込む（未設定なら無記録）。引数は
    /// （イベント名, 詳細）。診断が終わったら DiagProbe と一緒に外すこと。
    static var traceSink: ((String, String) -> Void)?
    private var converter: KanaKanjiConverter?
    private var learningCandidates: [String: Candidate] = [:]
    /// 最後に受け付けた変換リクエストの世代。actor は直列実行なので、古い
    /// リクエストが実行順を待っている間に新しい入力が来ると、古い変換を
    /// フルに計算してから捨てる「先行車両の渋滞」が起きる。実行開始時点で
    /// 自分より新しい世代が既に届いていたら、変換自体を丸ごと省く。
    private var newestGeneration = 0
    private lazy var memoryDirectoryURL: URL = {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = supportDirectory
            .appendingPathComponent("NumberKey", isDirectory: true)
            .appendingPathComponent("KeyboardMemory", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    func warmUp() {
        if converter == nil { converter = .withDefaultDictionary() }
    }

    /// 世代遅れでスキップした場合は nil を返す（本当に候補が無い場合の [] と区別する）。
    func candidates(for composition: ComposingText, generation: Int) -> [String]? {
        let target = composition.convertTarget
        if generation < newestGeneration {
            Self.traceSink?("svc.stale", "gen=\(generation) newest=\(newestGeneration) input=\(target)")
            return nil
        }
        newestGeneration = generation
        guard !composition.isEmpty else {
            learningCandidates.removeAll()
            Self.traceSink?("svc.empty", "gen=\(generation)")
            return []
        }
        warmUp()
        guard let converter else {
            Self.traceSink?("svc.noconverter", "gen=\(generation) input=\(target)")
            return []
        }
        learningCandidates.removeAll()
        let convStart = ProcessInfo.processInfo.systemUptime
        let visibleCandidates = fullInputCandidates(for: composition, converter: converter)
        let top = visibleCandidates.prefix(12).map { $0 }
        // AI リランク: 学習済み LM で候補を並べ替える (評価で top-1 76.0%→86.5%)。
        // モデルが読み込めなければ従来の順序のまま。計測 (conv) は変換+並べ替え
        // の合計 — 利用者体感に効くのはサービス全体の時間だから。
        guard let scorer = Self.scorerOverride ?? RerankScorer.shared else {
            Self.perfSink?("conv", (ProcessInfo.processInfo.systemUptime - convStart) * 1000)
            Self.traceSink?("svc.result", "gen=\(generation) input=\(target) count=\(top.count) first=\(top.first ?? "") rerank=off")
            return top
        }
        let reranked = scorer.rerank(top)
        // タイポ補正: 勝者の LM スコアが低いときだけ、1編集バリアントの
        // 候補プールで差し替えを試す (ゲート付き。TypoCorrection 参照)。
        let corrected = typoCorrected(input: composition.convertTarget, ranked: reranked, converter: converter, scorer: scorer)
        Self.perfSink?("conv", (ProcessInfo.processInfo.systemUptime - convStart) * 1000)
        Self.traceSink?("svc.result", "gen=\(generation) input=\(target) count=\(corrected.count) first=\(corrected.first ?? "")")
        return corrected
    }

    /// 変換器に問い合わせ、入力全体に対応する候補だけを返す (部分確定で
    /// 後続を捨てる候補は出さない)。通常変換とタイポ補正のバリアント
    /// 変換で共有する。
    private func fullInputCandidates(for composition: ComposingText, converter: KanaKanjiConverter) -> [String] {
        let results = converter.requestCandidates(composition, options: .init(
            N_best: 4,
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            learningType: .inputAndOutput,
            memoryDirectoryURL: memoryDirectoryURL,
            sharedContainerURL: memoryDirectoryURL,
            textReplacer: .empty,
            specialCandidateProviders: [],
            metadata: .init(versionString: "NumberKey 0.3.2")
        ))
        var seen = Set<String>()
        return results.mainResults.compactMap { candidate -> String? in
            guard candidate.inputable, !candidate.text.isEmpty else { return nil }
            // Only offer full-input candidates: committing a prefix must not discard the suffix.
            var remainder = composition
            remainder.prefixComplete(composingCount: candidate.composingCount)
            guard remainder.isEmpty, seen.insert(candidate.text).inserted else { return nil }
            if candidate.isLearningTarget { learningCandidates[candidate.text] = candidate }
            return candidate.text
        }
    }

    /// ゲート付きタイポ補正。勝者の lm_avg が閾値未満なら、入力の
    /// 1編集バリアントを変換して候補をプールし、プール最良が勝者を
    /// マージン以上上回る場合に限り、プールの上位で置き換える。
    /// それ以外 (ゲート不発・バリアント無し・プールが伸びない) は
    /// 通常の並びをそのまま返す。
    /// v0.3.32: TypoCorrection.enabled = false のため常に不発
    /// (実機で遅すぎると判断された。スイッチを戻せば復活する)。
    private func typoCorrected(input: String, ranked: [String], converter: KanaKanjiConverter, scorer: RerankScorer) -> [String] {
        guard TypoCorrection.enabled else { return ranked }
        guard let winner = ranked.first else { return ranked }
        let winnerSum = scorer.score([winner])[0]
        let winnerAvg = winnerSum / Float(TypoCorrection.tokenCount(of: winner))
        guard winnerAvg < TypoCorrection.gateThresholdAvg else { return ranked }
        let variants = TypoCorrection.variantKanas(forKana: input)
        guard !variants.isEmpty else { return ranked }
        var pool = ranked
        var seen = Set(ranked)
        for variant in variants {
            var composition = ComposingText()
            composition.insertAtCursorPosition(variant, inputStyle: .direct)
            for candidate in fullInputCandidates(for: composition, converter: converter)
            where seen.insert(candidate).inserted {
                pool.append(candidate)
            }
        }
        guard pool.count > ranked.count else { return ranked }
        let scores = scorer.score(pool)
        guard let bestIndex = scores.indices.max(by: { scores[$0] < scores[$1] }),
              pool[bestIndex] != winner,
              scores[bestIndex] - winnerSum >= TypoCorrection.marginSum
        else { return ranked }
        let order = pool.indices.sorted { a, b in
            scores[a] != scores[b] ? scores[a] > scores[b] : a < b
        }
        return order.prefix(12).map { pool[$0] }
    }

    /// 実機診断用 (DiagProbe から呼ばれる)。本番の世代管理には触れず、
    /// 「にほんご」の生の変換結果と fullInputCandidates の通過数を返す。
    /// rawCount が 0 なら変換器/辞書側、raw はあるのに filtered が 0 なら
    /// こちらのフィルタ側の問題と切り分けられる。
    func probeConversion() -> (rawCount: Int, rawFirst: [String], filtered: [String]) {
        warmUp()
        guard let converter else { return (-1, [], []) }
        var comp = ComposingText()
        comp.insertAtCursorPosition("nihongo", inputStyle: .roman2kana)
        let results = converter.requestCandidates(comp, options: .init(
            N_best: 4,
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            learningType: .inputAndOutput,
            memoryDirectoryURL: memoryDirectoryURL,
            sharedContainerURL: memoryDirectoryURL,
            textReplacer: .empty,
            specialCandidateProviders: [],
            metadata: .init(versionString: "NumberKey probe")
        ))
        let filtered = fullInputCandidates(for: comp, converter: converter)
        return (results.mainResults.count, results.mainResults.prefix(3).map { $0.text }, filtered)
    }

    func learn(_ text: String) {
        guard let converter, let candidate = learningCandidates[text], candidate.isLearningTarget else { return }
        converter.updateLearningData(candidate)
        converter.commitUpdateLearningData()
    }
}
