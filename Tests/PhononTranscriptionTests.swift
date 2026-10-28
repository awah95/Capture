import CryptoKit
import Foundation
import XCTest
@testable import Captur

private final class PhononFixture: PhononTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var loads = 0
    private var files: [URL] = []
    var loadCount: Int { lock.withLock { loads } }
    var inputs: [URL] { lock.withLock { files } }
    func loaded() { lock.withLock { loads += 1 } }
    func transcribe(fileURL: URL) throws -> String {
        lock.withLock { files.append(fileURL) }
        return "Synthetic transcript."
    }
}

final class PhononTranscriptionTests: XCTestCase {
    private func fixture(installed: Bool = true) throws -> (URL, CleanupModelManifest, PhononFixture, PhononTranscriptionRuntime) {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: support) }
        let bytes = Data("fixture".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manifest = CleanupModelManifest(repository: "example/fixture", revision: "test-revision",
            artifacts: [.init(name: "weights.bin", bytes: Int64(bytes.count), sha256: hash)])
        if installed {
            let root = support.appendingPathComponent("Models/Phonon2")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try bytes.write(to: root.appendingPathComponent("weights.bin"))
            try LocalModelInstallation.recordPrepared(root: root, version: manifest.revision)
        }
        let native = PhononFixture()
        let runtime = PhononTranscriptionRuntime(supportDirectory: support, manifest: manifest,
            loader: { _, _ in native.loaded(); return native })
        return (support, manifest, native, runtime)
    }

    func testManifestPinsEveryRequiredArtifactAndLicenses() throws {
        let manifest = PhononModel.manifest
        try manifest.validate()
        XCTAssertEqual(manifest.revision, "48af304c8db8bcc25307c206c199612f48479954")
        XCTAssertEqual(manifest.artifacts.count, 8)
        XCTAssertEqual(manifest.artifacts.reduce(Int64(0)) { $0 + $1.bytes }, 345_023_465)
        for name in ["manifest.json", "decoder.bin", "NOTICE", "LICENSE-WEIGHTS-CC-BY-4.0.txt",
                     "Phonon-2.mlpackage/Manifest.json", "Phonon-2.mlpackage/Data/com.apple.CoreML/weights/weight.bin"] {
            XCTAssertTrue(manifest.artifacts.contains { $0.name == name })
        }
    }

    func testInferenceWithoutDownloadDoesNotLoadOrFetch() async throws {
        let (_, _, native, runtime) = try fixture(installed: false)
        do {
            _ = try await runtime.transcribe(fileURL: URL(fileURLWithPath: "/tmp/synthetic.wav"))
            XCTFail("Missing weights must fail without fetching")
        } catch PhononError.notDownloaded { }
        XCTAssertEqual(native.loadCount, 0)
        let availability = await runtime.availability()
        XCTAssertFalse(availability.isDownloaded)
    }

    func testConcurrentPreparationReusesModelAndBatchKeepsAudioLocal() async throws {
        let (_, _, native, runtime) = try fixture()
        async let first: Void = runtime.prepare()
        async let second: Void = runtime.prepare()
        _ = try await (first, second)
        let file = URL(fileURLWithPath: "/tmp/synthetic-local.flac")
        let text = try await runtime.transcribe(fileURL: file, vocabularyTerms: ["ignored acoustic hint"])
        XCTAssertEqual(text, "Synthetic transcript.")
        XCTAssertEqual(native.loadCount, 1)
        XCTAssertEqual(native.inputs, [file])
    }

    func testSameSizeTamperingIsRejectedBeforeNativeLoad() async throws {
        let (support, _, native, runtime) = try fixture()
        try Data("corrupt".utf8).write(to: support.appendingPathComponent("Models/Phonon2/weights.bin"))
        do { try await runtime.prepare(); XCTFail("Checksum mismatch must fail") }
        catch PhononError.verificationFailed { }
        XCTAssertEqual(native.loadCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            support.appendingPathComponent("Models/Phonon2/captur-model-version.txt").path))
    }

    func testRemovalClearsOwnedCompiledCacheAndPreservesOtherModels() async throws {
        let (support, _, _, runtime) = try fixture()
        try await runtime.prepare()
        let compiled = support.appendingPathComponent("Models/Phonon2/Phonon-2.mlmodelc")
        let sibling = support.appendingPathComponent("Models/OtherProvider")
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try await runtime.removeModel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: compiled.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        do { try await runtime.prepare(); XCTFail("Removed model must be unavailable") }
        catch PhononError.notDownloaded { }
    }

    func testNoStreamingPathIsAdvertisedOrStarted() async throws {
        let (_, _, native, runtime) = try fixture()
        let id = UUID()
        do { try await runtime.startStreamingSession(id: id, vocabularyTerms: []); XCTFail("Batch only") }
        catch PhononError.streamingUnsupported { }
        do { _ = try await runtime.appendStreamingAudio(sessionID: id, samples: [0], sampleRate: 16_000); XCTFail("Batch only") }
        catch PhononError.streamingUnsupported { }
        XCTAssertEqual(native.loadCount, 0)
        XCTAssertNil(LocalModelDescriptor.all.first { $0.provider == .localPhonon }?.streamingModelID)
    }

    func testRemovalCannotRaceNativePreparation() async throws {
        let (support, manifest, native, _) = try fixture()
        let started = expectation(description: "native preparation started")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let runtime = PhononTranscriptionRuntime(supportDirectory: support, manifest: manifest,
            loader: { _, _ in started.fulfill(); gate.wait(); return native })
        let task = Task { try await runtime.prepare() }
        await fulfillment(of: [started], timeout: 3)
        do { try await runtime.removeModel(); XCTFail("Do not delete a preparing model") }
        catch is LocalModelBusyError { }
        gate.signal()
        try await task.value
        try await runtime.removeModel()
    }

    func testNativeLoadFailureKeepsVerifiedWeightsAndCanBeRetried() async throws {
        let (support, manifest, native, _) = try fixture()
        let runtime = PhononTranscriptionRuntime(supportDirectory: support, manifest: manifest,
            loader: { _, _ in
                native.loaded()
                if native.loadCount == 1 { throw CocoaError(.coderInvalidValue) }
                return native
            })
        do { try await runtime.prepare(); XCTFail("First native load should fail") }
        catch is CocoaError { }
        let installed = await runtime.availability()
        XCTAssertTrue(installed.isDownloaded)
        try await runtime.prepare()
        XCTAssertEqual(native.loadCount, 2)
    }
}
