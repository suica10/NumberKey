import Foundation
import StoreKit

/// 買い切りプロダクト（jp.onejpkey.NumberKey.full）の購入・復元を担う。
/// 購入状態の正は StoreKit の Transaction.currentEntitlements とし、
/// 確認できたら App Group の unlocked フラグへ写す（拡張はフラグだけを見る）。
@MainActor
final class StoreManager: ObservableObject {
    @Published private(set) var product: Product?
    @Published private(set) var isPurchased = false
    @Published private(set) var isWorking = false
    @Published var message: String?

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task.detached { [weak self] in
            // 購入の完了・返金などをアプリ起動中も拾う。
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
                await self?.refreshEntitlements()
            }
        }
        Task { await refresh() }
    }

    deinit { updatesTask?.cancel() }

    /// 商品情報の取得と購入状態の再確認。
    func refresh() async {
        if let products = try? await Product.products(for: [PurchaseLogic.productID]),
           let found = products.first {
            product = found
        }
        await refreshEntitlements()
    }

    func purchase() async {
        guard let product else {
            message = "商品情報を読み込めませんでした。通信環境を確認して、もう一度お試しください。"
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await refreshEntitlements()
                    if !isPurchased { message = "購入を確認できませんでした。" }
                } else {
                    message = "購入を確認できませんでした。"
                }
            case .userCancelled:
                break
            case .pending:
                message = "購入手続きが保留中です。完了すると自動で反映されます。"
            @unknown default:
                break
            }
        } catch {
            message = "購入に失敗しました。通信環境を確認して、もう一度お試しください。"
        }
    }

    /// 「購入を復元」: App Store と同期してから権利を再確認する。
    func restore() async {
        isWorking = true
        defer { isWorking = false }
        try? await AppStore.sync()
        await refreshEntitlements()
        if !isPurchased {
            message = "復元できる購入が見つかりませんでした。"
        }
    }

    func refreshEntitlements() async {
        var entitled = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == PurchaseLogic.productID,
               transaction.revocationDate == nil {
                entitled = true
            }
        }
        isPurchased = entitled
        if entitled { PurchaseFlags.setUnlocked(true) }
    }
}
