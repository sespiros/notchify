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

// Read macOS Focus / Do-Not-Disturb state from ~/Library/DoNotDisturb/DB.
// There is no public API, so this reads two private files and treats
// unknown active modes as "other Focus" rather than Do Not Disturb:
//
//   Assertions.json         Focus modes toggled on manually ON THIS MAC
//                           write a store assertion record here.
//   ModeConfigurations.json Schedule-triggered Focus (e.g. a Work mode
//                           set for weekday work hours) activates with
//                           NO assertion record anywhere, so it has to
//                           be computed from the configured schedule
//                           triggers. Muting for a scheduled Work focus
//                           silently never engaging (macOS 26) is what
//                           forced the two-source read.
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
    private static let dbDir =
        ("~/Library/DoNotDisturb/DB" as NSString).expandingTildeInPath
    private static let assertionsPath = dbDir + "/Assertions.json"
    private static let modeConfigurationsPath = dbDir + "/ModeConfigurations.json"

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

    static func currentState(now: Date = Date()) -> State {
        if let asserted = assertedState() {
            return asserted
        }
        return scheduledState(now: now)
    }

    private static func state(forMode mode: String?) -> State {
        mode == "com.apple.donotdisturb.mode.default" ? .doNotDisturb : .otherFocus
    }

    private static func readJSON(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func assertionsEntry() -> [String: Any]? {
        guard let json = readJSON(assertionsPath),
              let entries = json["data"] as? [[String: Any]] else {
            return nil
        }
        return entries.first
    }

    // A Focus mode toggled on manually on this Mac, or nil when no
    // assertion record exists (which does NOT mean no Focus is active:
    // scheduled activations never write one, see scheduledState).
    private static func assertedState() -> State? {
        guard let entry = assertionsEntry(),
              let records = entry["storeAssertionRecords"] as? [[String: Any]],
              let record = records.first else {
            return nil
        }
        let details = record["assertionDetails"] as? [String: Any]
        return state(forMode: details?["assertionDetailsModeIdentifier"] as? String)
    }

    // When the user manually changes Focus state (including ending a
    // scheduled Focus early), macOS stamps an invalidation request in
    // Assertions.json. A request stamped inside a schedule window means
    // the user opted out of that window; the next window starts after
    // the stamp, so the schedule resumes on its own.
    private static func latestInvalidationRequest() -> Date? {
        guard let entry = assertionsEntry(),
              let requests = entry["storeInvalidationRequestRecords"] as? [[String: Any]] else {
            return nil
        }
        let stamps = requests.compactMap { $0["invalidationRequestDateTimestamp"] as? Double }
        guard let latest = stamps.max() else { return nil }
        return Date(timeIntervalSinceReferenceDate: latest)
    }

    private static func scheduledState(now: Date) -> State {
        guard let json = readJSON(modeConfigurationsPath),
              let entries = json["data"] as? [[String: Any]] else {
            return .inactive
        }
        let optOut = latestInvalidationRequest()
        let calendar = Calendar.current
        for entry in entries {
            guard let configs = entry["modeConfigurations"] as? [String: [String: Any]] else {
                continue
            }
            for (modeID, config) in configs {
                guard let box = config["triggers"] as? [String: Any],
                      let triggers = box["triggers"] as? [[String: Any]] else {
                    continue
                }
                for trigger in triggers {
                    // Only time schedules are computable here; workout /
                    // sleep triggers have no local truth to evaluate.
                    // enabledSetting: 2 = on, 1 = off, 0 = unset.
                    guard trigger["class"] as? String == "DNDModeConfigurationScheduleTrigger",
                          trigger["enabledSetting"] as? Int == 2,
                          let windowStart = activeWindowStart(
                              trigger: trigger, now: now, calendar: calendar)
                    else { continue }
                    if let optOut, optOut >= windowStart, optOut <= now {
                        continue
                    }
                    return state(forMode: modeID)
                }
            }
        }
        return .inactive
    }

    // timePeriodWeekdays is a Monday-first bitmask (Monday == bit 0);
    // Calendar.weekday is 1 = Sunday ... 7 = Saturday.
    private static func weekdayBit(_ date: Date, _ calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    // The start of the schedule window covering `now`, or nil. The
    // window may have started yesterday when it crosses midnight; the
    // weekday mask applies to the day the window STARTS.
    private static func activeWindowStart(
        trigger: [String: Any], now: Date, calendar: Calendar
    ) -> Date? {
        guard let startHour = trigger["timePeriodStartTimeHour"] as? Int,
              let weekdays = trigger["timePeriodWeekdays"] as? Int else {
            return nil
        }
        let startMinute = trigger["timePeriodStartTimeMinute"] as? Int ?? 0
        let endHour = trigger["timePeriodEndTimeHour"] as? Int ?? startHour
        let endMinute = trigger["timePeriodEndTimeMinute"] as? Int ?? 0
        for dayOffset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now),
                  let start = calendar.date(
                      bySettingHour: startHour, minute: startMinute, second: 0, of: day),
                  var end = calendar.date(
                      bySettingHour: endHour, minute: endMinute, second: 0, of: day)
            else { continue }
            if end <= start {
                guard let wrapped = calendar.date(byAdding: .day, value: 1, to: end) else {
                    continue
                }
                end = wrapped
            }
            guard start <= now, now < end,
                  weekdays & (1 << weekdayBit(start, calendar)) != 0 else {
                continue
            }
            return start
        }
        return nil
    }
}
