import Combine
import Foundation
import ScreenMateCore

/// Holds the one tool confirmation the user is being asked about.
///
/// The tool runner is `async` and framework-free; the answer has to come from a
/// SwiftUI sheet. This bridges the two by suspending the runner on a continuation
/// until the user taps a button, with the safe default — decline — applied if the
/// request is ever dropped.
@MainActor
public final class ToolConfirmationCenter: ObservableObject {
    @Published public private(set) var pending: ToolConfirmationRequest?

    private var continuation: CheckedContinuation<Bool, Never>?

    public init() {}

    func awaitDecision(for request: ToolConfirmationRequest) async -> Bool {
        // Only one confirmation can be outstanding. If another arrives, decline
        // the older one rather than losing its continuation.
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: false)
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.pending = request
        }
    }

    public func approve() { resolve(true) }
    public func decline() { resolve(false) }

    /// Called when the panel closes or a turn is stopped, so nothing is left
    /// suspended forever.
    public func cancelPending() { resolve(false) }

    private func resolve(_ approved: Bool) {
        guard let continuation else {
            pending = nil
            return
        }
        self.continuation = nil
        pending = nil
        continuation.resume(returning: approved)
    }
}

/// Adapts `ToolConfirmationCenter` to the Core protocol.
///
/// `@unchecked Sendable` is sound here because the only stored reference is used
/// exclusively through a main-actor hop.
public struct InteractiveToolConfirmer: ToolConfirming, @unchecked Sendable {
    private let center: ToolConfirmationCenter

    public init(center: ToolConfirmationCenter) {
        self.center = center
    }

    public func confirm(_ request: ToolConfirmationRequest) async -> Bool {
        await center.awaitDecision(for: request)
    }
}
