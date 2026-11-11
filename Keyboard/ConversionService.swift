import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// The converter and its caches are confined to one actor; no text is sent off-device.
actor ConversionService {
    private var converter: KanaKanjiConverter?
    private var learningCandidates: [String: Candidate] = [:]
    private lazy var memoryDirectoryURL: URL = {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = supportDirectory
            .appendingPathComponent("NumberKey", isDirectory: true)
            .appendingPathComponent("KeyboardMemory", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    func candidates(for composition: ComposingText) -> [String] {
        guard !composition.isEmpty else { learningCandidates.removeAll(); return [] }
        if converter == nil { converter = .withDefaultDictionary() }
        guard let converter else { return [] }
        learningCandidates.removeAll()
        let results = converter.requestCandidates(composition, options: .init(
            N_best: 5,
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            learningType: .inputAndOutput,
            memoryDirectoryURL: memoryDirectoryURL,
            sharedContainerURL: memoryDirectoryURL,
            textReplacer: .empty,
            specialCandidateProviders: [],
            metadata: .init(versionString: "NumberKey 0.3.0")
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
