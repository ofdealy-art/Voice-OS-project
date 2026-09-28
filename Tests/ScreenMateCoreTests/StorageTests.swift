import XCTest
@testable import ScreenMateCore

final class SettingsPersistenceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.screenmate.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testRoundTripsEveryChangedPreference() throws {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        var settings = AppSettings()
        settings.chatProviderID = "openai"
        settings.chatModelID = "gpt-4o"
        settings.screenAwarenessEnabled = true
        settings.sendScreenContentToProvider = true
        settings.speakResponses = false
        settings.speechRate = 0.62
        settings.theme = .dark
        settings.webAccessEnabled = true
        settings.conversationRetention = .sevenDays
        settings.providersWithStoredKey = ["openai"]
        settings.widgetOriginX = 120.5
        settings.widgetOriginY = 640

        try store.save(settings)
        XCTAssertEqual(store.load(), settings)
    }

    func testDefaultsAreReturnedWhenNothingWasSaved() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let loaded = store.load()
        XCTAssertEqual(loaded, AppSettings())
        XCTAssertFalse(loaded.screenAwarenessEnabled, "screen awareness must default to off")
        XCTAssertFalse(loaded.sendScreenContentToProvider, "screen sharing must default to off")
        XCTAssertFalse(loaded.webAccessEnabled, "web access must default to off")
        XCTAssertFalse(loaded.analyticsEnabled, "analytics must default to off")
        XCTAssertFalse(loaded.hasCompletedOnboarding)
    }

    func testCorruptDataFallsBackToDefaultsInsteadOfCrashing() {
        defaults.set(Data("not json".utf8), forKey: UserDefaultsSettingsStore.defaultKey)
        let store = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(store.load(), AppSettings())
    }

    func testOlderSettingsFileKeepsItsKnownValues() throws {
        // A file written by a build that had only these three keys.
        let legacy = #"{"chatProviderID":"openai","chatModelID":"gpt-4o","speakResponses":false}"#
        defaults.set(Data(legacy.utf8), forKey: UserDefaultsSettingsStore.defaultKey)

        let loaded = UserDefaultsSettingsStore(defaults: defaults).load()
        XCTAssertEqual(loaded.chatProviderID, "openai")
        XCTAssertEqual(loaded.chatModelID, "gpt-4o")
        XCTAssertFalse(loaded.speakResponses)
        // Keys that did not exist fall back to the current defaults.
        XCTAssertEqual(loaded.conversationRetention, ConversationRetention.thirtyDays)
        XCTAssertFalse(loaded.screenAwarenessEnabled)
    }

    func testResetClearsStoredPreferences() throws {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        var settings = AppSettings()
        settings.theme = .dark
        try store.save(settings)
        try store.reset()
        XCTAssertEqual(store.load().theme, AppearanceTheme.system)
    }

    func testScreenSharingRequiresBothSwitches() {
        var settings = AppSettings()
        settings.screenAwarenessEnabled = true
        settings.sendScreenContentToProvider = false
        XCTAssertFalse(settings.mayShareScreenWithProvider)

        settings.screenAwarenessEnabled = false
        settings.sendScreenContentToProvider = true
        XCTAssertFalse(settings.mayShareScreenWithProvider)

        settings.screenAwarenessEnabled = true
        settings.sendScreenContentToProvider = true
        XCTAssertTrue(settings.mayShareScreenWithProvider)
    }
}

final class ConversationStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenmate-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testSavesAndReloadsATranscript() throws {
        let store = try FileConversationStore(directory: directory)
        var conversation = Conversation.fixture(userText: "explain this error")
        conversation.messages.append(ChatMessage(role: .assistant, text: "It is a type mismatch.", source: .model))

        try store.save(conversation)
        let loaded = try store.load(id: conversation.id)
        XCTAssertEqual(loaded?.messages.count, 2)
        XCTAssertEqual(loaded?.messages[1].text, "It is a type mismatch.")
    }

    func testFilesAreOwnerReadableOnly() throws {
        let store = try FileConversationStore(directory: directory)
        let conversation = Conversation.fixture()
        try store.save(conversation)

        let file = directory.appendingPathComponent("\(conversation.id.uuidString).json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600)
    }

    func testDeletingOneConversationLeavesTheOthers() throws {
        let store = try FileConversationStore(directory: directory)
        let keep = Conversation.fixture(userText: "keep me")
        var remove = Conversation.fixture(userText: "remove me")
        remove = Conversation(id: UUID(), title: remove.title, messages: remove.messages)

        try store.save(keep)
        try store.save(remove)
        try store.delete(id: remove.id)

        XCTAssertNil(try store.load(id: remove.id))
        XCTAssertNotNil(try store.load(id: keep.id))
        XCTAssertEqual(try store.summaries().count, 1)
    }

    func testDeleteAllLeavesNothingBehind() throws {
        let store = try FileConversationStore(directory: directory)
        for index in 0..<3 {
            try store.save(Conversation(id: UUID(), title: "c\(index)"))
        }
        XCTAssertEqual(try store.summaries().count, 3)

        try store.deleteAll()
        XCTAssertTrue(try store.summaries().isEmpty)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testStoreIsStillUsableAfterDeleteAll() throws {
        let store = try FileConversationStore(directory: directory)
        try store.save(Conversation(id: UUID(), title: "first"))
        try store.deleteAll()
        XCTAssertNoThrow(try store.save(Conversation(id: UUID(), title: "second")))
        XCTAssertEqual(try store.summaries().count, 1)
    }

    func testPruningRemovesOnlyExpiredConversations() throws {
        let store = try FileConversationStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = Conversation(
            id: UUID(),
            title: "old",
            createdAt: now.addingTimeInterval(-40 * 86_400),
            updatedAt: now.addingTimeInterval(-40 * 86_400)
        )
        let recent = Conversation(id: UUID(), title: "recent", createdAt: now, updatedAt: now)
        try store.save(old)
        try store.save(recent)

        let pruned = try store.pruneOlderThan(30 * 86_400, now: now)
        XCTAssertEqual(pruned, 1)
        XCTAssertNil(try store.load(id: old.id))
        XCTAssertNotNil(try store.load(id: recent.id))
    }

    func testSummariesAreNewestFirst() throws {
        let store = try FileConversationStore(directory: directory)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for offset in [0.0, 300.0, 60.0] {
            try store.save(Conversation(
                id: UUID(),
                title: "t\(Int(offset))",
                createdAt: base,
                updatedAt: base.addingTimeInterval(offset)
            ))
        }
        XCTAssertEqual(try store.summaries().map(\.title), ["t300", "t60", "t0"])
    }

    func testAnUnreadableFileDoesNotHideTheRest() throws {
        let store = try FileConversationStore(directory: directory)
        try store.save(Conversation(id: UUID(), title: "good"))
        try Data("garbage".utf8).write(to: directory.appendingPathComponent("broken.json"))
        XCTAssertEqual(try store.summaries().map(\.title), ["good"])
    }

    func testMissingConversationLoadsAsNilRatherThanThrowing() throws {
        let store = try FileConversationStore(directory: directory)
        XCTAssertNil(try store.load(id: UUID()))
    }

    func testNullStoreKeepsNothing() throws {
        let store = NullConversationStore()
        try store.save(Conversation.fixture())
        XCTAssertTrue(try store.summaries().isEmpty)
        XCTAssertNil(try store.load(id: UUID()))
    }

    func testTitleIsDerivedFromTheFirstUserMessage() {
        var conversation = Conversation.fixture(userText: "Explain the TypeScript error in my terminal")
        conversation.refreshTitleFromContent()
        XCTAssertEqual(conversation.title, "Explain the TypeScript error in my terminal")
    }

    func testLongTitleIsTruncatedAtAWordBoundary() {
        var conversation = Conversation.fixture(
            userText: "Compare these two architecture documents and tell me which approach handles retries better"
        )
        conversation.refreshTitleFromContent(limit: 30)
        XCTAssertTrue(conversation.title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(conversation.title.count, 31)
        XCTAssertFalse(conversation.title.contains("architectu…"))
    }

    func testExistingTitleIsNotOverwritten() {
        var conversation = Conversation.fixture(userText: "hello")
        conversation.title = "Pinned research"
        conversation.refreshTitleFromContent()
        XCTAssertEqual(conversation.title, "Pinned research")
    }
}

final class SecretStoreTests: XCTestCase {
    func testKeysAreNamespacedPerProvider() {
        XCTAssertEqual(SecretKey.chatProvider("anthropic"), "provider.anthropic.apiKey")
        XCTAssertEqual(SecretKey.searchProvider("brave"), "search.brave.apiKey")
        XCTAssertNotEqual(SecretKey.chatProvider("openai"), SecretKey.searchProvider("openai"))
    }

    func testRoundTripAndRemoval() throws {
        let store = InMemorySecretStore()
        try store.setSecret("sk-test", forKey: SecretKey.chatProvider("openai"))
        XCTAssertEqual(try store.secret(forKey: SecretKey.chatProvider("openai")), "sk-test")
        XCTAssertTrue(store.hasSecret(forKey: SecretKey.chatProvider("openai")))

        try store.removeSecret(forKey: SecretKey.chatProvider("openai"))
        XCTAssertNil(try store.secret(forKey: SecretKey.chatProvider("openai")))
        XCTAssertFalse(store.hasSecret(forKey: SecretKey.chatProvider("openai")))
    }

    func testRemoveAllClearsEveryProvider() throws {
        let store = InMemorySecretStore()
        try store.setSecret("a", forKey: SecretKey.chatProvider("anthropic"))
        try store.setSecret("b", forKey: SecretKey.searchProvider("brave"))
        try store.removeAllSecrets()
        XCTAssertNil(try store.secret(forKey: SecretKey.chatProvider("anthropic")))
        XCTAssertNil(try store.secret(forKey: SecretKey.searchProvider("brave")))
    }
}

final class ConversationExporterTests: XCTestCase {
    private let exporter = ConversationExporter()

    private func sample() -> Conversation {
        var conversation = Conversation.fixture(userText: "What is on my screen?")
        conversation.messages[0].attachments = [
            ScreenContext.fixture().attachment(includeExtractedText: false)
        ]
        conversation.messages.append(ChatMessage(
            role: .assistant,
            text: "A build error in Xcode.",
            source: .model,
            citations: [
                WebCitation(
                    title: "Swift docs",
                    url: URL(string: "https://swift.org")!,
                    retrievedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ],
            toolInvocations: [
                ToolInvocationRecord(
                    toolName: "web_search",
                    summary: "Searched the web",
                    outcome: .succeeded,
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ]
        ))
        conversation.title = "Build error"
        return conversation
    }

    func testMarkdownIncludesMessagesSourcesAndAttachmentNotes() throws {
        let markdown = String(decoding: try exporter.export(sample(), as: .markdown), as: UTF8.self)
        XCTAssertTrue(markdown.contains("# Build error"))
        XCTAssertTrue(markdown.contains("What is on my screen?"))
        XCTAssertTrue(markdown.contains("A build error in Xcode."))
        XCTAssertTrue(markdown.contains("[Swift docs](https://swift.org)"))
        XCTAssertTrue(markdown.contains("Action `web_search`"))
        XCTAssertTrue(markdown.contains("The image itself was not saved."))
    }

    func testJSONExportIsDecodableBackIntoAConversation() throws {
        let data = try exporter.export(sample(), as: .json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(Conversation.self, from: data)
        XCTAssertEqual(restored.title, "Build error")
        XCTAssertEqual(restored.messages.count, 2)
    }

    func testFilenameIsFileSystemSafe() {
        var conversation = sample()
        conversation.title = "What/is: this?? *really*"
        let name = exporter.suggestedFilename(for: conversation, format: .markdown)
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("?"))
        XCTAssertTrue(name.hasSuffix(".md"))
    }

    func testPlainTextExportHasNoMarkdownSyntax() throws {
        let text = String(decoding: try exporter.export(sample(), as: .plainText), as: UTF8.self)
        XCTAssertFalse(text.contains("# "))
        XCTAssertTrue(text.contains("ScreenMate:"))
    }
}
