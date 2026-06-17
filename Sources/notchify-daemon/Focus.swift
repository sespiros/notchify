import Foundation

enum FocusPolicy: String, CaseIterable {
    case ignore
    case doNotDisturbOnly
    case anyFocus

    private static let defaultsKey = "FocusPolicy"
    static let didChangeNotification = Notification.Name("NotchifyFocusPolicyDidChange")

    // Canonical bundle id of the shipped app; also the name of the
    // preferences domain the policy is persisted in.
    private static let suiteName = "cloud.seimenis.notchify"

    // The policy must resolve to the same value for every build, not
    // just the bundled .app. Unbundled daemons (`swift run`, tests)
    // have no bundle id, so `UserDefaults.standard` targets a different
    // domain that lacks the user's choice and silently falls back to
    // the default, which is how Focus notifications leaked through when
    // a dev build was running. Target the app's named domain directly.
    // (UserDefaults rejects a suite name equal to the running bundle's
    // own id, so the bundled app keeps using `.standard`, which already
    // points at this same domain.)
    private static var store: UserDefaults {
        if Bundle.main.bundleIdentifier == suiteName { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    static var current: FocusPolicy {
        get {
            guard let raw = store.string(forKey: defaultsKey),
                  let policy = FocusPolicy(rawValue: raw) else {
                return .doNotDisturbOnly
            }
            return policy
        }
        set {
            store.set(newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    var title: String {
        switch self {
        case .ignore: return "Ignore Focus Modes"
        case .doNotDisturbOnly: return "Mute for Do Not Disturb Only"
        case .anyFocus: return "Mute for Any Focus Mode"
        }
    }
}

// Read macOS Focus / Do-Not-Disturb state. macOS stores active Focus
// "assertions" in ~/Library/DoNotDisturb/DB/Assertions.json. This is
// not a public API, so unknown active modes are treated as "other
// Focus" rather than Do Not Disturb.
enum Focus {
    enum State {
        case inactive
        case doNotDisturb
        case otherFocus
    }

    static func shouldMute() -> Bool {
        switch FocusPolicy.current {
        case .ignore:
            return false
        case .doNotDisturbOnly:
            return currentState() == .doNotDisturb
        case .anyFocus:
            return currentState() != .inactive
        }
    }

    static func currentState() -> State {
        let path = ("~/Library/DoNotDisturb/DB/Assertions.json" as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return .inactive
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .inactive
        }
        if let entries = json["data"] as? [[String: Any]],
           let first = entries.first,
           let records = first["storeAssertionRecords"] as? [[String: Any]],
           let record = records.first {
            let details = record["assertionDetails"] as? [String: Any]
            let mode = details?["assertionDetailsModeIdentifier"] as? String
            return mode == "com.apple.donotdisturb.mode.default"
                ? .doNotDisturb
                : .otherFocus
        }
        return .inactive
    }
}
