import Foundation

/// 一時的な実機診断: TestFlight ビルド (39/41) で変換候補が全滅する件の切り分け。
/// キーボード起動時に一度だけ実行し、結果を App Group の diag-probe.txt に書く。
/// 本体アプリの「診断」セクションが内容をそのまま表示する。
/// 原因が判明したら、このファイルとフックごと削除すること。
enum DiagProbe {
    static let fileName = "diag-probe.txt"
    private static var didRun = false

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: KeyboardSettings.appGroupIdentifier)?
            .appendingPathComponent(fileName)
    }

    static func runOnce(service: ConversionService) {
        guard !didRun else { return }
        didRun = true
        Task {
            let fm = FileManager.default
            var lines: [String] = []
            lines.append("=== One Keyboard diag probe ===")
            lines.append("date: \(ISO8601DateFormatter().string(from: Date()))")
            let info = Bundle.main.infoDictionary
            lines.append("version: \(info?["CFBundleShortVersionString"] as? String ?? "-") (\(info?["CFBundleVersion"] as? String ?? "-"))")

            // App Group コンテナ (このファイル自体の書き込み先)
            let container = fm.containerURL(forSecurityApplicationGroupIdentifier: KeyboardSettings.appGroupIdentifier)
            lines.append("[group] containerURL: \(container?.path ?? "nil")")

            // (a) バンドル URL
            let mainBundle = Bundle.main
            let vcBundle = Bundle(for: KeyboardViewController.self)
            lines.append("[a] Bundle.main.bundleURL: \(mainBundle.bundleURL.path)")
            lines.append("[a] Bundle.main.resourceURL: \(mainBundle.resourceURL?.path ?? "nil")")
            lines.append("[a] Bundle(for: VC).bundleURL: \(vcBundle.bundleURL.path)")
            lines.append("[a] Bundle(for: VC).resourceURL: \(vcBundle.resourceURL?.path ?? "nil")")

            // (b) AzooKey 辞書バンドルの所在候補を総当たりで確認する
            let bundleName = "AzooKeyKanaKanjiConverter_KanaKanjiConverterModuleWithDefaultDictionary"
            let appexDir = mainBundle.bundleURL
            let plugInsDir = appexDir.deletingLastPathComponent()
            let appDir = plugInsDir.deletingLastPathComponent()
            var searchDirs: [(String, URL)] = [
                ("main.resourceURL", mainBundle.resourceURL ?? mainBundle.bundleURL),
                ("vc.resourceURL", vcBundle.resourceURL ?? vcBundle.bundleURL),
                ("appex dir", appexDir),
                ("PlugIns dir", plugInsDir),
                ("app dir", appDir),
            ]
            searchDirs.append(("app/Frameworks", appDir.appendingPathComponent("Frameworks")))
            for (label, dir) in searchDirs {
                let b = dir.appendingPathComponent(bundleName + ".bundle")
                let exists = fm.fileExists(atPath: b.path)
                var detail = ""
                if exists {
                    let louds = b.appendingPathComponent("Dictionary/louds")
                    let loudsExists = fm.fileExists(atPath: louds.path)
                    let count = loudsExists ? ((try? fm.contentsOfDirectory(atPath: louds.path))?.count ?? -1) : -1
                    detail = " loudsExists=\(loudsExists) loudsEntries=\(count)"
                    if let loaded = Bundle(url: b) {
                        detail += " Bundle(url:) OK -> \(loaded.bundleURL.path)"
                    } else {
                        detail += " Bundle(url:) FAILED"
                    }
                }
                lines.append("[b] \(label): bundleExists=\(exists)\(detail)")
            }
            // フォールバック先としてあり得る appex 直下の Dictionary も見る
            let directDict = appexDir.appendingPathComponent("Dictionary")
            lines.append("[b] appex/Dictionary exists=\(fm.fileExists(atPath: directDict.path))")

            // (d) llama.framework (ホストアプリ側 Frameworks)
            let llama = appDir.appendingPathComponent("Frameworks/llama.framework")
            var llamaDetail = ""
            if fm.fileExists(atPath: llama.path) {
                let entries = (try? fm.contentsOfDirectory(atPath: llama.path)) ?? []
                llamaDetail = " entries=\(entries.count)"
            }
            lines.append("[d] llama.framework exists=\(fm.fileExists(atPath: llama.path))\(llamaDetail) path=\(llama.path)")

            // (e) リランク等の Bundle.main リソース解決
            lines.append("[e] RerankScorer.shared loaded: \(RerankScorer.shared != nil)")
            lines.append("[e] rerank_weights via Bundle.main: \(Bundle.main.url(forResource: "rerank_weights", withExtension: "bin") != nil)")
            lines.append("[e] english_words via Bundle.main: \(Bundle.main.url(forResource: "english_words", withExtension: "txt") != nil)")
            lines.append("[mem] applicationSupport: \(fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? "nil")")

            // (c) 変換プローブ (「にほんご」)
            let probe = await service.probeConversion()
            lines.append("[c] nihongo raw mainResults count: \(probe.rawCount)")
            lines.append("[c] nihongo raw first3: \(probe.rawFirst.joined(separator: " / "))")
            lines.append("[c] nihongo filtered count: \(probe.filtered.count)")
            lines.append("[c] nihongo filtered first3: \(probe.filtered.prefix(3).joined(separator: " / "))")

            if let url = fileURL {
                try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
