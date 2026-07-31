//
//  FileAttestationStore.swift
//  Sur
//
//  Queue of file attestations (picked via FileAttestationView's document
//  picker), shaped identically to TextAttestationStore but always submitted
//  as a device-signed declaration (files have no ZK "human typing" proof
//  path — that only exists for Sur Keyboard keystroke sessions).
//

import Foundation

struct FileAttestation: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case pending, submitting, submitted, failed }

    let id: UUID
    let fileName: String
    let fileSize: Int
    let contentHash: Data
    let createdAt: Date
    var origin: String
    var citation: String?
    var status: Status
    var txHash: String?
    var txHeight: Int64?
    var error: String?
}

@MainActor
final class FileAttestationStore: ObservableObject {
    static let shared = FileAttestationStore()

    @Published private(set) var items: [FileAttestation] = []

    private static let appGroup = "group.com.ordo.sure.Sur"
    private static let storageKey = "sur.attestations.file.v1"
    private let defaults: UserDefaults
    private let identity = SurChainIdentityManager.shared

    private init() {
        self.defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        load()
    }

    func enqueue(fileName: String, fileSize: Int, contentHash: Data,
                 origin: AttestationOrigin, citation: String?) {
        let item = FileAttestation(
            id: UUID(), fileName: fileName, fileSize: fileSize, contentHash: contentHash,
            createdAt: Date(), origin: origin.rawValue, citation: citation,
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
        AttestationActivityManager.shared.start(id: id.uuidString, kindLabel: "File: \(item.fileName)")
        do {
            let result = try await identity.submitDeclaration(
                contentHash: item.contentHash, origin: item.origin, citation: item.citation ?? ""
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

    private func update(id: UUID, _ mutate: (inout FileAttestation) -> Void) {
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
              let decoded = try? JSONDecoder().decode([FileAttestation].self, from: data) else { return }
        items = decoded.map { var i = $0; if i.status == .submitting { i.status = .pending }; return i }
    }
}
