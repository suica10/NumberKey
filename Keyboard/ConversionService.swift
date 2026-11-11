import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// The converter and its caches are confined to one actor; no text is sent off-device.
actor ConversionService {
    private var converter: KanaKanjiConverter?

    func candidates(for composition: ComposingText) -> [String] {
        guard !composition.isEmpty else { return [] }
        if converter == nil { converter = .withDefaultDictionary() }
        guard let converter else { return [] }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let results = converter.requestCandidates(composition, options: .init(
            N_best: 5,
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            learningType: .nothing,
            memoryDirectoryURL: directory,
            sharedContainerURL: directory,
            textReplacer: .empty,
            specialCandidateProviders: [],
            metadata: .init(versionString: "NumberKey 0.1.2")
        ))
        var seen = Set<String>()
        return results.mainResults.compactMap { candidate in
            guard candidate.inputable, !candidate.text.isEmpty else { return nil }
            // Only offer full-input candidates: committing a prefix must not discard the suffix.
            var remainder = composition
            remainder.prefixComplete(composingCount: candidate.composingCount)
            guard remainder.isEmpty, seen.insert(candidate.text).inserted else { return nil }
            return candidate.text
        }.prefix(12).map { $0 }
    }
}
