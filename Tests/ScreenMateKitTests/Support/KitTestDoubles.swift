import Foundation
@testable import ScreenMateCore
@testable import ScreenMateKit

/// Answers permission queries from a script, so permission-dependent paths can be
/// tested without touching TCC.
final class FakePermissionProbe: PermissionProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [PermissionCapability: PermissionState]
    /// What each capability becomes when requested.
    var requestResults: [PermissionCapability: PermissionState] = [:]
    private(set) var requested: [PermissionCapability] = []
    private(set) var settingsOpened: [PermissionCapability] = []

    init(states: [PermissionCapability: PermissionState] = [:]) {
        self.states = states
    }

    func state(of capability: PermissionCapability) -> PermissionState {
        lock.lock(); defer { lock.unlock() }
        return states[capability] ?? .notDetermined
    }

    func request(_ capability: PermissionCapability) async -> PermissionState {
        lock.lock()
        requested.append(capability)
        let result = requestResults[capability] ?? .granted
        states[capability] = result
        lock.unlock()
        return result
    }

    func openSystemSettings(for capability: PermissionCapability) {
        lock.lock()
        settingsOpened.append(capability)
        lock.unlock()
    }

    /// Simulates the user turning something off in System Settings.
    func revoke(_ capability: PermissionCapability) {
        lock.lock()
        states[capability] = .denied
        lock.unlock()
    }

    func grant(_ capability: PermissionCapability) {
        lock.lock()
        states[capability] = .granted
        lock.unlock()
    }
}

/// A transcriber driven by the test rather than by a microphone.
@MainActor
final class FakeSpeechTranscriber: SpeechTranscribing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var lastLocale: Locale?
    private(set) var lastMicrophoneUID: String?
    var errorToThrowOnStart: (any Error)?
    /// True between `start` and the stream finishing — i.e. "is the mic open".
    private(set) var isOpen = false

    private var continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation?

    func start(
        locale: Locale,
        preferOnDevice: Bool,
        microphoneUID: String?
    ) throws -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        if let errorToThrowOnStart { throw errorToThrowOnStart }
        startCount += 1
        lastLocale = locale
        lastMicrophoneUID = microphoneUID
        isOpen = true
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func stop() {
        stopCount += 1
        isOpen = false
    }

    func cancel() {
        cancelCount += 1
        isOpen = false
        continuation?.finish()
        continuation = nil
    }

    // MARK: Test drivers

    func emit(_ event: TranscriptionEvent) {
        continuation?.yield(event)
    }

    func fail(_ error: any Error) {
        continuation?.finish(throwing: error)
        continuation = nil
        isOpen = false
    }
}

/// A capture service that returns a canned context, or a canned failure.
final class FakeScreenCapturer: ScreenCapturing, @unchecked Sendable {
    private let lock = NSLock()
    var isAuthorizedResult = true
    var contextToReturn: ScreenContext = .fixture()
    var errorToThrow: (any Error)?
    private(set) var captureCalls: [(scope: ScreenCaptureScope, region: ScreenRegion?)] = []

    func isAuthorized() async -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isAuthorizedResult
    }

    func capture(scope: ScreenCaptureScope, region: ScreenRegion?) async throws -> ScreenContext {
        lock.lock()
        captureCalls.append((scope, region))
        let error = errorToThrow
        let context = contextToReturn
        lock.unlock()
        if let error { throw error }
        return context
    }
}

extension ScreenContext {
    static func fixture(
        extractedText: String? = "error TS2345",
        bytes: Int = 1024,
        findings: [RedactionFinding] = []
    ) -> ScreenContext {
        ScreenContext(
            kind: .window,
            imageData: Data(repeating: 0x42, count: bytes),
            mimeType: "image/png",
            pixelWidth: 1440,
            pixelHeight: 900,
            backingScaleFactor: 2,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceDescription: "Xcode — Built-in Retina Display",
            sourceBundleIdentifier: "com.apple.dt.Xcode",
            extractedText: extractedText,
            redactionFindings: findings
        )
    }
}

/// A scripted chat provider, so a whole turn can run with no network.
final class ScriptedProvider: ChatModelProviding, @unchecked Sendable {
    let id = "scripted"
    let displayName = "Scripted"
    let requiresAPIKey = false
    let models = [AIModel(id: "scripted-1", displayName: "Scripted", supportsVision: true)]

    private let lock = NSLock()
    private var replies: [String]
    private(set) var receivedRequests: [AIChatRequest] = []

    init(replies: [String]) {
        self.replies = replies
    }

    func streamChat(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, any Error> {
        lock.lock()
        receivedRequests.append(request)
        let reply = replies.isEmpty ? "done" : replies.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(reply))
            continuation.yield(.finished(.endTurn))
            continuation.finish()
        }
    }
}

/// A transport that refuses every request; nothing in these tests should reach it.
struct StubTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPResponseMetadata) {
        throw AppError.networkUnavailable
    }

    func stream(
        _ request: URLRequest
    ) async throws -> (AsyncThrowingStream<String, any Error>, HTTPResponseMetadata) {
        throw AppError.networkUnavailable
    }
}

/// Builds an `AppEnvironment` that touches neither the Keychain nor the network.
@MainActor
func makeTestEnvironment(
    settings: AppSettings = AppSettings(),
    probe: FakePermissionProbe = FakePermissionProbe(),
    transcriber: FakeSpeechTranscriber? = nil,
    directory: URL? = nil
) -> (environment: AppEnvironment, transcriber: FakeSpeechTranscriber, probe: FakePermissionProbe) {
    let fakeTranscriber = transcriber ?? FakeSpeechTranscriber()
    let base = directory ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("screenmate-kit-tests-\(UUID().uuidString)", isDirectory: true)

    let environment = AppEnvironment(
        settingsStore: InMemorySettingsStore(settings),
        secrets: InMemorySecretStore(),
        transport: StubTransport(),
        permissions: PermissionCenter(probe: probe, observeActivation: false),
        transcriber: fakeTranscriber,
        paths: AppPaths(folderName: "ScreenMateTests", base: base)
    )
    return (environment, fakeTranscriber, probe)
}
