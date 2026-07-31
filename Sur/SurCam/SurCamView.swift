//
//  SurCamView.swift
//  Sur
//
//  Sur Cam tab root — the app's home screen (Snapchat-style: camera first).
//  Live preview, filter carousel (filter name label since preview itself
//  stays unfiltered), Photo/Video mode toggle, QR/flash/flip controls, and
//  a shutter button wired through MediaCaptureProcessor →
//  CaptureAttestationCoordinator → CapturePreviewView. QR-sticker
//  compositing and post-capture lineage edits land in the next step — the
//  QR toggle exists in chrome already but doesn't do anything yet.
//

import SwiftUI

enum SurCamMode: String, CaseIterable {
    case photo = "Photo"
    case video = "Video"
}

struct SurCamView: View {
    @StateObject private var camera = CameraSessionManager()
    @State private var selectedFilter: SurCamFilter = .none
    @State private var mode: SurCamMode = .photo
    @State private var qrEnabled = false
    @State private var isCapturing = false
    @State private var captureMessage: String?
    @State private var previewImage: UIImage?
    @State private var previewIsVideo = false
    @State private var previewAttestationId: UUID?
    @State private var showPreview = false

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
                filterCarousel
                modeAndShutter
            }
        }
        .onAppear { camera.configureIfNeeded() }
        .onDisappear { camera.stopSession() }
        .fullScreenCover(isPresented: $showPreview) {
            if let attestationId = previewAttestationId {
                CapturePreviewView(image: previewImage, isVideo: previewIsVideo, attestationId: attestationId)
            }
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

    private var filterCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(SurCamFilter.allCases) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text(filter.displayName)
                            .font(.caption)
                            .fontWeight(selectedFilter == filter ? .semibold : .regular)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedFilter == filter ? Theme.brandOrange : .black.opacity(0.35))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 8)
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

            shutterButton
        }
        .padding(.bottom, 24)
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
        isCapturing = true
        defer { isCapturing = false }
        do {
            switch mode {
            case .photo:
                let data = try await camera.capturePhoto()
                let processed = try MediaCaptureProcessor.processPhoto(rawData: data, filter: selectedFilter)
                // Hash is computed above from the pre-sticker image — the QR
                // (if enabled) is composited only into what gets saved/shown,
                // never into what's hashed.
                var finalImage = processed.finalImageForSaving
                if qrEnabled {
                    let link = ProofLink.build(contentHash: processed.contentHash)
                    finalImage = QRStickerComposer.composite(baseImage: finalImage, link: link)
                }
                let id = await CaptureAttestationCoordinator.attestPhoto(processed, finalImage: finalImage, qrApplied: qrEnabled)
                previewImage = finalImage
                previewIsVideo = false
                previewAttestationId = id
                showPreview = true
                captureMessage = nil
            case .video:
                if camera.isRecordingVideo {
                    let url = try await camera.stopRecordingVideo()
                    let processed = try MediaCaptureProcessor.processVideo(fileURL: url)
                    let id = await CaptureAttestationCoordinator.attestVideo(processed)
                    previewImage = nil
                    previewIsVideo = true
                    previewAttestationId = id
                    showPreview = true
                    captureMessage = nil
                } else {
                    _ = camera.startRecordingVideo()
                }
            }
        } catch {
            captureMessage = "Capture failed: \(error.localizedDescription)"
        }
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
