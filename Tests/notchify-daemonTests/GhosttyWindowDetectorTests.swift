import XCTest
@testable import notchify_daemon

/// A popup from a tmux pane belongs to whichever Ghostty window shows
/// that pane when the user looks, not to the client tmux picked at
/// send time. Reproduced live: a session no window showed got the
/// latest client's tty (ttys001), so visiting it from the other
/// window (ttys000) left the popup up and returning to ttys001
/// dismissed it.
@MainActor
final class GhosttyWindowDetectorTests: XCTestCase {
    private let key = DismissKey(
        bundle: "com.mitchellh.ghostty",
        tmuxPane: "%480",
        tmuxSocket: nil,
        tty: "/dev/ttys001"
    )

    private func snapshot(title: String?, clients: [String: Set<String>]) -> FocusSnapshot {
        FocusSnapshot(
            frontmostBundle: "com.mitchellh.ghostty",
            panesProvider: { _ in ["%480"] },
            ghosttyTitleProvider: { title },
            clientsProvider: { _ in clients }
        )
    }

    func testMatchesTheWindowShowingThePaneNow() {
        let s = snapshot(title: "notchify-repro (ttys000)", clients: ["%480": ["/dev/ttys000"]])
        XCTAssertEqual(GhosttyWindowDetector().matches(key: key, snapshot: s), true)
    }

    func testIgnoresTheSendTimeTtyWhileAnotherWindowShowsThePane() {
        let s = snapshot(title: "personal (ttys001)", clients: ["%480": ["/dev/ttys000"]])
        XCTAssertEqual(GhosttyWindowDetector().matches(key: key, snapshot: s), false)
    }

    func testFallsBackToTheKeyTtyWhenTmuxNamesNoClient() {
        let s = snapshot(title: "personal (ttys001)", clients: [:])
        XCTAssertEqual(GhosttyWindowDetector().matches(key: key, snapshot: s), true)
    }

    func testAbstainsOutsideGhostty() {
        let other = DismissKey(bundle: "com.apple.Terminal", tmuxPane: "%480", tmuxSocket: nil, tty: "/dev/ttys001")
        let s = snapshot(title: "personal (ttys001)", clients: [:])
        XCTAssertNil(GhosttyWindowDetector().matches(key: other, snapshot: s))
    }
}
