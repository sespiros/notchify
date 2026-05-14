import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let server = SocketServer()
    let controller = NotchController()
    let updater = Updater.makeIfEnabled()
    var statusBar: StatusBarController?
    private var screenObserver: NSObjectProtocol?
    private var signalSources: [DispatchSourceSignal] = []

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationHandlers()
        statusBar = StatusBarController(updater: updater)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak controller] _ in
            Task { @MainActor in
                controller?.screenConfigurationDidChange()
            }
        }
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

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    private func installTerminationHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.server.stop()
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
