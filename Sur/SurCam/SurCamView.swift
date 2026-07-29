//
//  SurCamView.swift
//  Sur
//
//  Sur Cam tab root — the app's home screen (Snapchat-style: camera first).
//  This step is chrome only: live preview, filter carousel (filter name
//  label since preview itself stays unfiltered), Photo/Video mode toggle,
//  QR/flash/flip controls, and a shutter button wired to real capture —
//  the capture → hash → attest → save pipeline lands in the next step.
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
    }

    private var topBar: some View {
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
                captureMessage = "Captured \(data.count / 1024) KB — attest pipeline lands next"
            case .video:
                if camera.isRecordingVideo {
                    let url = try await camera.stopRecordingVideo()
                    captureMessage = "Recorded \(url.lastPathComponent) — attest pipeline lands next"
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
