import AppKit
import ServiceManagement

@MainActor
final class StatusBarController: NSObject {
    private let item: NSStatusItem
    private let launchAtLoginItem = NSMenuItem(
        title: "Launch at Login", action: nil, keyEquivalent: ""
    )
    private let installCLIItem = NSMenuItem(
        title: "Install CLI in /usr/local/bin", action: nil, keyEquivalent: ""
    )

    private static let cliDestination = "/usr/local/bin/notchify"

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            button.image = Self.makeIconImage()
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "About Notchify", action: #selector(about), keyEquivalent: ""
        ).withTarget(self))

        menu.addItem(.separator())

        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        installCLIItem.action = #selector(installCLI)
        installCLIItem.target = self
        menu.addItem(installCLIItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Quit Notchify", action: #selector(quit), keyEquivalent: "q"
        ).withTarget(self))

        item.menu = menu
        refreshLaunchAtLoginState()
        refreshCLIState()
    }

    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(nil)
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
        let cli = Bundle.main.bundlePath + "/Contents/MacOS/notchify"
        // do shell script ... with administrator privileges triggers macOS's
        // standard auth dialog. Quote both paths for safety.
        let cliEsc = cli.replacingOccurrences(of: "\"", with: "\\\"")
        let dstEsc = Self.cliDestination
        let src = """
        do shell script "mkdir -p /usr/local/bin && ln -sf \\"\(cliEsc)\\" \\"\(dstEsc)\\"" with administrator privileges
        """
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err {
            NSLog("notchify: install CLI failed: \(err)")
        }
        refreshCLIState()
    }

    private func refreshCLIState() {
        let path = Self.installedCLIPath()
        let installed = path != nil
        installCLIItem.state = installed ? .on : .off
        installCLIItem.title = installed
            ? "CLI installed at \(path!)"
            : "Install CLI in /usr/local/bin"
        installCLIItem.action = installed ? nil : #selector(installCLI)
    }

    // Look for an existing notchify CLI in common install locations so the
    // menu item reports "installed" regardless of how it got there
    // (drag-install symlink, Homebrew, nix-darwin, etc.).
    private static func installedCLIPath() -> String? {
        var candidates = [
            "/usr/local/bin/notchify",
            "/opt/homebrew/bin/notchify",
            "/run/current-system/sw/bin/notchify",
        ]
        let userProfilesDir = "/etc/profiles/per-user"
        if let users = try? FileManager.default.contentsOfDirectory(atPath: userProfilesDir) {
            for u in users {
                candidates.append("\(userProfilesDir)/\(u)/bin/notchify")
            }
        }
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return c
        }
        return nil
    }

    // Custom menubar glyph: a tiny "MacBook with notch" silhouette.
    private static func makeIconImage() -> NSImage {
        let size = NSSize(width: 20, height: 14)
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return img }

        let w = size.width
        let h = size.height

        // Display rectangle: rounded rectangle filling most of the icon.
        let displayRect = CGRect(x: 1, y: 2, width: w - 2, height: h - 3)
        let displayPath = CGPath(
            roundedRect: displayRect,
            cornerWidth: 2.0,
            cornerHeight: 2.0,
            transform: nil
        )
        ctx.addPath(displayPath)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fillPath()

        // Notch hanging from the top edge of the display, with rounded
        // bottom corners. Drawn in the foreground color (black) but cut
        // back to transparent by punching it out using clear blend mode.
        let notchW: CGFloat = 6
        let notchH: CGFloat = 2.5
        let notchRadius: CGFloat = 0.9
        let notchTop = displayRect.maxY
        let notchY = notchTop - notchH
        let notchX = (w - notchW) / 2
        let notch = CGMutablePath()
        notch.move(to: CGPoint(x: notchX, y: notchTop + 0.5))
        notch.addLine(to: CGPoint(x: notchX + notchW, y: notchTop + 0.5))
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

        img.isTemplate = true
        return img
    }
}

private extension NSMenuItem {
    func withTarget(_ target: AnyObject) -> NSMenuItem {
        self.target = target
        return self
    }
}
