import Foundation

func usage() -> Never {
    FileHandle.standardError.write("usage: notchify [options] <title> [body]\n  options: [-icon <path>] [-symbol <SFSymbolName>] [-color <orange|red|blue|...>] [-sound <ready|warning|info|success|error|<SystemSoundName>>] [-action <url|shell-command>] [-timeout <seconds>]\n  legacy: -title <s> and -text <s> are still accepted as aliases\n".data(using: .utf8)!)
    exit(2)
}

var title: String?
var text: String?
var icon: String?
var symbol: String?
var color: String?
var sound: String?
var action: String?
var timeout: Double?
var positionals: [String] = []

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let flag = args.removeFirst()
    switch flag {
    case "-title":
        guard !args.isEmpty else { usage() }
        title = args.removeFirst()
    case "-text":
        guard !args.isEmpty else { usage() }
        text = args.removeFirst()
    case "-icon":
        guard !args.isEmpty else { usage() }
        icon = args.removeFirst()
    case "-symbol":
        guard !args.isEmpty else { usage() }
        symbol = args.removeFirst()
    case "-color":
        guard !args.isEmpty else { usage() }
        color = args.removeFirst()
    case "-sound":
        guard !args.isEmpty else { usage() }
        sound = args.removeFirst()
    case "-action":
        guard !args.isEmpty else { usage() }
        action = args.removeFirst()
    case "-timeout":
        guard !args.isEmpty, let v = Double(args.removeFirst()) else { usage() }
        timeout = v
    case "-h", "--help":
        usage()
    default:
        if flag.hasPrefix("-") { usage() }
        positionals.append(flag)
    }
}

if title == nil, !positionals.isEmpty {
    title = positionals.removeFirst()
}
if text == nil, !positionals.isEmpty {
    text = positionals.removeFirst()
}
if !positionals.isEmpty { usage() }

guard let title else { usage() }

struct Payload: Codable {
    let title: String
    let text: String?
    let icon: String?
    let symbol: String?
    let color: String?
    let sound: String?
    let action: String?
    let timeout: Double?
}
let payload = Payload(title: title, text: text, icon: icon, symbol: symbol, color: color, sound: sound, action: action, timeout: timeout)
let data = try JSONEncoder().encode(payload)

let path = "/tmp/notchify.sock"
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fputs("socket() failed\n", stderr); exit(1) }
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
    fputs("connect(\(path)) failed: is notchify-daemon running?\n", stderr)
    exit(1)
}
data.withUnsafeBytes { buf in
    _ = write(fd, buf.baseAddress, data.count)
}
