import AppKit
import ServiceManagement
import Sparkle

@MainActor
final class StatusBarController: NSObject {
    private let item: NSStatusItem
    private let launchAtLoginItem = NSMenuItem(
        title: "Launch at Login", action: nil, keyEquivalent: ""
    )
    private let installCLIItem = NSMenuItem(
        title: "Install CLI in /usr/local/bin", action: nil, keyEquivalent: ""
    )
    private let tcpListenerItem = NSMenuItem(
        title: "Loopback TCP Listener", action: nil, keyEquivalent: ""
    )
    private let settingsMenu = NSMenu(title: "Settings")
    private let focusBehaviorMenu = NSMenu()
    private let fdaCaptionItem = NSMenuItem(
        title: "Needs Full Disk Access to read Focus", action: nil, keyEquivalent: ""
    )
    private let integrations = IntegrationsMenu()
    private let updater: Updater?
    private let tcpState: () -> (enabled: Bool, detail: String)
    private let setTcpEnabled: (Bool) -> Void
    private var badgeView: NSView?
    private var refreshTimer: Timer?

    init(
        updater: Updater?,
        tcpState: @escaping () -> (enabled: Bool, detail: String),
        setTcpEnabled: @escaping (Bool) -> Void
    ) {
        self.updater = updater
        self.tcpState = tcpState
        self.setTcpEnabled = setTcpEnabled
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            button.image = Self.makeIconImage()
            // Small red dot pinned to the bottom-right of the status
            // icon as a subview, so it can show/hide without us having
            // to maintain a non-template variant of the icon (the
            // plain icon stays template-tinted by macOS automatically
            // across light/dark). NSStatusBarButton uses a non-flipped
            // coordinate system, so y=0 is the bottom edge.
            let dotSize: CGFloat = 6
            let dot = NSView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            dot.layer?.cornerRadius = dotSize / 2
            dot.isHidden = true
            button.addSubview(dot)
            // Overlap the icon's bottom-right corner so the badge
            // sits ON the icon rather than alongside it (matches the
            // System Settings / App Store update-indicator look).
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: dotSize),
                dot.heightAnchor.constraint(equalToConstant: dotSize),
                dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -5),
                dot.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -3),
            ])
            badgeView = dot
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "About Notchify", action: #selector(about), keyEquivalent: ""
        ).withTarget(self))

        // Sparkle wires "Check for Updates…" itself: target the standard
        // updater controller and let Sparkle's validateMenuItem(_:) gray
        // it out while a check is in flight. Item is only added for
        // non-Nix builds; nix-darwin manages the version directly.
        if let updater {
            let updateItem = NSMenuItem(
                title: "Check for Updates…",
                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                keyEquivalent: ""
            )
            updateItem.target = updater.controller
            menu.addItem(updateItem)
        }

        menu.addItem(.separator())

        menu.addItem(integrations.rootItem)

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)
        launchAtLoginItem.target = self
        settingsMenu.addItem(launchAtLoginItem)

        installCLIItem.action = #selector(installCLI)
        installCLIItem.target = self
        settingsMenu.addItem(installCLIItem)

        tcpListenerItem.action = #selector(toggleTcpListener)
        tcpListenerItem.target = self
        settingsMenu.addItem(tcpListenerItem)

        settingsMenu.addItem(.separator())

        let focusBehaviorItem = NSMenuItem(title: "Focus Behavior", action: nil, keyEquivalent: "")
        focusBehaviorItem.submenu = focusBehaviorMenu
        // Ignore needs no detection, so it sits alone above the divider.
        // Both mute policies read the TCC-protected assertions file, so
        // they're grouped below a Full Disk Access caption. The caption
        // shows only when access is missing (toggled in
        // refreshFocusPolicyState, re-evaluated on each open via the menu
        // delegate); it has no action so the menu auto-disables it into a
        // gray explanatory line above the options it qualifies.
        focusBehaviorMenu.addItem(makeFocusPolicyItem(.ignore))
        focusBehaviorMenu.addItem(.separator())
        focusBehaviorMenu.addItem(fdaCaptionItem)
        focusBehaviorMenu.addItem(makeFocusPolicyItem(.anyFocus))
        focusBehaviorMenu.addItem(makeFocusPolicyItem(.doNotDisturbOnly))
        focusBehaviorMenu.delegate = self
        settingsMenu.addItem(focusBehaviorItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Quit Notchify", action: #selector(quit), keyEquivalent: "q"
        ).withTarget(self))

        item.menu = menu

        // Wire integrations badge: hide/show menubar dot in sync
        // with the IntegrationsMenu's pending state. Initial poll
        // and a low-frequency periodic refresh so updates surface
        // without the user having to open the menu first.
        integrations.onPendingChange = { [weak self] pending in
            self?.badgeView?.isHidden = !pending
        }
        integrations.refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.integrations.refresh() }
        }

        refreshLaunchAtLoginState()
        refreshCLIState()
        refreshTcpListenerState()
        refreshFocusPolicyState()
    }

    @objc private func about() {
        // Dev builds carry a display-only NotchifyDevVersion (stamped by
        // package.sh when built off a non-tagged commit); surface it as
        // "Version <ver>-<hash> (dev)" so it's obvious this isn't a
        // release. Release builds omit the key and get the clean version.
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let dev = Bundle.main.object(forInfoDictionaryKey: "NotchifyDevVersion") as? String,
           !dev.isEmpty {
            options[.applicationVersion] = dev
            options[.version] = "dev"
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("notchify: launch-at-login toggle failed: \(error)")
        }
        refreshLaunchAtLoginState()
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func installCLI() {
        // Derive sibling binaries from the daemon's own executable path.
        // Using CommandLine.arguments[0] (not Bundle.main) works for
        // both .app bundles and `swift run` / `swift build` debug layouts.
        // Symlinks are resolved so `swift run` follows `.build/debug/`
        // links into `.build/<arch>/debug/` where SwiftPM places the
        // real product binaries.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
        let binDir = exe.deletingLastPathComponent()
        let cli = binDir.appendingPathComponent("notchify").path
        let recipes = binDir.appendingPathComponent("notchify-recipes").path
        let cliEsc = cli.replacingOccurrences(of: "\"", with: "\\\"")
        let recipesEsc = recipes.replacingOccurrences(of: "\"", with: "\\\"")
        let src = """
        do shell script "mkdir -p /usr/local/bin && ln -sf \\"\(cliEsc)\\" /usr/local/bin/notchify && ln -sf \\"\(recipesEsc)\\" /usr/local/bin/notchify-recipes" with administrator privileges
        """
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err {
            NSLog("notchify: install CLI failed: \(err)")
        }
        refreshCLIState()
    }

    private func refreshCLIState() {
        let prefix = Self.installedCLIPrefix()
        let installed = prefix != nil
        installCLIItem.state = installed ? .on : .off
        installCLIItem.title = installed
            ? "CLI installed at \(prefix!)"
            : "Install CLI in /usr/local/bin"
        installCLIItem.action = installed ? nil : #selector(installCLI)
    }

    @objc private func toggleTcpListener() {
        setTcpEnabled(!tcpState().enabled)
        refreshTcpListenerState()
    }

    func refreshTcpListenerState() {
        let state = tcpState()
        tcpListenerItem.state = state.enabled ? .on : .off
        tcpListenerItem.title = "Loopback TCP Listener: \(state.detail)"
    }

    private func makeFocusPolicyItem(_ policy: FocusPolicy) -> NSMenuItem {
        let item = NSMenuItem(
            title: policy.title,
            action: #selector(setFocusPolicy(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = policy.rawValue
        return item
    }

    @objc private func setFocusPolicy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let policy = FocusPolicy(rawValue: raw) else { return }
        FocusPolicy.current = policy
        refreshFocusPolicyState()
        // Picking a muting policy is the moment the user expresses intent
        // to mute, so surface the FDA settings pane right then if access
        // is missing (FDA can't be requested programmatically, only
        // opened to). Ignore needs no file access, so it never prompts.
        if policy != .ignore && !Focus.hasFullDiskAccess() {
            openFullDiskAccessSettings()
        }
    }

    private func openFullDiskAccessSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshFocusPolicyState() {
        let current = FocusPolicy.current
        for item in focusBehaviorMenu.items {
            guard let raw = item.representedObject as? String,
                  let policy = FocusPolicy(rawValue: raw) else { continue }
            item.state = policy == current ? .on : .off
        }
        fdaCaptionItem.isHidden = Focus.hasFullDiskAccess()
    }

    // Look for both notchify and notchify-recipes in common install
    // directories. Returns the directory path (e.g. /usr/local/bin)
    // when both binaries are present and executable, nil otherwise.
    // Uses isExecutableFile (follows symlinks) so broken symlinks
    // are rejected properly — unlike fileExists which sees the node.
    private static func installedCLIPrefix() -> String? {
        var dirs = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/run/current-system/sw/bin",
        ]
        let userProfilesDir = "/etc/profiles/per-user"
        if let users = try? FileManager.default.contentsOfDirectory(atPath: userProfilesDir) {
            for u in users {
                dirs.append("\(userProfilesDir)/\(u)/bin")
            }
        }
        for d in dirs {
            if FileManager.default.isExecutableFile(atPath: "\(d)/notchify")
                && FileManager.default.isExecutableFile(atPath: "\(d)/notchify-recipes") {
                return d
            }
        }
        return nil
    }

    // Custom menubar glyph: a tiny "MacBook with notch" silhouette.
    private static func makeIconImage() -> NSImage {
        return makeIconImage(size: NSSize(width: 20, height: 14), fill: .black, isTemplate: true)
    }

    /// Render the same MacBook-with-notch silhouette at a larger size
    /// in white, suitable for use as a chip icon over the notch
    /// pill's black background. Used by the Integrations menu to
    /// brand its install confirmation popups.
    nonisolated static func chipIconPath() -> String? {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("notchify-chip-icon.png")
        if FileManager.default.fileExists(atPath: path) { return path }
        let img = makeIconImage(size: NSSize(width: 64, height: 44), fill: .white, isTemplate: false)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            return nil
        }
    }

    nonisolated private static func makeIconImage(size: NSSize, fill: NSColor, isTemplate: Bool) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return img }

        let w = size.width
        let h = size.height
        // Path geometry was tuned for the 20x14 menubar size; scale
        // proportionally for any other render target.
        let s = min(w / 20, h / 14)

        // Display rectangle: rounded rectangle filling most of the icon.
        let displayRect = CGRect(x: 1 * s, y: 2 * s, width: w - 2 * s, height: h - 3 * s)
        let displayPath = CGPath(
            roundedRect: displayRect,
            cornerWidth: 2.0 * s,
            cornerHeight: 2.0 * s,
            transform: nil
        )
        ctx.addPath(displayPath)
        ctx.setFillColor(fill.cgColor)
        ctx.fillPath()

        // Notch hanging from the top edge of the display, with rounded
        // bottom corners. Drawn in the foreground color (black) but cut
        // back to transparent by punching it out using clear blend mode.
        let notchW: CGFloat = 6 * s
        let notchH: CGFloat = 2.5 * s
        let notchRadius: CGFloat = 0.9 * s
        let notchTop = displayRect.maxY
        let notchY = notchTop - notchH
        let notchX = (w - notchW) / 2
        let notch = CGMutablePath()
        notch.move(to: CGPoint(x: notchX, y: notchTop + 0.5 * s))
        notch.addLine(to: CGPoint(x: notchX + notchW, y: notchTop + 0.5 * s))
        notch.addLine(to: CGPoint(x: notchX + notchW, y: notchY + notchRadius))
        notch.addQuadCurve(
            to: CGPoint(x: notchX + notchW - notchRadius, y: notchY),
            control: CGPoint(x: notchX + notchW, y: notchY)
        )
        notch.addLine(to: CGPoint(x: notchX + notchRadius, y: notchY))
        notch.addQuadCurve(
            to: CGPoint(x: notchX, y: notchY + notchRadius),
            control: CGPoint(x: notchX, y: notchY)
        )
        notch.closeSubpath()
        ctx.setBlendMode(.clear)
        ctx.addPath(notch)
        ctx.fillPath()
        ctx.setBlendMode(.normal)

        img.isTemplate = isTemplate
        return img
    }
}

extension StatusBarController: NSMenuDelegate {
    // The menu is built once, but Full Disk Access can be granted while
    // it's closed. Re-evaluate the FDA nudge each time the Focus
    // Behavior submenu is about to open so it disappears once access is
    // granted (and reappears if it's revoked).
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshFocusPolicyState()
    }
}

private extension NSMenuItem {
    func withTarget(_ target: AnyObject) -> NSMenuItem {
        self.target = target
        return self
    }
}
