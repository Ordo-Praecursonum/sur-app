//
//  SurCamView.swift
//  Sur
//
//  Sur Cam tab root — the app's home screen (Snapchat-style: camera first).
//  Live preview, Photo/Video mode toggle, QR/flash/flip controls, a gallery
//  thumbnail, and a shutter button.
//
//  Photo capture is two-phase: the shutter only captures + orients the raw
//  image (MediaCaptureProcessor.decodeOrientedImage), then PhotoReviewView
//  shows the actual photo so the user picks a filter against what they
//  really shot — there's no filter picker here before the shutter, since
//  the live preview stays unfiltered and picking blind against it was
//  confusing (and easy to silently ignore once chosen). Once confirmed in
//  review, the final render + hash + Photos save + chain submission all run
//  in the background (finalizeAndAttestPhoto) so the camera is immediately
//  ready for the next shot — nothing here blocks on attestation.
//

import CoreImage
import SwiftUI

enum SurCamMode: String, CaseIterable {
    case photo = "Photo"
    case video = "Video"
}

private struct PendingPhotoCapture: Identifiable {
    let id = UUID()
    let orientedImage: CIImage
    let qrEnabled: Bool
}

struct SurCamView: View {
    @StateObject private var camera = CameraSessionManager()
    @State private var mode: SurCamMode = .photo
    @State private var qrEnabled = false
    @State private var isCapturing = false
    @State private var captureMessage: String?
    @State private var pendingPhoto: PendingPhotoCapture?
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
        .fullScreenCover(item: $pendingPhoto) { pending in
            PhotoReviewView(orientedImage: pending.orientedImage) {
                pendingPhoto = nil
            } onUsePhoto: { filter, citation in
                pendingPhoto = nil
                captureMessage = "Saved. Attesting…"
                Task {
                    await finalizeAndAttestPhoto(
                        orientedImage: pending.orientedImage, filter: filter,
                        qrEnabled: pending.qrEnabled, citation: citation
                    )
                }
            }
        }
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
                Button {
                    qrEnabled.toggle()
                } label: {
                    Label("QR", systemImage: qrEnabled ? "qrcode.viewfinder" : "qrcode")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundColor(qrEnabled ? Theme.brandOrange : .white)
                        .padding(10)
                        .background(.black.opacity(0.35))
                        .clipShape(Circle())
                }
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
                pendingPhoto = PendingPhotoCapture(orientedImage: oriented, qrEnabled: qrEnabled)
                captureMessage = nil
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

    /// Runs the full-res filter render off the main actor (real GPU/CPU
    /// work — must never block the camera UI), then hops back for the
    /// Photos save + chain submission. Called fire-and-forget from the
    /// PhotoReviewView confirm handler, which has already dismissed back to
    /// a live camera by the time this finishes.
    private func finalizeAndAttestPhoto(orientedImage: CIImage, filter: SurCamFilter, qrEnabled: Bool, citation: String) async {
        do {
            let processed = try await Task.detached(priority: .userInitiated) {
                try MediaCaptureProcessor.finalizePhoto(orientedImage: orientedImage, filter: filter)
            }.value
            var finalImage = processed.finalImageForSaving
            if qrEnabled {
                let link = ProofLink.build(contentHash: processed.contentHash)
                finalImage = await Task.detached(priority: .userInitiated) {
                    QRStickerComposer.composite(baseImage: processed.finalImageForSaving, link: link)
                }.value
            }
            await CaptureAttestationCoordinator.attestPhoto(
                processed, finalImage: finalImage, qrApplied: qrEnabled, citation: citation
            )
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
