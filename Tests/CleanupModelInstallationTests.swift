import CryptoKit
import XCTest
@testable import Captur

final class CleanupModelInstallationTests: XCTestCase {
    private let payload = Data("tiny model".utf8)
    private func manifest(revision: String = "rev1", name: String = "model.bin") -> CleanupModelManifest {
        .init(repository: "test/model", revision: revision, artifacts: [.init(name: name,
            bytes: Int64(payload.count), sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())])
    }
    private func transport(_ data: Data, status: Int = 200) -> CleanupModelInstaller.Transport {
        { url, progress in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: file)
            progress(Int64(data.count))
            return (file, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("model") }

    func testVerifiedInstallationAndReplacementPublishOnlyCompleteManifest() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try await CleanupModelInstaller.download(to: root, manifest: manifest(), name: "Test", progress: { _ in }, transport: transport(payload))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("model.bin")), payload)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(CleanupModelInstaller.markerName)), "rev1")
        XCTAssertEqual(CleanupModelInstaller.availability(root: root, manifest: manifest()).installedVersion, "rev1")
        try await CleanupModelInstaller.download(to: root, manifest: manifest(revision: "rev2"), name: "Test", progress: { _ in }, transport: transport(payload))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(CleanupModelInstaller.markerName)), "rev2")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path), ["model"])
    }

    func testBadChecksumAndHTTPResponsePreserveExistingInstallation() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try await CleanupModelInstaller.download(to: root, manifest: manifest(), name: "Test", progress: { _ in }, transport: transport(payload))
        for transport in [transport(Data("bad model!".utf8)), transport(payload, status: 403)] {
            do {
                try await CleanupModelInstaller.download(to: root, manifest: manifest(revision: "rev2"), name: "Test", progress: { _ in }, transport: transport)
                XCTFail("Bad download must fail")
            } catch is CleanupInstallationError {}
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("model.bin")), payload)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(CleanupModelInstaller.markerName)), "rev1")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path), ["model"])
        }
    }

    func testMissingSecondArtifactDoesNotPublishPartialInstallation() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let base = manifest()
        let multi = CleanupModelManifest(repository: base.repository, revision: base.revision,
            artifacts: base.artifacts + [.init(name: "tokenizer.json", bytes: 99, sha256: String(repeating: "0", count: 64))])
        do {
            try await CleanupModelInstaller.download(to: root, manifest: multi, name: "Test", progress: { _ in }, transport: transport(payload))
            XCTFail("Missing artifact must fail verification")
        } catch is CleanupInstallationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path), [])
    }

    func testCorruptionInvalidatesVersionForRepairAndMissingArtifactsAreUnavailable() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try await CleanupModelInstaller.download(to: root, manifest: manifest(), name: "Test", progress: { _ in }, transport: transport(payload))
        try Data(repeating: 0, count: payload.count).write(to: root.appendingPathComponent("model.bin"))
        XCTAssertThrowsError(try CleanupModelInstaller.verifyInstalled(root: root, manifest: manifest()))
        XCTAssertTrue(CleanupModelInstaller.availability(root: root, manifest: manifest()).updateAvailable)
        try FileManager.default.removeItem(at: root.appendingPathComponent("model.bin"))
        XCTAssertFalse(CleanupModelInstaller.availability(root: root, manifest: manifest()).isDownloaded)
    }

    func testUnsafeAndAmbiguousManifestPathsFailBeforeDownload() async throws {
        let root = root()
        for name in ["../escape", "/absolute", "folder/../../escape", "captur-model-version.txt", "model?x", "folder//model"] {
            do {
                try await CleanupModelInstaller.download(to: root, manifest: manifest(name: name), name: "Test", progress: { _ in },
                    transport: { _, _ in XCTFail("Invalid manifest must not reach network"); throw CancellationError() })
                XCTFail("Unsafe path accepted: \(name)")
            } catch CleanupInstallationError.invalidManifest {}
        }
        let base = manifest()
        XCTAssertThrowsError(try CleanupModelManifest(repository: base.repository, revision: base.revision,
            artifacts: base.artifacts + base.artifacts).validate())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().path))
    }

    @MainActor
    func testCancellationPreservesInstalledMarkerAndCreatesNoDownload() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let manifest = manifest()
        try await CleanupModelInstaller.download(to: root, manifest: manifest, name: "Test", progress: { _ in }, transport: transport(payload))
        let task = Task {
            try CleanupModelInstaller.verifyInstalled(root: root, manifest: manifest)
            try await CleanupModelInstaller.download(to: root, manifest: manifest, name: "Test", progress: { _ in },
                transport: { _, _ in XCTFail("Cancelled work must not download"); throw CancellationError() })
        }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(CleanupModelInstaller.markerName)), "rev1")
    }

    func testCancellingActiveDownloadCleansStagingAndPreservesOldModel() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try await CleanupModelInstaller.download(to: root, manifest: manifest(), name: "Test", progress: { _ in }, transport: transport(payload))
        let started = expectation(description: "Transport started")
        let manifest = manifest(revision: "rev2")
        let work = Task {
            try await CleanupModelInstaller.download(to: root, manifest: manifest, name: "Test", progress: { _ in },
                transport: { _, _ in started.fulfill(); try await Task.sleep(for: .seconds(60)); throw CancellationError() })
        }
        await fulfillment(of: [started], timeout: 1)
        work.cancel()
        do { try await work.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("model.bin")), payload)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(CleanupModelInstaller.markerName)), "rev1")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path), ["model"])
    }
}
