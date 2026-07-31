//
//  SurCamView.swift
//  Sur
//
//  Sur Cam tab root — the app's home screen (Snapchat-style: camera first).
//  Live preview, Photo/Video mode toggle, flash/flip controls, a gallery
//  thumbnail, and a shutter button.
//
//  Tapping the shutter is a single, no-confirmation action: capture, orient,
//  hash, watermark, save, and submit all happen in the background
//  (finalizeAndAttestPhoto) while the camera stays live for the next shot. No
//  filter is applied at capture time — filters only ever happen later, as a
//  deliberate re-edit from the gallery or Attest feed (EditCapturedPhotoView),
//  which records the change as a new lineage edge on chain rather than
//  something silently baked into the original capture.
//
//  Every saved photo always gets the QR proof sticker (see
//  PhotoWatermarkPipeline) — that's how the on-chain proof link travels with
//  the image, so it isn't a toggle. The Sur logo watermark next to it is
//  optional branding the user can turn off in Settings.
//

import CoreImage
import SwiftUI

enum SurCamMode: String, CaseIterable {
    case photo = "Photo"
    case video = "Video"
}

struct SurCamView: View {
    @StateObject private var camera = CameraSessionManager()
    @State private var mode: SurCamMode = .photo
    @State private var isCapturing = false
    @State private var captureMessage: String?
    @State private var lastThumbnail: UIImage?
    @State private var showGallery = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch camera.availability {
            case .ready:
                CameraPreviewView(session: camera.session)
                    .ignoresSafeArea()
            case .noHardware:
                emptyState(
                    icon: "camera.metering.unknown",
                    title: "Camera preview isn't available",
                    subtitle: "This device (or Simulator) doesn't expose a camera. Sur Cam works fully on a physical device."
                )
            case .permissionDenied:
                emptyState(
                    icon: "camera.fill.badge.ellipsis",
                    title: "Camera access is off",
                    subtitle: "Enable camera access in Settings to use Sur Cam.",
                    showSettingsButton: true
                )
            case .unknown:
                ProgressView().tint(.white)
            }

            VStack {
                topBar
                Spacer()
                if let message = captureMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.6))
                        .clipShape(Capsule())
                        .padding(.bottom, 8)
                }
                modeAndShutter
            }
        }
        .onAppear {
            camera.configureIfNeeded()
            if lastThumbnail == nil,
               let latestPhoto = CapturedMediaAttestationStore.shared.items.first(where: { $0.kind == .photo }) {
                lastThumbnail = CapturedImageCache.load(id: latestPhoto.id)
            }
        }
        .onDisappear { camera.stopSession() }
        .sheet(isPresented: $showGallery) {
            PhotoGalleryView()
        }
    }

    private var topBar: some View {
        ZStack {
            // Sur Cam brand mark — the "SnapChat home page" reference this
            // screen is modeled on always shows its own logo up top.
            HStack(spacing: 6) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text("Sur Cam")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
            }

            HStack {
                Spacer()
                Button {
                    camera.isFlashOn.toggle()
                } label: {
                    Image(systemName: camera.isFlashOn ? "bolt.fill" : "bolt.slash.fill")
                        .font(.title3)
                        .foregroundColor(.white)
                        .padding(10)
                        .background(.black.opacity(0.35))
                        .clipShape(Circle())
                }
                Button {
                    camera.toggleCamera()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.title3)
                        .foregroundColor(.white)
                        .padding(10)
                        .background(.black.opacity(0.35))
                        .clipShape(Circle())
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var modeAndShutter: some View {
        VStack(spacing: 16) {
            Picker("Mode", selection: $mode) {
                ForEach(SurCamMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .colorScheme(.dark)

            HStack {
                galleryButton
                Spacer()
                shutterButton
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 40)
        }
        .padding(.bottom, 24)
    }

    private var galleryButton: some View {
        Button {
            showGallery = true
        } label: {
            Group {
                if let lastThumbnail {
                    Image(uiImage: lastThumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.15)
                        .overlay {
                            Image(systemName: "photo.on.rectangle")
                                .foregroundColor(.white)
                        }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 1.5))
        }
    }

    private var shutterButton: some View {
        Button {
            Task { await handleShutterTap() }
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                Circle()
                    .fill(camera.isRecordingVideo ? Color.red : Color.white)
                    .frame(width: camera.isRecordingVideo ? 32 : 64, height: camera.isRecordingVideo ? 32 : 64)
                    .animation(.easeInOut(duration: 0.2), value: camera.isRecordingVideo)
            }
        }
        .disabled(camera.availability != .ready || isCapturing)
    }

    private func handleShutterTap() async {
        guard camera.availability == .ready else { return }
        switch mode {
        case .photo:
            isCapturing = true
            defer { isCapturing = false }
            do {
                let data = try await camera.capturePhoto()
                let oriented = try MediaCaptureProcessor.decodeOrientedImage(rawData: data)
                captureMessage = "Saved. Attesting…"
                Task { await finalizeAndAttestPhoto(orientedImage: oriented) }
            } catch {
                captureMessage = "Capture failed: \(error.localizedDescription)"
            }
        case .video:
            if camera.isRecordingVideo {
                isCapturing = true
                defer { isCapturing = false }
                do {
                    let url = try await camera.stopRecordingVideo()
                    let processed = try MediaCaptureProcessor.processVideo(fileURL: url)
                    captureMessage = "Saved. Attesting…"
                    Task { await attestVideoInBackground(processed) }
                } catch {
                    captureMessage = "Capture failed: \(error.localizedDescription)"
                }
            } else {
                _ = camera.startRecordingVideo()
            }
        }
    }

    /// No filter is applied here — a fresh capture is always "Normal"/`.none`;
    /// a filter only ever comes from a deliberate later re-edit
    /// (EditCapturedPhotoView), which records it as a lineage edge instead of
    /// silently baking it into the original. Runs off the main actor (real
    /// GPU/CPU work — hashing, PNG-encoding a full-res image) then hops back
    /// for the Photos save + chain submission, fire-and-forget from the
    /// shutter handler, which has already returned to a live camera by the
    /// time this finishes.
    private func finalizeAndAttestPhoto(orientedImage: CIImage) async {
        let includeLogoWatermark = AppSettings.shared.surCamLogoWatermarkEnabled
        do {
            let processed = try await Task.detached(priority: .userInitiated) {
                try MediaCaptureProcessor.finalizePhoto(orientedImage: orientedImage, filter: .none)
            }.value
            let finalImage = await Task.detached(priority: .userInitiated) {
                PhotoWatermarkPipeline.apply(
                    to: processed.finalImageForSaving, contentHash: processed.contentHash,
                    includeLogoWatermark: includeLogoWatermark
                )
            }.value
            await CaptureAttestationCoordinator.attestPhoto(processed, finalImage: finalImage, qrApplied: true)
            lastThumbnail = processed.finalImageForSaving
            if captureMessage == "Saved. Attesting…" { captureMessage = nil }
        } catch {
            captureMessage = "Attestation failed: \(error.localizedDescription)"
        }
    }

    private func attestVideoInBackground(_ processed: ProcessedVideoCapture) async {
        _ = await CaptureAttestationCoordinator.attestVideo(processed)
        if captureMessage == "Saved. Attesting…" { captureMessage = nil }
    }

    private func emptyState(icon: String, title: String, subtitle: String, showSettingsButton: Bool = false) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.7))
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if showSettingsButton {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        }
    }
}
