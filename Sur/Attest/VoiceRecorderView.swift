//
//  VoiceRecorderView.swift
//  Sur
//
//  Record a voice memo, preview it, then attest its fingerprint via
//  VoiceAttestationStore (device-signed declaration — same "only the hash
//  goes on-chain" model as FileAttestationView). The recording itself is a
//  temp file, deleted once submitted or discarded; nothing but the hash
//  and duration are kept.
//

import SwiftUI
import AVFoundation
import CryptoKit

@MainActor
final class VoiceRecorderController: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var elapsed: TimeInterval = 0
    @Published var recordedURL: URL?
    @Published var permissionDenied = false

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func requestPermissionAndStart() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.startRecording()
                } else {
                    self.permissionDenied = true
                }
            }
        }
    }

    private func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return }
        r.delegate = self
        r.record()
        recorder = r
        recordedURL = url
        isRecording = true
        elapsed = 0
        startTimer()
    }

    func stopRecording() {
        recorder?.stop()
        isRecording = false
        stopTimer()
    }

    func play() {
        guard let url = recordedURL, let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.play()
        player = p
        isPlaying = true
    }

    func stopPlayback() {
        player?.stop()
        isPlaying = false
    }

    func discard() {
        stopPlayback()
        if let url = recordedURL { try? FileManager.default.removeItem(at: url) }
        recordedURL = nil
        elapsed = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.recorder else { return }
                self.elapsed = r.currentTime
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

struct VoiceRecorderView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = VoiceRecorderController()
    @StateObject private var store = VoiceAttestationStore.shared
    @State private var citation = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                Text(timeString(controller.elapsed))
                    .font(.system(size: 48, weight: .semibold, design: .monospaced))

                if controller.permissionDenied {
                    Text("Microphone access is off. Enable it in Settings to record a voice memo.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                recordButton

                if controller.recordedURL != nil && !controller.isRecording {
                    Button(controller.isPlaying ? "Stop Playback" : "Play Back") {
                        controller.isPlaying ? controller.stopPlayback() : controller.play()
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.brandOrange)
                }

                Spacer()

                if controller.recordedURL != nil && !controller.isRecording {
                    TextField(EventDescription.audio, text: $citation)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 32)

                    HStack(spacing: 16) {
                        Button("Discard", role: .destructive) { controller.discard() }
                            .buttonStyle(.bordered)
                        Button("Sign & submit", action: submit)
                            .primaryCTA()
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Voice Memo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var recordButton: some View {
        Button {
            if controller.isRecording {
                controller.stopRecording()
            } else {
                controller.requestPermissionAndStart()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(controller.isRecording ? Color.red : Theme.brandOrange)
                    .frame(width: 72, height: 72)
                Image(systemName: controller.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white)
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func submit() {
        guard let url = controller.recordedURL, let data = try? Data(contentsOf: url) else { return }
        let hash = Data(SHA256.hash(data: data))
        let trimmed = citation.trimmingCharacters(in: .whitespacesAndNewlines)
        store.enqueue(duration: controller.elapsed, contentHash: hash,
                      citation: trimmed.isEmpty ? EventDescription.audio : trimmed)
        try? FileManager.default.removeItem(at: url)
        dismiss()
    }
}
