import Foundation

/// Static description of a provider, available before any key is entered.
public struct ProviderDescriptor: Sendable, Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let requiresAPIKey: Bool
    public let models: [AIModel]
    public let apiKeyHelpURL: URL?
    /// Shown under the key field, e.g. where requests are sent.
    public let privacyNote: String

    public init(
        id: String,
        displayName: String,
        requiresAPIKey: Bool,
        models: [AIModel],
        apiKeyHelpURL: URL?,
        privacyNote: String
    ) {
        self.id = id
        self.displayName = displayName
        self.requiresAPIKey = requiresAPIKey
        self.models = models
        self.apiKeyHelpURL = apiKeyHelpURL
        self.privacyNote = privacyNote
    }
}

/// Builds chat providers on demand from the current settings and Keychain.
///
/// The registry is the only place that knows the concrete provider types, which
/// is what makes "add another backend" a one-line change here plus a new file.
public struct ProviderCatalog: Sendable {
    public typealias Factory = @Sendable (_ apiKey: String, _ transport: any HTTPTransport) -> any ChatModelProviding

    public struct Entry: Sendable {
        public let descriptor: ProviderDescriptor
        public let factory: Factory

        public init(descriptor: ProviderDescriptor, factory: Factory) {
            self.descriptor = descriptor
            self.factory = factory
        }
    }

    private let entries: [Entry]
    private let transport: any HTTPTransport

    public init(entries: [Entry], transport: any HTTPTransport) {
        self.entries = entries
        self.transport = transport
    }

    public var descriptors: [ProviderDescriptor] { entries.map(\.descriptor) }

    public func descriptor(for id: String) -> ProviderDescriptor? {
        entries.first { $0.descriptor.id == id }?.descriptor
    }

    /// Returns a ready provider, or throws the specific reason it cannot be made.
    public func makeProvider(id: String, apiKey: String?) throws -> any ChatModelProviding {
        guard let entry = entries.first(where: { $0.descriptor.id == id }) else {
            throw AppError.providerUnavailable(status: 0, detail: "Unknown provider \"\(id)\".")
        }
        let key = apiKey ?? ""
        if entry.descriptor.requiresAPIKey && key.isEmpty {
            throw AppError.missingAPIKey(provider: entry.descriptor.displayName)
        }
        return entry.factory(key, transport)
    }

    /// Validates a provider/model pairing before a request is built, so the user
    /// gets "pick another model" rather than a 404 from the server.
    public func validate(providerID: String, modelID: String) throws {
        guard let descriptor = descriptor(for: providerID) else {
            throw AppError.providerUnavailable(status: 0, detail: "Unknown provider \"\(providerID)\".")
        }
        guard descriptor.models.contains(where: { $0.id == modelID }) else {
            throw AppError.modelUnavailable(model: modelID)
        }
    }

    public func supportsVision(providerID: String, modelID: String) -> Bool {
        descriptor(for: providerID)?.models.first { $0.id == modelID }?.supportsVision ?? false
    }

    // MARK: - Shipping configuration

    public static func standard(transport: any HTTPTransport) -> ProviderCatalog {
        ProviderCatalog(
            entries: [
                Entry(
                    descriptor: ProviderDescriptor(
                        id: AnthropicChatProvider.providerID,
                        displayName: "Anthropic",
                        requiresAPIKey: true,
                        models: AnthropicChatProvider(apiKey: "", transport: transport).models,
                        apiKeyHelpURL: URL(string: "https://console.anthropic.com/settings/keys"),
                        privacyNote: "Messages, and any screenshot you approve, are sent to api.anthropic.com."
                    ),
                    factory: { key, transport in
                        AnthropicChatProvider(apiKey: key, transport: transport)
                    }
                ),
                Entry(
                    descriptor: ProviderDescriptor(
                        id: OpenAIChatProvider.providerID,
                        displayName: "OpenAI",
                        requiresAPIKey: true,
                        models: OpenAIChatProvider.defaultModels,
                        apiKeyHelpURL: URL(string: "https://platform.openai.com/api-keys"),
                        privacyNote: "Messages, and any screenshot you approve, are sent to api.openai.com."
                    ),
                    factory: { key, transport in
                        OpenAIChatProvider(apiKey: key, transport: transport)
                    }
                ),
                Entry(
                    descriptor: ProviderDescriptor(
                        id: DemoChatProvider.providerID,
                        displayName: "Demo (offline)",
                        requiresAPIKey: false,
                        models: DemoChatProvider().models,
                        apiKeyHelpURL: nil,
                        privacyNote: "Nothing leaves your Mac. Replies are canned text, not a model."
                    ),
                    factory: { _, _ in DemoChatProvider() }
                ),
            ],
            transport: transport
        )
    }
}
