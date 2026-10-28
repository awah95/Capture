import CryptoKit
import Foundation

struct CleanupModelArtifact: Sendable {
    let name: String
    let bytes: Int64
    let sha256: String
}

struct CleanupModelManifest: Sendable {
    let repository: String
    let revision: String
    let artifacts: [CleanupModelArtifact]

    func validate() throws {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        func component(_ value: String) -> Bool {
            !value.isEmpty && value != "." && value != ".." && value.unicodeScalars.allSatisfy(safe.contains)
        }
        let repositoryParts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard repositoryParts.count == 2, repositoryParts.allSatisfy({ component(String($0)) }),
              component(revision), !artifacts.isEmpty,
              Set(artifacts.map { $0.name.lowercased() }).count == artifacts.count
        else { throw CleanupInstallationError.invalidManifest }
        var total: Int64 = 0
        for artifact in artifacts {
            let parts = artifact.name.split(separator: "/", omittingEmptySubsequences: false)
            let sum = total.addingReportingOverflow(artifact.bytes)
            guard parts.allSatisfy({ component(String($0)) }),
                  parts.first?.lowercased() != CleanupModelInstaller.markerName,
                  artifact.bytes > 0, !sum.overflow,
                  artifact.sha256.count == 64,
                  artifact.sha256.allSatisfy({ "0123456789abcdef".contains($0) })
            else { throw CleanupInstallationError.invalidManifest }
            total = sum.partialValue
        }
        // A manifest cannot describe a file and a directory at the same path.
        let names = artifacts.map { $0.name.lowercased() }
        guard !names.contains(where: { name in names.contains { $0.hasPrefix(name + "/") } })
        else { throw CleanupInstallationError.invalidManifest }
    }
}

enum CleanupInstallationError: Error {
    case invalidManifest, invalidArtifact, http(Int?)
}

private final class CleanupDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Int64) -> Void
    init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) { progress(totalBytesWritten) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

enum CleanupModelInstaller {
    static let markerName = "captur-model-version.txt"
    typealias Transport = @Sendable (URL, @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse)

    static func validate(_ file: URL, artifact: CleanupModelArtifact) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            count += Int64(data.count)
            guard count <= artifact.bytes else { throw CleanupInstallationError.invalidArtifact }
            hash.update(data: data)
        }
        guard count == artifact.bytes,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == artifact.sha256
        else { throw CleanupInstallationError.invalidArtifact }
    }

    static func availability(root: URL, manifest: CleanupModelManifest) -> LocalModelAvailability {
        guard (try? manifest.validate()) != nil else {
            return .init(isDownloaded: false, updateAvailable: false)
        }
        return LocalModelInstallation.availability(root: root, latestVersion: manifest.revision,
            artifactsPresent: manifest.artifacts.allSatisfy {
                let size = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent($0.name).path)[.size]) as? NSNumber
                return size?.int64Value == $0.bytes
            })
    }

    /// Verify once per weight load. Cancellation must not mark valid weights corrupt.
    static func verifyInstalled(root: URL, manifest: CleanupModelManifest) throws {
        try manifest.validate()
        do {
            for artifact in manifest.artifacts {
                try Task.checkCancellation()
                try validate(root.appendingPathComponent(artifact.name), artifact: artifact)
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            let marker = root.appendingPathComponent(markerName)
            if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
            throw error
        }
    }

    static func download(to root: URL, manifest: CleanupModelManifest, name: String,
                         progress: @escaping @Sendable (LocalModelDownloadProgress) -> Void,
                         transport: Transport = fetch) async throws {
        try manifest.validate()
        try Task.checkCancellation()
        let fm = FileManager.default
        let parent = root.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".cleanup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let total = manifest.artifacts.reduce(Int64(0)) { $0 + $1.bytes }
        let estimator = LocalModelProgressEstimator()
        var completed: Int64 = 0
        for artifact in manifest.artifacts {
            try Task.checkCancellation()
            let base = completed
            let url = URL(string: "https://huggingface.co/\(manifest.repository)/resolve/\(manifest.revision)/\(artifact.name)")!
            let (temporary, response) = try await transport(url) { bytes in
                let fraction = Double(base) / Double(total) + Double(max(0, bytes)) / Double(total)
                progress(estimator.snapshot(fraction: min(0.99, fraction), detail: "Downloading \(name)…"))
            }
            defer { try? fm.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw CleanupInstallationError.http((response as? HTTPURLResponse)?.statusCode)
            }
            try Task.checkCancellation()
            progress(.fraction(Double(completed) / Double(total), detail: "Verifying \(artifact.name)…"))
            try validate(temporary, artifact: artifact)
            let destination = staging.appendingPathComponent(artifact.name)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: temporary, to: destination)
            completed += artifact.bytes
        }
        try Task.checkCancellation()
        try Data(manifest.revision.utf8).write(to: staging.appendingPathComponent(markerName), options: .atomic)
        if fm.fileExists(atPath: root.path) { _ = try fm.replaceItemAt(root, withItemAt: staging) }
        else { try fm.moveItem(at: staging, to: root) }
        progress(.fraction(1, detail: "\(name) downloaded and verified"))
    }

    private static let fetch: Transport = { url, progress in
        try await URLSession.shared.download(from: url, delegate: CleanupDownloadDelegate(progress: progress))
    }
}
