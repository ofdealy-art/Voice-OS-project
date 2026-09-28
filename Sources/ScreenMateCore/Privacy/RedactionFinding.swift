import Foundation

public struct RedactionFinding: Codable, Sendable, Equatable, Hashable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case apiKey
        case privateKey
        case bearerToken
        case paymentCard
        case bankAccount
        case socialSecurityNumber
        case passwordAssignment

        public var displayName: String {
            switch self {
            case .apiKey: return "API key"
            case .privateKey: return "private key"
            case .bearerToken: return "access token"
            case .paymentCard: return "payment card number"
            case .bankAccount: return "bank account number"
            case .socialSecurityNumber: return "national ID number"
            case .passwordAssignment: return "password"
            }
        }
    }

    public let category: Category
    /// How many matches of this category were replaced.
    public let count: Int

    public init(category: Category, count: Int) {
        self.category = category
        self.count = count
    }

    /// "Removed 1 API key and 2 payment card numbers before sending."
    public static func summary(_ findings: [RedactionFinding]) -> String {
        guard !findings.isEmpty else { return "" }
        let parts = findings
            .sorted { $0.category.rawValue < $1.category.rawValue }
            .map { finding -> String in
                let name = finding.category.displayName
                return finding.count == 1 ? "1 \(name)" : "\(finding.count) \(name)s"
            }
        let list: String
        switch parts.count {
        case 1: list = parts[0]
        case 2: list = "\(parts[0]) and \(parts[1])"
        default: list = parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1]
        }
        return "Removed \(list) before sending."
    }
}
