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
    var citation: String
    var status: Status
    var txHash: String?
    var txHeight: Int64?
    var error: String?

    init(id: UUID, duration: TimeInterval, contentHash: Data, createdAt: Date, citation: String,
         status: Status, txHash: String?, txHeight: Int64?, error: String?) {
        self.id = id; self.duration = duration; self.contentHash = contentHash; self.createdAt = createdAt
        self.citation = citation; self.status = status; self.txHash = txHash; self.txHeight = txHeight; self.error = error
    }

    // Tolerant decoding so voice attestations persisted before `citation`
    // existed still load, falling back to the same default they were
    // submitted with.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        contentHash = try c.decode(Data.self, forKey: .contentHash)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        citation = try c.decodeIfPresent(String.self, forKey: .citation) ?? EventDescription.audio
        status = try c.decode(Status.self, forKey: .status)
        txHash = try c.decodeIfPresent(String.self, forKey: .txHash)
        txHeight = try c.decodeIfPresent(Int64.self, forKey: .txHeight)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
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

    func enqueue(duration: TimeInterval, contentHash: Data, citation: String = EventDescription.audio) {
        let item = VoiceAttestation(
            id: UUID(), duration: duration, contentHash: contentHash, createdAt: Date(), citation: citation,
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
        AttestationActivityManager.shared.start(id: id.uuidString, kindLabel: item.citation)
        do {
            let result = try await identity.submitDeclaration(
                contentHash: item.contentHash, origin: AttestationOrigin.deviceAuthored.rawValue,
                citation: item.citation
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
