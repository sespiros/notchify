import SwiftUI

/// Shared design constants for the notch overlay.
///
/// Why this is a fixed-size design rather than Dynamic Type: every
/// rectangle in the pill (notch height, chip slot, drop area, hover
/// list rows) is sized in points relative to `safeAreaInsets.top`
/// from the active built-in display. That value is a hardware
/// constant per machine (Apple's notched MacBooks all sit between
/// ~32pt and ~38pt), and the pill clips to those bounds. Letting
/// `.font(.body)` scale with Dynamic Type would push glyphs past
/// the pill height, clip them, or force a re-layout the controller's
/// animation timeline isn't built to handle. Centralising the sizes
/// here makes the deviation explicit and lets a future iteration
/// swap to capped `@ScaledMetric` values in one place.
enum Design {
    enum Font {
        /// Title font for body rows in the in-flight body and the
        /// hover-expanded row list.
        static let rowTitle = SwiftUI.Font.system(size: 12, weight: .semibold)
        /// Body font for the secondary line in row views.
        static let rowBody = SwiftUI.Font.system(size: 11)
        /// Chevron-down hint under each chip slot.
        static let slotChevron = SwiftUI.Font.system(size: 7, weight: .bold)
        /// Unread-count badge on a chip slot when count > 1.
        static let slotBadge = SwiftUI.Font.system(size: 9, weight: .bold)
    }
}
