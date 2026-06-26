//
//  SurChainSigner.swift
//  Sur
//
//  Sur Chain account address derivation + Amino transaction signing.
//
//  The Sur Chain account (the fee-paying `creator`) is a secp256k1 key. For M1 we
//  reuse the wallet's stored secp256k1 private key as the Sur Chain account key and
//  derive its `sur1…` bech32 address the same way MultiChainKeyManager derives the
//  Cosmos address (SHA-256 → RIPEMD-160 → bech32), only with the "sur" HRP.
//
//  Signing follows the Amino-JSON path already in CosmosTxBuilder:
//    canonical JSON(signDoc) → SHA-256 → secp256k1 sign (64-byte compact, low-S).
//
//  NOTE (verify on device): this reuses the wallet key for the chain account and
//  assumes the account is funded with usur before registration/attestation (fees).
//

import Foundation
import CryptoKit

enum SurChainSignerError: LocalizedError {
    case addressDerivationFailed
    case signingFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .addressDerivationFailed: return "Could not derive the Sur Chain address."
        case .signingFailed:           return "Failed to sign the transaction."
        case .encodingFailed:          return "Failed to encode the transaction."
        }
    }
}

enum SurChainSigner {

    /// Sur Chain bech32 human-readable prefix.
    static let hrp = "sur"

    /// Derive the `sur1…` account address from a secp256k1 private key.
    static func address(fromPrivateKey privateKey: Data) -> String? {
        guard let compressed = Secp256k1.deriveCompressedPublicKey(from: privateKey) else {
            return nil
        }
        return address(fromCompressedPubKey: compressed)
    }

    /// Derive the `sur1…` address from a 33-byte compressed secp256k1 public key.
    static func address(fromCompressedPubKey compressed: Data) -> String? {
        let sha = SHA256.hash(data: compressed)
        let hash160 = RIPEMD160.hash(Data(sha))
        return Bech32.encode(hrp: hrp, data: hash160)
    }

    /// Sign an unsigned tx body and return broadcast-ready JSON bytes.
    ///
    /// - Parameters:
    ///   - txBody: from one of `CosmosTxBuilder.build*Tx`.
    ///   - account: from `CosmosClient.getAccount` (sequence + account number).
    ///   - chainID: target chain id.
    ///   - privateKey: secp256k1 account key (the fee payer / signer).
    static func signAndEncode(
        txBody: AminoTxBody,
        account: CosmosAccount,
        chainID: String,
        privateKey: Data
    ) throws -> Data {
        let signDoc = CosmosTxBuilder.buildSignDoc(txBody: txBody, account: account, chainID: chainID)
        guard let canonical = CosmosTxBuilder.canonicalJSON(signDoc) else {
            throw SurChainSignerError.encodingFailed
        }
        let digest = Data(SHA256.hash(data: canonical))
        guard let sig = Secp256k1.sign(messageHash: digest, with: privateKey) else {
            throw SurChainSignerError.signingFailed
        }
        guard let compressed = Secp256k1.deriveCompressedPublicKey(from: privateKey) else {
            throw SurChainSignerError.signingFailed
        }
        let signed = CosmosTxBuilder.attachSignature(
            to: txBody,
            compressedPubKey: compressed,
            signatureBytes: sig
        )
        guard let body = CosmosTxBuilder.encodeTxForBroadcast(signed) else {
            throw SurChainSignerError.encodingFailed
        }
        return body
    }
}
