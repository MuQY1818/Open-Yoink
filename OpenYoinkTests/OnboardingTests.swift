import XCTest
@testable import OpenYoink

final class OnboardingSessionStoreTests: XCTestCase {
    private func makeStore() -> (OnboardingSessionStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-Tutorial-\(UUID().uuidString)", isDirectory: true)
        return (OnboardingSessionStore(rootURL: root), root)
    }

    func testBeginCreatesOnlyManagedPracticeFileAndRoundTripsRecord() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let record = try store.begin()
        let file = store.tutorialFileURL(for: record)

        XCTAssertEqual(record.phase, .awaitingImport)
        XCTAssertNil(record.tutorialItemID)
        XCTAssertFalse(record.token.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(file.lastPathComponent, OnboardingSessionStore.tutorialFileName)
        XCTAssertEqual(file.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL,
                       root.standardizedFileURL)
        XCTAssertEqual(store.load(), record)
    }

    func testAwaitingExportPersistsItemIdentityForCrashResume() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try store.begin()
        let itemID = UUID()

        let updated = try store.markAwaitingExport(record, tutorialItemID: itemID)

        XCTAssertEqual(updated.phase, .awaitingExport)
        XCTAssertEqual(updated.tutorialItemID, itemID)
        XCTAssertEqual(store.load(), updated)
    }

    func testDiscardRemovesSessionButNeverParentDirectory() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-TutorialParent-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("Tutorial", isDirectory: true)
        let sentinel = parent.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = OnboardingSessionStore(rootURL: root)
        let record = try store.begin()

        try store.discard(record)

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path),
                      "单个 session 清理只删除 UUID 子目录和记录，根目录可以保留")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testCorruptRecordDoesNotEscapeTutorialRoot() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"sessionID":"../../","token":"x"}"#.utf8)
            .write(to: root.appendingPathComponent("tutorial-session.json"))

        XCTAssertNil(store.load())
        try store.discardAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}

final class OnboardingPolicyAndLayoutTests: XCTestCase {
    func testFreshInstallShowsOnce() {
        XCTAssertTrue(OnboardingLaunchPolicy.shouldAutomaticallyShow(
            onboardingVersion: 0,
            hadPersistedVersion: false,
            hasLegacyInstallEvidence: false,
            hasPendingSession: false
        ))
    }

    func testLegacyUpgradeWithoutVersionDoesNotInterruptUser() {
        XCTAssertFalse(OnboardingLaunchPolicy.shouldAutomaticallyShow(
            onboardingVersion: 0,
            hadPersistedVersion: false,
            hasLegacyInstallEvidence: true,
            hasPendingSession: false
        ))
    }

    func testInterruptedSessionAlwaysResumes() {
        XCTAssertTrue(OnboardingLaunchPolicy.shouldAutomaticallyShow(
            onboardingVersion: 1,
            hadPersistedVersion: true,
            hasLegacyInstallEvidence: true,
            hasPendingSession: true
        ))
    }

    func testCompletedOrSkippedVersionStaysSilent() {
        XCTAssertFalse(OnboardingLaunchPolicy.shouldAutomaticallyShow(
            onboardingVersion: 1,
            hadPersistedVersion: true,
            hasLegacyInstallEvidence: false,
            hasPendingSession: false
        ))
    }

    func testPanelSitsInsideVisibleFrameBesideRightShelf() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let shelf = CGRect(x: 1120, y: 180, width: 320, height: 560)
        let panel = OnboardingPanelLayout.frame(shelfFrame: shelf,
                                                panelSize: CGSize(width: 430, height: 286),
                                                visibleFrame: visible)
        XCTAssertLessThan(panel.maxX, shelf.minX)
        XCTAssertTrue(visible.insetBy(dx: 12, dy: 12).contains(panel))
    }

    func testPanelClampsOnNarrowScreen() {
        let visible = CGRect(x: -800, y: 25, width: 800, height: 575)
        let shelf = CGRect(x: -320, y: 60, width: 320, height: 500)
        let panel = OnboardingPanelLayout.frame(shelfFrame: shelf,
                                                panelSize: CGSize(width: 430, height: 286),
                                                visibleFrame: visible)
        XCTAssertGreaterThanOrEqual(panel.minX, visible.minX + 12)
        XCTAssertLessThanOrEqual(panel.maxX, visible.maxX - 12)
        XCTAssertGreaterThanOrEqual(panel.minY, visible.minY + 12)
        XCTAssertLessThanOrEqual(panel.maxY, visible.maxY - 12)
    }
}
