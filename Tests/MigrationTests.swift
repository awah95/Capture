import XCTest
@testable import Captur

private final class FakeKeychain: KeychainMigrating {
    var copies: [(from: String, to: String)] = []
    var errorToThrow: Error?

    func copyItems(fromService: String, toService: String) throws {
        if let errorToThrow { throw errorToThrow }
        copies.append((fromService, toService))
    }
}

final class MigrationTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func test_movesSupportDirectoryCopiesKeychainAndPrefixesDefaults() throws {
        let root = try tempDir()
        let old = root.appendingPathComponent("QuickCaptureMac")
        let new = root.appendingPathComponent("Captur")
        try FileManager.default.createDirectory(at: old.appendingPathComponent("captures"),
                                                withIntermediateDirectories: true)
        let defaults = freshDefaults()
        defaults.set("noisy", forKey: "dictationSensitivity")
        let keychain = FakeKeychain()

        let result = Migration.runIfNeeded(fileManager: .default, defaults: defaults,
                                           oldSupportDir: old, newSupportDir: new,
                                           keychain: keychain)

        XCTAssertEqual(result, .migrated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent("captures").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(keychain.copies.count, 1)
        XCTAssertEqual(keychain.copies.first?.from, Keychain.legacyService)
        XCTAssertEqual(keychain.copies.first?.to, Keychain.service)
        XCTAssertEqual(defaults.string(forKey: "captur.dictationSensitivity"), "noisy")
        XCTAssertTrue(defaults.bool(forKey: Migration.guardKey))
    }

    func test_neverOverwritesDataAlreadyUnderTheNewName() throws {
        let root = try tempDir()
        let old = root.appendingPathComponent("QuickCaptureMac")
        let new = root.appendingPathComponent("Captur")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try "old".write(to: old.appendingPathComponent("m.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try "new".write(to: new.appendingPathComponent("m.txt"), atomically: true, encoding: .utf8)

        let result = Migration.runIfNeeded(fileManager: .default, defaults: freshDefaults(),
                                           oldSupportDir: old, newSupportDir: new,
                                           keychain: FakeKeychain())

        XCTAssertEqual(result, .skipped)
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("m.txt"), encoding: .utf8),
                       "new")
    }

    func test_doesNotClobberAnExistingPrefixedDefault() throws {
        let root = try tempDir()
        let old = root.appendingPathComponent("QuickCaptureMac")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let defaults = freshDefaults()
        defaults.set("noisy", forKey: "dictationSensitivity")
        defaults.set("whisper", forKey: "captur.dictationSensitivity")

        _ = Migration.runIfNeeded(fileManager: .default, defaults: defaults,
                                  oldSupportDir: old,
                                  newSupportDir: root.appendingPathComponent("Captur"),
                                  keychain: FakeKeychain())

        XCTAssertEqual(defaults.string(forKey: "captur.dictationSensitivity"), "whisper")
    }

    func test_isIdempotent() throws {
        let root = try tempDir()
        let old = root.appendingPathComponent("QuickCaptureMac")
        let new = root.appendingPathComponent("Captur")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let defaults = freshDefaults()

        let first = Migration.runIfNeeded(fileManager: .default, defaults: defaults,
                                          oldSupportDir: old, newSupportDir: new,
                                          keychain: FakeKeychain())
        let second = Migration.runIfNeeded(fileManager: .default, defaults: defaults,
                                           oldSupportDir: old, newSupportDir: new,
                                           keychain: FakeKeychain())

        XCTAssertEqual(first, .migrated)
        XCTAssertEqual(second, .skipped)
    }

    func test_keychainFailureDoesNotBlockOrSetTheGuardOrMoveData() throws {
        let root = try tempDir()
        let old = root.appendingPathComponent("QuickCaptureMac")
        let new = root.appendingPathComponent("Captur")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let defaults = freshDefaults()
        let keychain = FakeKeychain()
        keychain.errorToThrow = NSError(domain: "test", code: 1)

        let result = Migration.runIfNeeded(fileManager: .default, defaults: defaults,
                                           oldSupportDir: old, newSupportDir: new,
                                           keychain: keychain)

        guard case .failed = result else {
            return XCTFail("expected .failed, got \(result)")
        }
        XCTAssertFalse(defaults.bool(forKey: Migration.guardKey),
                       "a failed migration must retry on the next launch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path),
                      "the old data must be left untouched")
    }

    func test_absentLegacyInstallIsAClean_skipped() throws {
        let root = try tempDir()
        let result = Migration.runIfNeeded(fileManager: .default, defaults: freshDefaults(),
                                           oldSupportDir: root.appendingPathComponent("QuickCaptureMac"),
                                           newSupportDir: root.appendingPathComponent("Captur"),
                                           keychain: FakeKeychain())
        XCTAssertEqual(result, .skipped)
    }
}
