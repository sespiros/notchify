import AppKit
import Foundation

// IntegrationsMenu builds the "Integrations" submenu in the menubar.
// Each recipe shows up as one item with a state-tagged title:
//
//   claude-code: install (v1)               — not installed
//   claude-code: v1                         — installed, clean
//   claude-code: v1 → v2 (update)           — update available
//   claude-code: v1 (re-install needed)     — drifted (registrations gone)
//
// Clicking an actionable item shells out to `notchify-recipes install
// <name>`. The submenu rebuilds itself on every open so the user always
// sees current state without us having to invalidate caches.
@MainActor
final class IntegrationsMenu: NSObject, NSMenuDelegate {
    private let item: NSMenuItem
    private let submenu: NSMenu

    /// Called whenever the "needs attention" state flips. Subscribers
    /// (StatusBarController) use this to toggle a menubar-level dot.
    var onPendingChange: ((Bool) -> Void)?
    private(set) var hasPending: Bool = false

    var rootItem: NSMenuItem { item }

    override init() {
        submenu = NSMenu(title: "Integrations")
        item = NSMenuItem(title: "Integrations", action: nil, keyEquivalent: "")
        item.submenu = submenu
        super.init()
        submenu.delegate = self
        rebuild(from: nil)
    }

    /// Re-fetch status, rebuild the submenu, and notify subscribers of
    /// pending-state changes. Called on menu open and on a timer.
    func refresh() {
        let entries = fetchStatus()
        rebuild(from: entries)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    private struct Entry: Decodable {
        let name: String
        let available: String
        let installed: String?
        let drift: Bool
    }

    nonisolated private static func recipesBinaryPath() -> String {
        // Daemon is at <bundle>/Contents/MacOS/notchify-daemon. The
        // notchify-recipes binary lives next to it.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        return exe.deletingLastPathComponent().appendingPathComponent("notchify-recipes").path
    }

    private func fetchStatus() -> [Entry]? {
        let bin = Self.recipesBinaryPath()
        guard FileManager.default.fileExists(atPath: bin) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["status", "--json"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        // status returns nonzero on drift; we still want the data.
        return try? JSONDecoder().decode([Entry].self, from: data)
    }

    private func rebuild(from entries: [Entry]?) {
        submenu.removeAllItems()
        item.attributedTitle = nil
        item.title = "Integrations"
        item.view = nil
        var pending = false
        defer {
            // Always run pending-change notification so subscribers
            // see the badge clear if recipes become unavailable.
            if hasPending != pending {
                hasPending = pending
                onPendingChange?(pending)
            }
        }
        guard let entries else {
            let placeholder = NSMenuItem(title: "notchify-recipes not found", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            submenu.addItem(placeholder)
            return
        }
        if entries.isEmpty {
            let placeholder = NSMenuItem(title: "no integrations available", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            submenu.addItem(placeholder)
            return
        }
        for e in entries {
            let needsAttention = (e.installed != nil) && (e.drift || e.installed != e.available)
            let isClean = (e.installed != nil) && !needsAttention
            let mi = NSMenuItem(title: titleFor(e), action: nil, keyEquivalent: "")
            mi.target = self
            mi.representedObject = e.name
            // Disable click when there's nothing to do (installed, no
            // update, no drift). Otherwise wire up install.
            let actionable = (e.installed == nil) || needsAttention
            if actionable {
                mi.action = #selector(install(_:))
            }
            // All rows use the custom view so columns line up. The
            // view reserves a leading checkmark slot (drawn only for
            // clean-installed rows) so titles align whether the row
            // is checked or not.
            mi.view = IntegrationsRowView(
                title: titleFor(e),
                icon: Self.iconFor(e.name),
                showsCheckmark: isClean,
                showsAttentionDot: needsAttention,
                showsChevron: false,
                isDimmed: isClean,
                compactIndent: false,
                menuItem: mi
            )
            if needsAttention { pending = true }
            submenu.addItem(mi)
        }
        // "Pending" = any *installed* recipe needs attention. Surface
        // it as a trailing red dot on the rootItem (flush right, just
        // inside the disclosure chevron, which the custom view also
        // renders since NSMenuItem.view replaces default chrome).
        if pending {
            // Custom view with `compactIndent` so the "Integrations"
            // title sits at the same x-position default chrome uses
            // for items in a menu that has a checkmark column (~21pt).
            // This keeps it aligned with About / Install CLI / Quit
            // while still letting us pin a flush-right red dot and a
            // disclosure chevron.
            item.view = IntegrationsRowView(
                title: "Integrations",
                icon: nil,
                showsCheckmark: false,
                showsAttentionDot: true,
                showsChevron: true,
                isDimmed: false,
                compactIndent: true,
                menuItem: item
            )
        }
    }

    private func titleFor(_ e: Entry) -> String {
        let display = Self.displayName(e.name)
        if e.installed == nil { return display }
        if e.drift { return "\(display) (reinstall needed)" }
        if e.installed != e.available { return "\(display) (update available)" }
        return display
    }

    // "claude-code" -> "Claude Code", "codex" -> "Codex". Generic
    // slug-to-title rendering so future recipes don't need a hardcoded
    // mapping.
    nonisolated private static func displayName(_ slug: String) -> String {
        slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // Load a template-friendly icon for the recipe's menu item. Looks
    // under recipes/<name>/files/.config/*/icons/source.svg — a one-
    // color SVG that we render as a template image so macOS tints it
    // neutral (white in dark mode, black in light mode, system accent
    // when highlighted). Falls back to done.png if SVG loading fails.
    //
    // Recipe names and agent directory names need not match
    // (`claude-code` recipe writes to `~/.config/claude/`), so we
    // discover the agent dir by listing files/.config/ rather than
    // hardcoding.
    nonisolated private static func iconFor(_ name: String) -> NSImage? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bin = exe.deletingLastPathComponent()
        let roots = [
            bin.appendingPathComponent("../share/notchify/recipes/\(name)/files/.config").standardized,
            bin.appendingPathComponent("../../recipes/\(name)/files/.config").standardized,
        ]
        let fm = FileManager.default
        for root in roots {
            guard let agents = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for agent in agents {
                let dir = root.appendingPathComponent("\(agent)/icons")
                // Prefer the prebuilt PNG (768×768 RGBA, already a
                // clean single-color silhouette) over source.svg —
                // NSImage's SVG renderer mishandles fill-rule="evenodd"
                // on some recipes (codex's bird shape loses interior
                // cutouts), which a baked PNG sidesteps. Marking the
                // image as a template makes macOS treat the alpha
                // channel as a mask and tint it neutral.
                for filename in ["done.png", "source.svg"] {
                    let path = dir.appendingPathComponent(filename)
                    guard let img = NSImage(contentsOf: path) else { continue }
                    img.size = NSSize(width: 16, height: 16)
                    img.isTemplate = true
                    return img
                }
            }
        }
        return nil
    }

    @objc private func install(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        // The menu closes on click before the user could see any
        // "installing..." UI flip, so feedback comes via the popup
        // fired in the completion handler below.

        DispatchQueue.global(qos: .userInitiated).async {
            let bin = Self.recipesBinaryPath()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = ["install", name]
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = outPipe
            var success = false
            var output = ""
            do {
                try proc.run()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                output = String(data: data, encoding: .utf8) ?? ""
                proc.waitUntilExit()
                success = proc.terminationStatus == 0
            } catch {
                output = "exec failed: \(error)"
            }
            // On failure, dump captured stdout+stderr to a known
            // file so the user can `cat` it without grovelling
            // through Console.app or the unified log.
            var logFile: String?
            if !success {
                let path = "/tmp/notchify-recipes-\(name).log"
                if (try? output.write(toFile: path, atomically: true, encoding: .utf8)) != nil {
                    logFile = path
                }
            }
            DispatchQueue.main.async {
                let body: String
                if success {
                    body = name
                } else if let f = logFile {
                    body = "\(name): cat \(f)"
                } else {
                    body = "\(name): install failed"
                }
                // Per-recipe group so two installs in quick succession
                // don't coalesce into one anonymous chip and hide the
                // earlier popup behind the later one.
                Self.notify(
                    title: success ? "Integration installed" : "Integration install failed",
                    body: body,
                    group: "integration:\(name)"
                )
                if !success { NSLog("notchify: %@ install failed: %@", name, output) }
                // Refresh now so the menubar badge clears (or updates)
                // immediately rather than waiting for the next open.
                self.refresh()
            }
        }
    }

    // Fire a confirmation popup via the notchify CLI. The CLI talks
    // to the daemon over its socket, so this round-trips back to us
    // and renders through the existing notification machinery.
    nonisolated private static func notify(title: String, body: String, group: String) {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let cli = exe.deletingLastPathComponent().appendingPathComponent("notchify").path
        guard FileManager.default.fileExists(atPath: cli) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cli)
        proc.arguments = [title, body, "-sound", "ready", "-group", group]
        try? proc.run()
    }
}
