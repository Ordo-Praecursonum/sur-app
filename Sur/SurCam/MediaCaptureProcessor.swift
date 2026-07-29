//
//  MediaCaptureProcessor.swift
//  Sur
//
//  Turns raw capture output into something attestable: applies the selected
//  SurCamFilter to a photo and computes its content hash. Video is hashed
//  as-is (no filter/QR on video in v1 — see the plan's deferred-items note).
//

import CoreImage
import CryptoKit
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

    /// Applies `filter` to the captured photo and hashes the resulting PNG
    /// bytes. The hash is computed on this filtered-but-unstickered image —
    /// any QR sticker is composited afterwards (see QRStickerComposer), never
    /// before hashing, so the proof link isn't a hash of its own encoding.
    static func processPhoto(rawData: Data, filter: SurCamFilter) throws -> ProcessedCapture {
        guard let ciImage = CIImage(data: rawData) else { throw ProcessingError.decodeFailed }
        let filtered = filter.apply(to: ciImage)
        let context = CIContext()
        guard let cgImage = context.createCGImage(filtered, from: filtered.extent) else {
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
