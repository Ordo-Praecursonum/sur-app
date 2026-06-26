//
//  CosmosProtoTx.swift
//  Sur
//
//  Builds a protobuf SIGN_MODE_DIRECT Cosmos transaction by hand.
//
//  Why hand-rolled protobuf: modern Cosmos SDK (the Sur Chain is v0.53) only
//  accepts a protobuf `BroadcastTxRequest` at POST /cosmos/tx/v1beta1/txs — the
//  body must carry base64 `tx_bytes` (a serialized `TxRaw`). The legacy Amino-JSON
//  `StdTx` broadcast was removed, which is why posting Amino JSON returned
//  `code 3: "invalid empty tx"`. The Sur messages are simple (strings/bytes/uints),
//  so a minimal wire-format encoder is reliable and avoids adding SwiftProtobuf +
//  generated stubs.
//
//  Signing: SIGN_MODE_DIRECT signs SHA-256(SignDoc) with secp256k1 (64-byte r‖s,
//  low-S). The chain reconstructs the same SignDoc from the received body/auth-info
//  bytes (taken verbatim) plus chain_id and account_number, so the signature verifies.
//

import Foundation
import CryptoKit

enum CosmosProtoTx {

    // MARK: - Protobuf wire writer

    struct Writer {
        var data = Data()

        mutating func putVarint(_ value: UInt64) {
            var v = value
            while v >= 0x80 {
                data.append(UInt8((v & 0x7F) | 0x80))
                v >>= 7
            }
            data.append(UInt8(v))
        }

        /// Wire type 2 (length-delimited): tag, length, bytes.
        mutating func putLengthDelimited(_ field: Int, _ bytes: Data) {
            putVarint((UInt64(field) << 3) | 2)
            putVarint(UInt64(bytes.count))
            data.append(bytes)
        }

        /// Wire type 0 (varint). Proto3 omits zero defaults.
        mutating func putUInt64(_ field: Int, _ value: UInt64) {
            guard value != 0 else { return }
            putVarint((UInt64(field) << 3) | 0)
            putVarint(value)
        }

        /// String, omitting the proto3 empty default.
        mutating func putString(_ field: Int, _ s: String) {
            let b = Data(s.utf8)
            guard !b.isEmpty else { return }
            putLengthDelimited(field, b)
        }

        /// String, always emitted (e.g. Any.type_url).
        mutating func putStringAlways(_ field: Int, _ s: String) {
            putLengthDelimited(field, Data(s.utf8))
        }

        /// Bytes, omitting the proto3 empty default.
        mutating func putBytes(_ field: Int, _ b: Data) {
            guard !b.isEmpty else { return }
            putLengthDelimited(field, b)
        }

        /// Embedded message (always emitted; caller controls presence).
        mutating func putMessage(_ field: Int, _ b: Data) {
            putLengthDelimited(field, b)
        }
    }

    // MARK: - Sur message encoders (produce the Any.value bytes)

    static func encodeMsgRegisterUsername(creator: String, username: String, controlPubkey: Data,
                                          firstCommitment: Data, identitySig: Data, payload: Data) -> Data {
        var w = Writer()
        w.putString(1, creator)
        w.putString(2, username)
        w.putBytes(3, controlPubkey)
        w.putBytes(4, firstCommitment)
        w.putBytes(5, identitySig)
        w.putBytes(6, payload)
        return w.data
    }

    static func encodeMsgAddDevice(creator: String, username: String, newCommitment: Data,
                                   identitySig: Data, payload: Data, controlPubkey: Data) -> Data {
        var w = Writer()
        w.putString(1, creator)
        w.putString(2, username)
        w.putBytes(3, newCommitment)
        w.putBytes(4, identitySig)
        w.putBytes(5, payload)
        w.putBytes(6, controlPubkey)
        return w.data
    }

    static func encodeMsgSubmitAttestation(creator: String, username: String, contentHash: Data,
                                           nullifier: Data, commitmentRoot: Data, proofBytes: Data,
                                           origin: String = "", citation: String = "",
                                           devicePubkey: Data = Data(), deviceSignature: Data = Data()) -> Data {
        var w = Writer()
        w.putString(1, creator)
        w.putString(2, username)
        w.putBytes(3, contentHash)
        w.putBytes(4, nullifier)
        w.putBytes(5, commitmentRoot)
        w.putBytes(6, proofBytes)
        w.putString(7, origin)        // "" => human_keyboard
        w.putString(8, citation)
        w.putBytes(9, devicePubkey)
        w.putBytes(10, deviceSignature)
        return w.data
    }

    /// cosmos.bank.v1beta1.MsgSend { from_address=1, to_address=2, amount=3 [Coin] }.
    /// `amount` is the integer micro-denom amount as a string (e.g. "1500000").
    static func encodeMsgSend(from: String, to: String, denom: String, amount: String) -> Data {
        var coin = Writer()
        coin.putString(1, denom)
        coin.putString(2, amount)

        var w = Writer()
        w.putString(1, from)
        w.putString(2, to)
        w.putMessage(3, coin.data)   // repeated Coin (single element)
        return w.data
    }

    // MARK: - Tx assembly + signing

    /// google.protobuf.Any { type_url = 1, value = 2 }
    private static func encodeAny(typeURL: String, value: Data) -> Data {
        var w = Writer()
        w.putStringAlways(1, typeURL)
        w.putLengthDelimited(2, value)
        return w.data
    }

    /// Build a signed `TxRaw` (the bytes that go into `tx_bytes`) for a single message.
    ///
    /// - Parameters:
    ///   - msgTypeURL: e.g. "/surchain.identity.v1.MsgRegisterUsername".
    ///   - msgBody: output of one of the encodeMsg* helpers.
    ///   - feeAmount: micro-denom amount as a string ("0" or "" = no explicit fee coin).
    static func buildSignedTxBytes(
        msgTypeURL: String,
        msgBody: Data,
        chainID: String,
        accountNumber: UInt64,
        sequence: UInt64,
        privateKey: Data,
        feeDenom: String,
        feeAmount: String,
        gasLimit: UInt64
    ) throws -> Data {
        guard let compressedPub = Secp256k1.deriveCompressedPublicKey(from: privateKey) else {
            throw SurChainSignerError.signingFailed
        }

        // TxBody { messages: [Any] }
        let anyMsg = encodeAny(typeURL: msgTypeURL, value: msgBody)
        var body = Writer()
        body.putMessage(1, anyMsg)
        let bodyBytes = body.data

        // secp256k1 PubKey { key = 1 } wrapped in Any
        var pkInner = Writer()
        pkInner.putBytes(1, compressedPub)
        let pubAny = encodeAny(typeURL: "/cosmos.crypto.secp256k1.PubKey", value: pkInner.data)

        // ModeInfo { single { mode = SIGN_MODE_DIRECT (1) } }
        var single = Writer()
        single.putVarint((UInt64(1) << 3) | 0) // field 1, varint
        single.putVarint(1)                     // SIGN_MODE_DIRECT
        var modeInfo = Writer()
        modeInfo.putMessage(1, single.data)

        // SignerInfo { public_key = 1, mode_info = 2, sequence = 3 }
        var signer = Writer()
        signer.putMessage(1, pubAny)
        signer.putMessage(2, modeInfo.data)
        signer.putUInt64(3, sequence)

        // Fee { amount = 1 [Coin], gas_limit = 2 }
        var fee = Writer()
        if !feeAmount.isEmpty && feeAmount != "0" {
            var coin = Writer()
            coin.putString(1, feeDenom)
            coin.putString(2, feeAmount)
            fee.putMessage(1, coin.data)
        }
        fee.putUInt64(2, gasLimit)

        // AuthInfo { signer_infos = 1 [SignerInfo], fee = 2 }
        var authInfo = Writer()
        authInfo.putMessage(1, signer.data)
        authInfo.putMessage(2, fee.data)
        let authInfoBytes = authInfo.data

        // SignDoc { body_bytes = 1, auth_info_bytes = 2, chain_id = 3, account_number = 4 }
        var signDoc = Writer()
        signDoc.putLengthDelimited(1, bodyBytes)
        signDoc.putLengthDelimited(2, authInfoBytes)
        signDoc.putString(3, chainID)
        signDoc.putUInt64(4, accountNumber)

        // Cosmos verifies the secp256k1 signature over SHA-256(SignDoc). signMessage
        // applies SHA-256 exactly once (sign(messageHash:) would double-hash).
        guard let signature = Secp256k1.signMessage(signDoc.data, with: privateKey) else {
            throw SurChainSignerError.signingFailed
        }

        // TxRaw { body_bytes = 1, auth_info_bytes = 2, signatures = 3 [bytes] }
        var txRaw = Writer()
        txRaw.putLengthDelimited(1, bodyBytes)
        txRaw.putLengthDelimited(2, authInfoBytes)
        txRaw.putLengthDelimited(3, signature)
        return txRaw.data
    }
}
