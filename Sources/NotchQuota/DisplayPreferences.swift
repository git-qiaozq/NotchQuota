import Foundation

extension Notification.Name {
    static let quotaCardVisibilityDidChange = Notification.Name("quotaCardVisibilityDidChange")
}

struct QuotaCardOption {
    let id: String
    let name: String
}

enum QuotaDisplayPreferences {
    static let knownCards: [QuotaCardOption] = [
        QuotaCardOption(id: "codex", name: "Codex"),
        QuotaCardOption(id: "claude", name: "Claude"),
        QuotaCardOption(id: "hermes", name: "Z.AI"),
        QuotaCardOption(id: "antigravity", name: "Antigravity"),
    ]

    private static let hiddenCardIDsKey = "hiddenQuotaCardIDs"

    static var hiddenCardIDs: Set<String> {
        get {
            let ids = UserDefaults.standard.stringArray(forKey: hiddenCardIDsKey) ?? []
            return Set(ids)
        }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: hiddenCardIDsKey)
            NotificationCenter.default.post(name: .quotaCardVisibilityDidChange, object: nil)
        }
    }

    static func isCardVisible(id: String) -> Bool {
        !hiddenCardIDs.contains(id)
    }

    static func setCardVisible(id: String, visible: Bool) {
        var hidden = hiddenCardIDs
        if visible {
            hidden.remove(id)
        } else {
            hidden.insert(id)
        }
        hiddenCardIDs = hidden
    }

    static func visibleServices(from services: [QuotaService]) -> [QuotaService] {
        services.filter { isCardVisible(id: $0.id) }
    }
}
