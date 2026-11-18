import Foundation
import Accelerate

/// LM v3 の文脈条件付きスコアラ。学習済み char-GRU (生徒モデル) で
/// 「確定済み文脈でプライミング → 候補スパンの文字平均 logprob」を返す。
///
/// 学習時の定義 (train_student.py): 入力列は <bos> 文脈 <ctx> 候補 <eos>、
/// スコアは <ctx> の後ろ (候補 + <eos>) の平均 logprob。文脈は学習データに
/// 合わせ末尾 40 字に切り詰める。プライミングした隠れ状態は文脈文字列を
/// キーにキャッシュし、打鍵ごとの追加コストを候補スパン分だけにする。
///
/// 数学は RerankScorer と同じ PyTorch nn.GRU 互換実装。参照スコアとの
/// 一致は Tests/ContextRerankScorerTests (rerank3_fixture.json) が検証する。
/// 重み・語彙が読み込めなければ shared は nil になり、呼び出し側は v2
/// スコアラ (文脈なし) にフォールバックする。
final class ContextRerankScorer: @unchecked Sendable {
    static let shared: ContextRerankScorer? = {
        guard let weights = Bundle.main.url(forResource: "rerank3_weights", withExtension: "bin"),
              let vocab = Bundle.main.url(forResource: "rerank3_vocab", withExtension: "json")
        else { return nil }
        return try? ContextRerankScorer(weightsURL: weights, vocabURL: vocab)
    }()

    private let hidden = 512
    private let embDim = 128
    private let vocabSize: Int
    private let charToID: [UInt32: Int]
    private let bosID: Int, eosID: Int, ctxID: Int, unkID: Int
    private let data: Data
    private let emb: UnsafePointer<Float>
    private let wih0: UnsafePointer<Float>, whh0: UnsafePointer<Float>
    private let bih0: UnsafePointer<Float>, bhh0: UnsafePointer<Float>
    private let wih1: UnsafePointer<Float>, whh1: UnsafePointer<Float>
    private let bih1: UnsafePointer<Float>, bhh1: UnsafePointer<Float>
    private let wout: UnsafePointer<Float>, bout: UnsafePointer<Float>

    /// プライミング済み隠れ状態のキャッシュ (直近の文脈 1 件分)。
    /// 呼び出しは ConversionService (actor) から直列に来る前提。
    private var cachedContext: String?
    private var cachedH1: [Float] = []
    private var cachedH2: [Float] = []

    init(weightsURL: URL, vocabURL: URL) throws {
        let vocabData = try Data(contentsOf: vocabURL)
        let parsed = try JSONSerialization.jsonObject(with: vocabData) as? [String: Any]
        guard let itos = parsed?["itos"] as? [String],
              let manifest = parsed?["manifest"] as? [String: [Int]] else {
            throw NSError(domain: "ContextRerankScorer", code: 1)
        }
        vocabSize = itos.count
        var map: [UInt32: Int] = [:]
        for (index, entry) in itos.enumerated() {
            let scalars = entry.unicodeScalars
            if scalars.count == 1, let scalar = scalars.first { map[scalar.value] = index }
        }
        charToID = map
        func special(_ name: String) throws -> Int {
            guard let idx = itos.firstIndex(of: name) else {
                throw NSError(domain: "ContextRerankScorer", code: 3)
            }
            return idx
        }
        bosID = try special("<bos>")
        eosID = try special("<eos>")
        ctxID = try special("<ctx>")
        unkID = try special("<unk>")
        let loaded = try Data(contentsOf: weightsURL, options: [.mappedIfSafe])
        data = loaded
        let base = loaded.withUnsafeBytes { raw in
            raw.baseAddress!.assumingMemoryBound(to: Float.self)
        }
        func pointer(_ name: String) throws -> UnsafePointer<Float> {
            guard let entry = manifest[name], entry.count == 2 else {
                throw NSError(domain: "ContextRerankScorer", code: 2)
            }
            return UnsafePointer(base) + entry[0]
        }
        emb = try pointer("embedding.weight")
        wih0 = try pointer("gru.weight_ih_l0"); whh0 = try pointer("gru.weight_hh_l0")
        bih0 = try pointer("gru.bias_ih_l0"); bhh0 = try pointer("gru.bias_hh_l0")
        wih1 = try pointer("gru.weight_ih_l1"); whh1 = try pointer("gru.weight_hh_l1")
        bih1 = try pointer("gru.bias_ih_l1"); bhh1 = try pointer("gru.bias_hh_l1")
        wout = try pointer("out.weight"); bout = try pointer("out.bias")
    }

    private func gemm(_ a: UnsafePointer<Float>, _ lda: Int32, _ b: UnsafePointer<Float>, _ ldb: Int32,
                      _ c: UnsafeMutablePointer<Float>, _ ldc: Int32, rows: Int32, cols: Int32, inner: Int32) {
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, rows, cols, inner, 1,
                    a, lda, b, ldb, 0, c, ldc)
    }

    /// GRU 2 層をバッチ (n 行) で 1 ステップ進める。RerankScorer と同一の数学。
    private func gruBatchStep(x: UnsafePointer<Float>, inDim: Int, n: Int,
                              h1: inout [Float], h2: inout [Float],
                              gi: inout [Float], gh: inout [Float], active: [Bool]) {
        let H = hidden
        func layer(x: UnsafePointer<Float>, inDim: Int, h: inout [Float],
                   wih: UnsafePointer<Float>, whh: UnsafePointer<Float>,
                   bih: UnsafePointer<Float>, bhh: UnsafePointer<Float>) {
            h.withUnsafeBufferPointer { hb in
                gemm(x, Int32(inDim), wih, Int32(inDim), &gi, Int32(3 * H), rows: Int32(n), cols: Int32(3 * H), inner: Int32(inDim))
                gemm(hb.baseAddress!, Int32(H), whh, Int32(H), &gh, Int32(3 * H), rows: Int32(n), cols: Int32(3 * H), inner: Int32(H))
            }
            for i in 0..<n where active[i] {
                let go = i * 3 * H, ho = i * H
                for j in 0..<H {
                    let r = 1 / (1 + expf(-(gi[go + j] + bih[j] + gh[go + j] + bhh[j])))
                    let z = 1 / (1 + expf(-(gi[go + H + j] + bih[H + j] + gh[go + H + j] + bhh[H + j])))
                    let nv = tanhf(gi[go + 2 * H + j] + bih[2 * H + j] + r * (gh[go + 2 * H + j] + bhh[2 * H + j]))
                    h[ho + j] = (1 - z) * nv + z * h[ho + j]
                }
            }
        }
        // x は layer0 への入力ベクトル列 (埋め込み済み) として受け取る。
        layer(x: x, inDim: inDim, h: &h1, wih: wih0, whh: whh0, bih: bih0, bhh: bhh0)
        h1.withUnsafeBufferPointer { hb in
            layer(x: hb.baseAddress!, inDim: H, h: &h2, wih: wih1, whh: whh1, bih: bih1, bhh: bhh1)
        }
    }

    /// 文脈でプライミングした隠れ状態を返す (キャッシュ付き)。
    private func prime(context: String) -> (h1: [Float], h2: [Float]) {
        let truncated = String(context.unicodeScalars.suffix(40))
        if cachedContext == truncated, !cachedH1.isEmpty {
            return (cachedH1, cachedH2)
        }
        let H = hidden
        var ids: [Int32] = [Int32(bosID)]
        for scalar in truncated.unicodeScalars {
            ids.append(Int32(charToID[scalar.value] ?? unkID))
        }
        ids.append(Int32(ctxID))
        var h1 = [Float](repeating: 0, count: H)
        var h2 = [Float](repeating: 0, count: H)
        var gi = [Float](repeating: 0, count: 3 * H)
        var gh = [Float](repeating: 0, count: 3 * H)
        let active = [true]
        var xRow = [Float](repeating: 0, count: embDim)
        for token in ids {
            let row = emb + Int(token) * embDim
            xRow.withUnsafeMutableBufferPointer { xp in
                xp.baseAddress!.update(from: row, count: embDim)
            }
            xRow.withUnsafeBufferPointer { xp in
                gruBatchStep(x: xp.baseAddress!, inDim: embDim, n: 1,
                             h1: &h1, h2: &h2, gi: &gi, gh: &gh, active: active)
            }
        }
        cachedContext = truncated
        cachedH1 = h1
        cachedH2 = h2
        return (h1, h2)
    }

    /// 各候補の文脈条件付きスコア (候補スパンの文字平均 logprob)。
    func score(_ candidates: [String], context: String) -> [Float] {
        let n = candidates.count
        guard n > 0 else { return [] }
        let H = hidden
        let (ph1, ph2) = prime(context: context)
        var h1 = [Float](repeating: 0, count: n * H)
        var h2 = [Float](repeating: 0, count: n * H)
        for i in 0..<n {
            h1.replaceSubrange(i * H..<(i + 1) * H, with: ph1)
            h2.replaceSubrange(i * H..<(i + 1) * H, with: ph2)
        }
        // ids[i] = [候補の文字..., eos] (v2 と同じく 62 字で打ち切り)
        let ids: [[Int32]] = candidates.map { s in
            var seq: [Int32] = []
            for scalar in s.unicodeScalars.prefix(62) {
                seq.append(Int32(charToID[scalar.value] ?? unkID))
            }
            seq.append(Int32(eosID))
            return seq
        }
        let steps = ids.map { $0.count }.max() ?? 0
        var sums = [Float](repeating: 0, count: n)
        var xPack = [Float](repeating: 0, count: n * embDim)
        var gi = [Float](repeating: 0, count: n * 3 * H)
        var gh = [Float](repeating: 0, count: n * 3 * H)
        var logits = [Float](repeating: 0, count: n * vocabSize)
        var active = [Bool](repeating: false, count: n)

        for t in 0..<steps {
            for i in 0..<n { active[i] = t < ids[i].count }
            // head: 現在の h2 から次のトークンの logprob を先に取る
            // (logits[t] は ids[t] を予測する — 教師 forcing の並び)。
            h2.withUnsafeBufferPointer { hb in
                gemm(hb.baseAddress!, Int32(H), wout, Int32(H), &logits, Int32(vocabSize), rows: Int32(n), cols: Int32(vocabSize), inner: Int32(H))
            }
            for i in 0..<n where active[i] {
                let off = i * vocabSize
                var maxV: Float = -1e30
                for v in 0..<vocabSize { maxV = max(maxV, logits[off + v] + bout[v]) }
                var sumExp: Float = 0
                for v in 0..<vocabSize { sumExp += expf(logits[off + v] + bout[v] - maxV) }
                let target = Int(ids[i][t])
                sums[i] += (logits[off + target] + bout[target]) - (maxV + logf(sumExp))
            }
            // 次に ids[t] を消費して状態を進める (最終ステップでは不要だが無害)
            for i in 0..<n where active[i] {
                let row = emb + Int(ids[i][t]) * embDim
                xPack.withUnsafeMutableBufferPointer { xp in
                    (xp.baseAddress! + i * embDim).update(from: row, count: embDim)
                }
            }
            xPack.withUnsafeBufferPointer { xp in
                gruBatchStep(x: xp.baseAddress!, inDim: embDim, n: n,
                             h1: &h1, h2: &h2, gi: &gi, gh: &gh, active: active)
            }
        }
        return zip(sums, ids).map { sum, seq in sum / Float(max(seq.count, 1)) }
    }
}
