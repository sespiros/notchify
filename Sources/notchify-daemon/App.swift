import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let server = SocketServer()
    var tcpServer: TcpServer?
    let controller = NotchController()
    let updater = Updater.makeIfEnabled()
    var statusBar: StatusBarController?
    private var tcpStartError: Error?
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
        statusBar = StatusBarController(
            updater: updater,
            tcpState: { [weak self] in
                guard let self else { return (false, "Off") }
                return self.tcpMenuState()
            },
            setTcpEnabled: { [weak self] enabled in
                self?.setTcpEnabled(enabled)
            }
        )
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
            try server.start(
                { [weak self] msg in
                    Task { @MainActor in self?.controller.present(msg) }
                },
                onQuit: {
                    NSApp.terminate(nil)
                }
            )
            NSLog("notchify-daemon: listening on \(server.path)")
        } catch {
            NSLog("notchify-daemon: failed to start: \(error)")
            NSApp.terminate(nil)
        }

        startTcpServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tcpServer?.stop()
        server.stop()
    }

    private func installTerminationHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.tcpServer?.stop()
                self?.server.stop()
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func startTcpServer() {
        tcpStartError = nil
        do {
            tcpServer = try TcpServer.configuredFromEnvironment()
            if let tcpServer {
                try tcpServer.start { [weak self] msg in
                    Task { @MainActor in self?.controller.present(msg) }
                }
                NSLog("notchify-daemon: listening on tcp://\(tcpServer.host):\(tcpServer.port)")
            } else {
                NSLog("notchify-daemon: tcp listener disabled")
            }
        } catch {
            NSLog("notchify-daemon: failed to start tcp listener: \(error)")
            tcpStartError = error
            tcpServer = nil
        }
        statusBar?.refreshTcpListenerState()
    }

    private func setTcpEnabled(_ enabled: Bool) {
        TcpListenerSettings.enabled = enabled
        tcpServer?.stop()
        tcpServer = nil
        if enabled {
            startTcpServer()
        } else {
            tcpStartError = nil
            NSLog("notchify-daemon: tcp listener disabled")
            statusBar?.refreshTcpListenerState()
        }
    }

    private func tcpMenuState() -> (Bool, String) {
        guard TcpListenerSettings.enabled else {
            return (false, "Off")
        }
        if ProcessInfo.processInfo.environment["NOTCHIFY_TCP_LISTEN"] == "off" {
            return (false, "Off")
        }
        if let tcpServer {
            return (true, "\(tcpServer.host):\(tcpServer.port)")
        }
        if tcpStartError != nil {
            return (true, "Unavailable")
        }
        return (true, "Starting")
    }
}
