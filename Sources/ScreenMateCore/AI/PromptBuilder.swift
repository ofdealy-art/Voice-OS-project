import Foundation

/// Assembles the exact payload sent to a provider.
///
/// This is the app's privacy choke point: it is the only place that can attach a
/// screenshot, and it refuses to unless `AppSettings.mayShareScreenWithProvider`
/// is true *and* the caller passed a context the user approved. Keeping that rule
/// in one pure function is what makes it testable.
public struct PromptBuilder: Sendable {
    public struct Input: Sendable {
        public let conversation: Conversation
        /// Screen context the user approved for *this* turn, if any.
        public let screenContext: ScreenContext?
        public let settings: AppSettings
        public let modelSupportsVision: Bool
        public let toolNames: [String]
        public let webAccessEnabled: Bool
        public let likelyNeedsFreshInformation: Bool
        public let now: Date
        public let timeZone: TimeZone
        /// Prior tool traffic for the current turn, appended after the transcript.
        public let pendingToolTurns: [AITurn]

        public init(
            conversation: Conversation,
            screenContext: ScreenContext?,
            settings: AppSettings,
            modelSupportsVision: Bool,
            toolNames: [String],
            webAccessEnabled: Bool,
            likelyNeedsFreshInformation: Bool,
            now: Date = Date(),
            timeZone: TimeZone = .current,
            pendingToolTurns: [AITurn] = []
        ) {
            self.conversation = conversation
            self.screenContext = screenContext
            self.settings = settings
            self.modelSupportsVision = modelSupportsVision
            self.toolNames = toolNames
            self.webAccessEnabled = webAccessEnabled
            self.likelyNeedsFreshInformation = likelyNeedsFreshInformation
            self.now = now
            self.timeZone = timeZone
            self.pendingToolTurns = pendingToolTurns
        }
    }

    public struct Output: Sendable {
        public let system: String
        public let turns: [AITurn]
        /// True when a screenshot was actually attached. The UI shows this so
        /// the user can see, after the fact, that their screen was sent.
        public let didAttachScreenImage: Bool
        /// True when OCR text was included as text (no image).
        public let didAttachScreenText: Bool

        public init(system: String, turns: [AITurn], didAttachScreenImage: Bool, didAttachScreenText: Bool) {
            self.system = system
            self.turns = turns
            self.didAttachScreenImage = didAttachScreenImage
            self.didAttachScreenText = didAttachScreenText
        }
    }

    /// How many prior messages to send. Older turns are dropped rather than
    /// summarised; summarisation is on the roadmap, not implemented.
    public let historyLimit: Int

    public init(historyLimit: Int = 24) {
        self.historyLimit = historyLimit
    }

    public func build(_ input: Input) -> Output {
        // Failed turns and the empty assistant placeholder that the UI creates
        // before streaming are not part of the conversation the model should see.
        let history = input.conversation.messages
            .filter { $0.role != .system && $0.failure == nil && !$0.isEmptyPlaceholder }
            .suffix(historyLimit)

        // Only the latest user message carries an attachment; earlier turns go in
        // as plain text. Built in place rather than appended at the end, so the
        // transcript stays in order even if a later assistant message exists.
        let currentUserIndex = history.lastIndex { $0.role == .user }

        var turns: [AITurn] = []
        var didAttachImage = false
        var didAttachText = false

        for (index, message) in zip(history.indices, history) {
            guard index == currentUserIndex else {
                turns.append(.message(.text(message.role, message.text)))
                continue
            }
            let built = currentUserTurn(for: message, input: input)
            turns.append(.message(built.message))
            didAttachImage = built.didAttachImage
            didAttachText = built.didAttachText
        }

        turns.append(contentsOf: input.pendingToolTurns)

        return Output(
            system: systemPrompt(input),
            turns: turns,
            didAttachScreenImage: didAttachImage,
            didAttachScreenText: didAttachText
        )
    }

    /// Assembles the latest user message, attaching the approved screen context if
    /// — and only if — the settings permit it and the model can use it.
    private func currentUserTurn(
        for message: ChatMessage,
        input: Input
    ) -> (message: AIRequestMessage, didAttachImage: Bool, didAttachText: Bool) {
        var parts: [AIContentPart] = []
        var didAttachImage = false
        var didAttachText = false

        if let context = input.screenContext, input.settings.mayShareScreenWithProvider {
            if input.modelSupportsVision {
                parts.append(.image(AIImagePayload(
                    data: context.imageData,
                    mimeType: context.mimeType
                )))
                parts.append(.text(Self.screenDescription(context, imageAttached: true)))
                didAttachImage = true
            } else if let text = context.extractedText, !text.isEmpty {
                // The chosen model has no vision: send the on-device text rather
                // than silently dropping what the user asked about.
                parts.append(.text(Self.screenDescription(context, imageAttached: false)))
                didAttachText = true
            }
        }

        let userText = message.text.isEmpty
            ? "(The user sent this screen capture with no message. Describe what matters about it.)"
            : message.text
        parts.append(.text(userText))

        return (AIRequestMessage(role: .user, parts: parts), didAttachImage, didAttachText)
    }

    // MARK: - System prompt

    func systemPrompt(_ input: Input) -> String {
        var sections: [String] = []

        sections.append("""
        You are ScreenMate, a compact assistant that lives in a floating widget on the \
        user's Mac desktop. You help them understand what is on their screen, look \
        things up, draft text, and work out what to do next.
        """)

        let formatter = DateFormatter()
        formatter.timeZone = input.timeZone
        formatter.dateFormat = "EEEE, d MMMM yyyy 'at' HH:mm zzz"
        sections.append("The user's current local date and time is \(formatter.string(from: input.now)).")

        sections.append("""
        How to answer:
        - Be brief. Your replies are read in a small panel and are often spoken aloud, \
        so lead with the answer and keep to a few sentences unless asked for more.
        - Plain prose by default. Use a short list only when the answer really is a list. \
        Avoid headings and tables; they do not render well at this size and read badly aloud.
        - Never invent screen content, file names, error text, or numbers. If you cannot \
        see something you need, say so and ask for a capture of it.
        - Separate what you know from what you looked up. Attribute retrieved facts to \
        their source and say when something is unverified.
        - If a question turns on information that changes, and you have no fresh source, \
        say your answer may be out of date rather than guessing.
        """)

        if !input.toolNames.isEmpty {
            sections.append("""
            Actions available to you: \(input.toolNames.sorted().joined(separator: ", ")). \
            Anything that changes the user's Mac — the clipboard, a file, opening a page — \
            is shown to them for approval before it runs, and they may decline. Do not \
            promise an action has happened until the result comes back.
            """)
        }

        if input.webAccessEnabled {
            var note = "You can search the web with web_search. Use it when the answer depends on current facts, and cite the sources you used."
            if input.likelyNeedsFreshInformation {
                note += " The user's message looks time-sensitive, so prefer searching over answering from memory."
            }
            sections.append(note)
        } else {
            sections.append("""
            Web access is switched off, so you cannot look anything up. Answer from what \
            you know and from the conversation, and say plainly when something may have \
            changed since your training data.
            """)
        }

        if input.screenContext != nil && input.settings.mayShareScreenWithProvider {
            sections.append("""
            The user has attached a capture of their screen for this message and can see \
            exactly what was sent. Describe only what is actually visible in it.
            """)
        } else if input.settings.screenAwarenessEnabled {
            sections.append("""
            No screen capture is attached to this message. If you need to see the screen, \
            ask the user to press the capture button — you cannot take one yourself without them.
            """)
        }

        if input.settings.speakResponses {
            sections.append("""
            Your reply will be read aloud, so write it to be heard: no markdown syntax, \
            no code fences unless the user asked for code, and spell out anything that \
            would be unintelligible spoken.
            """)
        }

        return sections.joined(separator: "\n\n")
    }

    /// The text that accompanies a screenshot, telling the model what it is
    /// looking at (and, when relevant, that content was removed).
    static func screenDescription(_ context: ScreenContext, imageAttached: Bool) -> String {
        var lines: [String] = []
        if imageAttached {
            lines.append("Attached: a capture of the user's \(context.label.lowercased()) — \(context.sourceDescription), \(context.pixelWidth)×\(context.pixelHeight) pixels.")
        } else {
            lines.append("No image could be attached (the selected model has no vision support). Text read from the user's \(context.label.lowercased()) — \(context.sourceDescription) — follows instead.")
        }
        if let text = context.extractedText, !text.isEmpty {
            lines.append("Text read from that capture on-device:")
            lines.append("---")
            lines.append(text)
            lines.append("---")
        }
        if !context.redactionFindings.isEmpty {
            lines.append(RedactionFinding.summary(context.redactionFindings) + " Where you see [redacted], the value was withheld on purpose; do not guess it.")
        }
        return lines.joined(separator: "\n")
    }
}
