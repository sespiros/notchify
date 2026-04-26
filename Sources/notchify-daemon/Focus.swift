import Foundation

// Read macOS Focus / Do-Not-Disturb state. macOS 12+ stores active Focus
// "assertions" in ~/Library/DoNotDisturb/DB/Assertions.json. Any assertion
// in storeAssertionRecords means a Focus mode is currently active.
enum Focus {
    static func doNotDisturbActive() -> Bool {
        let path = ("~/Library/DoNotDisturb/DB/Assertions.json" as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return false
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if let entries = json["data"] as? [[String: Any]],
           let first = entries.first,
           let records = first["storeAssertionRecords"] as? [Any],
           !records.isEmpty {
            return true
        }
        return false
    }
}
