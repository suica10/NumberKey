import Foundation

/// クリップボード文字列の整形。ペーストボタン（build 95）と定型文の
/// 取り込み（pasteIntoCapture）で同じ規則を使うため、純粋関数として
/// 切り出してある。UIPasteboard の読み取り自体は呼び出し側の責務で、
/// ここは文字列の整形だけを担う。
enum PasteText {
    /// 文書へ直接挿入できる形に整える。改行コードは \n に統一し、
    /// 改行以外の制御文字を落とす（従来の pasteIntoCapture と同じ規則）。
    static func sanitized(_ raw: String) -> String {
        let lineNormalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var result = ""
        for scalar in lineNormalized.unicodeScalars {
            if scalar == "\n" { result.append("\n") }
            else if !CharacterSet.controlCharacters.contains(scalar) { result.unicodeScalars.append(scalar) }
        }
        return result
    }

    /// ペーストボタンのラベルに出す1行プレビュー。改行・タブは空白に
    /// 畳み、前後の空白を落として、長い場合は先頭 maxLength 文字＋…。
    static func preview(_ text: String, maxLength: Int = 12) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard oneLine.count > maxLength else { return oneLine }
        return String(oneLine.prefix(maxLength)) + "…"
    }
}
