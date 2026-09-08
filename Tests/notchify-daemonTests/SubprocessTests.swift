import XCTest
@testable import notchify_daemon

/// The two guarantees the daemon relies on to survive a wedged
/// system: a bounded `Subprocess.run` gives up on time, and a
/// `GuardedProbe` asked repeatedly while its child hangs answers nil
/// immediately instead of spawning again, then recovers.
final class SubprocessTests: XCTestCase {
    func testRunCollectsOutput() {
        let r = Subprocess.run("/bin/echo", ["hello"], timeout: 5)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.stdout, "hello\n")
        XCTAssertEqual(r.stderr, "")
    }

    func testRunReportsLaunchFailure() {
        let r = Subprocess.run("/nonexistent/binary", [], timeout: 5)
        XCTAssertEqual(r.exitCode, -1)
        XCTAssertNil(r.stdout)
    }

    func testRunGivesUpAtTheDeadline() {
        let start = Date()
        let r = Subprocess.run("/bin/sleep", ["30"], timeout: 0.3)
        XCTAssertEqual(r.exitCode, -1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }

    func testGuardedProbeFastPath() {
        let probe = GuardedProbe<Int>(label: "test-fast", wait: 1.0)
        XCTAssertEqual(probe.ask { 42 }, 42)
        XCTAssertNil(probe.ask { nil })
        XCTAssertFalse(probe.isBusy)
    }

    func testGuardedProbeAnswersNilWhileBusyThenRecovers() {
        let probe = GuardedProbe<String>(label: "test-slow", wait: 0.2)

        // A hanging child: the ask returns nil at the wait bound, not
        // when the child does.
        let t0 = Date()
        XCTAssertNil(probe.ask {
            Thread.sleep(forTimeInterval: 1.0)
            return "slow"
        })
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.8)
        XCTAssertTrue(probe.isBusy)

        // Later asks while it hangs: nil at once, and the work is not
        // run (a run would flip the flag).
        let ran = expectation(description: "second ask must not run")
        ran.isInverted = true
        let t1 = Date()
        XCTAssertNil(probe.ask {
            ran.fulfill()
            return "fast"
        })
        XCTAssertLessThan(Date().timeIntervalSince(t1), 0.1)
        wait(for: [ran], timeout: 0.3)

        // Once the slow child returns, the probe answers again.
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(probe.isBusy)
        XCTAssertEqual(probe.ask { "fast" }, "fast")
    }
}
