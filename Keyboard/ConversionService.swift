import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// The converter and its caches are confined to one actor; no text is sent off-device.
actor ConversionService {
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
        if generation < newestGeneration { return nil }
        newestGeneration = generation
        guard !composition.isEmpty else { learningCandidates.removeAll(); return [] }
        warmUp()
        guard let converter else { return [] }
        learningCandidates.removeAll()
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
        let visibleCandidates = results.mainResults.compactMap { candidate -> String? in
            guard candidate.inputable, !candidate.text.isEmpty else { return nil }
            // Only offer full-input candidates: committing a prefix must not discard the suffix.
            var remainder = composition
            remainder.prefixComplete(composingCount: candidate.composingCount)
            guard remainder.isEmpty, seen.insert(candidate.text).inserted else { return nil }
            if candidate.isLearningTarget { learningCandidates[candidate.text] = candidate }
            return candidate.text
        }
        return visibleCandidates.prefix(12).map { $0 }
    }

    func learn(_ text: String) {
        guard let converter, let candidate = learningCandidates[text], candidate.isLearningTarget else { return }
        converter.updateLearningData(candidate)
        converter.commitUpdateLearningData()
    }
}
