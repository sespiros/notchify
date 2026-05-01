import Foundation
import CoreGraphics

/// Observable state shared between the controller and the SwiftUI
/// stage view. Mutations happen on the main actor in the controller;
/// the stage observes and re-renders. Keeping this here (rather than
/// in NotchController) lets us add @Published properties without
/// rewiring the panel/hosting setup each time.
@MainActor
final class NotchModel: ObservableObject {
    /// Chipstacks left-to-right. `chipstackOrder` order from the
    /// controller is projected into this array (newest at the *end*
    /// so they render closest to the notch on the right).
    @Published var chipstacks: [ChipStack] = []
    /// Notifications currently visible in the dropped-down area of
    /// the pill ("live stack"). Newest first (index 0 = topmost row).
    /// All entries belong to the same group (same `chipstackID`); a new
    /// arrival from a different group waits in the controller's
    /// `arrivals` queue until this drains. Empty when nothing is in
    /// flight, in which case only chips render.
    @Published var liveStack: [StoredNotification] = []
    /// Convenience: topmost (most recent) live row, used by callers
    /// that just need to know "is anything in flight" or want the
    /// most recently arrived notification. Use `liveStack` for full
    /// state including the older rows below it.
    var inflight: StoredNotification? { liveStack.first }
    /// Notch geometry from the active display, used to size the
    /// per-chip and in-flight rectangles.
    @Published var notchSize: CGSize = .zero
    /// Keeps the pill visible (slid down) even when there are no
    /// stacks and no in-flight. The controller flips this on right
    /// before publishing the first stack so the slide-in (a) plays
    /// in isolation, then publishes (b) only after the slide
    /// finishes. Cleared automatically when stacks become non-empty.
    @Published var forcedVisible: Bool = false
    /// True while the user's cursor is anywhere on the pill. The
    /// controller treats this as "user is reading the notch" and
    /// skips the in-flight (phase c) animation for arrivals: those
    /// just get added to their stacks as persistent rows. Cleared
    /// when the cursor leaves or the pill hides.
    @Published var isUserEngaged: Bool = false
    /// True from the moment `beginRetraction` runs until the pill is
    /// fully torn down (or another notification re-engages the pill).
    /// Used by the view to suppress hover-driven expansions during
    /// the retraction window so a just-dismissed notification can't
    /// "reappear" as a hover-list row.
    @Published var inRetraction: Bool = false
    /// Chipstack id of the notification most recently ingested
    /// (whether or not it played in flight). Used to expand the
    /// "right" chipstack when the user hovers a generic part of the
    /// pill rather than a specific slot. nil if no notification has
    /// arrived yet or if the most-recent chipstack has since been
    /// emptied.
    @Published var mostRecentChipstackID: String? = nil
}
