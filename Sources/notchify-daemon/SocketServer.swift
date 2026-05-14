import Foundation

final class SocketServer {
    let path: String
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "notchify.socket", qos: .userInitiated)
    private var onMessage: ((Message) -> Void)?
    private var ownsSocketPath = false

    init(path: String = "/tmp/notchify.sock") {
        self.path = path
    }

    deinit {
        stop()
    }

    func start(_ handler: @escaping (Message) -> Void) throws {
        onMessage = handler

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EIO) }

        var addr = socketAddress()
        if bindSocket(to: &addr) != 0 {
            let bindErrno = errno
            guard bindErrno == EADDRINUSE else {
                stop()
                throw POSIXError(POSIXErrorCode(rawValue: bindErrno) ?? .EIO)
            }
            try removeStaleSocketPath()
            if bindSocket(to: &addr) != 0 {
                let retryErrno = errno
                stop()
                throw POSIXError(POSIXErrorCode(rawValue: retryErrno) ?? .EADDRINUSE)
            }
        }
        ownsSocketPath = true
        chmod(path, 0o600)
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
        if ownsSocketPath {
            unlink(path)
            ownsSocketPath = false
        }
    }

    private func socketAddress() -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCap = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                _ = strlcpy(UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self), src, pathCap)
            }
        }
        return addr
    }

    private func bindSocket(to addr: inout sockaddr_un) -> Int32 {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private func removeStaleSocketPath() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }

        var addr = socketAddress()
        let connectOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectOK == 0 {
            throw POSIXError(.EADDRINUSE)
        }

        unlink(path)
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
