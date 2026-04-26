import AppKit

struct ScreenSnapshot {
    let frame: CGRect
    let safeAreaTop: CGFloat
    let auxiliaryTopLeftWidth: CGFloat?
    let auxiliaryTopRightWidth: CGFloat?
    let isBuiltIn: Bool
}

struct NotchGeometry {
    let screen: NSScreen
    let notchSize: CGSize
    let notchRect: CGRect

    static func current() -> NotchGeometry? {
        guard let screen = targetDisplay else { return nil }
        return forScreen(screen)
    }

    static var targetDisplay: NSScreen? {
        NSScreen.screens.first(where: { $0.snapshot.hasBuiltInNotch })
    }

    static func forScreen(_ screen: NSScreen) -> NotchGeometry? {
        guard let geometry = geometry(for: screen.snapshot) else { return nil }
        return NotchGeometry(screen: screen, notchSize: geometry.notchSize, notchRect: geometry.notchRect)
    }

    static func geometry(for snapshot: ScreenSnapshot) -> (notchSize: CGSize, notchRect: CGRect)? {
        guard snapshot.hasBuiltInNotch,
              let leftWidth = snapshot.auxiliaryTopLeftWidth,
              let rightWidth = snapshot.auxiliaryTopRightWidth else {
            return nil
        }

        let notchWidth = snapshot.frame.width - leftWidth - rightWidth
        guard notchWidth > 0 else { return nil }

        let notchSize = CGSize(width: notchWidth, height: snapshot.safeAreaTop)
        let notchRect = CGRect(
            x: snapshot.frame.midX - (notchWidth / 2),
            y: snapshot.frame.maxY - snapshot.safeAreaTop,
            width: notchWidth,
            height: snapshot.safeAreaTop
        )

        return (notchSize, notchRect)
    }
}

private extension ScreenSnapshot {
    var hasBuiltInNotch: Bool {
        isBuiltIn && safeAreaTop > 0
    }
}

private extension NSScreen {
    var snapshot: ScreenSnapshot {
        ScreenSnapshot(
            frame: frame,
            safeAreaTop: safeAreaInsets.top,
            auxiliaryTopLeftWidth: Self.positiveWidth(auxiliaryTopLeftArea),
            auxiliaryTopRightWidth: Self.positiveWidth(auxiliaryTopRightArea),
            isBuiltIn: isBuiltInDisplay
        )
    }

    var isBuiltInDisplay: Bool {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return false
        }
        return CGDisplayIsBuiltin(screenNumber) != 0
    }

    static func positiveWidth(_ rect: CGRect?) -> CGFloat? {
        guard let rect, rect.width > 0 else { return nil }
        return rect.width
    }
}
