import Foundation
import ScreenMateCore

/// Lets the model ask to look at the screen — but only via the same path a
/// button press takes.
///
/// It is marked `mutating` on purpose. Reading the screen is not a side effect in
/// the filesystem sense, but it is exactly the kind of thing that must never
/// happen without the user saying yes, so it goes through the confirmation gate
/// like any other consequential action. If screen awareness is off, it fails with
/// an explanation the model can relay instead of retrying.
public struct CaptureScreenTool: AssistantTool {
    public let name = "capture_screen"
    public let description = """
    Ask to take a fresh look at the user's screen. Only use this when you need to \
    see something that is not already in the conversation, and say what you are \
    looking for. The user must approve each capture, and may decline. Prefer asking \
    the user to capture a specific region when the screen is busy.
    """
    public let parameters: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "scope": .object([
                "type": "string",
                "enum": .array(["activeWindow", "activeDisplay"]),
                "description": "activeWindow for the front window, activeDisplay for the whole screen.",
            ]),
            "looking_for": .object([
                "type": "string",
                "description": "What you expect to find. Shown to the user when they are asked to approve.",
            ]),
        ]),
        "required": .array(["looking_for"]),
    ])
    public let sideEffect = ToolSideEffect.mutating(verb: "take a new capture of your screen")

    private let capturer: any ScreenCapturing
    /// Where the captured pixels are deposited for the UI to pick up. A box
    /// rather than a callback because the tool runs outside the main actor.
    private let deposit: ScreenContextBox

    public init(capturer: any ScreenCapturing, deposit: ScreenContextBox) {
        self.capturer = capturer
        self.deposit = deposit
    }

    public func confirmationPrompt(arguments: JSONValue) -> String {
        let reason = arguments["looking_for"]?.stringValue ?? "something on your screen"
        let scope = arguments["scope"]?.stringValue == "activeDisplay" ? "your whole screen" : "your front window"
        return "ScreenMate wants to capture \(scope) to look for: \(reason)\n\nThe picture is sent to your AI provider."
    }

    public func execute(arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let scope: ScreenCaptureScope = arguments["scope"]?.stringValue == "activeDisplay"
            ? .activeDisplay
            : .activeWindow

        guard await capturer.isAuthorized() else {
            throw AppError.screenRecordingPermissionDenied
        }

        let captured = try await capturer.capture(scope: scope, region: nil)
        deposit.set(captured)

        // What the model gets back is the on-device text, not the picture: the
        // image blocks for a request are fixed when the turn starts, so a capture
        // taken mid-turn is attached to the *next* message instead. The UI shows
        // it right away, and the text below is enough for most follow-ups.
        var lines = ["Captured \(captured.label.lowercased()) — \(captured.sourceDescription), \(captured.pixelWidth)×\(captured.pixelHeight) pixels. It is now attached to the conversation, and the user can see it."]
        if let text = captured.extractedText, !text.isEmpty {
            lines.append("Text read from it on-device:")
            lines.append(text)
        }
        if !captured.redactionFindings.isEmpty {
            lines.append(RedactionFinding.summary(captured.redactionFindings))
        }

        return ToolOutput(
            content: lines.joined(separator: "\n"),
            userVisibleSummary: "Captured \(captured.label.lowercased())"
        )
    }
}
