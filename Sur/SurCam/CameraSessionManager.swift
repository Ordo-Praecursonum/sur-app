//
//  CameraSessionManager.swift
//  Sur
//
//  Owns the AVCaptureSession for Sur Cam: permission handling, photo/movie
//  outputs, front/back + flash toggles, and the actual capture calls.
//  Degrades to a friendly "no camera" state on Simulator (no camera
//  hardware) rather than crashing or silently failing.
//

@preconcurrency import AVFoundation
import UIKit

enum CameraAvailability {
    case unknown
    case ready
    case noHardware
    case permissionDenied
}

@MainActor
final class CameraSessionManager: NSObject, ObservableObject {
    @Published private(set) var availability: CameraAvailability = .unknown
    @Published private(set) var isRecordingVideo = false
    @Published var isUsingFrontCamera = false
    @Published var isFlashOn = false

    // AVFoundation recommends configuring/starting a capture session on a
    // dedicated background queue (beginConfiguration/startRunning can block).
    // These are only ever touched from `sessionQueue`'s closures (or read as
    // an immutable reference by CameraPreviewView) — `nonisolated(unsafe)`
    // opts them out of this class's MainActor isolation so those background
    // closures compile under strict concurrency, while every @Published
    // property above stays properly MainActor-protected for SwiftUI.
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) private var videoInput: AVCaptureDeviceInput?
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let movieOutput = AVCaptureMovieFileOutput()
    nonisolated(unsafe) private var photoContinuation: CheckedContinuation<Data, Error>?
    nonisolated(unsafe) private var videoContinuation: CheckedContinuation<URL, Error>?
    private let sessionQueue = DispatchQueue(label: "com.ordo.sur.surcam.session")

    func configureIfNeeded() {
        guard AVCaptureDevice.default(for: .video) != nil else {
            availability = .noHardware
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startConfiguredSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.startConfiguredSession()
                    } else {
                        self.availability = .permissionDenied
                    }
                }
            }
        default:
            availability = .permissionDenied
        }
    }

    private func startConfiguredSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
               let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)
                self.videoInput = input
            }
            if let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
               self.session.canAddInput(audioInput) {
                self.session.addInput(audioInput)
            }
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }
            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
            }
            self.session.commitConfiguration()
            self.session.startRunning()
            Task { @MainActor in self.availability = .ready }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    func toggleCamera() {
        guard let currentInput = videoInput else { return }
        let newPosition: AVCaptureDevice.Position = isUsingFrontCamera ? .back : .front
        guard let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
              let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.removeInput(currentInput)
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoInput = newInput
            } else {
                self.session.addInput(currentInput)
            }
            self.session.commitConfiguration()
        }
        isUsingFrontCamera.toggle()
    }

    func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.photoContinuation = continuation
            let settings = AVCapturePhotoSettings()
            if let device = videoInput?.device, device.hasFlash {
                settings.flashMode = isFlashOn ? .on : .off
            }
            sessionQueue.async { [weak self] in
                self?.photoOutput.capturePhoto(with: settings, delegate: self!)
            }
        }
    }

    func startRecordingVideo() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        sessionQueue.async { [weak self] in
            self?.movieOutput.startRecording(to: url, recordingDelegate: self!)
        }
        isRecordingVideo = true
        return url
    }

    func stopRecordingVideo() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.videoContinuation = continuation
            sessionQueue.async { [weak self] in
                self?.movieOutput.stopRecording()
            }
        }
    }
}

extension CameraSessionManager: AVCapturePhotoCaptureDelegate {
    // Fires on an AVFoundation-managed queue, not necessarily MainActor.
    // CheckedContinuation.resume is safe to call from any thread, so only
    // the (nonisolated(unsafe)) continuation itself is touched here.
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let continuation = photoContinuation else { return }
        photoContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else if let data = photo.fileDataRepresentation() {
            continuation.resume(returning: data)
        } else {
            continuation.resume(throwing: CosmosError.chainError(-1, "photo capture produced no data"))
        }
    }
}

extension CameraSessionManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                 from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in self.isRecordingVideo = false }
        guard let continuation = videoContinuation else { return }
        videoContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: outputFileURL)
        }
    }
}
