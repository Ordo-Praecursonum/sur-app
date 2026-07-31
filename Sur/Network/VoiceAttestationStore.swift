//
//  VoiceAttestationStore.swift
//  Sur
//
//  Queue of voice-memo attestations, shaped like FileAttestationStore.
//  Always a device-signed declaration (origin "device_authored") — a voice
//  memo has no ZK "human typing" proof path, only Sur Keyboard text does.
//

import Foundation

struct VoiceAttestation: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case pending, submitting, submitted, failed }

    let id: UUID
    let duration: TimeInterval
    let contentHash: Data
    let createdAt: Date
    var status: Status
    var txHash: String?
    var txHeight: Int64?
    var error: String?
}

@MainActor
final class VoiceAttestationStore: ObservableObject {
    static let shared = VoiceAttestationStore()

    @Published private(set) var items: [VoiceAttestation] = []

    private static let appGroup = "group.com.ordo.sure.Sur"
    private static let storageKey = "sur.attestations.voice.v1"
    private let defaults: UserDefaults
    private let identity = SurChainIdentityManager.shared

    private init() {
        self.defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        load()
    }

    func enqueue(duration: TimeInterval, contentHash: Data) {
        let item = VoiceAttestation(
            id: UUID(), duration: duration, contentHash: contentHash, createdAt: Date(),
            status: .pending, txHash: nil, txHeight: nil, error: nil
        )
        items.insert(item, at: 0)
        persist()
        Task { await submit(id: item.id) }
    }

    func submit(id: UUID) async {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if items[idx].status == .submitted || items[idx].status == .submitting { return }
        let item = items[idx]
        update(id: id) { $0.status = .submitting; $0.error = nil }
        AttestationActivityManager.shared.start(id: id.uuidString, kindLabel: "Voice memo (\(Int(item.duration))s)")
        do {
            let result = try await identity.submitDeclaration(
                contentHash: item.contentHash, origin: AttestationOrigin.deviceAuthored.rawValue,
                citation: "Voice memo (\(Int(item.duration))s)"
            )
            update(id: id) { $0.status = .submitted; $0.txHash = result.txHash; $0.txHeight = result.height; $0.error = nil }
            await AttestationActivityManager.shared.end(id: id.uuidString, status: .submitted, detail: "Confirmed on-chain")
        } catch {
            update(id: id) { $0.status = .failed; $0.error = error.localizedDescription }
            await AttestationActivityManager.shared.end(id: id.uuidString, status: .failed, detail: error.localizedDescription)
        }
    }

    private var isFlushing = false

    func submitPending() async {
        if isFlushing { return }
        isFlushing = true
        defer { isFlushing = false }
        for item in items where item.status == .pending || item.status == .failed {
            await submit(id: item.id)
        }
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    private func update(id: UUID, _ mutate: (inout VoiceAttestation) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[idx])
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([VoiceAttestation].self, from: data) else { return }
        items = decoded.map { var i = $0; if i.status == .submitting { i.status = .pending }; return i }
    }
}
