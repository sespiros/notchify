import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let server = SocketServer()
    let controller = NotchController()
    var statusBar: StatusBarController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
        do {
            try server.start { [weak self] msg in
                Task { @MainActor in self?.controller.present(msg) }
            }
            NSLog("notchify-daemon: listening on \(server.path)")
        } catch {
            NSLog("notchify-daemon: failed to start: \(error)")
            NSApp.terminate(nil)
        }
    }
}
