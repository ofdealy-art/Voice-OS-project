import Foundation

// MARK: - Read-only

/// Models have no clock. Without this they guess at "today", which is the single
/// most common wrong answer in a desktop assistant.
public struct CurrentDateTimeTool: AssistantTool {
    public let name = "current_datetime"
    public let description = """
    Get the user's current local date, time and time zone. Call this before any \
    answer that depends on today's date, the day of the week, or elapsed time.
    """
    public let parameters: JSONValue = .object([
        "type": "object",
        "properties": .object([:]),
    ])
    public let sideEffect = ToolSideEffect.readOnly

    public init() {}

    public func execute(arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let now = context.now()
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone.current
        return ToolOutput(
            content: """
            Local time: \(formatter.string(from: now))
            ISO 8601: \(iso.string(from: now))
            Time zone: \(TimeZone.current.identifier)
            """,
            userVisibleSummary: "Checked the current date and time"
        )
    }
}

public struct WebSearchTool: AssistantTool {
    public let name = "web_search"
    public let description = """
    Search the web for current information. Use this when the answer depends on \
    facts that change, on anything after your training data, or when the user asks \
    you to look something up. Return sources so the user can verify. Do not use it \
    for questions you can answer from the conversation or the user's screen.
    """
    public let parameters: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "query": .object([
                "type": "string",
                "description": "The search query. Keep it short and specific.",
            ]),
        ]),
        "required": .array(["query"]),
    ])
    public let sideEffect = ToolSideEffect.readOnly

    public init() {}

    public func execute(arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let query = try requiredString("query", from: arguments)
        let response = try await context.search.search(query: query, maxResults: context.maxWebResults)
        let summary = response.results.isEmpty
            ? "Searched the web for \"\(query)\" — no results"
            : "Searched the web for \"\(query)\" — \(response.results.count) result\(response.results.count == 1 ? "" : "s")"
        return ToolOutput(
            content: response.promptRepresentation(),
            userVisibleSummary: summary,
            citations: response.citations
        )
    }
}

/// Turns loose text into a checklist. Pure formatting, kept as a tool so the
/// model can produce structured output the app could later act on.
public struct MakeChecklistTool: AssistantTool {
    public let name = "make_checklist"
    public let description = """
    Format a list of steps as a Markdown checklist. Use it when the user asks for \
    a to-do list, a plan, or steps to follow.
    """
    public let parameters: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "title": .object(["type": "string", "description": "Short heading for the list."]),
            "items": .object([
                "type": "array",
                "items": .object(["type": "string"]),
                "description": "The steps, in order.",
            ]),
        ]),
        "required": .array(["items"]),
    ])
    public let sideEffect = ToolSideEffect.readOnly

    public init() {}

    public func execute(arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        guard let items = arguments["items"]?.arrayValue, !items.isEmpty else {
            throw AppError.toolArgumentsInvalid(tool: name, detail: "\"items\" was empty")
        }
        let title = arguments["title"]?.stringValue
        var lines: [String] = []
        if let title, !title.isEmpty { lines.append("### \(title)") }
        for item in items {
            guard let text = item.stringValue, !text.isEmpty else { continue }
            lines.append("- [ ] \(text)")
        }
        let markdown = lines.joined(separator: "\n")
        return ToolOutput(
            content: markdown,
            userVisibleSummary: "Built a \(items.count)-item checklist"
        )
    }
}

// MARK: - Mutating (always confirmed)

public struct CopyToClipboardTool: AssistantTool {
    public let name = "copy_to_clipboard"
    public let description = """
    Put text on the user's clipboard so they can paste it. The user is asked to \
    approve before anything is copied.
    """
    public let parameters: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "text": .object(["type": "string", "description": "The exact text to copy."]),
        ]),
        "required": .array(["text"]),
    ])
    public let sideEffect = ToolSideEffect.mutating(verb: "replace your clipboard contents")

    public init() {}

    public func confirmationPrompt(arguments: JSONValue) -> String {
        let text = arguments["text"]?.stringValue ?? ""
        let preview = text.count > 120 ? String(text.prefix(120)) + "…" : text
        return "Copy this to your clipboard? It replaces what is there now.\n\n\(preview)"
    }

    public func execute(arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let text = try requiredString("text", from: arguments)
        do {
            let count = try context.clipboard.write(text)
            return ToolOutput(
                content: "Copied \(count) characters to the clipboard.",
                userVisibleSummary: "Copied \(count) characters to your clipboard"
            )
        } catch {
            throw AppError.toolExecutionFailed(tool: name, detail: error.localizedDescription)
        }
    }
}

public struct OpenURLTool: AssistantTool {
    public let name = "open_url"
    public let description = """
    Open a web page in the user's default browser. The user is asked to approve, \
    and is shown the exact address, before anything opens.
    """
    public let parameters: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "url": .object(["type": "string", "description": "An absolute http or https URL."]),
            "reason": .object(["type": "string", "description": "Why this page is worth opening."]),
        ]),
        "required": .array(["url"]),
    ])
    public let sideEffect = ToolSideEffect.mutating(verb: "open a web page")

    public init() {}

    public func confirmationPrompt(arguments: JSONValue) -> String {
        let url = arguments["url"]?.stringValue ?? "(no address)"
        if let reason = arguments["reason"]?.stringValue, !reason.isEmpty {
            return "Open this page in your browser?\n\n\(url)\n\n\(reason)"
        }
        return "Open this page in your browser?\n\n\(url)"
    }

    public func execute(arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let raw = try requiredString("url", from: arguments)
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            // Refusing non-web schemes keeps this away from file:// and
            // custom handlers that could do far more than open a page.
            throw AppError.toolArgumentsInvalid(
                tool: name,
                detail: "only http and https addresses can be opened"
            )
        }
        do {
            try context.urlOpener.open(url)
        } catch {
            throw AppError.toolExecutionFailed(tool: name, detail: error.localizedDescription)
        }
        return ToolOutput(
            content: "Opened \(url.absoluteString) in the default browser.",
            userVisibleSummary: "Opened \(url.host ?? url.absoluteString)"
        )
    }
}

public struct CreateNoteTool: AssistantTool {
    public let name = "create_note"
    public let description = """
    Save text as a note file in the user's ScreenMate notes folder. The user is \
    asked to approve, and is shown the title, before anything is written.
    """
    public let parameters: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "title": .object(["type": "string", "description": "Short file title."]),
            "body": .object(["type": "string", "description": "Markdown body of the note."]),
        ]),
        "required": .array(["title", "body"]),
    ])
    public let sideEffect = ToolSideEffect.mutating(verb: "save a note to disk")

    public init() {}

    public func confirmationPrompt(arguments: JSONValue) -> String {
        let title = arguments["title"]?.stringValue ?? "Untitled"
        let body = arguments["body"]?.stringValue ?? ""
        let preview = body.count > 200 ? String(body.prefix(200)) + "…" : body
        return "Save a note called \"\(title)\"?\n\n\(preview)"
    }

    public func execute(arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let title = try requiredString("title", from: arguments)
        let body = try requiredString("body", from: arguments)
        do {
            let location = try context.noteWriter.writeNote(title: title, body: body)
            return ToolOutput(
                content: "Saved the note to \(location).",
                userVisibleSummary: "Saved \"\(title)\""
            )
        } catch {
            throw AppError.toolExecutionFailed(tool: name, detail: error.localizedDescription)
        }
    }
}
