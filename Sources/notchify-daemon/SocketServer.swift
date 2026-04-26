import Foundation

final class SocketServer {
    let path: String
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "notchify.socket", qos: .userInitiated)
    private var onMessage: ((Message) -> Void)?

    init(path: String = "/tmp/notchify.sock") {
        self.path = path
    }

    func start(_ handler: @escaping (Message) -> Void) throws {
        onMessage = handler
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCap = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                _ = strlcpy(UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self), src, pathCap)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, len)
            }
        }
        guard bindOK == 0 else { throw POSIXError(.EADDRINUSE) }
        chmod(path, 0o600)
        guard listen(listenFD, 8) == 0 else { throw POSIXError(.EIO) }

        queue.async { [weak self] in self?.acceptLoop() }
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
            FileHandle.standardError.write("notchify-daemon: bad payload\n".data(using: .utf8)!)
            return
        }
        DispatchQueue.main.async { self.onMessage?(msg) }
    }
}
