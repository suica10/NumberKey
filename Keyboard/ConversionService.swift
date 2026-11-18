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
    /// context は同じフィールドで確定済みのテキスト (LM v3 の文脈条件付け用)。
    func candidates(for composition: ComposingText, generation: Int, context: String = "") -> [String]? {
        let target = composition.convertTarget
        if generation < newestGeneration {
            return nil
        }
        newestGeneration = generation
        guard !composition.isEmpty else {
            learningCandidates.removeAll()
            return []
        }
        warmUp()
        guard let converter else {
            return []
        }
        learningCandidates.removeAll()
        let convStart = ProcessInfo.processInfo.systemUptime
        let visibleCandidates = fullInputCandidates(for: composition, converter: converter)
        let top = visibleCandidates.prefix(12).map { $0 }
        // LM v3: 文脈条件付きスコア (候補スパンの平均 logprob) に、変換器自身の
        // 順位プライア (-0.5/位) と常用漢字調整を重ねて最終順位にする。
        // 係数はオフライン評価で検証済み (dev で決定: test top1 0.902、
        // 素の順序 0.824 / v2 経路 0.650)。検証用差し込み口 (scorerOverride)
        // が設定されている場合は従来経路を優先し、テストの意味を変えない。
        if Self.scorerOverride == nil, let v3 = ContextRerankScorer.shared {
            let scores = v3.score(top, context: context)
            let joyo = JoyoKanji.shared
            let adjusted = top.indices.map { i in
                scores[i] + (joyo?.adjustment(for: top[i]) ?? 0) - 0.5 * Float(i)
            }
            let order = top.indices.sorted { a, b in
                adjusted[a] != adjusted[b] ? adjusted[a] > adjusted[b] : a < b
            }
            let reranked = order.map { top[$0] }
            Self.perfSink?("conv", (ProcessInfo.processInfo.systemUptime - convStart) * 1000)
            return reranked
        }
        // AI リランク: 学習済み LM で候補を並べ替える (評価で top-1 76.0%→86.5%)。
        // モデルが読み込めなければ従来の順序のまま。計測 (conv) は変換+並べ替え
        // の合計 — 利用者体感に効くのはサービス全体の時間だから。
        guard let scorer = Self.scorerOverride ?? RerankScorer.shared else {
            Self.perfSink?("conv", (ProcessInfo.processInfo.systemUptime - convStart) * 1000)
            return top
        }
        // 常用漢字ボーナス: LM スコアに字種の調整を加えて最終順位にする
        // (JoyoKanji 参照)。ペナルティ免除は渡さない。以前は
        // learningCandidates のキーを免除していたが、その集合は
        // 「ユーザーが実際に選んで学習した候補」ではなく、変換器が
        // isLearningTarget を立てた候補の集合であり、辞書候補のほぼ
        // 全てが該当する (実測: 「くるま」上位12件すべて true)。
        // そのため常用外候補へのペナルティが実機で丸ごと無効化されて
        // いた (ビルド60〜63)。learningCandidates は learn() での
        // 学習確定のためにだけ使う。
        let scores = scorer.score(top)
        let order = joyoAdjustedOrder(
            candidates: top, scores: scores, joyo: JoyoKanji.shared,
            penaltyExempt: [])
        let reranked = order.map { top[$0] }
        Self.perfSink?("conv", (ProcessInfo.processInfo.systemUptime - convStart) * 1000)
        return reranked
    }

    /// 変換器に問い合わせ、入力全体に対応する候補だけを返す (部分確定で
    /// 後続を捨てる候補は出さない)。
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

    func learn(_ text: String) {
        guard let converter, let candidate = learningCandidates[text], candidate.isLearningTarget else { return }
        converter.updateLearningData(candidate)
        converter.commitUpdateLearningData()
    }
}
