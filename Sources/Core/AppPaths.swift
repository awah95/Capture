import Foundation

/// Single source of truth for on-disk locations. The directory name lives here so a
/// future rename touches one constant instead of every store.
enum AppPaths {
    static let directoryName = "Captur"
    /// Pre-rename name. Only Migration should reference this.
    static let legacyDirectoryName = "QuickCaptureMac"

    static func applicationSupportRoot(fileManager: FileManager = .default) -> URL {
        (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
    }

    static func supportDirectory(fileManager: FileManager = .default) -> URL {
        applicationSupportRoot(fileManager: fileManager)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func legacySupportDirectory(fileManager: FileManager = .default) -> URL {
        applicationSupportRoot(fileManager: fileManager)
            .appendingPathComponent(legacyDirectoryName, isDirectory: true)
    }
}
