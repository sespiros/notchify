import Foundation

enum TcpListenerSettings {
    private static let enabledKey = "TcpListenerEnabled"

    static var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }
}

final class TcpServer {
    let host: String
    let port: UInt16
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "notchify.tcp", qos: .userInitiated)
    private var onMessage: ((Message) -> Void)?

    init(host: String = "127.0.0.1", port: UInt16 = 43187) throws {
        guard TcpServer.isLoopback(host) else {
            throw TcpServerError.nonLoopbackBind(host)
        }
        self.host = host
        self.port = port
    }

    static func configuredFromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> TcpServer? {
        guard TcpListenerSettings.enabled else {
            return nil
        }
        guard let listen = env["NOTCHIFY_TCP_LISTEN"], !listen.isEmpty else {
            return try TcpServer()
        }
        if listen == "off" {
            return nil
        }
        let endpoint = try parseEndpoint(listen)
        return try TcpServer(host: endpoint.host, port: endpoint.port)
    }

    deinit {
        stop()
    }

    func start(_ handler: @escaping (Message) -> Void) throws {
        onMessage = handler

        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EIO) }

        var reuse: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = try socketAddress()
        let bindOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else {
            let bindErrno = errno
            stop()
            throw POSIXError(POSIXErrorCode(rawValue: bindErrno) ?? .EIO)
        }

        guard listen(listenFD, 8) == 0 else {
            stop()
            throw POSIXError(.EIO)
        }

        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
    }

    private func socketAddress() throws -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian

        let bindHost = host == "localhost" ? "127.0.0.1" : host
        guard inet_pton(AF_INET, bindHost, &addr.sin_addr) == 1 else {
            throw TcpServerError.invalidHost(host)
        }
        return addr
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { continue }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(client: client)
            }
        }
    }

    private func handle(client: Int32) {
        defer { close(client) }
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = read(client, &buf, buf.count)
        guard n > 0 else { return }

        let data = Data(buf.prefix(Int(n)))
        guard let msg = try? JSONDecoder().decode(Message.self, from: data) else {
            FileHandle.standardError.write("notchify-daemon: bad tcp payload\n".data(using: .utf8)!)
            return
        }

        // Strip the raw `action` field: TCP is an untrusted boundary
        // (loopback-only today, but the principle stands), and `action`
        // carries a shell string that the daemon would `sh -c` on click.
        // Keep `focus`: it's structured data (bundle/tmux pane/tty),
        // not executable code. The daemon resolves it into a safe shell
        // action at click time via FocusActionBuilder, with proper
        // shell quoting on the values it embeds.
        let sanitized = Message(
            title: msg.title,
            text: msg.text,
            icon: msg.icon,
            color: msg.color,
            sound: msg.sound,
            action: nil,
            timeout: msg.timeout,
            group: msg.group,
            focus: msg.focus
        )
        DispatchQueue.main.async { self.onMessage?(sanitized) }
    }

    private static func parseEndpoint(_ listen: String) throws -> (host: String, port: UInt16) {
        guard let colon = listen.lastIndex(of: ":") else {
            throw TcpServerError.invalidEndpoint(listen)
        }
        let host = String(listen[..<colon])
        let portString = String(listen[listen.index(after: colon)...])
        guard !host.isEmpty, let port = UInt16(portString) else {
            throw TcpServerError.invalidEndpoint(listen)
        }
        return (host, port)
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" {
            return true
        }
        return host == "127.0.0.1" || host.hasPrefix("127.")
    }
}

private enum TcpServerError: LocalizedError {
    case invalidEndpoint(String)
    case invalidHost(String)
    case nonLoopbackBind(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let value):
            return "invalid NOTCHIFY_TCP_LISTEN endpoint '\(value)', expected host:port"
        case .invalidHost(let host):
            return "invalid TCP bind host '\(host)'"
        case .nonLoopbackBind(let host):
            return "refusing non-loopback TCP bind host '\(host)'"
        }
    }
}
