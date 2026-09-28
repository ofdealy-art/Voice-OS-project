import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ScreenMateCore

/// Turns a `CGImage` into bytes small enough to send.
///
/// Retina displays produce very large captures — a 5K screen is over 14 megapixels
/// — so the image is downscaled to a pixel budget and re-encoded before it ever
/// reaches a provider. This keeps requests inside the size limit, cuts upload
/// time, and costs nothing in legibility for text on screen.
public struct CapturedImageEncoder: Sendable {
    /// Longest edge, in pixels, after downscaling. 1568 is a good match for what
    /// current vision models actually resolve; larger images cost more and read
    /// no better.
    public let maxLongestEdge: Int
    public let byteBudget: Int

    public init(maxLongestEdge: Int = 1568, byteBudget: Int = 4 * 1024 * 1024) {
        self.maxLongestEdge = maxLongestEdge
        self.byteBudget = byteBudget
    }

    public struct Encoded: Sendable {
        public let data: Data
        public let mimeType: String
        public let pixelWidth: Int
        public let pixelHeight: Int
    }

    /// Downscales if needed, then encodes as PNG — falling back to progressively
    /// more aggressive JPEG if PNG will not fit the budget.
    public func encode(_ image: CGImage) throws -> Encoded {
        let scaled = try downscaleIfNeeded(image)

        if let png = encode(scaled, as: UTType.png.identifier, quality: nil), png.count <= byteBudget {
            return Encoded(
                data: png,
                mimeType: "image/png",
                pixelWidth: scaled.width,
                pixelHeight: scaled.height
            )
        }

        // Screenshots of text compress badly as JPEG at low quality, so step down
        // rather than jumping straight to the bottom.
        for quality in [0.85, 0.7, 0.55, 0.4] as [Double] {
            guard let jpeg = encode(scaled, as: UTType.jpeg.identifier, quality: quality) else { continue }
            if jpeg.count <= byteBudget {
                return Encoded(
                    data: jpeg,
                    mimeType: "image/jpeg",
                    pixelWidth: scaled.width,
                    pixelHeight: scaled.height
                )
            }
        }

        // Last resort: halve the dimensions once more and try again.
        let smaller = try downscale(scaled, to: max(maxLongestEdge / 2, 320))
        guard let jpeg = encode(smaller, as: UTType.jpeg.identifier, quality: 0.6) else {
            throw AppError.screenCaptureFailed(detail: "the capture could not be encoded")
        }
        guard jpeg.count <= byteBudget else {
            throw AppError.imageTooLarge(bytes: jpeg.count, limit: byteBudget)
        }
        return Encoded(
            data: jpeg,
            mimeType: "image/jpeg",
            pixelWidth: smaller.width,
            pixelHeight: smaller.height
        )
    }

    func downscaleIfNeeded(_ image: CGImage) throws -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxLongestEdge else { return image }
        return try downscale(image, to: maxLongestEdge)
    }

    func downscale(_ image: CGImage, to longestEdge: Int) throws -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > longestEdge, longest > 0 else { return image }
        let ratio = Double(longestEdge) / Double(longest)
        let width = max(1, Int((Double(image.width) * ratio).rounded()))
        let height = max(1, Int((Double(image.height) * ratio).rounded()))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AppError.screenCaptureFailed(detail: "the capture could not be resized")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else {
            throw AppError.screenCaptureFailed(detail: "the capture could not be resized")
        }
        return result
    }

    private func encode(_ image: CGImage, as type: String, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            type as CFString,
            1,
            nil
        ) else { return nil }

        var properties: [CFString: Any] = [:]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Crops to a rectangle expressed in the image's own pixel space.
    public func crop(_ image: CGImage, to rect: CGRect) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = rect.intersection(bounds).integral
        guard clamped.width >= 1, clamped.height >= 1, let cropped = image.cropping(to: clamped) else {
            throw AppError.screenCaptureFailed(detail: "the selected area was outside the display")
        }
        return cropped
    }
}
