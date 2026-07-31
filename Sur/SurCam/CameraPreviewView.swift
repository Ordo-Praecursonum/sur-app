//
//  CameraPreviewView.swift
//  Sur
//
//  UIViewRepresentable wrapping AVCaptureVideoPreviewLayer. Unfiltered live
//  preview by design (see SurCamFilter) — filters are applied to the
//  captured still, not rendered in real time, to avoid a GPU frame-pipeline
//  build-out disproportionate to a curated filter list.
//

import AVFoundation
import SwiftUI

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            // swiftlint:disable:next force_cast
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
