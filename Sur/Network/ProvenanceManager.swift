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

import Foundation

@MainActor
final class ProvenanceManager {
    static let shared = ProvenanceManager()
    private init() {}

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

        // Sign: content_hash_in ‖ content_hash_out ‖ transformation_type.
        var payload = hashIn
        payload.append(hashOut)
        payload.append(Data(transformationType.utf8))
        guard let sig = DeviceIDManager.shared.signDeclaration(payload) else {
            throw CosmosError.chainError(-1, "failed to sign provenance node")
        }

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
}
