//
//  TextAttestationStore.swift
//  Sur
//
//  Queue of content attestations the user creates in-app. Each item is proved
//  (gnark Groth16) and submitted to the Sur Chain. Submission runs in the
//  background; an item that hasn't landed yet can be retried manually. The queue
//  is persisted so attestations survive relaunch and can be resubmitted.
//

import Foundation
import SwiftUI

/// One attested piece of content and its on-chain submission status.
struct AttestationItem: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case pending, submitting, submitted, failed }

    let id: UUID
    let text: String
    let createdAt: Date
    var ikiValues: [Int]
    var humanScore: Int
    var keystrokeCount: Int
    var status: Status
    var txHash: String?
    /// Block height the attestation was included in, once confirmed.
    var txHeight: Int64?
    var error: String?
    /// Set when this attestation originates from a captured keyboard session
    /// (KeystrokeLogsView), so we never auto-attest the same session twice.
    var sessionId: String?
    /// Provenance class. "human_keyboard" => ZK keystroke proof; the declaration
    /// origins are device-signed and do NOT claim human typing.
    var origin: String = AttestationOrigin.humanKeyboard.rawValue
    /// Citation for external_source / imported origins.
    var citation: String?

    init(id: UUID, text: String, createdAt: Date, ikiValues: [Int],
         humanScore: Int, keystrokeCount: Int, status: Status,
         txHash: String?, error: String?, sessionId: String?,
         origin: String = AttestationOrigin.humanKeyboard.rawValue, citation: String? = nil) {
        self.id = id; self.text = text; self.createdAt = createdAt
        self.ikiValues = ikiValues; self.humanScore = humanScore
        self.keystrokeCount = keystrokeCount; self.status = status
        self.txHash = txHash; self.error = error; self.sessionId = sessionId
        self.origin = origin; self.citation = citation
    }

    // Tolerant decoding so attestations persisted before keystrokeCount/sessionId
    // existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        ikiValues = try c.decodeIfPresent([Int].self, forKey: .ikiValues) ?? []
        humanScore = try c.decodeIfPresent(Int.self, forKey: .humanScore) ?? 60
        keystrokeCount = try c.decodeIfPresent(Int.self, forKey: .keystrokeCount) ?? text.count
        status = try c.decode(Status.self, forKey: .status)
        txHash = try c.decodeIfPresent(String.self, forKey: .txHash)
        txHeight = try c.decodeIfPresent(Int64.self, forKey: .txHeight)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? AttestationOrigin.humanKeyboard.rawValue
        citation = try c.decodeIfPresent(String.self, forKey: .citation)
    }
}

/// Content provenance classes (must match the chain's recognized origin strings).
enum AttestationOrigin: String, CaseIterable, Identifiable {
    case humanKeyboard = "human_keyboard"
    case deviceAuthored = "device_authored"
    case aiGenerated = "ai_generated"
    case externalSource = "external_source"
    case imported = "imported"

    var id: String { rawValue }

    /// Whether this origin requires a citation field.
    var needsCitation: Bool { self == .externalSource || self == .imported }

    /// Short label for the picker.
    var label: String {
        switch self {
        case .humanKeyboard:  return "Typed on Sur Keyboard"
        case .deviceAuthored: return "This device (typing unverified)"
        case .aiGenerated:    return "AI-generated"
        case .externalSource: return "Copied from a source"
        case .imported:       return "Imported / other"
        }
    }
}

@MainActor
final class TextAttestationStore: ObservableObject {

    static let shared = TextAttestationStore()

    @Published private(set) var items: [AttestationItem] = []

    private static let appGroup = "group.com.ordo.sure.Sur"
    private static let storageKey = "sur.attestations.v1"
    private let defaults: UserDefaults
    private let identity = SurChainIdentityManager.shared

    private init() {
        self.defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        load()
    }

    /// Minimum keystrokes the circuit accepts. Sessions below this can't produce
    /// a valid human-typing proof, so we don't auto-attest them.
    static let minKeystrokes = 10

    /// Create an attestation and immediately try to submit it (in the background).
    /// `origin` selects the provenance class; declarations carry an optional citation.
    func enqueue(text: String, ikiValues: [Int], humanScore: Int, keystrokeCount: Int,
                 origin: AttestationOrigin = .humanKeyboard, citation: String? = nil) {
        let item = AttestationItem(
            id: UUID(), text: text, createdAt: Date(),
            ikiValues: ikiValues, humanScore: humanScore, keystrokeCount: keystrokeCount,
            status: .pending, txHash: nil, error: nil, sessionId: nil,
            origin: origin.rawValue, citation: citation
        )
        items.insert(item, at: 0)
        persist()
        Task { await submit(id: item.id) }
    }

    /// Auto-attest captured keyboard sessions. Called when the Keystroke Logs view
    /// appears (and on relaunch): every eligible session not already attested is
    /// proved + submitted in the background. Re-runs are deduped by sessionId.
    func autoAttest(sessions: [KeystrokeSession]) {
        guard identity.registeredUsername != nil else { return }
        var didEnqueue = false
        for session in sessions {
            guard isEligible(session) else { continue }
            if items.contains(where: { $0.sessionId == session.sessionId }) { continue }
            let item = AttestationItem(
                id: UUID(), text: session.typedText, createdAt: Date(),
                ikiValues: interKeystrokeIntervals(session),
                humanScore: Int((session.humanTypingScore ?? 60).rounded()),
                keystrokeCount: session.signedKeystrokes.count,
                status: .pending, txHash: nil, error: nil, sessionId: session.sessionId
            )
            items.insert(item, at: 0)
            didEnqueue = true
        }
        if didEnqueue { persist() }
        Task { await submitPending() }
    }

    /// Status of a captured session in the attestation queue (for the logs UI).
    func status(forSessionId sessionId: String) -> AttestationItem? {
        items.first { $0.sessionId == sessionId }
    }

    /// A session can be auto-attested only if it has enough keystrokes to satisfy
    /// the circuit and has non-empty text.
    func isEligible(_ session: KeystrokeSession) -> Bool {
        session.signedKeystrokes.count >= Self.minKeystrokes
            && !session.typedText.isEmpty
    }

    /// Inter-keystroke intervals (ms) from a session's keystroke timestamps.
    private func interKeystrokeIntervals(_ session: KeystrokeSession) -> [Int] {
        let stamps = session.signedKeystrokes.map { $0.keystroke.timestamp }.sorted()
        guard stamps.count >= 2 else { return [] }
        var iki: [Int] = []
        for i in 1..<stamps.count {
            let ms = Int(stamps[i] - stamps[i - 1])
            if ms > 0 { iki.append(ms) }
        }
        return iki
    }

    /// Prove + submit a single item. Safe to call repeatedly (manual retry).
    func submit(id: UUID) async {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if items[idx].status == .submitted || items[idx].status == .submitting { return }
        let item = items[idx]
        update(id: id) { $0.status = .submitting; $0.error = nil }
        let isHumanKeyboard = item.origin == AttestationOrigin.humanKeyboard.rawValue
        AttestationActivityManager.shared.start(id: id.uuidString, kindLabel: isHumanKeyboard ? "Keyboard attestation" : "Text attestation")
        do {
            let result: CosmosTransactionResult
            if isHumanKeyboard {
                // Sur Keyboard content → real human-typing ZK proof.
                result = try await identity.proveAndSubmitText(
                    text: item.text, ikiValues: item.ikiValues,
                    humanScore: item.humanScore, keystrokeCount: item.keystrokeCount
                )
            } else {
                // Off-keyboard content → device-signed declaration (no human claim).
                result = try await identity.submitDeclaration(
                    text: item.text, origin: item.origin, citation: item.citation ?? ""
                )
            }
            update(id: id) { $0.status = .submitted; $0.txHash = result.txHash; $0.txHeight = result.height; $0.error = nil }
            await AttestationActivityManager.shared.end(id: id.uuidString, status: .submitted, detail: "Confirmed on-chain")
        } catch {
            update(id: id) { $0.status = .failed; $0.error = error.localizedDescription }
            await AttestationActivityManager.shared.end(id: id.uuidString, status: .failed, detail: error.localizedDescription)
        }
    }

    private var isFlushing = false

    /// Background pass: retry anything not yet on-chain. Call on view appear or
    /// from a background task. Reentrancy-guarded so a foreground and a background
    /// flush can't run concurrently and race the account sequence number.
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

    // MARK: - Private

    private func update(id: UUID, _ mutate: (inout AttestationItem) -> Void) {
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
              let decoded = try? JSONDecoder().decode([AttestationItem].self, from: data) else { return }
        // Anything left mid-submit from a previous run is treated as pending.
        items = decoded.map { var i = $0; if i.status == .submitting { i.status = .pending }; return i }
    }
}
