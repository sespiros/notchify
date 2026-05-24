import Foundation

/// Short one-liner shown on bad args. The full options list lives
/// in `help()`, reachable via `-h` / `--help`.
func usage() -> Never {
    let text = "usage: notchify <title> [body] [options] | notchify --daemon quit (run 'notchify -h' for full help)\n"
    FileHandle.standardError.write(text.data(using: .utf8)!)
    exit(2)
}

/// Full help, only shown when the user explicitly asks via -h/--help.
func help() -> Never {
    let text = """
usage: notchify <title> [body] [options]
       notchify --daemon quit

  -i, --icon <name|path>  SF Symbol or image file (default: bell.fill)
                          e.g. checkmark.circle.fill, ~/icons/claude.png
  -c, --color <name>      tint for SF Symbol icons (default: white)
                          orange, red, yellow, green, blue, purple, pink, gray
  -s, --sound <name>      ready | warning | info | success | error
                          or any name from /System/Library/Sounds/ (default: silent)
  -a, --action <url|cmd>  URL opened or shell command run on click
  -f, --focus             raise source terminal / jump to tmux pane on click
                          (mutually exclusive with --action; implies --timeout 0)
  -t, --timeout <secs>    auto-dismiss after N seconds, 0 = persistent (default: 5)
  -g, --group <name>      stack notifications under a named chip;
                          icon/color come from the first arrival in the group
  --daemon quit           quit the running daemon

Examples:
  notchify "Done" "build succeeded"
  notchify "Heads up" "deploy needs input" --icon exclamationmark.triangle.fill --color orange
  notchify "Open" "tap me" --action https://example.com
  notchify "Build done" "ready to commit" -g claude -i ~/icons/claude.png
  notchify --daemon quit

"""
    FileHandle.standardOutput.write(text.data(using: .utf8)!)
    exit(0)
}

var title: String?
var text: String?
var icon: String?
var color: String?
var sound: String?
var action: String?
var focus: Bool = false
var timeout: Double?
var group: String?
var positionals: [String] = []

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "--daemon" {
    args.removeFirst()
    guard args.count == 1, args[0] == "quit" else { usage() }
    struct CommandPayload: Encodable {
        let type = "command"
        let command = "quit"
    }
    try sendToDaemon(try JSONEncoder().encode(CommandPayload()), allowTCPFallback: false)
    exit(0)
}

while !args.isEmpty {
    let flag = args.removeFirst()
    switch flag {
    case "-i", "--icon":
        guard !args.isEmpty else { usage() }
        icon = args.removeFirst()
    case "-c", "--color":
        guard !args.isEmpty else { usage() }
        color = args.removeFirst()
    case "-s", "--sound":
        guard !args.isEmpty else { usage() }
        sound = args.removeFirst()
    case "-a", "--action":
        guard !args.isEmpty else { usage() }
        action = args.removeFirst()
    case "-f", "--focus":
        focus = true
    case "-t", "--timeout":
        guard !args.isEmpty, let v = Double(args.removeFirst()) else { usage() }
        timeout = v
    case "-g", "--group":
        guard !args.isEmpty else { usage() }
        group = args.removeFirst()
    case "-h", "--help":
        help()
    default:
        if flag.hasPrefix("-") { usage() }
        positionals.append(flag)
    }
}

if !positionals.isEmpty {
    title = positionals.removeFirst()
}
if !positionals.isEmpty {
    text = positionals.removeFirst()
}
if !positionals.isEmpty { usage() }

guard let title else { usage() }

var dismissKey: DismissKeyPayload? = nil
if focus {
    if action != nil {
        FileHandle.standardError.write("notchify: --focus and --action are mutually exclusive\n".data(using: .utf8)!)
        exit(2)
    }
    let env = ProcessInfo.processInfo.environment
    let result = buildFocus(env: env)
    if result.action == nil && result.dismissKey == nil {
        FileHandle.standardError.write("notchify: --focus requested but no terminal or tmux context detected; ignoring\n".data(using: .utf8)!)
    }
    action = result.action
    dismissKey = result.dismissKey
    // --focus implies persist: the notification keeps a row in its
    // stack after the in-flight retracts, ready to be dismissed
    // when the user visits the source.
    if timeout == nil {
        timeout = 0
    }
}

struct Payload: Codable {
    let title: String
    let text: String?
    let icon: String?
    let color: String?
    let sound: String?
    let action: String?
    let timeout: Double?
    let group: String?
    let dismissKey: DismissKeyPayload?
}
let payload = Payload(
    title: title,
    text: text,
    icon: icon,
    color: color,
    sound: sound,
    action: action,
    timeout: timeout,
    group: group,
    dismissKey: dismissKey
)
let data = try JSONEncoder().encode(payload)

try sendToDaemon(data, allowTCPFallback: true)

func sendToDaemon(_ data: Data, allowTCPFallback: Bool) throws {
    let path = "/tmp/notchify.sock"
    if sendToUnixSocket(data, path: path) {
        return
    }
    if allowTCPFallback, sendToTcpListener(data) {
        return
    }
    fputs("connect(\(path)) failed: is notchify-daemon running?\n", stderr)
    exit(1)
}

func sendToUnixSocket(_ data: Data, path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathCap = MemoryLayout.size(ofValue: addr.sun_path)
    path.withCString { src in
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            _ = strlcpy(UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self), src, pathCap)
        }
    }
    let connectOK = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectOK == 0 else {
        return false
    }
    data.withUnsafeBytes { buf in
        _ = write(fd, buf.baseAddress, data.count)
    }
    return true
}

func sendToTcpListener(_ data: Data) -> Bool {
    let env = ProcessInfo.processInfo.environment
    let host = env["NOTCHIFY_TCP_HOST"].flatMap { $0.isEmpty ? nil : $0 } ?? "127.0.0.1"
    let port = env["NOTCHIFY_TCP_PORT"].flatMap(UInt16.init) ?? 43187
    var hints = addrinfo(
        ai_flags: 0,
        ai_family: AF_INET,
        ai_socktype: SOCK_STREAM,
        ai_protocol: IPPROTO_TCP,
        ai_addrlen: 0,
        ai_canonname: nil,
        ai_addr: nil,
        ai_next: nil
    )
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else {
        return false
    }
    defer { freeaddrinfo(first) }

    var cursor: UnsafeMutablePointer<addrinfo>? = first
    while let info = cursor {
        defer { cursor = info.pointee.ai_next }
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { continue }
        let connected = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0
        if connected {
            data.withUnsafeBytes { buf in
                _ = write(fd, buf.baseAddress, data.count)
            }
            close(fd)
            return true
        }
        close(fd)
    }
    return false
}
