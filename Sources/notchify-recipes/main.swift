import Foundation

// notchify-recipes: thin wrapper around recipe shell scripts.
//
// Subcommands:
//   list                       enumerate available recipes
//   install <name> [--prefix DIR] [--dry-run]
//   uninstall <name> [--prefix DIR] [--dry-run]
//   status                     compare bundled vs installed VERSION
//
// Recipes are resolved (in order) from:
//   1. $NOTCHIFY_RECIPES_DIR
//   2. <binary-dir>/../share/notchify/recipes  (nix / brew / app bundle)
//   3. <binary-dir>/../../recipes               (swift run, repo layout)

func usage() -> Never {
    let text = """
usage: notchify-recipes <command> [args]

  list                              list available recipes
  install <name> [opts]             install a recipe
  uninstall <name> [opts]           remove a recipe
  status                            show installed vs available versions

options for install / uninstall:
  --prefix DIR                      destination root (default: $HOME)
  --dry-run                         print actions without executing

"""
    FileHandle.standardError.write(text.data(using: .utf8)!)
    exit(2)
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write("error: \(msg)\n".data(using: .utf8)!)
    exit(1)
}

func recipesDir() -> String {
    if let env = ProcessInfo.processInfo.environment["NOTCHIFY_RECIPES_DIR"], !env.isEmpty {
        return env
    }
    let exe = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
    let binDir = exe.deletingLastPathComponent()
    let candidates = [
        binDir.appendingPathComponent("../share/notchify/recipes").path,
        binDir.appendingPathComponent("../../recipes").path,
        binDir.appendingPathComponent("../../../recipes").path,
    ]
    let fm = FileManager.default
    for c in candidates {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: c, isDirectory: &isDir), isDir.boolValue {
            return URL(fileURLWithPath: c).standardized.path
        }
    }
    die("could not locate recipes directory; set NOTCHIFY_RECIPES_DIR")
}

func listRecipes(_ root: String) -> [String] {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
    return entries.filter { name in
        var isDir: ObjCBool = false
        let p = (root as NSString).appendingPathComponent(name)
        guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return false }
        if name == "lib" { return false }
        return fm.fileExists(atPath: (p as NSString).appendingPathComponent("install.sh"))
    }.sorted()
}

func readVersion(_ path: String) -> String {
    guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return "?" }
    return data.split(separator: "\n").first.map(String.init) ?? "?"
}

func runRecipeScript(_ recipeDir: String, _ script: String, prefix: String?, dryRun: Bool) -> Never {
    let path = (recipeDir as NSString).appendingPathComponent(script)
    guard FileManager.default.fileExists(atPath: path) else {
        die("\(script) not found at \(path)")
    }
    var env = ProcessInfo.processInfo.environment
    env["NOTCHIFY_RECIPE_DIR"] = recipeDir
    if let p = prefix { env["NOTCHIFY_PREFIX"] = p }
    if dryRun { env["NOTCHIFY_DRY_RUN"] = "1" }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = [path]
    proc.environment = env
    do { try proc.run() } catch { die("failed to exec \(path): \(error)") }
    proc.waitUntilExit()
    exit(proc.terminationStatus)
}

func cmdList() {
    let root = recipesDir()
    for name in listRecipes(root) {
        let v = readVersion((root as NSString).appendingPathComponent("\(name)/VERSION"))
        print("\(name)  v\(v)")
    }
}

// Run a recipe's verify.sh and return whether it reported drift.
// Nonzero exit = drift, zero exit = clean. Recipes without a
// verify.sh are treated as always-clean.
func runVerify(_ recipeDir: String, prefix: String) -> Bool {
    let path = (recipeDir as NSString).appendingPathComponent("verify.sh")
    guard FileManager.default.fileExists(atPath: path) else { return false }
    var env = ProcessInfo.processInfo.environment
    env["NOTCHIFY_RECIPE_DIR"] = recipeDir
    env["NOTCHIFY_PREFIX"] = prefix
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = [path]
    proc.environment = env
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return false }
    proc.waitUntilExit()
    return proc.terminationStatus != 0
}

func cmdStatus() {
    let root = recipesDir()
    let prefix = ProcessInfo.processInfo.environment["NOTCHIFY_PREFIX"]
        ?? ProcessInfo.processInfo.environment["HOME"]!
    let installedDir = "\(prefix)/.config/notchify/installed"
    var anyDrift = false
    for name in listRecipes(root) {
        let recipeDir = (root as NSString).appendingPathComponent(name)
        let avail = readVersion("\(recipeDir)/VERSION")
        let installedFile = "\(installedDir)/\(name)"
        if FileManager.default.fileExists(atPath: installedFile) {
            let inst = readVersion(installedFile)
            var notes: [String] = []
            if inst != avail { notes.append("update available") }
            if runVerify(recipeDir, prefix: prefix) {
                notes.append("registrations missing — re-run install")
                anyDrift = true
            }
            let suffix = notes.isEmpty ? "" : "  (" + notes.joined(separator: "; ") + ")"
            print("\(name): installed v\(inst), available v\(avail)\(suffix)")
        } else {
            print("\(name): not installed (available v\(avail))")
        }
    }
    if anyDrift { exit(1) }
}

func parseInstallArgs(_ args: [String]) -> (name: String, prefix: String?, dryRun: Bool) {
    var name: String?
    var prefix: String?
    var dryRun = false
    var it = args.makeIterator()
    while let a = it.next() {
        switch a {
        case "--prefix":
            guard let v = it.next() else { usage() }
            prefix = (v as NSString).expandingTildeInPath
        case "--dry-run":
            dryRun = true
        case "-h", "--help":
            usage()
        default:
            if name == nil { name = a } else { usage() }
        }
    }
    guard let n = name else { usage() }
    return (n, prefix, dryRun)
}

func resolveRecipe(_ name: String) -> String {
    let root = recipesDir()
    let dir = (root as NSString).appendingPathComponent(name)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
        die("unknown recipe: \(name) (try `notchify-recipes list`)")
    }
    return dir
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }
let rest = Array(args.dropFirst())

switch cmd {
case "list":
    cmdList()
case "status":
    cmdStatus()
case "install":
    let (name, prefix, dryRun) = parseInstallArgs(rest)
    let dir = resolveRecipe(name)
    runRecipeScript(dir, "install.sh", prefix: prefix, dryRun: dryRun)
case "uninstall":
    let (name, prefix, dryRun) = parseInstallArgs(rest)
    let dir = resolveRecipe(name)
    runRecipeScript(dir, "uninstall.sh", prefix: prefix, dryRun: dryRun)
case "-h", "--help":
    usage()
default:
    usage()
}
