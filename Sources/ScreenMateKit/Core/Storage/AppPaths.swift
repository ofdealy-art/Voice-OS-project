import Foundation
import ScreenMateCore

/// Every location ScreenMate writes to, in one place, so that "delete all my
/// data" can be exhaustive and so nothing lands somewhere unexpected.
/// `@unchecked Sendable` because it holds a `FileManager`, which is not marked
/// `Sendable`; the shared instance is thread-safe for the operations used here.
public struct AppPaths: @unchecked Sendable {
    public let supportDirectory: URL
    public let conversationsDirectory: URL
    public let notesDirectory: URL
    /// Scratch space for screen captures. Emptied on launch and on quit.
    public let temporaryCaptureDirectory: URL

    private let fileManager: FileManager

    /// `base` is the container for ScreenMate's folder. It defaults to
    /// Application Support, falling back to the temporary directory on the rare
    /// Mac where that is unreachable — losing history is better than refusing to
    /// launch.
    public init(
        fileManager: FileManager = .default,
        folderName: String = "ScreenMate",
        base: URL? = nil
    ) {
        self.fileManager = fileManager
        let support = base
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.supportDirectory = support.appendingPathComponent(folderName, isDirectory: true)
        self.conversationsDirectory = supportDirectory.appendingPathComponent("Conversations", isDirectory: true)
        self.notesDirectory = supportDirectory.appendingPathComponent("Notes", isDirectory: true)
        self.temporaryCaptureDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("\(folderName)-Captures", isDirectory: true)
    }

    public func ensureDirectories() throws {
        for directory in [supportDirectory, conversationsDirectory, notesDirectory, temporaryCaptureDirectory] {
            guard !fileManager.fileExists(atPath: directory.path) else { continue }
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw AppError.storageFailure(detail: error.localizedDescription)
            }
        }
    }

    /// Deletes any screenshot that reached disk. ScreenMate keeps captures in
    /// memory, so this directory is normally empty — it exists so that the
    /// "save this capture" path has somewhere safe to go, and so a crashed
    /// previous run leaves nothing behind.
    public func purgeTemporaryCaptures() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: temporaryCaptureDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in contents {
            try? fileManager.removeItem(at: file)
        }
    }

    /// Removes everything ScreenMate has written. Secrets are cleared separately
    /// through `SecretStoring.removeAllSecrets`.
    public func deleteAllStoredData() throws {
        purgeTemporaryCaptures()
        guard fileManager.fileExists(atPath: supportDirectory.path) else { return }
        do {
            try fileManager.removeItem(at: supportDirectory)
        } catch {
            throw AppError.storageFailure(detail: error.localizedDescription)
        }
        try ensureDirectories()
    }

    /// Bytes currently on disk, shown in Settings › Privacy so the user can see
    /// what "delete my data" would remove.
    public func storedByteCount() -> Int {
        guard let enumerator = fileManager.enumerator(
            at: supportDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += size
        }
        return total
    }
}
