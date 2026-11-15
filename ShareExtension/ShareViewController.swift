import UIKit
import UniformTypeIdentifiers

/// 共有シートから受け取ったテキストを、One Keyboard のクリップボード履歴
/// （App Group 共有）へ追加する共有拡張。キーボードが起動していない
/// 状態でも取り込めるようにするための入り口。
/// 履歴本体は ClipboardHistoryStore（キーボード側と同一クラス・同一保存先）。
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private var didComplete = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.text = "One Keyboard"
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textAlignment = .center

        statusLabel.text = "読み込んでいます…"
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        let doneButton = UIButton(type: .system)
        doneButton.setTitle("完了", for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        doneButton.addAction(UIAction { [weak self] _ in self?.complete() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, statusLabel, doneButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])

        collectSharedText()
    }

    private func collectSharedText() {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }
        guard !providers.isEmpty else {
            statusLabel.text = "テキストが見つかりませんでした"
            return
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var texts: [String] = []
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { value, _ in
                defer { group.leave() }
                var text: String?
                switch value {
                case let string as String: text = string
                case let data as Data: text = String(data: data, encoding: .utf8)
                case let url as URL: text = url.absoluteString
                default: break
                }
                if let text {
                    lock.lock()
                    texts.append(text)
                    lock.unlock()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            // ClipboardHistoryStore.record と同じ条件で保存できるものだけ数える
            let valid = texts.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.count <= ClipboardHistoryStore.maxLength
            }
            guard !valid.isEmpty else {
                self.statusLabel.text = "保存できるテキストがありませんでした"
                return
            }
            let store = ClipboardHistoryStore()
            for text in valid { store.record(text) }
            self.statusLabel.text = "クリップボード履歴に保存しました"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.complete()
            }
        }
    }

    private func complete() {
        guard !didComplete else { return }
        didComplete = true
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
