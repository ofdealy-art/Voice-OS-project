import AppKit
import Foundation
import ScreenMateCore

/// AppKit-backed implementations of the ports the Core tools depend on.

public struct PasteboardClipboardWriter: ClipboardWriting {
    public init() {}

    public func write(_ text: String) throws -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw AppError.toolExecutionFailed(
                tool: "copy_to_clipboard",
                detail: "the clipboard refused the text"
            )
        }
        return text.count
    }
}

public struct WorkspaceURLOpener: URLOpening {
    public init() {}

    public func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw AppError.toolExecutionFailed(
                tool: "open_url",
                detail: "no application was able to open that address"
            )
        }
    }
}

/// Writes notes as Markdown files under Application Support.
///
/// Deliberately not AppleScript into Notes.app: that needs Automation
/// permission and can silently alter the user's existing notes. A plain file the
/// user can find, move or delete is the smaller promise.
public struct FileNoteWriter: NoteWriting, @unchecked Sendable {
    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public func writeNote(title: String, body: String) throws -> String {
        let safeTitle = title
            .replacingOccurrences(of: "[^A-Za-z0-9 _-]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let stem = safeTitle.isEmpty ? "Note" : String(safeTitle.prefix(64))

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "\(stamp.string(from: Date()))-\(stem.replacingOccurrences(of: " ", with: "-")).md"
        let url = directory.appendingPathComponent(filename, isDirectory: false)

        let contents = "# \(title)\n\n\(body)\n"
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(contents.utf8).write(to: url, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw AppError.toolExecutionFailed(tool: "create_note", detail: error.localizedDescription)
        }
        // Shown to the user and handed back to the model.
        return url.path.replacingOccurrences(of: fileManager.homeDirectoryForCurrentUser.path, with: "~")
    }
}
