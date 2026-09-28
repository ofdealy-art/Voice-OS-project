import Foundation

public struct SearchProviderDescriptor: Sendable, Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let requiresAPIKey: Bool
    public let apiKeyHelpURL: URL?
    public let privacyNote: String

    public init(
        id: String,
        displayName: String,
        requiresAPIKey: Bool,
        apiKeyHelpURL: URL?,
        privacyNote: String
    ) {
        self.id = id
        self.displayName = displayName
        self.requiresAPIKey = requiresAPIKey
        self.apiKeyHelpURL = apiKeyHelpURL
        self.privacyNote = privacyNote
    }
}

public struct SearchCatalog: Sendable {
    public typealias Factory = @Sendable (_ apiKey: String, _ transport: any HTTPTransport) -> any WebSearchProviding

    public struct Entry: Sendable {
        public let descriptor: SearchProviderDescriptor
        public let factory: Factory

        public init(descriptor: SearchProviderDescriptor, factory: Factory) {
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

    public var descriptors: [SearchProviderDescriptor] { entries.map(\.descriptor) }

    public func descriptor(for id: String) -> SearchProviderDescriptor? {
        entries.first { $0.descriptor.id == id }?.descriptor
    }

    /// Returns a live provider, or `DisabledWebSearchProvider` when web access is
    /// off — so the tool layer never has to special-case the setting.
    public func makeProvider(id: String, apiKey: String?, webAccessEnabled: Bool) -> any WebSearchProviding {
        guard webAccessEnabled else { return DisabledWebSearchProvider() }
        guard let entry = entries.first(where: { $0.descriptor.id == id }) else {
            return DisabledWebSearchProvider()
        }
        return entry.factory(apiKey ?? "", transport)
    }

    public static func standard(transport: any HTTPTransport) -> SearchCatalog {
        SearchCatalog(
            entries: [
                Entry(
                    descriptor: SearchProviderDescriptor(
                        id: BraveWebSearchProvider.providerID,
                        displayName: "Brave Search",
                        requiresAPIKey: true,
                        apiKeyHelpURL: URL(string: "https://api-dashboard.search.brave.com/app/keys"),
                        privacyNote: "Your search words are sent to api.search.brave.com. Your screen is never sent to a search provider."
                    ),
                    factory: { key, transport in
                        BraveWebSearchProvider(apiKey: key, transport: transport)
                    }
                ),
                Entry(
                    descriptor: SearchProviderDescriptor(
                        id: TavilyWebSearchProvider.providerID,
                        displayName: "Tavily",
                        requiresAPIKey: true,
                        apiKeyHelpURL: URL(string: "https://app.tavily.com/home"),
                        privacyNote: "Your search words are sent to api.tavily.com. Your screen is never sent to a search provider."
                    ),
                    factory: { key, transport in
                        TavilyWebSearchProvider(apiKey: key, transport: transport)
                    }
                ),
            ],
            transport: transport
        )
    }
}
