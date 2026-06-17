import XCTest
@testable import FlockCore

final class DismissalStoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openflock-dismissals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testDismissPersistsAndReloads() throws {
        let when = Date(timeIntervalSince1970: 1_780_000_000)
        var store = DismissalStore(directory: dir)
        store.dismiss("claudeCode:a", at: when)

        // A fresh store reads the same value back from disk.
        let reloaded = DismissalStore(directory: dir)
        let got = try XCTUnwrap(reloaded.dismissedAt("claudeCode:a"))
        // ISO-8601 round-trips at millisecond precision.
        XCTAssertEqual(got.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(reloaded.dismissedAt("claudeCode:missing"))
    }

    func testRestoreRemovesEntry() throws {
        var store = DismissalStore(directory: dir)
        store.dismiss("claudeCode:a", at: Date())
        store.restore("claudeCode:a")
        XCTAssertNil(DismissalStore(directory: dir).dismissedAt("claudeCode:a"))
    }

    func testPruneDropsAbsentKeepsPresentAndReportsChange() throws {
        var store = DismissalStore(directory: dir)
        store.dismiss("claudeCode:keep", at: Date())
        store.dismiss("claudeCode:drop", at: Date())

        XCTAssertTrue(store.prune(keeping: ["claudeCode:keep"]))
        XCTAssertNotNil(store.dismissedAt("claudeCode:keep"))
        XCTAssertNil(store.dismissedAt("claudeCode:drop"))

        // No change ⇒ no write, returns false (the lazy-write contract)…
        XCTAssertFalse(store.prune(keeping: ["claudeCode:keep"]))
        // …including when keeping a superset of what's present.
        XCTAssertFalse(store.prune(keeping: ["claudeCode:keep", "claudeCode:other"]))
    }

    func testCorruptFileLoadsEmptyAndRecovers() throws {
        try Data("{ not valid json".utf8).write(to: dir.appendingPathComponent("dismissals.json"))

        let store = DismissalStore(directory: dir)
        XCTAssertNil(store.dismissedAt("anything"))

        // A write over the corruption succeeds and is readable again.
        var writable = store
        writable.dismiss("claudeCode:a", at: Date())
        XCTAssertNotNil(DismissalStore(directory: dir).dismissedAt("claudeCode:a"))
    }

    // MARK: - The classification rule

    func testDismissalRuleOnlyAppliesToWaitingAndBlocked() {
        let t = Date()
        // Waiting / blocked with no new activity ⇒ dismissed.
        XCTAssertTrue(AgentSession.isDismissed(state: .waiting, lastActivity: t, dismissedAt: t))
        XCTAssertTrue(AgentSession.isDismissed(state: .blocked, lastActivity: t, dismissedAt: t))
        // Working ⇒ never (would mask a live agent); stale ⇒ never (already out of the count).
        XCTAssertFalse(AgentSession.isDismissed(state: .working, lastActivity: t, dismissedAt: t))
        XCTAssertFalse(AgentSession.isDismissed(state: .stale, lastActivity: t, dismissedAt: t))
        // No dismissal recorded ⇒ false.
        XCTAssertFalse(AgentSession.isDismissed(state: .waiting, lastActivity: t, dismissedAt: nil))
    }

    func testDismissalRuleClearsOnceActivityAdvances() {
        let dismissedAt = Date()
        // A genuinely new event (seconds later) clears the dismissal.
        let later = dismissedAt.addingTimeInterval(10)
        XCTAssertFalse(AgentSession.isDismissed(state: .waiting, lastActivity: later, dismissedAt: dismissedAt))
        // Sub-second timestamp drift (same instant) stays dismissed.
        let drift = dismissedAt.addingTimeInterval(0.2)
        XCTAssertTrue(AgentSession.isDismissed(state: .waiting, lastActivity: drift, dismissedAt: dismissedAt))
    }
}
