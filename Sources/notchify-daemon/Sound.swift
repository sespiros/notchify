import AppKit

// Generic sound presets that map to macOS system sounds. The CLI accepts
// either a preset name or any system sound name (loaded from
// `/System/Library/Sounds/<name>.aiff`).
enum Sound {
    private static let presets: [String: String] = [
        "ready":   "Glass",
        "warning": "Sosumi",
        "info":    "Pop",
        "success": "Hero",
        "error":   "Basso",
    ]

    // Cache resolved NSSound instances so repeated plays don't re-read
    // the AIFF off disk on every notification.
    private static var cache: [String: NSSound] = [:]

    static func play(_ name: String?) {
        guard let raw = name?.lowercased(), !raw.isEmpty else { return }
        let resolved = presets[raw] ?? raw
        if let cached = cache[resolved] {
            cached.stop()
            cached.play()
            return
        }
        if let s = NSSound(named: NSSound.Name(resolved)) {
            cache[resolved] = s
            s.play()
            return
        }
        let path = "/System/Library/Sounds/\(resolved).aiff"
        if let s = NSSound(contentsOfFile: path, byReference: false) {
            cache[resolved] = s
            s.play()
        }
    }
}
