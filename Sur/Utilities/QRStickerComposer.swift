//
//  QRStickerComposer.swift
//  Sur
//
//  Composites a QR-code "sticker" (encoding a proof link) onto a captured
//  Sur Cam photo. QR generation mirrors ReceiveSurView.qrImage(from:) exactly
//  (CIFilter.qrCodeGenerator(), correction level "M"); compositing is plain
//  Core Graphics via UIGraphicsImageRenderer.
//
//  Important: callers must compute the photo's content hash from the image
//  BEFORE calling composite(_:link:) — the sticker is applied to the already-
//  hashed bytes, not the other way around, so the hash doesn't depend on its
//  own encoded representation.
//

import CoreImage.CIFilterBuiltins
import UIKit

enum QRStickerComposer {
    private static let qrContext = CIContext()

    /// Returns `baseImage` with a white-backed QR sticker (encoding `link`)
    /// composited into the bottom-right corner. Returns `baseImage` unchanged
    /// if QR generation fails for any reason (never blocks a capture).
    static func composite(baseImage: UIImage, link: URL) -> UIImage {
        guard let qrImage = qrImage(from: link.absoluteString) else { return baseImage }

        let renderer = UIGraphicsImageRenderer(size: baseImage.size, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = baseImage.scale
            return format
        }())

        return renderer.image { _ in
            baseImage.draw(at: .zero)

            let shortSide = min(baseImage.size.width, baseImage.size.height)
            let stickerSide = shortSide * 0.18
            let padding = shortSide * 0.04
            let stickerRect = CGRect(
                x: baseImage.size.width - stickerSide - padding,
                y: baseImage.size.height - stickerSide - padding,
                width: stickerSide,
                height: stickerSide
            )

            // White backing card so the QR stays scannable over busy photo content.
            let backingInset = stickerSide * 0.08
            let backingRect = stickerRect.insetBy(dx: -backingInset, dy: -backingInset)
            let backingPath = UIBezierPath(roundedRect: backingRect, cornerRadius: backingInset)
            UIColor.white.setFill()
            backingPath.fill()

            qrImage.draw(in: stickerRect)
        }
    }

    private static func qrImage(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = qrContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
