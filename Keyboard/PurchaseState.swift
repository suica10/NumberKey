import Foundation
#if canImport(Security)
import Security
#endif

/// 販売ビルド（v0.3.30）の購入/トライアル状態。
/// `unlocked` = 買い切り済み、`trial` = 体験期間中（残日数つき）、`expired` = 期限切れ。
enum PurchaseState: Equatable {
    case unlocked
    case trial(daysLeft: Int)
    case expired
}

/// 状態判定の純粋ロジック。StoreKit・Keychain・UserDefaults に依存しないため
/// CI で単体テストできる（Tests/PurchaseStateTests.swift）。
enum PurchaseLogic {
    /// App Store Connect 側で作る非消耗型プロダクト。価格は Connect 側設定。
    static let productID = "jp.onejpkey.NumberKey.full"
    /// 体験期間は 7 日間ちょうど。
    static let trialDuration: TimeInterval = 7 * 24 * 60 * 60
    static var fullTrialDays: Int { Int(trialDuration / 86_400) }

    /// - Parameters:
    ///   - trialStart: Keychain から読めたトライアル開始日時。`nil` は「未記録」
    ///     または「読み取り失敗」のどちらかで、呼び出し側は区別しない。
    ///   - unlocked: App Group の購入済みフラグ。
    /// フェイルオープン原則: ロック（`expired`）になるのは「trialStart が読めて、
    /// 7 日を超過し、未購入」が確定したときだけ。情報が欠けたら trial 扱いにする。
    static func evaluate(trialStart: Date?, unlocked: Bool, now: Date) -> PurchaseState {
        if unlocked { return .unlocked }
        guard let trialStart else { return .trial(daysLeft: fullTrialDays) }
        let remaining = trialDuration - now.timeIntervalSince(trialStart)
        if remaining <= 0 { return .expired }
        // 残り時間を日単位に切り上げる（開始直後は 7、最後の 24 時間は 1）。
        // 時計が巻き戻って remaining が trialDuration を超えても fullTrialDays に丸める。
        let daysLeft = min(fullTrialDays, Int((remaining / 86_400).rounded(.up)))
        return .trial(daysLeft: daysLeft)
    }
}

/// トライアル開始日時を Keychain に保存する。
/// 保存先はアプリ/拡張共通の keychain-access-groups（エンタイトルメントの先頭に
/// 置いた共有グループ）。クエリにアクセスグループを指定しないことで、先頭の
/// グループが読み書きの対象になる前提にしている。
/// Feather 再署名などでグループが壊れている場合は全操作が失敗し、読み取りは
/// nil（＝trial 扱い）になる。これがフェイルオープンの要。
enum TrialStartStore {
    private static let service = "jp.onejpkey.NumberKey.trial"
    private static let account = "trialStart"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// 開始日時を読む。未記録・読み取り失敗はどちらも nil。
    static func read() -> Date? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8),
              let seconds = TimeInterval(text) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// まだ記録がなければ開始日時を書く（既存の記録は上書きしない＝再インストール
    /// しても Keychain が残る限りトライアルはリセットされない）。
    /// 戻り値は書き込みに成功したかどうか。失敗しても呼び出し側は trial 扱いを続ける。
    @discardableResult
    static func recordStartIfNeeded(now: Date) -> Bool {
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(String(now.timeIntervalSince1970).utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }
}

/// 購入済みフラグは App Group の UserDefaults で共有する。
/// 書き込みはホストアプリ（購入・復元の確認後）だけが行い、拡張は読むだけ。
enum PurchaseFlags {
    // KeyboardSettings.appGroupIdentifier と一致させること（あちらは変更しない）。
    static let appGroupIdentifier = "group.jp.onejpkey.NumberKey"
    private static let unlockedKey = "purchase.unlocked.v1"

    static var isUnlocked: Bool {
        UserDefaults(suiteName: appGroupIdentifier)?.bool(forKey: unlockedKey) ?? false
    }
    static func setUnlocked(_ value: Bool) {
        UserDefaults(suiteName: appGroupIdentifier)?.set(value, forKey: unlockedKey)
    }
}

/// アプリ/拡張の両方から使う評価ファサード。
enum PurchaseGate {
    /// 読み取り専用の評価。
    static func currentState(now: Date = Date()) -> PurchaseState {
        PurchaseLogic.evaluate(trialStart: TrialStartStore.read(),
                               unlocked: PurchaseFlags.isUnlocked, now: now)
    }

    /// 表示時に呼ぶ評価。トライアル開始が未記録なら、ここで記録して時計を進め始める。
    /// 記録に失敗しても trial として返す（フェイルオープン）。
    static func evaluateForDisplay(now: Date = Date()) -> PurchaseState {
        if !PurchaseFlags.isUnlocked, TrialStartStore.read() == nil {
            TrialStartStore.recordStartIfNeeded(now: now)
            return .trial(daysLeft: PurchaseLogic.fullTrialDays)
        }
        return currentState(now: now)
    }
}
