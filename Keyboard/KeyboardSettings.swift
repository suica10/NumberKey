import UIKit

struct KeyboardSettings {
    private let defaults = UserDefaults.standard
    var topKeys: [String] {
        get {
            let saved = defaults.stringArray(forKey: "topKeys") ?? []
            return saved.count == 10 && saved.allSatisfy({ $0.count == 1 })
                ? saved : Array("1234567890").map(String.init)
        }
        nonmutating set { defaults.set(newValue, forKey: "topKeys") }
    }
    var keyHeight: CGFloat {
        get {
            let saved = defaults.double(forKey: "keyHeight")
            return saved == 0 ? 43 : CGFloat(min(56, max(32, saved)))
        }
        nonmutating set { defaults.set(Double(newValue), forKey: "keyHeight") }
    }
    var theme: Int {
        get { min(2, max(0, defaults.integer(forKey: "theme"))) }
        nonmutating set { defaults.set(newValue, forKey: "theme") }
    }
    var japanese: Bool {
        get { defaults.object(forKey: "japanese") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "japanese") }
    }
}
