//
//  MediaCaptureProcessor.swift
//  Sur
//
//  Turns raw capture output into something attestable. Photo processing is
//  split in two: decodeOrientedImage() runs right after the shutter (orients
//  the raw sensor bytes correctly, no filter yet — filters are chosen in
//  PhotoReviewView against the actual photo, not before the shutter), and
//  finalizePhoto() renders the chosen filter + hashes once the user commits
//  in review. Video is hashed as-is (no filter/QR on video in v1 — see the
//  plan's deferred-items note).
//

import CoreImage
import CryptoKit
import ImageIO
import UIKit

struct ProcessedCapture {
    let finalImageForSaving: UIImage
    let contentHash: Data
    let filterApplied: SurCamFilter
}

struct ProcessedVideoCapture {
    let fileURL: URL
    let contentHash: Data
}

enum MediaCaptureProcessor {
    enum ProcessingError: Error {
        case decodeFailed
        case renderFailed
    }

    /// Decodes the raw capture bytes and bakes in the correct orientation
    /// from the JPEG's EXIF tag. `AVCapturePhoto.fileDataRepresentation()`
    /// encodes the sensor's raw readout with an orientation tag rather than
    /// pre-rotated pixels — `CIImage(data:)` alone ignores that tag, which
    /// is what was producing sideways/upside-down saved photos. Applying it
    /// once here means every downstream step (preview, filtering, hashing,
    /// QR compositing) works with pixels that are already right-side up.
    static func decodeOrientedImage(rawData: Data) throws -> CIImage {
        guard let ciImage = CIImage(data: rawData) else { throw ProcessingError.decodeFailed }
        guard let source = CGImageSourceCreateWithData(rawData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawOrientation = properties[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) else {
            return ciImage
        }
        return ciImage.oriented(orientation)
    }

    /// Renders `filter` on an already-oriented image at full resolution and
    /// hashes the resulting PNG bytes. The hash is computed on this
    /// filtered-but-unstickered image — any QR sticker is composited
    /// afterwards (see QRStickerComposer), never before hashing, so the
    /// proof link isn't a hash of its own encoding.
    ///
    /// `nonisolated` so callers can run it off the main actor (from
    /// `Task.detached`) — this does real GPU/CPU work and must never block
    /// the camera UI when the user confirms a photo.
    nonisolated static func finalizePhoto(orientedImage: CIImage, filter: SurCamFilter) throws -> ProcessedCapture {
        let filtered = filter.apply(to: orientedImage)
        let context = CIContext()
        guard let cgImage = context.createCGImage(filtered, from: orientedImage.extent) else {
            throw ProcessingError.renderFailed
        }
        let uiImage = UIImage(cgImage: cgImage)
        guard let pngData = uiImage.pngData() else { throw ProcessingError.renderFailed }
        let hash = Data(SHA256.hash(data: pngData))
        return ProcessedCapture(finalImageForSaving: uiImage, contentHash: hash, filterApplied: filter)
    }

    static func processVideo(fileURL: URL) throws -> ProcessedVideoCapture {
        let data = try Data(contentsOf: fileURL)
        let hash = Data(SHA256.hash(data: data))
        return ProcessedVideoCapture(fileURL: fileURL, contentHash: hash)
    }
}
