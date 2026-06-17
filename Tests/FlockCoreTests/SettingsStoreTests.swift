import XCTest
@testable import FlockCore

final class SettingsStoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openflock-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testReturnsDefaultWhenUnset() {
        let store = SettingsStore(directory: dir)
        XCTAssertTrue(store.bool("missing", default: true))
        XCTAssertFalse(store.bool("missing", default: false))
    }

    func testSetPersistsAndReloads() {
        var store = SettingsStore(directory: dir)
        store.setBool("component.menuBarRate", true)

        // A fresh store — a different bundle, or the future CLI — reads it back.
        let reloaded = SettingsStore(directory: dir)
        XCTAssertTrue(reloaded.bool("component.menuBarRate", default: false))
        // Keys are independent: an unset one still returns its default.
        XCTAssertTrue(reloaded.bool("component.throughput", default: true))
    }

    func testNoFileWrittenUntilAValueChanges() {
        var store = SettingsStore(directory: dir)
        let path = dir.appendingPathComponent("settings.json").path
        // Reading a default doesn't create the file.
        _ = store.bool("component.throughput", default: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        // Writing does.
        store.setBool("component.throughput", false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testCorruptFileFallsBackToDefaults() throws {
        try Data("not json".utf8).write(to: dir.appendingPathComponent("settings.json"))
        let store = SettingsStore(directory: dir)
        XCTAssertTrue(store.bool("component.throughput", default: true))
    }
}
