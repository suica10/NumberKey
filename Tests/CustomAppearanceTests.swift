import XCTest
@testable import PhraseStore

/// 着せ替え (2026-11-26 確定仕様) の設定まわりの単体テスト。
/// UIKit には触れない純粋ロジック (色の保存・パレット解決) だけを対象にし、
/// 特に「OFF のときに現行パレットと等価になる」ことを固定する。
final class CustomAppearanceTests: XCTestCase {

    // MARK: - 保存・復元 (ラウンドトリップ)

    func testRoundTripPreservesCustomization() throws {
        var settings = LayoutSettings.defaults
        settings.customizationEnabled = true
        settings.customAppearance.background = KeyboardColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.9)
        settings.customAppearance.keyFace = KeyboardColor(red: 0.9, green: 0.85, blue: 0.8)
        settings.customAppearance.panelText = .white
        settings.customAppearance.popupSelectedBackground = KeyboardColor(red: 0.25, green: 0.5, blue: 0.75)
        settings.customAppearance.backgroundImageFileName = CustomAppearance.standardBackgroundImageFileName
        settings.customAppearance.backgroundImageFillsScreen = false
        settings.customAppearance.backgroundImageDim = 0.5

        // JSON (snapshot の保存形式) のラウンドトリップ。
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(LayoutSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertTrue(decoded.isValid)

        // exportString / decode (設定の受け渡し形式) のラウンドトリップ。
        XCTAssertEqual(LayoutSettings.decode(settings.exportString()), settings)
    }

    func testLegacyJSONWithoutCustomizationDecodesToDefaults() throws {
        // 着せ替え導入前の設定 JSON (新フィールドなし) が壊れず読めること。
        let json = #"{"version":1,"keyHeight":0,"theme":1,"japanese":false,"flickMode":true}"#
        let decoded = try JSONDecoder().decode(LayoutSettings.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.customizationEnabled)
        XCTAssertEqual(decoded.customAppearance, CustomAppearance())
        XCTAssertTrue(decoded.isValid)
        // 既存フィールドは従来どおり解釈される。
        XCTAssertEqual(decoded.theme, 1)
        XCTAssertFalse(decoded.japanese)
        XCTAssertTrue(decoded.flickMode)
    }

    func testKeyboardSettingsSnapshotRoundTrip() {
        // App Group の UserDefaults 経由の保存・復元 (実保存先は一時 suite)。
        let suiteName = "test.customAppearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = KeyboardSettings(defaults: defaults)
        var settings = LayoutSettings.defaults
        settings.customizationEnabled = true
        settings.customAppearance.keyText = KeyboardColor(red: 0.2, green: 0.4, blue: 0.6)
        settings.customAppearance.backgroundImageFileName = CustomAppearance.standardBackgroundImageFileName
        store.snapshot = settings
        XCTAssertEqual(store.snapshot, settings)
    }

    // MARK: - OFF 等価性

    func testDefaultSettingsResolveToStandardPalette() {
        for dark in [true, false] {
            XCTAssertEqual(LayoutSettings.defaults.resolvedPalette(dark: dark),
                           KeyboardPalette.standard(dark: dark))
        }
    }

    func testDisabledCustomizationIgnoresStoredColors() {
        // OFF のまま色や画像の設定を保持していても、解決結果は現行
        // パレットと完全一致する (OFF の描画が従来と等価である担保)。
        var settings = LayoutSettings.defaults
        settings.customizationEnabled = false
        settings.customAppearance.background = KeyboardColor(red: 1, green: 0, blue: 0)
        settings.customAppearance.keyFace = KeyboardColor(red: 0, green: 1, blue: 0)
        settings.customAppearance.panelText = KeyboardColor(red: 0, green: 0, blue: 1)
        settings.customAppearance.backgroundImageFileName = CustomAppearance.standardBackgroundImageFileName
        for dark in [true, false] {
            XCTAssertEqual(settings.resolvedPalette(dark: dark), KeyboardPalette.standard(dark: dark))
        }
        XCTAssertFalse(settings.usesBackgroundImage)
    }

    func testStandardPaletteMatchesLegacyConstants() {
        // 現行 (着せ替え導入前) のハードコード値と一致すること。
        let dark = KeyboardPalette.standard(dark: true)
        XCTAssertEqual(dark.background, .gray(0.17))
        XCTAssertEqual(dark.keyFace, .gray(0.38))
        XCTAssertEqual(dark.keyPressed, .gray(0.56))
        XCTAssertEqual(dark.keyText, .white)
        XCTAssertEqual(dark.candidateText, .white)
        XCTAssertEqual(dark.candidateSelectedBackground, .gray(0.45, alpha: 0.95))
        XCTAssertEqual(dark.panelBackground, .gray(0.24))
        XCTAssertEqual(dark.panelBorder, .gray(0.42))
        XCTAssertEqual(dark.panelCardBackground, .gray(0.32))
        XCTAssertEqual(dark.panelText, .white)
        XCTAssertEqual(dark.popupSelectedBackground, .gray(0.92))
        XCTAssertEqual(dark.popupSelectedText, .black)

        let light = KeyboardPalette.standard(dark: false)
        XCTAssertEqual(light.background, .gray(0.82))
        XCTAssertEqual(light.keyFace, .white)
        XCTAssertEqual(light.keyPressed, .gray(0.92))
        XCTAssertEqual(light.keyText, .black)
        XCTAssertEqual(light.candidateText, .black)
        XCTAssertEqual(light.candidateSelectedBackground, .gray(0.45, alpha: 0.95))
        XCTAssertEqual(light.panelBackground, .gray(0.97))
        XCTAssertEqual(light.panelBorder, .gray(0.72))
        XCTAssertEqual(light.panelCardBackground, .white)
        XCTAssertEqual(light.panelText, .black)
        XCTAssertEqual(light.popupSelectedBackground, .gray(0.35))
        XCTAssertEqual(light.popupSelectedText, .white)
    }

    // MARK: - ON の適用

    func testEnabledCustomizationOverridesOnlyPickedElements() {
        var settings = LayoutSettings.defaults
        settings.customizationEnabled = true
        let face = KeyboardColor(red: 0.9, green: 0.8, blue: 0.7)
        let panelText = KeyboardColor(red: 0.1, green: 0.1, blue: 0.9)
        settings.customAppearance.keyFace = face
        settings.customAppearance.panelText = panelText
        for dark in [true, false] {
            let resolved = settings.resolvedPalette(dark: dark)
            let standard = KeyboardPalette.standard(dark: dark)
            XCTAssertEqual(resolved.keyFace, face)
            XCTAssertEqual(resolved.panelText, panelText)
            // ピックしていない要素は両モードとも現行パレットのまま。
            XCTAssertEqual(resolved.background, standard.background)
            XCTAssertEqual(resolved.keyPressed, standard.keyPressed)
            XCTAssertEqual(resolved.keyText, standard.keyText)
            XCTAssertEqual(resolved.candidateText, standard.candidateText)
            XCTAssertEqual(resolved.candidateSelectedBackground, standard.candidateSelectedBackground)
            XCTAssertEqual(resolved.panelBackground, standard.panelBackground)
            XCTAssertEqual(resolved.panelBorder, standard.panelBorder)
            XCTAssertEqual(resolved.panelCardBackground, standard.panelCardBackground)
            XCTAssertEqual(resolved.popupSelectedBackground, standard.popupSelectedBackground)
            XCTAssertEqual(resolved.popupSelectedText, standard.popupSelectedText)
        }
    }

    func testUsesBackgroundImageRequiresEnabledAndFileName() {
        var settings = LayoutSettings.defaults
        settings.customAppearance.backgroundImageFileName = CustomAppearance.standardBackgroundImageFileName
        XCTAssertFalse(settings.usesBackgroundImage)
        settings.customizationEnabled = true
        XCTAssertTrue(settings.usesBackgroundImage)
        settings.customAppearance.backgroundImageFileName = nil
        XCTAssertFalse(settings.usesBackgroundImage)
    }

    // MARK: - 値の防御

    func testOutOfRangeColorComponentsAreClampedOnDecode() throws {
        let json = #"{"background":{"red":2,"green":-1,"blue":0.5,"alpha":1}}"#
        let appearance = try JSONDecoder().decode(CustomAppearance.self, from: Data(json.utf8))
        XCTAssertEqual(appearance.background, KeyboardColor(red: 1, green: 0, blue: 0.5, alpha: 1))
        XCTAssertTrue(appearance.isValid)
    }

    func testBackgroundImageDimIsClampedOnDecode() throws {
        let json = #"{"backgroundImageDim":3.5}"#
        let appearance = try JSONDecoder().decode(CustomAppearance.self, from: Data(json.utf8))
        XCTAssertEqual(appearance.backgroundImageDim, CustomAppearance.backgroundImageDimRange.upperBound)
        XCTAssertTrue(appearance.isValid)
    }

    func testUnsafeBackgroundImageFileNameIsInvalid() {
        var settings = LayoutSettings.defaults
        settings.customAppearance.backgroundImageFileName = "../secret.jpg"
        XCTAssertFalse(settings.customAppearance.isValid)
        XCTAssertFalse(settings.isValid)
        settings.customAppearance.backgroundImageFileName = "a/b.jpg"
        XCTAssertFalse(settings.isValid)
        settings.customAppearance.backgroundImageFileName = CustomAppearance.standardBackgroundImageFileName
        XCTAssertTrue(settings.isValid)
    }

    func testResetColorsClearsOnlyColors() {
        var appearance = CustomAppearance()
        appearance.keyFace = .white
        appearance.panelText = .black
        appearance.backgroundImageFileName = CustomAppearance.standardBackgroundImageFileName
        appearance.backgroundImageDim = 0.6
        appearance.resetColors()
        XCTAssertNil(appearance.keyFace)
        XCTAssertNil(appearance.panelText)
        // 画像まわりの設定は色リセットの対象外。
        XCTAssertEqual(appearance.backgroundImageFileName, CustomAppearance.standardBackgroundImageFileName)
        XCTAssertEqual(appearance.backgroundImageDim, 0.6)
    }
}
