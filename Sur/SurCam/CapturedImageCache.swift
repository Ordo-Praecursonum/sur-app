//
//  CapturedImageCache.swift
//  Sur
//
//  On-disk cache of each Sur Cam photo's clean (filtered, pre-QR-sticker)
//  bytes, keyed by attestation id. Used by the in-app photo gallery and by
//  EditCapturedPhotoView's re-filter flow — deliberately NOT backed by
//  PHAsset/Photos reads: this app only ever requests add-only Photos access
//  (see CaptureAttestationCoordinator's header comment), and reading a saved
//  asset back out via PHAsset/PHImageManager without the read-access usage
//  description crashes at runtime. Keeping our own copy sidesteps that
//  entirely and doesn't depend on the user's Photos library still having
//  the asset (not deleted, fully downloaded from iCloud, etc).
//

import UIKit

enum CapturedImageCache {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SurCamCaptures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).jpg")
    }

    @discardableResult
    static func save(_ image: UIImage, id: UUID) -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.92) else { return false }
        return (try? data.write(to: url(for: id), options: .atomic)) != nil
    }

    static func load(id: UUID) -> UIImage? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return UIImage(data: data)
    }

    static func exists(id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path)
    }

    static func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}
