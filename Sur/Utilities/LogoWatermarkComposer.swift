//
//  LogoWatermarkComposer.swift
//  Sur
//
//  Composites a translucent Sur logo watermark onto a captured Sur Cam
//  photo — bottom-left corner, mirroring QRStickerComposer's bottom-right
//  QR sticker so the two never overlap. Purely cosmetic branding: unlike
//  the QR sticker (always applied, since it carries the on-chain proof
//  link), this is optional and gated by AppSettings.surCamLogoWatermarkEnabled.
//

import UIKit

enum LogoWatermarkComposer {
    /// Returns `baseImage` with a low-opacity Sur logo composited into the
    /// bottom-left corner. Returns `baseImage` unchanged if the logo asset
    /// can't be loaded (never blocks a capture).
    static func composite(baseImage: UIImage) -> UIImage {
        guard let logo = UIImage(named: "AppLogo") else { return baseImage }

        let renderer = UIGraphicsImageRenderer(size: baseImage.size, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = baseImage.scale
            return format
        }())

        return renderer.image { _ in
            baseImage.draw(at: .zero)

            let shortSide = min(baseImage.size.width, baseImage.size.height)
            let logoSide = shortSide * 0.16
            let padding = shortSide * 0.04
            let logoRect = CGRect(x: padding, y: baseImage.size.height - logoSide - padding,
                                   width: logoSide, height: logoSide)

            logo.draw(in: logoRect, blendMode: .normal, alpha: 0.55)
        }
    }
}
