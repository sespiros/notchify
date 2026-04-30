import Foundation

func usage() -> Never {
    FileHandle.standardError.write("usage: notchify [options] <title> [body]\n  options: [-icon <path>] [-symbol <SFSymbolName>] [-color <orange|red|blue|...>] [-sound <ready|warning|info|success|error|<SystemSoundName>>] [-action <url|shell-command>] [-focus] [-timeout <seconds>] [-group <name>] [-group-icon <SFSymbolName>] [-group-color <color>]\n  legacy: -title <s> and -text <s> are still accepted as aliases\n  -focus is incompatible with -action; it builds a click action that\n  raises the source terminal app and (when in tmux) jumps to the\n  originating pane. It also implies -timeout 0 and attaches a dismiss\n  key so the daemon can clear the notification once the user visits\n  its source. Override the auto-detected terminal with the\n  NOTCHIFY_TERMINAL_BUNDLE env var. See Sources/notchify/Focus/ for\n  how to add support for a new terminal or multiplexer.\n  -timeout 0 makes the notification persist until clicked (or\n  focus-dismissed when -focus is set).\n  -group stacks notifications under a named chip on the notch; chip\n  icon/color fall back to the notification's own -symbol/-color.\n".data(using: .utf8)!)
    exit(2)
}

var title: String?
var text: String?
var icon: String?
var symbol: String?
var color: String?
var sound: String?
var action: String?
var focus: Bool = false
var timeout: Double?
var group: String?
var groupIcon: String?
var groupColor: String?
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
    case "-focus":
        focus = true
    case "-timeout":
        guard !args.isEmpty, let v = Double(args.removeFirst()) else { usage() }
        timeout = v
    case "-group":
        guard !args.isEmpty else { usage() }
        group = args.removeFirst()
    case "-group-icon":
        guard !args.isEmpty else { usage() }
        groupIcon = args.removeFirst()
    case "-group-color":
        guard !args.isEmpty else { usage() }
        groupColor = args.removeFirst()
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

var dismissKey: DismissKeyPayload? = nil
if focus {
    if action != nil {
        FileHandle.standardError.write("notchify: -focus and -action are mutually exclusive\n".data(using: .utf8)!)
        exit(2)
    }
    let env = ProcessInfo.processInfo.environment
    let result = buildFocus(env: env)
    if result.action == nil && result.dismissKey == nil {
        FileHandle.standardError.write("notchify: -focus requested but no terminal or tmux context detected; ignoring\n".data(using: .utf8)!)
    }
    action = result.action
    dismissKey = result.dismissKey
    // -focus implies persist: the notification keeps a row in its
    // stack after the in-flight retracts, ready to be dismissed
    // when the user visits the source. The in-flight body itself
    // still auto-retracts after the persistent dwell (4s in the
    // daemon) — only the row's lifetime is extended.
    if timeout == nil {
        timeout = 0
    }
}

struct Payload: Codable {
    let title: String
    let text: String?
    let icon: String?
    let symbol: String?
    let color: String?
    let sound: String?
    let action: String?
    let timeout: Double?
    let group: String?
    let groupIcon: String?
    let groupColor: String?
    let dismissKey: DismissKeyPayload?
}
let payload = Payload(
    title: title,
    text: text,
    icon: icon,
    symbol: symbol,
    color: color,
    sound: sound,
    action: action,
    timeout: timeout,
    group: group,
    groupIcon: groupIcon,
    groupColor: groupColor,
    dismissKey: dismissKey
)
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
