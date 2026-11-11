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
            exclude: ["KeyboardSettings.swift", "KeyboardViewController.swift", "KeyboardCanvas.swift", "MarkedTextSession.swift", "Info.plist"],
            sources: ["ConversionService.swift"]
        ),
        .testTarget(
            name: "ConversionTests",
            dependencies: ["KeyboardConversion", .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter")],
            path: "Tests"
        )
    ],
    swiftLanguageModes: [.v5]
)
