//
//  CaptureAttestationCoordinator.swift
//  Sur
//
//  Bridges a processed Sur Cam capture to the chain (via
//  CapturedMediaAttestationStore) and to the Photos library. Saves are
//  add-only (NSPhotoLibraryAddUsageDescription) — Sur never reads the
//  existing library, only adds what it just captured.
//

import Photos
import UIKit

@MainActor
enum CaptureAttestationCoordinator {
    @discardableResult
    static func attestPhoto(_ capture: ProcessedCapture) -> UUID {
        saveImageToPhotos(capture.finalImageForSaving)
        return CapturedMediaAttestationStore.shared.enqueue(
            kind: .photo,
            contentHash: capture.contentHash,
            filterApplied: capture.filterApplied == .none ? nil : capture.filterApplied.rawValue,
            qrApplied: false,
            citation: "Sur Cam photo"
        )
    }

    @discardableResult
    static func attestVideo(_ capture: ProcessedVideoCapture) -> UUID {
        saveVideoToPhotos(capture.fileURL)
        return CapturedMediaAttestationStore.shared.enqueue(
            kind: .video,
            contentHash: capture.contentHash,
            filterApplied: nil,
            qrApplied: false,
            citation: "Sur Cam video"
        )
    }

    private static func saveImageToPhotos(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            })
        }
    }

    private static func saveVideoToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            })
        }
    }
}
