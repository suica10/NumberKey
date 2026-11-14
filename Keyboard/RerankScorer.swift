import Foundation
import Accelerate

/// 学習済み char-GRU 言語モデルで変換候補を並べ替える。
///
/// Prototype のオフライン評価 (Prototype/README.md) で、候補文字列そのものの
/// 尤もらしさ (lm_sum: <bos> 候補 <eos> の対数尤度合計) で並べ替えると
/// top-1 が 76.0% → 86.5% になることを実測した方式。文脈は使わない純関数
/// なので、ホストのテキストを読む必要がない。
/// 数学は PyTorch の nn.GRU (ゲート順 r, z, n) と同一で、NumPy 参照実装が
/// PyTorch と top-1 一致・スコア差 2e-5 以内であることをエクスポート時に
/// 検証済み。Swift 側も Tests/RerankScorerTests が同じ fixture で検証する。
///
/// 重み・語彙が読み込めなければ shared は nil になり、呼び出し側は従来の
/// 候補順にフォールバックする (販売時の安全弁を兼ねる)。
final class RerankScorer: @unchecked Sendable {
    static let shared: RerankScorer? = {
        guard let weights = Bundle.main.url(forResource: "rerank_weights", withExtension: "bin"),
              let vocab = Bundle.main.url(forResource: "rerank_vocab", withExtension: "json")
        else { return nil }
        return try? RerankScorer(weightsURL: weights, vocabURL: vocab)
    }()

    private let hidden = 512
    private let embDim = 128
    private let vocabSize: Int
    private let charToID: [UInt32: Int]
    private let bosID = 1, eosID = 2, unkID = 3
    // テンソルは mmap した Data の中へのポインタで保持する (コピーしない)。
    private let data: Data
    private let emb: UnsafePointer<Float>
    private let wih0: UnsafePointer<Float>, whh0: UnsafePointer<Float>
    private let bih0: UnsafePointer<Float>, bhh0: UnsafePointer<Float>
    private let wih1: UnsafePointer<Float>, whh1: UnsafePointer<Float>
    private let bih1: UnsafePointer<Float>, bhh1: UnsafePointer<Float>
    private let wout: UnsafePointer<Float>, bout: UnsafePointer<Float>

    init(weightsURL: URL, vocabURL: URL) throws {
        let vocabData = try Data(contentsOf: vocabURL)
        let parsed = try JSONSerialization.jsonObject(with: vocabData) as? [String: Any]
        guard let itos = parsed?["itos"] as? [String],
              let manifest = parsed?["manifest"] as? [String: [Int]] else {
            throw NSError(domain: "RerankScorer", code: 1)
        }
        vocabSize = itos.count
        var map: [UInt32: Int] = [:]
        for (index, entry) in itos.enumerated() {
            let scalars = entry.unicodeScalars
            if scalars.count == 1, let scalar = scalars.first { map[scalar.value] = index }
        }
        charToID = map
        let loaded = try Data(contentsOf: weightsURL, options: [.mappedIfSafe])
        data = loaded
        // ポインタはローカル変数だけから作る (init 中に self へ触れるクロージャを
        // 挟むと definite-initialization チェックに落ちるため)。
        let base = loaded.withUnsafeBytes { raw in
            raw.baseAddress!.assumingMemoryBound(to: Float.self)
        }
        func pointer(_ name: String) throws -> UnsafePointer<Float> {
            guard let entry = manifest[name], entry.count == 2 else {
                throw NSError(domain: "RerankScorer", code: 2)
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

    /// 候補を lm_sum の降順に並べ替える。同点は元の順序を保つ。
    func rerank(_ candidates: [String]) -> [String] {
        guard candidates.count > 1 else { return candidates }
        let scores = score(candidates)
        return candidates.enumerated()
            .sorted { a, b in scores[a.offset] != scores[b.offset] ? scores[a.offset] > scores[b.offset] : a.offset < b.offset }
            .map(\.element)
    }

    /// 各文字列の対数尤度合計。<bos>…<eos> を教師 forcing で流す。
    /// 全文字列を時刻で揃えてバッチ処理し、重みの読み直しを最小化する。
    func score(_ strings: [String]) -> [Float] {
        let n = strings.count
        guard n > 0 else { return [] }
        let H = hidden
        // ids[i] = [bos, chars..., eos] (学習時の encode 上限に合わせ 64 で打ち切り)
        let ids: [[Int32]] = strings.map { s in
            var seq: [Int32] = [Int32(bosID)]
            for scalar in s.unicodeScalars.prefix(62) {
                seq.append(Int32(charToID[scalar.value] ?? unkID))
            }
            seq.append(Int32(eosID))
            return seq
        }
        let steps = ids.map { $0.count - 1 }.max() ?? 0
        var h1 = [Float](repeating: 0, count: n * H)
        var h2 = [Float](repeating: 0, count: n * H)
        var sums = [Float](repeating: 0, count: n)
        // 作業バッファ
        var xPack = [Float](repeating: 0, count: n * embDim)     // layer0 入力 (埋め込み)
        var gi = [Float](repeating: 0, count: n * 3 * H)
        var gh = [Float](repeating: 0, count: n * 3 * H)
        var logits = [Float](repeating: 0, count: n * vocabSize)
        // Reuse one mask across timesteps; every entry is overwritten before use.
        var active = [Bool](repeating: false, count: n)

        func gemm(_ a: UnsafePointer<Float>, _ lda: Int32, _ b: UnsafePointer<Float>, _ ldb: Int32,
                  _ c: UnsafeMutablePointer<Float>, _ ldc: Int32, rows: Int32, cols: Int32, inner: Int32) {
            // C[rows, cols] = A[rows, inner] · B[cols, inner]^T (B は [out, in] 行優先)
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, rows, cols, inner, 1,
                        a, lda, b, ldb, 0, c, ldc)
        }
        func gruStep(x: UnsafePointer<Float>, inDim: Int, h: inout [Float],
                     wih: UnsafePointer<Float>, whh: UnsafePointer<Float>,
                     bih: UnsafePointer<Float>, bhh: UnsafePointer<Float>, active: [Bool]) {
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

        for t in 0..<steps {
            for i in 0..<n { active[i] = t < ids[i].count - 1 }
            // layer 0: 入力は埋め込みベクトル
            for i in 0..<n where active[i] {
                let row = emb + Int(ids[i][t]) * embDim
                xPack.withUnsafeMutableBufferPointer { xp in
                    (xp.baseAddress! + i * embDim).update(from: row, count: embDim)
                }
            }
            xPack.withUnsafeBufferPointer { xp in
                gruStep(x: xp.baseAddress!, inDim: embDim, h: &h1, wih: wih0, whh: whh0, bih: bih0, bhh: bhh0, active: active)
            }
            // layer 1: 入力は h1
            gruStep(x: h1.withUnsafeBufferPointer { $0.baseAddress! }, inDim: H, h: &h2, wih: wih1, whh: whh1, bih: bih1, bhh: bhh1, active: active)
            // head: logits → 目標文字の log-prob を加算
            h2.withUnsafeBufferPointer { hb in
                gemm(hb.baseAddress!, Int32(H), wout, Int32(H), &logits, Int32(vocabSize), rows: Int32(n), cols: Int32(vocabSize), inner: Int32(H))
            }
            for i in 0..<n where active[i] {
                let off = i * vocabSize
                var maxV: Float = -1e30
                for v in 0..<vocabSize { maxV = max(maxV, logits[off + v] + bout[v]) }
                var sumExp: Float = 0
                for v in 0..<vocabSize { sumExp += expf(logits[off + v] + bout[v] - maxV) }
                let target = Int(ids[i][t + 1])
                sums[i] += (logits[off + target] + bout[target]) - (maxV + logf(sumExp))
            }
        }
        return sums
    }
}
