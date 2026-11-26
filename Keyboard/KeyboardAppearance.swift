import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// ユーザーがカラーピッカーで選んだ色 (sRGB、RGBA 各 0...1)。
/// Codable でそのまま LayoutSettings に保存する。デコード時に範囲外の
/// 成分はクランプし、壊れた色 1 つで設定全体が読めなくなる事態を避ける。
/// UIColor への変換は UIKit 側に分離し、このファイルの純粋ロジックは
/// macOS の単体テスト (Tests/CustomAppearanceTests.swift) で検証する。
struct KeyboardColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    static func gray(_ white: Double, alpha: Double = 1) -> KeyboardColor {
        KeyboardColor(red: white, green: white, blue: white, alpha: alpha)
    }
    static let black = KeyboardColor(red: 0, green: 0, blue: 0)
    static let white = KeyboardColor(red: 1, green: 1, blue: 1)

    private enum CodingKeys: String, CodingKey { case red, green, blue, alpha }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        red = try values.decodeIfPresent(Double.self, forKey: .red) ?? 0
        green = try values.decodeIfPresent(Double.self, forKey: .green) ?? 0
        blue = try values.decodeIfPresent(Double.self, forKey: .blue) ?? 0
        alpha = try values.decodeIfPresent(Double.self, forKey: .alpha) ?? 1
        self = clamped
    }

    /// 全成分が有限値か (範囲はクランプで吸収するので問わない)。
    var isValid: Bool {
        red.isFinite && green.isFinite && blue.isFinite && alpha.isFinite
    }
    /// 成分を 0...1 に収めた複製。非有限値は 0 (alpha は 1) に倒す。
    var clamped: KeyboardColor {
        func clamp(_ value: Double, fallback: Double) -> Double {
            value.isFinite ? min(1, max(0, value)) : fallback
        }
        return KeyboardColor(red: clamp(red, fallback: 0),
                             green: clamp(green, fallback: 0),
                             blue: clamp(blue, fallback: 0),
                             alpha: clamp(alpha, fallback: 1))
    }
}

/// 着せ替えのカスタム内容。色は要素ごとに Optional で持ち、nil は
/// 「その要素はデフォルト (現行パレット) のまま」を意味する。
/// 背景画像は App Group 共有コンテナ内のファイルへの参照だけを持ち、
/// 実体は KeyboardBackgroundImageStore が読み書きする。
struct CustomAppearance: Codable, Equatable {
    var background: KeyboardColor?
    var keyFace: KeyboardColor?
    var keyPressed: KeyboardColor?
    var keyText: KeyboardColor?
    var candidateText: KeyboardColor?
    var candidateSelectedBackground: KeyboardColor?
    var panelBackground: KeyboardColor?
    var panelBorder: KeyboardColor?
    var panelCardBackground: KeyboardColor?
    var panelText: KeyboardColor?
    var popupSelectedBackground: KeyboardColor?
    var popupSelectedText: KeyboardColor?
    /// 背景画像のファイル名 (共有コンテナ直下の名前のみ。パス区切りは不可)。
    var backgroundImageFileName: String?
    /// true = 全面に広げる (aspectFill)、false = 全体を表示 (aspectFit)。
    var backgroundImageFillsScreen = true
    /// 背景画像の上にパレットの背景色を重ねる濃さ (0...0.85)。
    /// 画像のままではキー文字が読みにくい場面の調整用。
    var backgroundImageDim: Double = 0.35

    static let backgroundImageDimRange: ClosedRange<Double> = 0...0.85
    /// 背景画像の保存名は世代管理のため固定名にする (選び直しは上書き)。
    static let standardBackgroundImageFileName = "keyboard-background-v1.jpg"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case background, keyFace, keyPressed, keyText, candidateText, candidateSelectedBackground
        case panelBackground, panelBorder, panelCardBackground, panelText
        case popupSelectedBackground, popupSelectedText
        case backgroundImageFileName, backgroundImageFillsScreen, backgroundImageDim
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        background = try values.decodeIfPresent(KeyboardColor.self, forKey: .background)
        keyFace = try values.decodeIfPresent(KeyboardColor.self, forKey: .keyFace)
        keyPressed = try values.decodeIfPresent(KeyboardColor.self, forKey: .keyPressed)
        keyText = try values.decodeIfPresent(KeyboardColor.self, forKey: .keyText)
        candidateText = try values.decodeIfPresent(KeyboardColor.self, forKey: .candidateText)
        candidateSelectedBackground = try values.decodeIfPresent(KeyboardColor.self, forKey: .candidateSelectedBackground)
        panelBackground = try values.decodeIfPresent(KeyboardColor.self, forKey: .panelBackground)
        panelBorder = try values.decodeIfPresent(KeyboardColor.self, forKey: .panelBorder)
        panelCardBackground = try values.decodeIfPresent(KeyboardColor.self, forKey: .panelCardBackground)
        panelText = try values.decodeIfPresent(KeyboardColor.self, forKey: .panelText)
        popupSelectedBackground = try values.decodeIfPresent(KeyboardColor.self, forKey: .popupSelectedBackground)
        popupSelectedText = try values.decodeIfPresent(KeyboardColor.self, forKey: .popupSelectedText)
        backgroundImageFileName = try values.decodeIfPresent(String.self, forKey: .backgroundImageFileName)
        backgroundImageFillsScreen = try values.decodeIfPresent(Bool.self, forKey: .backgroundImageFillsScreen) ?? true
        let dim = try values.decodeIfPresent(Double.self, forKey: .backgroundImageDim) ?? 0.35
        backgroundImageDim = dim.isFinite ? min(Self.backgroundImageDimRange.upperBound,
                                                max(Self.backgroundImageDimRange.lowerBound, dim)) : 0.35
    }

    /// ピック済みの色をすべて外す (背景画像の設定は対象外)。
    mutating func resetColors() {
        background = nil; keyFace = nil; keyPressed = nil; keyText = nil
        candidateText = nil; candidateSelectedBackground = nil
        panelBackground = nil; panelBorder = nil; panelCardBackground = nil; panelText = nil
        popupSelectedBackground = nil; popupSelectedText = nil
    }

    var isValid: Bool {
        let colors = [background, keyFace, keyPressed, keyText, candidateText, candidateSelectedBackground,
                      panelBackground, panelBorder, panelCardBackground, panelText,
                      popupSelectedBackground, popupSelectedText]
        guard colors.allSatisfy({ $0?.isValid ?? true }) else { return false }
        guard backgroundImageDim.isFinite, Self.backgroundImageDimRange.contains(backgroundImageDim) else { return false }
        if let name = backgroundImageFileName {
            // 共有コンテナ直下のファイル名だけを許可する (パス traversal 防止)。
            guard !name.isEmpty, name.count <= 64, !name.contains("/"), !name.contains("..") else { return false }
        }
        return true
    }
}

/// 全要素の色が確定したパレット。standard(dark:) は着せ替え導入前の
/// 現行色をそのまま返し、OFF 時の描画が従来と等価になることの基準になる。
struct KeyboardPalette: Equatable {
    var background: KeyboardColor
    var keyFace: KeyboardColor
    var keyPressed: KeyboardColor
    var keyText: KeyboardColor
    var candidateText: KeyboardColor
    var candidateSelectedBackground: KeyboardColor
    var panelBackground: KeyboardColor
    var panelBorder: KeyboardColor
    var panelCardBackground: KeyboardColor
    var panelText: KeyboardColor
    var popupSelectedBackground: KeyboardColor
    var popupSelectedText: KeyboardColor

    /// 現行パレット (着せ替え OFF / 未ピック要素のデフォルト)。
    /// 数値は KeyboardCanvas / FlickCanvas / KeyboardViewController が
    /// 従来ハードコードしていた定数と一致させる。
    static func standard(dark: Bool) -> KeyboardPalette {
        if dark {
            return KeyboardPalette(
                background: .gray(0.17), keyFace: .gray(0.38), keyPressed: .gray(0.56),
                keyText: .white, candidateText: .white,
                candidateSelectedBackground: .gray(0.45, alpha: 0.95),
                panelBackground: .gray(0.24), panelBorder: .gray(0.42),
                panelCardBackground: .gray(0.32), panelText: .white,
                popupSelectedBackground: .gray(0.92), popupSelectedText: .black)
        }
        return KeyboardPalette(
            background: .gray(0.82), keyFace: .white, keyPressed: .gray(0.92),
            keyText: .black, candidateText: .black,
            candidateSelectedBackground: .gray(0.45, alpha: 0.95),
            panelBackground: .gray(0.97), panelBorder: .gray(0.72),
            panelCardBackground: .white, panelText: .black,
            popupSelectedBackground: .gray(0.35), popupSelectedText: .white)
    }

    /// カスタム色のうち非 nil の要素だけを上書きした複製を返す。
    func applying(_ custom: CustomAppearance) -> KeyboardPalette {
        var result = self
        if let value = custom.background { result.background = value }
        if let value = custom.keyFace { result.keyFace = value }
        if let value = custom.keyPressed { result.keyPressed = value }
        if let value = custom.keyText { result.keyText = value }
        if let value = custom.candidateText { result.candidateText = value }
        if let value = custom.candidateSelectedBackground { result.candidateSelectedBackground = value }
        if let value = custom.panelBackground { result.panelBackground = value }
        if let value = custom.panelBorder { result.panelBorder = value }
        if let value = custom.panelCardBackground { result.panelCardBackground = value }
        if let value = custom.panelText { result.panelText = value }
        if let value = custom.popupSelectedBackground { result.popupSelectedBackground = value }
        if let value = custom.popupSelectedText { result.popupSelectedText = value }
        return result
    }
}

extension LayoutSettings {
    /// 現在の設定に対する実効パレット。着せ替え OFF では現行パレット
    /// (standard) をそのまま返し、OFF の描画が従来と等価になる。
    /// ピックした色はライト/ダークの両方に同じ色が適用される。
    func resolvedPalette(dark: Bool) -> KeyboardPalette {
        let base = KeyboardPalette.standard(dark: dark)
        guard customizationEnabled else { return base }
        return base.applying(customAppearance)
    }

    /// 背景画像を実際に表示するか (着せ替え ON かつ画像の参照があるとき)。
    var usesBackgroundImage: Bool {
        customizationEnabled && customAppearance.backgroundImageFileName != nil
    }
}

#if canImport(UIKit)
extension KeyboardColor {
    var uiColor: UIColor {
        UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
    /// UIColor から取り込む。グレースケール等の色空間でも sRGB 成分が
    /// 取れる場合は変換し、取れない色は nil を返す。
    init?(uiColor: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        self.init(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
    }
    /// SwiftUI の ColorPicker (Binding<CGColor>) との受け渡し用。
    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
    init?(cgColor: CGColor) {
        guard let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: srgbSpace, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3 else { return nil }
        self.init(red: Double(components[0]), green: Double(components[1]), blue: Double(components[2]),
                  alpha: components.count >= 4 ? Double(components[3]) : 1)
    }
}

/// 背景画像の実体の置き場所 (App Group 共有コンテナ)。
/// ホストアプリが保存・削除し、キーボード拡張は読み込みだけを行う。
/// 保存時は拡張のメモリ上限に配慮し、長辺 1024px へ縮小した JPEG にする。
enum KeyboardBackgroundImageStore {
    static func fileURL(fileName: String) -> URL? {
        guard !fileName.isEmpty, !fileName.contains("/"), !fileName.contains("..") else { return nil }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: KeyboardSettings.appGroupIdentifier)?
            .appendingPathComponent(fileName)
    }

    static func loadImage(fileName: String) -> UIImage? {
        guard let url = fileURL(fileName: fileName) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// 選ばれた画像を縮小して保存し、設定へ入れる参照 (ファイル名) を返す。
    @discardableResult
    static func save(_ image: UIImage) -> String? {
        let name = CustomAppearance.standardBackgroundImageFileName
        guard let url = fileURL(fileName: name) else { return nil }
        let maxEdge: CGFloat = 1024
        let scale = min(1, maxEdge / max(image.size.width, image.size.height))
        let target = CGSize(width: max(1, (image.size.width * scale).rounded()),
                            height: max(1, (image.size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = resized.jpegData(compressionQuality: 0.85) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    static func remove(fileName: String) {
        guard let url = fileURL(fileName: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
