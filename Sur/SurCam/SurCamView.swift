//
//  SurCamView.swift
//  Sur
//
//  Sur Cam tab root — stub for now, fleshed out in the Sur Cam chrome and
//  capture-pipeline steps (CameraSessionManager, filter carousel, capture,
//  QR sticker, lineage edits).
//

import SwiftUI

struct SurCamView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
                Text("Sur Cam")
                    .font(.headline)
                    .foregroundColor(.white)
            }
        }
    }
}
