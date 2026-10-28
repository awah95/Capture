import FluidAudio
import XCTest
@testable import Captur

final class LocalModelInstallationTests: XCTestCase {
    func testUltraCacheDetectionAndRemovalUseTheSDKRepositoryDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = root.appendingPathComponent("Models/ParakeetUltra")
            .appendingPathComponent(Repo.parakeetUltra.folderName)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = [ModelNames.ASR.preprocessorFile, ModelNames.ASR.encoderFile,
                     ModelNames.ASR.decoderFile, ModelNames.ASR.jointV3File,
                     ModelNames.ASR.vocabularyFile]
        for name in names {
            try Data("fixture".utf8).write(to: cache.appendingPathComponent(name))
        }
        try LocalModelInstallation.recordPrepared(root: cache,
            version: "fluid-0.17.4-parakeet-ultra-coreml-int8")
        let sibling = root.appendingPathComponent("Models/FluidAudio")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let runtime = UltraTranscriptionRuntime(supportDirectory: root)
        let installed = await runtime.availability()
        XCTAssertTrue(installed.isDownloaded)
        XCTAssertFalse(installed.updateAvailable)
        try await runtime.removeModel()
        let removed = await runtime.availability()
        XCTAssertFalse(removed.isDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    func testWarmPreparationDoesNotHideAnOlderInstallation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try LocalModelInstallation.recordPrepared(root: root, version: "fluid-0.15.6")
        try LocalModelInstallation.recordPrepared(root: root, version: "fluid-0.17.4")
        let old = LocalModelInstallation.availability(root: root,
            latestVersion: "fluid-0.17.4", artifactsPresent: true)
        XCTAssertTrue(old.updateAvailable)
        XCTAssertEqual(old.installedVersion, "fluid-0.15.6")
        // The explicit replacement removes old files and the old marker together.
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try LocalModelInstallation.recordPrepared(root: root, version: "fluid-0.17.4")
        let current = LocalModelInstallation.availability(root: root,
            latestVersion: "fluid-0.17.4", artifactsPresent: true)
        XCTAssertFalse(current.updateAvailable)
        XCTAssertEqual(current.installedVersion, "fluid-0.17.4")
    }

    func testMarkerCannotMakeAnIncompleteDownloadReady() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try LocalModelInstallation.recordPrepared(root: root, version: "current")
        let incomplete = LocalModelInstallation.availability(root: root,
            latestVersion: "current", artifactsPresent: false)
        XCTAssertFalse(incomplete.isDownloaded)
        XCTAssertFalse(incomplete.updateAvailable)
    }

    func testUnversionedArtifactsOfferAnUpgradeAfterWarmPreparation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try LocalModelInstallation.recordPrepared(root: root, version: "current", existingArtifacts: true)
        let unknown = LocalModelInstallation.availability(root: root,
            latestVersion: "current", artifactsPresent: true)
        XCTAssertTrue(unknown.isDownloaded)
        XCTAssertTrue(unknown.updateAvailable)
        XCTAssertNil(unknown.installedVersion)
    }
}
