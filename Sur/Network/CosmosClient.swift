//
//  CosmosClient.swift
//  Sur
//
//  Swift REST client for the Sur Chain (Cosmos SDK chain).
//
//  The Sur Chain is a separate project running a Cosmos SDK appchain with:
//    - x/identity module  — username registry, device commitment tree
//    - x/attestation module — ZK proof verification, nullifier set
//
//  This iOS app is a CLIENT. It signs transactions offline and broadcasts them
//  via the standard Cosmos REST/gRPC-gateway. No raw protobuf encoding is done
//  here; signed transactions are submitted as Amino-JSON via CosmosTxBuilder.
//
//  Endpoints consumed:
//    GET  /sur/identity/v1/user/{username}
//    GET  /sur/attestation/v1/attestations/{username}
//    GET  /cosmos/auth/v1beta1/accounts/{address}
//    POST /cosmos/tx/v1beta1/txs
//

import Foundation

// MARK: - Data models

/// Result of broadcasting a signed transaction to the Sur Chain.
struct CosmosTransactionResult: Codable {
    let txHash: String
    let height: Int64?
    /// 0 = success; non-zero = chain-level error (see rawLog).
    let code: Int
    let rawLog: String?
    let gasUsed: Int64?

    private enum CodingKeys: String, CodingKey {
        case txHash   = "txhash"
        case height
        case code
        case rawLog   = "raw_log"
        case gasUsed  = "gas_used"
    }
}

/// A single attestation record stored on the Sur Chain by x/attestation.
///
/// Field set mirrors the chain's `AttestationRecord` proto
/// (`username, content_hash, nullifier, commitment_root, timestamp`). Byte fields
/// arrive base64-encoded from the gRPC-gateway; helpers expose hex for display.
struct CosmosAttestation: Codable, Identifiable {
    let username: String
    /// Base64 (gateway encoding) of the 32-byte SHA-256 content hash.
    let contentHash: String
    /// Base64 of the 32-byte nullifier — the chain rejects any reuse of this value.
    let nullifier: String
    /// Base64 of the 32-byte commitment root at proof time.
    let commitmentRoot: String
    /// Unix seconds when the attestation was recorded.
    let timestamp: Int64

    /// Stable identity for SwiftUI lists: a record is unique per (username, nullifier).
    var id: String { "\(username):\(nullifier)" }

    private enum CodingKeys: String, CodingKey {
        case username
        case contentHash    = "content_hash"
        case nullifier
        case commitmentRoot = "commitment_root"
        case timestamp
    }

    /// 0x-hex of the content hash (decoded from the gateway's base64), for display/links.
    var contentHashHex: String { Self.base64ToHex(contentHash) }
    var nullifierHex: String { Self.base64ToHex(nullifier) }

    private static func base64ToHex(_ b64: String) -> String {
        guard let data = Data(base64Encoded: b64) else { return b64 }
        return "0x" + data.map { String(format: "%02x", $0) }.joined()
    }
}

/// A coin balance returned by the bank module.
struct CosmosBalance: Codable, Equatable {
    /// Raw amount in the base denom (e.g. usur), as an integer string.
    let amount: String
    let denom: String

    /// Human-readable amount using the given exponent (1 SUR = 10^exponent usur).
    func formatted(displayDenom: String, exponent: Int) -> String {
        let raw = Decimal(string: amount) ?? 0
        let divisor = pow(Decimal(10), exponent)
        let value = raw / divisor
        return "\(value) \(displayDenom)"
    }
}

/// Identity record for a username registered via x/identity.
struct CosmosIdentity: Codable {
    let username: String
    let address: String
    let deviceCount: Int
    let attestationCount: Int
    let registeredAt: Date?

    private enum CodingKeys: String, CodingKey {
        case username
        case address
        case deviceCount      = "device_count"
        case attestationCount = "attestation_count"
        case registeredAt     = "registered_at"
    }
}

/// Cosmos account info required for transaction signing (sequence + account number).
struct CosmosAccount: Codable {
    let address: String
    let accountNumber: UInt64
    let sequence: UInt64

    private enum CodingKeys: String, CodingKey {
        case address
        case accountNumber = "account_number"
        case sequence
    }
}

// MARK: - Error type

enum CosmosError: LocalizedError {
    case networkError(Error)
    case httpError(Int, String?)
    /// Chain rejected the transaction; code is the Cosmos error code, message is rawLog.
    case chainError(Int, String)
    case decodingError(Error)
    case invalidResponse
    case accountNotFound

    var errorDescription: String? {
        switch self {
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .httpError(let status, let body):
            return "HTTP \(status): \(body ?? "(no body)")"
        case .chainError(let code, let log):
            return "Chain error \(code): \(log)"
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid or unexpected response from the Sur Chain."
        case .accountNotFound:
            return "Account not found on chain. Has the address been funded?"
        }
    }
}

// MARK: - Private response envelope types

/// Wraps the gRPC-gateway envelope for /cosmos/auth/v1beta1/accounts/{address}.
private struct AuthAccountResponse: Decodable {
    struct AccountInfo: Decodable {
        let address: String
        let accountNumber: String
        let sequence: String

        private enum CodingKeys: String, CodingKey {
            case address
            case accountNumber = "account_number"
            case sequence
        }
    }
    let account: AccountInfo
}

/// Wraps the gRPC-gateway envelope for /cosmos/tx/v1beta1/txs (broadcast).
private struct TxBroadcastResponse: Decodable {
    struct TxResponse: Decodable {
        let txhash: String
        let height: String?
        let code: Int?
        let raw_log: String?
        let gas_used: String?
    }
    let tx_response: TxResponse
}

/// Wraps the gRPC-gateway envelope for /sur/identity/v1/user/{username}.
private struct IdentityResponse: Decodable {
    let user: CosmosIdentity
}

/// Wraps the gRPC-gateway envelope for /sur/attestation/v1/attestations/{username}.
private struct AttestationsResponse: Decodable {
    let attestations: [CosmosAttestation]
}

/// Wraps the gRPC-gateway envelope for /cosmos/bank/v1beta1/balances/{address}/by_denom.
private struct BalanceResponse: Decodable {
    let balance: CosmosBalance?
}

/// Wraps the gRPC-gateway envelope for /cosmos/base/tendermint/v1beta1/node_info.
private struct NodeInfoResponse: Decodable {
    struct DefaultNodeInfo: Decodable { let network: String }
    let default_node_info: DefaultNodeInfo
}

// MARK: - Client

/// Swift REST client for the Sur Chain (Cosmos SDK chain).
///
/// All mutations (register, addDevice, submitAttestation) expect a fully signed
/// Cosmos transaction produced by `CosmosTxBuilder` and signed by the caller.
/// This client only broadcasts — it does not hold or access any private key material.
///
/// Base URL and chain ID are configurable so the same binary can target
/// testnet, mainnet, or a local devnet without recompilation.
final class CosmosClient {

    // MARK: - Singleton / Configuration

    static let shared = CosmosClient()

    var baseURL: URL
    var chainID: String
    /// Fee/stake denom (micro-SUR) used for balance queries and gas. Driven by `SurChainConfig`.
    var feeDenom: String = "usur"

    /// Shared URLSession with a reasonable timeout.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    /// ISO 8601 date decoder shared by all JSON decoders.
    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(
        baseURL: URL = URL(string: "https://rpc.testnet.surprotocol.com")!,
        chainID: String = "sur-testnet-1"
    ) {
        self.baseURL = baseURL
        self.chainID = chainID
    }

    // MARK: - Identity Module (x/identity)

    /// Register a username on the Sur Chain.
    ///
    /// The caller must build and sign the transaction containing `MsgRegisterUsername`
    /// via `CosmosTxBuilder` before calling this method. This method only broadcasts.
    ///
    /// - Parameters:
    ///   - username: The desired username (validated on-chain by x/identity rules).
    ///   - senderAddress: Bech32 address of the signing account (must match signedTx signer).
    ///   - signedTx: Amino-JSON encoded, fully signed StdTx bytes.
    func registerUsername(
        _ username: String,
        senderAddress: String,
        signedTx: Data
    ) async throws -> CosmosTransactionResult {
        // MsgRegisterUsername is submitted as a standard Cosmos broadcast.
        // The signed transaction already encodes the message type and payload.
        return try await broadcastTx(signedTx)
    }

    /// Add a device to an existing account.
    ///
    /// The caller must include the App Attest object in the signed transaction.
    /// The Sur Chain's x/identity module verifies the Apple attestation server-side.
    ///
    /// - Parameters:
    ///   - username: Registered username that owns this device.
    ///   - devicePubKey: 65-byte uncompressed P-256 public key from the Secure Enclave.
    ///   - appAttestObject: Apple App Attest CBOR blob (from `DCAppAttestService.attestKey`).
    ///   - appAttestKeyID: Key ID returned by `DCAppAttestService.generateKey`.
    ///   - senderAddress: Bech32 address of the signing account.
    ///   - signedTx: Amino-JSON encoded, fully signed StdTx bytes.
    func addDevice(
        username: String,
        devicePubKey: Data,
        appAttestObject: Data,
        appAttestKeyID: String,
        senderAddress: String,
        signedTx: Data
    ) async throws -> CosmosTransactionResult {
        return try await broadcastTx(signedTx)
    }

    // MARK: - Attestation Module (x/attestation)

    /// Submit a gnark Groth16 attestation proof.
    ///
    /// The proof must be generated by the ZK circuit that the Sur Chain's x/attestation
    /// module was compiled against. The verification key hash is a chain parameter —
    /// a proof generated against a different VK will be rejected.
    ///
    /// - Parameters:
    ///   - username: Username that owns this attestation.
    ///   - proofBytes: 256-byte gnark Groth16 proof (BN254 curve).
    ///   - publicInputs: Five hex strings: [usernameHash, contentHashLo, contentHashHi, nullifier, commitmentRoot].
    ///   - contentURL: URL of the content being attested.
    ///   - senderAddress: Bech32 address of the signing account.
    ///   - signedTx: Amino-JSON encoded, fully signed StdTx bytes.
    func submitAttestation(
        username: String,
        proofBytes: Data,
        publicInputs: [String],
        contentURL: String,
        senderAddress: String,
        signedTx: Data
    ) async throws -> CosmosTransactionResult {
        return try await broadcastTx(signedTx)
    }

    /// Fetch all attestations for a username from the x/attestation module.
    ///
    /// Calls `GET /sur/attestation/v1/attestations/{username}`.
    func getAttestations(username: String) async throws -> [CosmosAttestation] {
        let url = baseURL
            .appendingPathComponent("sur/attestation/v1/attestations")
            .appendingPathComponent(username)

        let data = try await get(url: url)

        do {
            let response = try Self.jsonDecoder.decode(AttestationsResponse.self, from: data)
            return response.attestations
        } catch {
            throw CosmosError.decodingError(error)
        }
    }

    /// Fetch identity info for a username from the x/identity module.
    ///
    /// Calls `GET /sur/identity/v1/user/{username}`.
    func getIdentity(username: String) async throws -> CosmosIdentity {
        let url = baseURL
            .appendingPathComponent("sur/identity/v1/user")
            .appendingPathComponent(username)

        let data = try await get(url: url)

        do {
            let response = try Self.jsonDecoder.decode(IdentityResponse.self, from: data)
            return response.user
        } catch {
            throw CosmosError.decodingError(error)
        }
    }

    // MARK: - Tx lookup

    /// Fetch a broadcast transaction by hash. Returns nil if it isn't included in a
    /// block yet (so callers can poll). A SYNC broadcast only confirms CheckTx; this
    /// surfaces the real in-block result (height + DeliverTx code).
    /// Calls `GET /cosmos/tx/v1beta1/txs/{hash}`.
    func getTx(hash: String) async throws -> CosmosTransactionResult? {
        let url = baseURL.appendingPathComponent("cosmos/tx/v1beta1/txs").appendingPathComponent(hash)
        let data: Data
        do {
            data = try await get(url: url)
        } catch CosmosError.httpError {
            // Not found yet (gateway returns 404/500 for a tx not yet in a block).
            return nil
        }
        guard let envelope = try? JSONDecoder().decode(TxBroadcastResponse.self, from: data) else {
            return nil
        }
        let tx = envelope.tx_response
        return CosmosTransactionResult(
            txHash:  tx.txhash,
            height:  tx.height.flatMap { Int64($0) },
            code:    tx.code ?? 0,
            rawLog:  tx.raw_log,
            gasUsed: tx.gas_used.flatMap { Int64($0) }
        )
    }

    // MARK: - Node info

    /// Fetch the chain's actual chain-id from the node, so signing always uses the
    /// value the chain verifies against (avoids `signature verification failed` when
    /// the locally configured chain-id is stale/wrong).
    /// Calls `GET /cosmos/base/tendermint/v1beta1/node_info`.
    func getChainID() async throws -> String {
        let url = baseURL.appendingPathComponent("cosmos/base/tendermint/v1beta1/node_info")
        let data = try await get(url: url)
        let envelope = try JSONDecoder().decode(NodeInfoResponse.self, from: data)
        return envelope.default_node_info.network
    }

    // MARK: - Bank Module (balances)

    /// Fetch the account's balance of the fee denom (default `usur`).
    ///
    /// Calls `GET /cosmos/bank/v1beta1/balances/{address}/by_denom?denom={feeDenom}`.
    /// Returns a zero balance (not an error) when the account holds none of the denom,
    /// which is the common case for a freshly created address before funding.
    func getBalance(address: String, denom: String? = nil) async throws -> CosmosBalance {
        let wanted = denom ?? feeDenom
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("cosmos/bank/v1beta1/balances")
                .appendingPathComponent(address)
                .appendingPathComponent("by_denom"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "denom", value: wanted)]
        guard let url = components?.url else { throw CosmosError.invalidResponse }

        let data: Data
        do {
            data = try await get(url: url)
        } catch CosmosError.httpError(404, _) {
            // Account/denom not found → treat as zero balance.
            return CosmosBalance(amount: "0", denom: wanted)
        }

        do {
            let envelope = try JSONDecoder().decode(BalanceResponse.self, from: data)
            return envelope.balance ?? CosmosBalance(amount: "0", denom: wanted)
        } catch {
            throw CosmosError.decodingError(error)
        }
    }

    // MARK: - Transaction Broadcasting

    /// Broadcast a fully signed transaction to the Sur Chain.
    ///
    /// `txRawBytes` is a serialized protobuf `TxRaw` (from `CosmosProtoTx`). This
    /// wraps it in a `BroadcastTxRequest` — `{ "tx_bytes": base64, "mode": ... }` —
    /// which is the ONLY format the modern Cosmos SDK accepts at this endpoint
    /// (Amino-JSON StdTx returns `code 3: invalid empty tx`).
    /// A chain-level error (code != 0) is surfaced as `CosmosError.chainError`.
    func broadcastTx(_ txRawBytes: Data) async throws -> CosmosTransactionResult {
        let url = baseURL.appendingPathComponent("cosmos/tx/v1beta1/txs")
        let requestBody: [String: Any] = [
            "tx_bytes": txRawBytes.base64EncodedString(),
            "mode": "BROADCAST_MODE_SYNC"
        ]
        let body = try JSONSerialization.data(withJSONObject: requestBody)
        let responseData = try await post(url: url, body: body)

        let envelope: TxBroadcastResponse
        do {
            let decoder = JSONDecoder()
            envelope = try decoder.decode(TxBroadcastResponse.self, from: responseData)
        } catch {
            throw CosmosError.decodingError(error)
        }

        let txResponse = envelope.tx_response
        let code = txResponse.code ?? 0

        // Parse optional numeric fields that arrive as strings from gRPC-gateway.
        let height  = txResponse.height.flatMap  { Int64($0) }
        let gasUsed = txResponse.gas_used.flatMap { Int64($0) }

        if code != 0 {
            throw CosmosError.chainError(code, txResponse.raw_log ?? "unknown chain error")
        }

        return CosmosTransactionResult(
            txHash:  txResponse.txhash,
            height:  height,
            code:    code,
            rawLog:  txResponse.raw_log,
            gasUsed: gasUsed
        )
    }

    /// Query account info for a Bech32 address.
    ///
    /// Calls `GET /cosmos/auth/v1beta1/accounts/{address}`.
    /// The returned `CosmosAccount` contains the sequence number and account number
    /// required when building a transaction with `CosmosTxBuilder`.
    func getAccount(address: String) async throws -> CosmosAccount {
        let url = baseURL
            .appendingPathComponent("cosmos/auth/v1beta1/accounts")
            .appendingPathComponent(address)

        let data: Data
        do {
            data = try await get(url: url)
        } catch CosmosError.httpError(404, _) {
            throw CosmosError.accountNotFound
        }

        let envelope: AuthAccountResponse
        do {
            let decoder = JSONDecoder()
            envelope = try decoder.decode(AuthAccountResponse.self, from: data)
        } catch {
            throw CosmosError.decodingError(error)
        }

        guard
            let accountNumber = UInt64(envelope.account.accountNumber),
            let sequence      = UInt64(envelope.account.sequence)
        else {
            throw CosmosError.invalidResponse
        }

        return CosmosAccount(
            address:       envelope.account.address,
            accountNumber: accountNumber,
            sequence:      sequence
        )
    }

    // MARK: - Private HTTP helpers

    /// Perform a GET request and return raw response body bytes.
    private func get(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return try await perform(request)
    }

    /// Perform a POST request with a JSON body and return raw response body bytes.
    private func post(url: URL, body: Data) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        return try await perform(request)
    }

    /// Execute a URLRequest, validate the HTTP status code, and return the response body.
    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CosmosError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CosmosError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw CosmosError.httpError(http.statusCode, body)
        }

        return data
    }
}
