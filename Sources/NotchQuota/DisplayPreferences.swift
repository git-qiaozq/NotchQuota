import Foundation

extension Notification.Name {
    static let quotaCardVisibilityDidChange = Notification.Name("quotaCardVisibilityDidChange")
    static let quotaTriggerModeDidChange = Notification.Name("quotaTriggerModeDidChange")
}

// 面板触发方式:刘海悬停,或屏幕右上角触发(类触发角)
enum QuotaTriggerMode: String {
    case notch
    case topRightCorner

    var displayName: String {
        switch self {
        case .notch: return "刘海悬停"
        case .topRightCorner: return "右上角触发"
        }
    }
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
        QuotaCardOption(id: "kimi", name: "Kimi"),
        QuotaCardOption(id: "antigravity", name: "Antigravity"),
        QuotaCardOption(id: "deepseek", name: "DeepSeek"),
        QuotaCardOption(id: "opencode-go", name: "OpenCode Go"),
        QuotaCardOption(id: "cursor", name: "Cursor"),
    ]

    private static let hiddenCardIDsKey = "hiddenQuotaCardIDs"
    private static let cardOrderKey = "quotaCardOrder"
    private static let triggerModeKey = "quotaTriggerMode"

    static var triggerMode: QuotaTriggerMode {
        get {
            QuotaTriggerMode(rawValue: UserDefaults.standard.string(forKey: triggerModeKey) ?? "") ?? .notch
        }
        set {
            guard newValue != triggerMode else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: triggerModeKey)
            NotificationCenter.default.post(name: .quotaTriggerModeDidChange, object: nil)
        }
    }

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

    static var orderedCards: [QuotaCardOption] {
        get {
            let savedIDs = UserDefaults.standard.stringArray(forKey: cardOrderKey) ?? []
            let knownByID = Dictionary(uniqueKeysWithValues: knownCards.map { ($0.id, $0) })
            let savedCards = savedIDs.compactMap { knownByID[$0] }
            let savedSet = Set(savedCards.map(\.id))
            let missingCards = knownCards.filter { !savedSet.contains($0.id) }
            return savedCards + missingCards
        }
        set {
            let knownIDs = Set(knownCards.map(\.id))
            let ids = newValue.map(\.id).filter { knownIDs.contains($0) }
            UserDefaults.standard.set(ids, forKey: cardOrderKey)
            NotificationCenter.default.post(name: .quotaCardVisibilityDidChange, object: nil)
        }
    }

    static func setCardOrder(_ cards: [QuotaCardOption]) {
        orderedCards = cards
    }

    static func visibleServices(from services: [QuotaService]) -> [QuotaService] {
        let order = Dictionary(uniqueKeysWithValues: orderedCards.enumerated().map { ($0.element.id, $0.offset) })
        return services
            .filter { isCardVisible(id: $0.id) }
            .sorted {
                let lhs = order[$0.id] ?? Int.max
                let rhs = order[$1.id] ?? Int.max
                if lhs == rhs { return $0.name < $1.name }
                return lhs < rhs
            }
    }
}
