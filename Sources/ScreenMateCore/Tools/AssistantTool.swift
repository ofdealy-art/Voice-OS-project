import Foundation

/// How dangerous a tool is. This is the *only* thing that decides whether the
/// user is asked before it runs, so it is declared next to the tool and checked
/// centrally in `ToolRunner` rather than at each call site.
public enum ToolSideEffect: Sendable, Equatable {
    /// Reads or transforms data. Runs without asking.
    case readOnly
    /// Changes something outside the app — the clipboard, a file, another app,
    /// a message. Always requires explicit confirmation.
    case mutating(verb: String)

    public var requiresConfirmation: Bool {
        if case .mutating = self { return true }
        return false
    }
}

public struct ToolOutput: Sendable, Equatable {
    /// Text handed back to the model.
    public let content: String
    /// One line shown in the transcript, e.g. "Copied 412 characters".
    public let userVisibleSummary: String
    /// Sources to attribute, when the tool retrieved anything.
    public let citations: [WebCitation]

    public init(content: String, userVisibleSummary: String, citations: [WebCitation] = []) {
        self.content = content
        self.userVisibleSummary = userVisibleSummary
        self.citations = citations
    }
}

/// Everything a tool is allowed to touch, injected rather than reached for.
///
/// Tools in `ScreenMateCore` stay free of AppKit because every OS capability
/// arrives as one of these ports; `ScreenMateKit` supplies the real ones.
public struct ToolContext: Sendable {
    public let search: any WebSearchProviding
    public let clipboard: any ClipboardWriting
    public let urlOpener: any URLOpening
    public let noteWriter: any NoteWriting
    public let maxWebResults: Int
    public let now: @Sendable () -> Date

    public init(
        search: any WebSearchProviding,
        clipboard: any ClipboardWriting,
        urlOpener: any URLOpening,
        noteWriter: any NoteWriting,
        maxWebResults: Int,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.search = search
        self.clipboard = clipboard
        self.urlOpener = urlOpener
        self.noteWriter = noteWriter
        self.maxWebResults = maxWebResults
        self.now = now
    }
}

public protocol AssistantTool: Sendable {
    var name: String { get }
    /// Written for the model.
    var description: String { get }
    var parameters: JSONValue { get }
    var sideEffect: ToolSideEffect { get }

    /// One sentence shown in the confirmation sheet, built from the actual
    /// arguments so the user approves the specific action, not the category.
    func confirmationPrompt(arguments: JSONValue) -> String

    func execute(arguments: JSONValue, context: ToolContext) async throws -> ToolOutput
}

public extension AssistantTool {
    func confirmationPrompt(arguments: JSONValue) -> String {
        if case .mutating(let verb) = sideEffect {
            return "Let ScreenMate \(verb)?"
        }
        return "Run \(name)?"
    }

    var specification: AIToolSpec {
        AIToolSpec(name: name, description: description, parameters: parameters)
    }

    /// Reads a required string argument, throwing a precise error if it is missing.
    func requiredString(_ key: String, from arguments: JSONValue) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw AppError.toolArgumentsInvalid(tool: name, detail: "\"\(key)\" is missing")
        }
        return value
    }
}
