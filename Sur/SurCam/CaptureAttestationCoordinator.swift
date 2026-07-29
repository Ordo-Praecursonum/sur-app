//
//  CaptureAttestationCoordinator.swift
//  Sur
//
//  Bridges a processed Sur Cam capture to the chain (via
//  CapturedMediaAttestationStore) and to the Photos library. Saves are
//  add-only (NSPhotoLibraryAddUsageDescription) — Sur never reads the
//  existing library, only adds what it just captured. The saved asset's
//  localIdentifier is kept on the attestation record so a later edit
//  (EditCapturedPhotoView) can re-fetch the original image bytes.
//

import Photos
import UIKit

@MainActor
enum CaptureAttestationCoordinator {
    /// `finalImage` is what actually gets saved/attested-against — pass a
    /// QR-stickered image here when the QR toggle is on; `capture.contentHash`
    /// always stays the pre-sticker hash (computed by MediaCaptureProcessor).
    @discardableResult
    static func attestPhoto(_ capture: ProcessedCapture, finalImage: UIImage, qrApplied: Bool) async -> UUID {
        let assetId = await saveImageToPhotos(finalImage)
        return CapturedMediaAttestationStore.shared.enqueue(
            kind: .photo,
            contentHash: capture.contentHash,
            filterApplied: capture.filterApplied == .none ? nil : capture.filterApplied.rawValue,
            qrApplied: qrApplied,
            citation: "Sur Cam photo",
            localAssetIdentifier: assetId
        )
    }

    @discardableResult
    static func attestVideo(_ capture: ProcessedVideoCapture) async -> UUID {
        let assetId = await saveVideoToPhotos(capture.fileURL)
        return CapturedMediaAttestationStore.shared.enqueue(
            kind: .video,
            contentHash: capture.contentHash,
            filterApplied: nil,
            qrApplied: false,
            citation: "Sur Cam video",
            localAssetIdentifier: assetId
        )
    }

    private static func saveImageToPhotos(_ image: UIImage) async -> String? {
        guard await requestAddOnlyAuthorization() else { return nil }
        return await withCheckedContinuation { continuation in
            var placeholderId: String?
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetChangeRequest.creationRequestForAsset(from: image)
                placeholderId = request.placeholderForCreatedAsset?.localIdentifier
            }, completionHandler: { success, _ in
                continuation.resume(returning: success ? placeholderId : nil)
            })
        }
    }

    private static func saveVideoToPhotos(_ url: URL) async -> String? {
        guard await requestAddOnlyAuthorization() else { return nil }
        return await withCheckedContinuation { continuation in
            var placeholderId: String?
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                placeholderId = request?.placeholderForCreatedAsset?.localIdentifier
            }, completionHandler: { success, _ in
                continuation.resume(returning: success ? placeholderId : nil)
            })
        }
    }

    private static func requestAddOnlyAuthorization() async -> Bool {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }
        return status == .authorized || status == .limited
    }
}
