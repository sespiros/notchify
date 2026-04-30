import Foundation
import CoreGraphics

/// Observable state shared between the controller and the SwiftUI
/// stage view. Mutations happen on the main actor in the controller;
/// the stage observes and re-renders. Keeping this here (rather than
/// in NotchController) lets us add @Published properties without
/// rewiring the panel/hosting setup each time.
@MainActor
final class NotchModel: ObservableObject {
    /// Stacks left-to-right. `stackOrder` order from the controller is
    /// projected into this array (newest stacks at the *end* so they
    /// render closest to the notch on the right).
    @Published var stacks: [NotificationStack] = []
    /// The notification currently doing its slide-in / slide-out. nil
    /// when nothing is in flight, in which case only chips render.
    @Published var inflight: StoredNotification?
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
    /// Stack id of the notification most recently ingested (whether
    /// or not it played in flight). Used to expand the "right"
    /// stack when the user hovers a generic part of the pill rather
    /// than a specific slot. nil if no notification has arrived yet
    /// or if the most-recent stack has since been emptied.
    @Published var mostRecentStackID: String? = nil
}
