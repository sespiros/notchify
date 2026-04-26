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
        guard let screen = preferredDisplay else { return nil }
        return forScreen(screen)
    }

    static var preferredDisplay: NSScreen? {
        NSScreen.screens.first ?? NSScreen.main
    }

    static func forScreen(_ screen: NSScreen) -> NotchGeometry? {
        let geometry = geometry(for: screen.snapshot)
        return NotchGeometry(screen: screen, notchSize: geometry.notchSize, notchRect: geometry.notchRect)
    }

    static func geometry(for snapshot: ScreenSnapshot) -> (notchSize: CGSize, notchRect: CGRect) {
        if snapshot.hasBuiltInNotch,
           let leftWidth = snapshot.auxiliaryTopLeftWidth,
           let rightWidth = snapshot.auxiliaryTopRightWidth {
            let notchWidth = snapshot.frame.width - leftWidth - rightWidth
            if notchWidth > 0 {
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

        let notchWidth = min(Self.syntheticNotchWidth, snapshot.frame.width * 0.28)
        let notchHeight = Self.syntheticNotchHeight
        let notchSize = CGSize(width: notchWidth, height: notchHeight)
        let notchRect = CGRect(
            x: snapshot.frame.midX - (notchWidth / 2),
            y: snapshot.frame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )

        return (notchSize, notchRect)
    }

    private static let syntheticNotchWidth: CGFloat = 210
    private static let syntheticNotchHeight: CGFloat = 32
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
