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
                // Default to Ignore: both mute policies need Full Disk
                // Access to read Focus state, so a fresh install opts out
                // of muting (and the FDA prompt) until the user picks one.
                return .ignore
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

    // ~/Library/DoNotDisturb is gated behind Full Disk Access. A
    // normally-launched app (login / launchd / `open`) gets
    // NSFileReadNoPermission (257) here and can't see Focus state at
    // all; only a process that inherits the terminal's FDA (e.g.
    // `swift run`) can. See hasFullDiskAccess().
    private static let assertionsPath =
        ("~/Library/DoNotDisturb/DB/Assertions.json" as NSString).expandingTildeInPath

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

    // Whether the daemon can actually read the Focus assertions file.
    // Without Full Disk Access the read fails with 257 and currentState()
    // silently reports .inactive, so every Focus leaks through unmuted.
    // A genuinely missing file (260, no Focus DB yet) still counts as
    // accessible: "no file" legitimately means "no Focus active". This
    // is what the menu uses to surface the "Grant Full Disk Access"
    // nudge instead of failing silently.
    static func hasFullDiskAccess() -> Bool {
        do {
            _ = try Data(contentsOf: URL(fileURLWithPath: assertionsPath))
            return true
        } catch {
            let e = error as NSError
            return e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError
        }
    }

    static func currentState() -> State {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: assertionsPath)) else {
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
