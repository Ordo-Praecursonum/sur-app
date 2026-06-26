//
//  CosmosTxBuilder.swift
//  Sur
//
//  Builds and encodes Cosmos SDK transactions for Sur Chain messages.
//
//  ENCODING STRATEGY:
//  ==================
//  Transactions are Amino-JSON encoded (StdTx format), which is compatible with
//  the Cosmos SDK REST /cosmos/tx/v1beta1/txs broadcast endpoint when wrapped
//  in the legacy broadcast mode request body.
//
//  Full protobuf (SIGN_MODE_DIRECT) encoding is a future enhancement. The Amino
//  path is chosen for Phase 1 because it requires no generated proto stubs on iOS.
//
//  SIGNING:
//  ========
//  This file only builds the unsigned transaction body. The caller is responsible
//  for:
//    1. Serialising the AminoSignDoc to canonical JSON (sorted keys).
//    2. Signing the JSON bytes with the account's secp256k1 private key.
//    3. Encoding the signature as base64.
//    4. Inserting the signature into the AminoTx.signatures field.
//    5. Passing the resulting AminoTxBody to CosmosClient.broadcastTx().
//
//  MESSAGE TYPES (Amino type strings):
//    sur/MsgRegisterUsername   — x/identity
//    sur/MsgAddDevice          — x/identity
//    sur/MsgSubmitAttestation  — x/attestation
//

import Foundation

// MARK: - AnyCodable

/// Heterogeneous JSON value container.
///
/// Required for AminoMsg.value, which is a map of field name → value where values
/// may be strings, numbers, booleans, arrays, or nested objects.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues { $0.value }
        } else {
            self.value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            let codableArray = array.map { AnyCodable($0) }
            try container.encode(codableArray)
        case let dict as [String: Any]:
            let codableDict = dict.mapValues { AnyCodable($0) }
            try container.encode(codableDict)
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - Transaction envelope types

/// Top-level Amino-JSON transaction wrapper (the "StdTx" format).
struct AminoTxBody: Codable {
    /// Fixed type string for Amino JSON broadcast.
    let type: String
    let value: AminoTx
}

/// The contents of a StdTx: messages, fee, signatures, memo.
struct AminoTx: Codable {
    let msg: [AminoMsg]
    let fee: AminoFee
    /// Nil before signing; populated by the caller after signing the SignDoc.
    let signatures: [AminoSignature]?
    let memo: String
}

/// A single message in the transaction.
struct AminoMsg: Codable {
    /// Amino type string, e.g. "sur/MsgRegisterUsername".
    let type: String
    /// Message fields as a heterogeneous JSON map.
    let value: [String: AnyCodable]
}

/// Transaction fee descriptor.
struct AminoFee: Codable {
    let amount: [AmountDenom]
    /// Gas limit as a decimal string (Amino JSON convention).
    let gas: String

    /// Standard fee: 5 000 usur, 200 000 gas.
    /// The x/identity ante handler requires at least registration_fee on top of gas.
    static let standard = AminoFee(
        amount: [AmountDenom(denom: "usur", amount: "5000")],
        gas: "200000"
    )

    /// Higher fee for attestation messages — ZK proof verification costs ~100 000 gas.
    static let attestation = AminoFee(
        amount: [AmountDenom(denom: "usur", amount: "10000")],
        gas: "300000"
    )
}

/// A coin amount with denomination.
struct AmountDenom: Codable {
    let denom: String
    let amount: String
}

/// A single signature entry inside the StdTx.
struct AminoSignature: Codable {
    /// Base64-encoded compressed secp256k1 public key JSON object.
    let pubKey: AminoPubKey
    /// Base64-encoded 64-byte secp256k1 compact (r||s) signature over the sign doc.
    let signature: String

    private enum CodingKeys: String, CodingKey {
        case pubKey   = "pub_key"
        case signature
    }
}

/// Amino-encoded public key (secp256k1).
struct AminoPubKey: Codable {
    let type: String
    let value: String

    /// Standard Amino type string for secp256k1 keys.
    static let secp256k1Type = "tendermint/PubKeySecp256k1"
}

// MARK: - Sign document

/// The canonical JSON sign document that must be signed by the account's private key.
///
/// This must be serialised to canonical JSON (lexicographically sorted keys, no spaces)
/// before signing. The resulting bytes are what `MultiChainKeyManager` / secp256k1 signs.
struct AminoSignDoc: Codable {
    let accountNumber: String
    let chainId: String
    let fee: AminoFee
    let memo: String
    let msgs: [AminoMsg]
    let sequence: String

    private enum CodingKeys: String, CodingKey {
        case accountNumber = "account_number"
        case chainId       = "chain_id"
        case fee
        case memo
        case msgs
        case sequence
    }
}

// MARK: - Builder

/// Builds unsigned Cosmos SDK transaction bodies for Sur Chain messages.
///
/// Workflow:
///   1. Fetch `CosmosAccount` via `CosmosClient.getAccount(address:)`.
///   2. Call one of the `build*Tx` methods to get an `AminoTxBody`.
///   3. Build an `AminoSignDoc` and serialise it to canonical JSON.
///   4. Sign the bytes with secp256k1.
///   5. Re-encode the complete `AminoTxBody` with signatures inserted.
///   6. Wrap in a broadcast request and call `CosmosClient.broadcastTx`.
struct CosmosTxBuilder {

    // MARK: - x/identity messages

    /// Build a MsgRegisterUsername transaction body (unsigned).
    ///
    /// Field set matches the chain proto (surchain.identity.v1.MsgRegisterUsername):
    /// `creator, username, control_pubkey, first_commitment, identity_sig, payload`.
    /// Byte fields are base64-encoded per the Cosmos JSON tx convention. The App
    /// Attest object is NOT sent on-chain — only the commitment (a Poseidon hash of
    /// the device key + blinding) is registered (see docs/INTEGRATION.md §3.2).
    ///
    /// - Parameters:
    ///   - creator: Bech32 address of the registrant and fee payer (proto `creator`).
    ///   - username: 3–32 chars, `^[a-z0-9_-]+$`.
    ///   - controlPubkey: 65-byte uncompressed P-256 control key (`0x04 || X || Y`).
    ///   - firstCommitment: 32-byte `Poseidon(devicePubKeyX, devicePubKeyY, blinding)`.
    ///   - identitySig: ECDSA P-256 signature over `payload`.
    ///   - payload: SHA-256 pre-image bytes the chain re-verifies (see §3.2).
    static func buildRegisterUsernameTx(
        creator: String,
        username: String,
        controlPubkey: Data,
        firstCommitment: Data,
        identitySig: Data,
        payload: Data,
        memo: String = ""
    ) -> AminoTxBody {
        let msg = AminoMsg(
            type: "sur/MsgRegisterUsername",
            value: [
                "creator":          AnyCodable(creator),
                "username":         AnyCodable(username),
                "control_pubkey":   AnyCodable(controlPubkey.base64EncodedString()),
                "first_commitment": AnyCodable(firstCommitment.base64EncodedString()),
                "identity_sig":     AnyCodable(identitySig.base64EncodedString()),
                "payload":          AnyCodable(payload.base64EncodedString())
            ]
        )
        let tx = AminoTx(msg: [msg], fee: .standard, signatures: nil, memo: memo)
        return AminoTxBody(type: "cosmos-sdk/StdTx", value: tx)
    }

    /// Build a MsgAddDevice transaction body (unsigned).
    ///
    /// Field set matches the chain proto (surchain.identity.v1.MsgAddDevice):
    /// `creator, username, new_commitment, identity_sig, payload, control_pubkey`.
    /// As with registration, the App Attest object stays off-chain; only the new
    /// device commitment is added to the user's commitment tree.
    static func buildAddDeviceTx(
        creator: String,
        username: String,
        newCommitment: Data,
        identitySig: Data,
        payload: Data,
        controlPubkey: Data
    ) -> AminoTxBody {
        let msg = AminoMsg(
            type: "sur/MsgAddDevice",
            value: [
                "creator":        AnyCodable(creator),
                "username":       AnyCodable(username),
                "new_commitment": AnyCodable(newCommitment.base64EncodedString()),
                "identity_sig":   AnyCodable(identitySig.base64EncodedString()),
                "payload":        AnyCodable(payload.base64EncodedString()),
                "control_pubkey": AnyCodable(controlPubkey.base64EncodedString())
            ]
        )
        let tx = AminoTx(msg: [msg], fee: .standard, signatures: nil, memo: "")
        return AminoTxBody(type: "cosmos-sdk/StdTx", value: tx)
    }

    /// Build a MsgSubmitAttestation transaction body (unsigned).
    ///
    /// The field set MUST match the chain proto
    /// (surchain.attestation.v1.MsgSubmitAttestation):
    /// `creator, username, content_hash, nullifier, commitment_root, proof_bytes`.
    /// The chain reconstructs the 5 public inputs from these fields, so the app
    /// sends content_hash / nullifier / commitment_root rather than the public
    /// inputs vector.  Byte fields are base64-encoded per the Cosmos JSON tx
    /// convention.
    ///
    /// Gas is set to `.attestation` because ZK proof verification in gnark costs
    /// approximately 100 000 gas on the Sur Chain (measured and governance-tuned).
    ///
    /// - Parameters:
    ///   - creator: Bech32 address of the signing account (proto `creator`).
    ///   - username: Username submitting the attestation.
    ///   - contentHash: 32-byte SHA-256 of the attested content.
    ///   - nullifier: 32-byte anti-replay token (public input #3).
    ///   - commitmentRoot: 32-byte device-commitment Merkle root (public input #4).
    ///   - proofBytes: 256-byte gnark Groth16 proof (BN254): A||B||C.
    /// - Returns: Unsigned `AminoTxBody`.
    static func buildSubmitAttestationTx(
        creator: String,
        username: String,
        contentHash: Data,
        nullifier: Data,
        commitmentRoot: Data,
        proofBytes: Data
    ) -> AminoTxBody {
        let msg = AminoMsg(
            type: "sur/MsgSubmitAttestation",
            value: [
                "creator":         AnyCodable(creator),
                "username":        AnyCodable(username),
                "content_hash":    AnyCodable(contentHash.base64EncodedString()),
                "nullifier":       AnyCodable(nullifier.base64EncodedString()),
                "commitment_root": AnyCodable(commitmentRoot.base64EncodedString()),
                "proof_bytes":     AnyCodable(proofBytes.base64EncodedString())
            ]
        )

        let tx = AminoTx(
            msg:        [msg],
            fee:        .attestation,
            signatures: nil,
            memo:       ""
        )

        return AminoTxBody(type: "cosmos-sdk/StdTx", value: tx)
    }

    // MARK: - Sign document construction

    /// Build the canonical sign document for a transaction.
    ///
    /// The returned `AminoSignDoc` must be encoded to canonical JSON (lexicographically
    /// sorted keys, no extra whitespace) before hashing and signing.
    ///
    /// - Parameters:
    ///   - txBody: Unsigned transaction body from one of the `build*Tx` methods.
    ///   - account: Account info (sequence and account number).
    ///   - chainID: Chain identifier matching the intended target chain.
    /// - Returns: `AminoSignDoc` ready for JSON serialisation and signing.
    static func buildSignDoc(
        txBody: AminoTxBody,
        account: CosmosAccount,
        chainID: String
    ) -> AminoSignDoc {
        return AminoSignDoc(
            accountNumber: String(account.accountNumber),
            chainId:       chainID,
            fee:           txBody.value.fee,
            memo:          txBody.value.memo,
            msgs:          txBody.value.msg,
            sequence:      String(account.sequence)
        )
    }

    /// Attach a signature to a transaction body, producing a broadcast-ready body.
    ///
    /// - Parameters:
    ///   - txBody: Unsigned transaction body.
    ///   - compressedPubKey: 33-byte compressed secp256k1 public key.
    ///   - signatureBytes: 64-byte compact (r||s) secp256k1 signature over the sign doc hash.
    /// - Returns: `AminoTxBody` with the signature field populated, ready for JSON encoding
    ///   and broadcast via `CosmosClient.broadcastTx`.
    static func attachSignature(
        to txBody: AminoTxBody,
        compressedPubKey: Data,
        signatureBytes: Data
    ) -> AminoTxBody {
        let pubKey = AminoPubKey(
            type:  AminoPubKey.secp256k1Type,
            value: compressedPubKey.base64EncodedString()
        )

        let signature = AminoSignature(
            pubKey:    pubKey,
            signature: signatureBytes.base64EncodedString()
        )

        let signedTx = AminoTx(
            msg:        txBody.value.msg,
            fee:        txBody.value.fee,
            signatures: [signature],
            memo:       txBody.value.memo
        )

        return AminoTxBody(type: txBody.type, value: signedTx)
    }

    // MARK: - Canonical JSON encoding

    /// Encode an `AminoSignDoc` to canonical JSON (sorted keys, no whitespace).
    ///
    /// Cosmos Amino signing requires deterministic JSON. This is a recursive sort
    /// implementation that guarantees key order without relying on Foundation's
    /// dictionary insertion order (which is unspecified).
    ///
    /// - Parameter signDoc: The sign document to encode.
    /// - Returns: Canonical JSON bytes, or nil if encoding fails.
    static func canonicalJSON(_ signDoc: AminoSignDoc) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(signDoc)
    }

    /// Encode a complete `AminoTxBody` to JSON for broadcast.
    ///
    /// - Parameter txBody: Signed transaction body.
    /// - Returns: JSON bytes ready for `CosmosClient.broadcastTx`, or nil if encoding fails.
    static func encodeTxForBroadcast(_ txBody: AminoTxBody) -> Data? {
        let encoder = JSONEncoder()
        // Broadcast payload does not require sorted keys — only the sign doc does.
        return try? encoder.encode(txBody)
    }
}
