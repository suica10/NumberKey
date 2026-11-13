import XCTest
@testable import PhraseStore

/// 販売ビルドの状態機械（PurchaseLogic）の単体テスト。
/// StoreKit・Keychain には触れない純粋ロジックだけを対象にする。
final class PurchaseStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var hour: TimeInterval { 3_600 }
    private var day: TimeInterval { 24 * 3_600 }

    private func evaluate(start: Date?, unlocked: Bool = false) -> PurchaseState {
        PurchaseLogic.evaluate(trialStart: start, unlocked: unlocked, now: now)
    }

    func testPurchasedIsAlwaysUnlocked() {
        XCTAssertEqual(evaluate(start: nil, unlocked: true), .unlocked)
        XCTAssertEqual(evaluate(start: now.addingTimeInterval(-30 * day), unlocked: true), .unlocked)
    }

    func testMissingStartIsTrialWithFullDays() {
        // 未記録・読み取り失敗はどちらも nil → フェイルオープンで trial 扱い。
        XCTAssertEqual(evaluate(start: nil), .trial(daysLeft: 7))
    }

    func testStartNowShowsSevenDays() {
        XCTAssertEqual(evaluate(start: now), .trial(daysLeft: 7))
    }

    func testOneDayElapsedShowsSixDays() {
        XCTAssertEqual(evaluate(start: now.addingTimeInterval(-day)), .trial(daysLeft: 6))
    }

    func testLastDayShowsOneDay() {
        // 残り 23 時間 → 切り上げで 1 日。
        XCTAssertEqual(evaluate(start: now.addingTimeInterval(-(6 * day + hour))), .trial(daysLeft: 1))
        // 残りちょうど 24 時間でも 1 日。
        XCTAssertEqual(evaluate(start: now.addingTimeInterval(-6 * day)), .trial(daysLeft: 1))
    }

    func testJustBeforeExpiryIsStillTrial() {
        XCTAssertEqual(evaluate(start: now.addingTimeInterval(-(7 * day - 1))), .trial(daysLeft: 1))
    }

    func testExactlySevenDaysIsExpired() {
        XCTAssertEqual(evaluate(start: now.addingTimeInterval(-7 * day)), .expired)
    }

    func testLongPastExpiryIsExpired() {
        XCTAssertEqual(evaluate(start: now.addingTimeInterval(-30 * day)), .expired)
    }

    func testFutureStartIsClampedToFullTrial() {
        // 端末の時計が巻き戻った場合も 7 日を超えて表示しない。
        XCTAssertEqual(evaluate(start: now.addingTimeInterval(2 * day)), .trial(daysLeft: 7))
    }

    func testProductIDAndTrialLength() {
        XCTAssertEqual(PurchaseLogic.productID, "jp.onejpkey.NumberKey.full")
        XCTAssertEqual(PurchaseLogic.fullTrialDays, 7)
        XCTAssertEqual(PurchaseLogic.trialDuration, 7 * 24 * 60 * 60)
    }
}
