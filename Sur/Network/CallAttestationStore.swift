//
//  CallAttestationStore.swift
//  Sur
//
//  Queue of call-initiation attestations, shaped like the other attestation
//  stores. Always a device-signed declaration submitted BEFORE the call
//  handoff, fire-and-forget — chain confirmation shouldn't delay placing a
//  call. Failures are retryable from here (and from the Attest feed's Calls
//  filter chip).
//

import Foundation
import CryptoKit

enum CallMethod: String, Codable {
    case phone
    case facetimeVideo
    case facetimeAudio
    case whatsapp

    var displayName: String {
        switch self {
        case .phone: return "Phone"
        case .facetimeVideo: return "FaceTime Video"
        case .facetimeAudio: return "FaceTime Audio"
        case .whatsapp: return "WhatsApp"
        }
    }
}

struct CallAttestation: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case pending, submitting, submitted, failed }

    let id: UUID
    let calleeDisplayName: String
    let calleeNumberE164: String
    let method: CallMethod
    let createdAt: Date
    var status: Status
    var txHash: String?
    var txHeight: Int64?
    var error: String?
}

@MainActor
final class CallAttestationStore: ObservableObject {
    static let shared = CallAttestationStore()

    @Published private(set) var items: [CallAttestation] = []

    private static let appGroup = "group.com.ordo.sure.Sur"
    private static let storageKey = "sur.attestations.call.v1"
    private let defaults: UserDefaults
    private let identity = SurChainIdentityManager.shared

    private init() {
        self.defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        load()
    }

    @discardableResult
    func enqueue(calleeDisplayName: String, calleeNumberE164: String, method: CallMethod) -> UUID {
        let item = CallAttestation(
            id: UUID(), calleeDisplayName: calleeDisplayName, calleeNumberE164: calleeNumberE164,
            method: method, createdAt: Date(), status: .pending, txHash: nil, txHeight: nil, error: nil
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
        AttestationActivityManager.shared.start(id: id.uuidString, kindLabel: "Call to \(item.calleeDisplayName)")
        do {
            let isoTimestamp = ISO8601DateFormatter().string(from: item.createdAt)
            let canonical = "call:\(item.calleeNumberE164):\(isoTimestamp):\(item.method.rawValue)"
            let hash = Data(SHA256.hash(data: Data(canonical.utf8)))
            let result = try await identity.submitDeclaration(
                contentHash: hash, origin: AttestationOrigin.deviceAuthored.rawValue,
                citation: "Call initiated via \(item.method.displayName)"
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

    private func update(id: UUID, _ mutate: (inout CallAttestation) -> Void) {
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
              let decoded = try? JSONDecoder().decode([CallAttestation].self, from: data) else { return }
        items = decoded.map { var i = $0; if i.status == .submitting { i.status = .pending }; return i }
    }
}
