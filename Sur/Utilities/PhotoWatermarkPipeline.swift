//
//  PhotoWatermarkPipeline.swift
//  Sur
//
//  Shared by SurCamView (fresh captures) and EditCapturedPhotoView (lineage
//  re-edits) so both apply watermarks identically. The QR proof sticker is
//  always applied — it's how the photo's on-chain proof link travels with
//  the image itself, not a cosmetic choice. The Sur logo watermark is
//  optional branding, controlled by AppSettings.surCamLogoWatermarkEnabled;
//  callers read that setting on their own actor and pass the resolved Bool
//  in, rather than this function touching AppSettings itself, so it stays
//  safe to call from a detached background task.
//

import UIKit

enum PhotoWatermarkPipeline {
    static func apply(to image: UIImage, contentHash: Data, includeLogoWatermark: Bool) -> UIImage {
        let link = ProofLink.build(contentHash: contentHash)
        var result = QRStickerComposer.composite(baseImage: image, link: link)
        if includeLogoWatermark {
            result = LogoWatermarkComposer.composite(baseImage: result)
        }
        return result
    }
}
