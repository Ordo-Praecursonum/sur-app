//
//  ProvenanceManager.swift
//  Sur
//
//  Client for surchain.provenance.v1.MsgSubmitProvenanceNode — links two
//  already-attested content hashes as a transformation edge (e.g. a Sur Cam
//  photo re-edited with a new filter from the Attest feed). Modeled on
//  SurChainIdentityManager's submitDeclaration: same device-signed shape, no
//  ZK proof, reuses SurChainIdentityManager.broadcastSignedMessage for the
//  actual sign/broadcast/confirm plumbing rather than duplicating it.
//
//  Self-authored edits only: the device's own bech32 id (surdev1…) is used as
//  `principal_id`. Registering Sur as a named platform principal (via
//  MsgRegisterPrincipal, for third-party pipeline operators) is a separate,
//  later concern — not needed for a user editing their own capture.
//
//  Two things the chain enforces that are easy to miss:
//   - SubmitProvenanceNode's signature is verified with `ecdsa.VerifyASN1`
//     against a P-256 pubkey — that's the Secure Enclave device key
//     (SecureEnclaveManager), NOT the secp256k1 key DeviceIDManager uses for
//     x/attestation declarations. Signing with the wrong key/curve here
//     fails verification silently different from a helpful error.
//   - `principal_id` must already exist via a prior MsgRegisterPrincipal —
//     the keeper looks it up and rejects unknown principals. This class
//     self-registers the device's own id lazily, once, before its first
//     provenance node submission.
//

import Foundation

@MainActor
final class ProvenanceManager {
    static let shared = ProvenanceManager()
    private init() {
        self.defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
    }

    private static let appGroup = "group.com.ordo.sure.Sur"
    private static let principalRegisteredKey = "sur.provenance.principalRegistered.v1"
    private let defaults: UserDefaults

    /// Records that `hashOut` was derived from `hashIn` via `transformationType`
    /// (e.g. "filter:noir"). Throws if the device has no identity yet or if the
    /// broadcast/confirmation fails — callers should treat this as best-effort
    /// alongside the edited photo's own independent attestation, not a
    /// precondition for saving the edit locally.
    @discardableResult
    func submitProvenanceNode(hashIn: Data, hashOut: Data, transformationType: String) async throws -> CosmosTransactionResult {
        let identity = SurChainIdentityManager.shared
        let deviceID = try identity.ensureDeviceIdentity()
        guard let creator = identity.accountAddress() else {
            throw CosmosError.chainError(-1, "wallet account unavailable")
        }

        try await ensurePrincipalRegistered(deviceID: deviceID, creator: creator)

        // Sign: content_hash_in ‖ content_hash_out ‖ transformation_type — with
        // the P-256 Secure Enclave device key, matching the chain's
        // ecdsa.VerifyASN1(principal.Pubkey, ...) check.
        var payload = hashIn
        payload.append(hashOut)
        payload.append(Data(transformationType.utf8))
        let sig = try SecureEnclaveManager.shared.signWithDeviceKey(payload)

        let msgBody = CosmosProtoTx.encodeMsgSubmitProvenanceNode(
            creator: creator,
            contentHashIn: hashIn,
            contentHashOut: hashOut,
            transformationType: transformationType,
            principalID: deviceID,
            sig: sig
        )
        return try await identity.broadcastSignedMessage(
            msgTypeURL: "/surchain.provenance.v1.MsgSubmitProvenanceNode",
            msgBody: msgBody,
            feeAmount: "10000",
            gasLimit: 300_000
        )
    }

    /// Self-registers the device's own id as a provenance principal, once.
    /// Skips the broadcast entirely once the local flag is set; if the flag
    /// was lost (reinstall, restore) and the chain says the principal already
    /// exists, that's treated as success too rather than surfaced as an error.
    private func ensurePrincipalRegistered(deviceID: String, creator: String) async throws {
        guard !defaults.bool(forKey: Self.principalRegisteredKey) else { return }

        let pubkey = try SecureEnclaveManager.shared.getDeviceSigningPublicKeyBytes()
        let msgBody = CosmosProtoTx.encodeMsgRegisterPrincipal(
            creator: creator,
            principalID: deviceID,
            name: "",
            pubkey: pubkey,
            principalType: "device",
            domain: ""
        )
        do {
            _ = try await SurChainIdentityManager.shared.broadcastSignedMessage(
                msgTypeURL: "/surchain.provenance.v1.MsgRegisterPrincipal",
                msgBody: msgBody,
                feeAmount: "10000",
                gasLimit: 250_000
            )
            defaults.set(true, forKey: Self.principalRegisteredKey)
        } catch let CosmosError.chainError(_, log) where log.localizedCaseInsensitiveContains("already registered") {
            defaults.set(true, forKey: Self.principalRegisteredKey)
        }
    }
}
