import CoreGraphics
import Foundation
import Vision
import ScreenMateCore

/// On-device text recognition.
///
/// Runs entirely locally through Vision — the image does not leave the Mac for
/// this step. The extracted text matters for two reasons: it lets a text-only
/// model still answer questions about the screen, and it is what the redactor
/// scans so the app can tell the user what it found.
public struct OCRService: Sendable {
    public init() {}

    /// Returns recognised text in reading order, or an empty string if there is
    /// none. OCR failure is never fatal: a capture without text is still useful
    /// to a vision model, so this reports nothing and lets the turn continue.
    public func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            // Vision is synchronous and CPU-heavy, so it runs off the main actor.
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true

                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                } catch {
                    continuation.resume(returning: "")
                    return
                }

                // Observations arrive top-to-bottom, so joining with newlines
                // preserves enough of the on-screen layout to be readable.
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }
}
