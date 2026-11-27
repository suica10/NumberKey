// swift-tools-version: 6.1
import PackageDescription

// Run the conversion smoke tests on macOS without UIKit or code signing.
let package = Package(
    name: "NumberKeyVerification",
    platforms: [.macOS(.v13), .iOS(.v17)],
    dependencies: [.package(path: "Vendor/AzooKeyKanaKanjiConverter")],
    targets: [
        .target(
            name: "KeyboardConversion",
            dependencies: [.product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter")],
            path: "Keyboard",
            exclude: ["KeyboardSettings.swift", "KeyboardViewController.swift", "KeyboardCanvas.swift", "MarkedTextSession.swift", "PerfProbe.swift", "Info.plist", "PrivacyInfo.xcprivacy"],
            sources: ["ConversionService.swift", "RerankScorer.swift", "ContextRerankScorer.swift", "JoyoKanji.swift", "SelectionHistory.swift"]
        ),
        .target(
            name: "PhraseStore",
            path: "Keyboard",
            exclude: ["BufferDocument.swift", "ConversionService.swift", "KeyboardCanvas.swift", "KeyboardViewController.swift", "MarkedTextSession.swift", "Info.plist", "NumberKeyKeyboard.entitlements", "PrivacyInfo.xcprivacy"],
            sources: ["PhraseStore.swift", "ClipboardHistory.swift", "EnglishSuggest.swift", "EnglishWordMode.swift", "EmojiData.swift", "DictionaryPacks.swift", "PurchaseState.swift", "KeyboardSettings.swift", "KeyboardAppearance.swift", "FlickPopupGeometry.swift"]
        ),
        .testTarget(
            name: "ConversionTests",
            dependencies: ["KeyboardConversion", "PhraseStore", .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter")],
            path: "Tests"
        )
    ],
    swiftLanguageModes: [.v5]
)
