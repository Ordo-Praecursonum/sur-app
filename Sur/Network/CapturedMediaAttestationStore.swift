//
//  CapturedMediaAttestationStore.swift
//  Sur
//
//  Queue of Sur Cam photo/video attestations, shaped like the other
//  attestation stores. Always a device-signed declaration — captured media
//  has no ZK "human typing" proof path, only Sur Keyboard text does.
//

import Foundation

struct CapturedMediaAttestation: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case photo, video }
    enum Status: String, Codable { case pending, submitting, submitted, failed }

    let id: UUID
    let kind: Kind
    let createdAt: Date
    let contentHash: Data
    var filterApplied: String?
    var qrApplied: Bool
    var citation: String
    var status: Status
    var txHash: String?
    var txHeight: Int64?
    var error: String?
}

@MainActor
final class CapturedMediaAttestationStore: ObservableObject {
    static let shared = CapturedMediaAttestationStore()

    @Published private(set) var items: [CapturedMediaAttestation] = []

    private static let appGroup = "group.com.ordo.sure.Sur"
    private static let storageKey = "sur.attestations.media.v1"
    private let defaults: UserDefaults
    private let identity = SurChainIdentityManager.shared

    private init() {
        self.defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        load()
    }

    @discardableResult
    func enqueue(kind: CapturedMediaAttestation.Kind, contentHash: Data,
                 filterApplied: String?, qrApplied: Bool, citation: String) -> UUID {
        let item = CapturedMediaAttestation(
            id: UUID(), kind: kind, createdAt: Date(), contentHash: contentHash,
            filterApplied: filterApplied, qrApplied: qrApplied, citation: citation,
            status: .pending, txHash: nil, txHeight: nil, error: nil
        )
        items.insert(item, at: 0)
        persist()
        Task { await submit(id: item.id) }
        return item.id
    }

    func submit(id: UUID) async {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if items[idx].status == .submitted || items[idx].status == .submitting { return }
        let item = items[idx]
        update(id: id) { $0.status = .submitting; $0.error = nil }
        do {
            let result = try await identity.submitDeclaration(
                contentHash: item.contentHash, origin: AttestationOrigin.deviceAuthored.rawValue,
                citation: item.citation
            )
            update(id: id) { $0.status = .submitted; $0.txHash = result.txHash; $0.txHeight = result.height; $0.error = nil }
        } catch {
            update(id: id) { $0.status = .failed; $0.error = error.localizedDescription }
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

    private func update(id: UUID, _ mutate: (inout CapturedMediaAttestation) -> Void) {
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
              let decoded = try? JSONDecoder().decode([CapturedMediaAttestation].self, from: data) else { return }
        items = decoded.map { var i = $0; if i.status == .submitting { i.status = .pending }; return i }
    }
}
