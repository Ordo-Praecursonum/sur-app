//
//  L1Client.swift
//  Sur
//
//  Read-only Ethereum L1 client for the Sur Protocol iOS app.
//
//  The iOS app reads attestation state that has been settled on L1 by the
//  Sur Protocol batch prover (a separate off-chain service). The iOS app:
//    - Does NOT submit L1 transactions.
//    - Does NOT hold ETH or any EVM private key.
//    - Calls only eth_call (read-only) via the Ethereum JSON-RPC interface.
//
//  CONTRACTS CALLED:
//  =================
//  AttestationDirect.sol   — per-proof nullifier registry and attestation records
//  AttestationSettlement.sol — epoch checkpoints (settled state roots from Sur Chain)
//
//  ABI ENCODING:
//  =============
//  A minimal ABI encoder/decoder is implemented inline — no third-party Web3
//  library is required. Only the four function selectors used here are supported.
//
//  FUNCTION SELECTORS (keccak256 first 4 bytes):
//    isNullifierUsed(bytes32)   → 0x9cef38fe
//    getAttestation(bytes32)    → 0x6a27b0e7
//    getCheckpoint(uint256)     → 0x633b6e9e
//    getCurrentEpoch()          → 0xb4a176d3
//

import Foundation

// MARK: - Data models

/// A single attestation record stored in AttestationDirect.sol.
struct L1Attestation: Codable {
    /// bytes32 hex — the unique ZK proof nullifier.
    let nullifier: String
    /// bytes32 hex — Poseidon hash of the username.
    let usernameHash: String
    /// bytes32 hex — lower 128 bits of the content hash.
    let contentHashLo: String
    /// bytes32 hex — upper 128 bits of the content hash.
    let contentHashHi: String
    /// bytes32 hex — device commitment Merkle tree root at proof time.
    let commitmentRoot: String
    let blockNumber: UInt64
    let timestamp: UInt64
}

/// An epoch checkpoint settled into AttestationSettlement.sol by the batch prover.
struct L1Checkpoint: Codable {
    let epoch: UInt64
    /// bytes32 hex — Poseidon Merkle root of all attestations in the epoch.
    let stateRoot: String
    let proofCount: UInt64
    let blockNumber: UInt64
}

// MARK: - Error type

enum L1Error: LocalizedError {
    case rpcError(String)
    case abiDecodingError
    case contractReverted(String)
    case networkError(Error)
    case invalidContractAddress

    var errorDescription: String? {
        switch self {
        case .rpcError(let message):
            return "JSON-RPC error: \(message)"
        case .abiDecodingError:
            return "Failed to ABI-decode the eth_call response."
        case .contractReverted(let reason):
            return "Contract call reverted: \(reason)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidContractAddress:
            return "Invalid or zero contract address configured in L1Client."
        }
    }
}

// MARK: - ABI value enum

/// A typed ABI-encodable function argument.
enum ABIValue {
    case bytes32(Data)
    case uint256(UInt64)
    case address(String)
}

// MARK: - ABI Encoder

/// Minimal ABI encoder / decoder covering the four function calls used by L1Client.
///
/// Ethereum ABI encoding reference: https://docs.soliditylang.org/en/latest/abi-spec.html
///
/// All types used here are static (no dynamic-length arguments in eth_call data),
/// so no offset table is required.
struct ABIEncoder {

    // MARK: - Encoding

    /// Encode a complete function call: 4-byte selector + ABI-encoded arguments.
    ///
    /// - Parameters:
    ///   - functionSelector: Hex string of the 4-byte selector, with or without "0x" prefix.
    ///   - args: Ordered list of arguments. Each is padded to 32 bytes.
    /// - Returns: Raw call data bytes.
    static func encodeCall(functionSelector: String, args: [ABIValue]) -> Data {
        var result = Data()

        // Strip optional "0x" prefix and decode 4 selector bytes.
        let cleanSelector = functionSelector.hasPrefix("0x")
            ? String(functionSelector.dropFirst(2))
            : functionSelector

        if let selectorBytes = Data(hexString: cleanSelector) {
            result.append(selectorBytes)
        }

        for arg in args {
            result.append(encodeArgument(arg))
        }

        return result
    }

    /// Encode a single ABI argument, padded to 32 bytes.
    private static func encodeArgument(_ arg: ABIValue) -> Data {
        switch arg {
        case .bytes32(let data):
            return encodeBytes32(data)
        case .uint256(let value):
            return encodeUInt256(value)
        case .address(let addr):
            return encodeAddress(addr)
        }
    }

    /// ABI-encode a bytes32 value (left-padded with leading zeros to 32 bytes,
    /// then right-padded with trailing zeros if input is shorter than 32 bytes).
    ///
    /// Per ABI spec: bytes32 is right-aligned — the value occupies the rightmost
    /// bytes and the remaining high bytes are zero.
    static func encodeBytes32(_ data: Data) -> Data {
        var padded = Data(repeating: 0, count: 32)
        let copyLength = min(data.count, 32)
        // bytes32 is right-aligned: copy into the high bytes.
        padded.replaceSubrange(0..<copyLength, with: data.prefix(copyLength))
        return padded
    }

    /// ABI-encode a uint256 value (big-endian, left zero-padded to 32 bytes).
    static func encodeUInt256(_ value: UInt64) -> Data {
        var padded = Data(repeating: 0, count: 32)
        // Write the value as big-endian into the last 8 bytes.
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes in
            padded.replaceSubrange(24..<32, with: bytes)
        }
        return padded
    }

    /// ABI-encode an Ethereum address (20 bytes, left zero-padded to 32 bytes).
    static func encodeAddress(_ hexAddress: String) -> Data {
        let clean = hexAddress.hasPrefix("0x")
            ? String(hexAddress.dropFirst(2))
            : hexAddress
        let addrBytes = Data(hexString: clean) ?? Data(repeating: 0, count: 20)
        var padded = Data(repeating: 0, count: 32)
        let copyLength = min(addrBytes.count, 20)
        // Address is right-aligned (occupies bytes 12–31).
        padded.replaceSubrange((32 - copyLength)..<32, with: addrBytes.prefix(copyLength))
        return padded
    }

    // MARK: - Decoding

    /// Decode a bool from a 32-byte ABI-encoded eth_call hex result.
    ///
    /// - Parameter hexResult: Full hex result string from JSON-RPC, with or without "0x".
    /// - Returns: The decoded bool, or nil if the result is malformed.
    static func decodeBool(_ hexResult: String) -> Bool? {
        guard let data = normaliseHexResult(hexResult), data.count >= 32 else { return nil }
        // bool is encoded as uint256; non-zero last byte = true.
        return data[31] != 0
    }

    /// Decode a uint256 from a 32-byte ABI-encoded eth_call hex result.
    ///
    /// Values larger than UInt64.max are truncated to the low 8 bytes, which is
    /// acceptable for epoch numbers and block numbers in the foreseeable Sur timeline.
    ///
    /// - Parameter hexResult: Full hex result string from JSON-RPC, with or without "0x".
    /// - Returns: The low 64 bits of the uint256, or nil if malformed.
    static func decodeUInt256(_ hexResult: String) -> UInt64? {
        guard let data = normaliseHexResult(hexResult), data.count >= 32 else { return nil }
        // Take the last 8 bytes of the 32-byte word (big-endian uint256).
        let slice = data[24..<32]
        return slice.withUnsafeBytes { ptr in
            ptr.loadUnaligned(as: UInt64.self).byteSwapped
        }
    }

    /// Decode a bytes32 field from a given 32-byte word within a hex result.
    ///
    /// - Parameters:
    ///   - hexResult: Full hex result string.
    ///   - wordIndex: 0-based index of the 32-byte word to read.
    /// - Returns: Hex string of the bytes32 value (without 0x prefix), or nil if malformed.
    static func decodeBytes32(_ hexResult: String, wordIndex: Int) -> String? {
        guard let data = normaliseHexResult(hexResult) else { return nil }
        let start = wordIndex * 32
        let end   = start + 32
        guard data.count >= end else { return nil }
        return data[start..<end].map { String(format: "%02x", $0) }.joined()
    }

    /// Decode a uint64 field from a given 32-byte word within a hex result.
    static func decodeUInt64(_ hexResult: String, wordIndex: Int) -> UInt64? {
        guard let data = normaliseHexResult(hexResult) else { return nil }
        let start = wordIndex * 32
        let end   = start + 32
        guard data.count >= end else { return nil }
        let slice = data[(start + 24)..<end]
        return slice.withUnsafeBytes { ptr in
            ptr.loadUnaligned(as: UInt64.self).byteSwapped
        }
    }

    // MARK: - Private helpers

    /// Strip "0x" prefix and decode hex string to Data.
    private static func normaliseHexResult(_ hex: String) -> Data? {
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        return Data(hexString: clean)
    }
}

// MARK: - Data hex helpers

private extension Data {
    /// Initialise Data from a hex string (without "0x" prefix).
    /// Returns nil if the string length is odd or contains non-hex characters.
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    /// Convert Data to lowercase hex string without "0x" prefix.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - JSON-RPC types

/// JSON-RPC 2.0 request body.
private struct JSONRPCRequest: Encodable {
    let jsonrpc: String = "2.0"
    let method: String
    let params: [JSONRPCParam]
    let id: Int = 1
}

/// A single JSON-RPC parameter (either an object or a primitive string).
private enum JSONRPCParam: Encodable {
    case object([String: String])
    case string(String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let dict):
            try container.encode(dict)
        case .string(let value):
            try container.encode(value)
        }
    }
}

/// JSON-RPC 2.0 response envelope.
private struct JSONRPCResponse: Decodable {
    struct RPCError: Decodable {
        let code: Int
        let message: String
    }
    let result: String?
    let error: RPCError?
}

// MARK: - L1Client

/// Read-only Ethereum L1 client for the Sur Protocol iOS app.
///
/// Connects to a standard Ethereum JSON-RPC endpoint (Infura, Alchemy, or a
/// local node) and calls `eth_call` against the deployed Sur Protocol contracts.
///
/// No private key is held; no write operations are performed.
final class L1Client {

    // MARK: - Singleton / Configuration

    static let shared = L1Client()

    var rpcURL: URL
    /// Deployed address of AttestationDirect.sol.
    var directContractAddress: String
    /// Deployed address of AttestationSettlement.sol.
    var settlementContractAddress: String

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    init(
        rpcURL: URL = URL(string: "https://mainnet.infura.io/v3/YOUR_KEY")!,
        directContractAddress: String    = "0x0000000000000000000000000000000000000000",
        settlementContractAddress: String = "0x0000000000000000000000000000000000000000"
    ) {
        self.rpcURL = rpcURL
        self.directContractAddress = directContractAddress
        self.settlementContractAddress = settlementContractAddress
    }

    // MARK: - AttestationDirect reads

    /// Check whether a nullifier has already been consumed on L1.
    ///
    /// The Sur Chain also maintains its own nullifier set in x/attestation; this
    /// provides an independent L1-anchored check for the iOS app without trusting
    /// a single data source.
    ///
    /// Calls: `isNullifierUsed(bytes32 nullifier) → bool`
    /// Selector: 0x9cef38fe
    ///
    /// - Parameter nullifier: 32 bytes of nullifier data.
    /// - Returns: true if the nullifier is already registered; false otherwise.
    func isNullifierUsed(_ nullifier: Data) async throws -> Bool {
        try validateContractAddress(directContractAddress)

        let callData = ABIEncoder.encodeCall(
            functionSelector: "0x9cef38fe",
            args: [.bytes32(nullifier)]
        )

        let hexResult = try await ethCall(to: directContractAddress, data: callData)

        guard let result = ABIEncoder.decodeBool(hexResult) else {
            throw L1Error.abiDecodingError
        }

        return result
    }

    /// Fetch an attestation record by nullifier from AttestationDirect.sol.
    ///
    /// Calls: `getAttestation(bytes32 nullifier) → AttestationRecord`
    /// Selector: 0x6a27b0e7
    ///
    /// The Solidity struct is ABI-encoded as 7 consecutive 32-byte words:
    ///   [0] nullifier (bytes32)
    ///   [1] usernameHash (bytes32)
    ///   [2] contentHashLo (bytes32)
    ///   [3] contentHashHi (bytes32)
    ///   [4] commitmentRoot (bytes32)
    ///   [5] blockNumber (uint256 → uint64)
    ///   [6] timestamp (uint256 → uint64)
    ///
    /// - Parameter nullifier: 32 bytes of nullifier data.
    /// - Returns: The attestation record, or nil if the nullifier is not found (all-zero result).
    func getAttestation(nullifier: Data) async throws -> L1Attestation? {
        try validateContractAddress(directContractAddress)

        let callData = ABIEncoder.encodeCall(
            functionSelector: "0x6a27b0e7",
            args: [.bytes32(nullifier)]
        )

        let hexResult = try await ethCall(to: directContractAddress, data: callData)

        // A clean hex result for 7 words is 7 * 32 * 2 = 448 hex chars.
        // Strip "0x" prefix for length check.
        let clean = hexResult.hasPrefix("0x") ? String(hexResult.dropFirst(2)) : hexResult
        guard clean.count >= 448 else {
            throw L1Error.abiDecodingError
        }

        guard
            let nullifierHex     = ABIEncoder.decodeBytes32(clean, wordIndex: 0),
            let usernameHash     = ABIEncoder.decodeBytes32(clean, wordIndex: 1),
            let contentHashLo    = ABIEncoder.decodeBytes32(clean, wordIndex: 2),
            let contentHashHi    = ABIEncoder.decodeBytes32(clean, wordIndex: 3),
            let commitmentRoot   = ABIEncoder.decodeBytes32(clean, wordIndex: 4),
            let blockNumber      = ABIEncoder.decodeUInt64(clean,  wordIndex: 5),
            let timestamp        = ABIEncoder.decodeUInt64(clean,  wordIndex: 6)
        else {
            throw L1Error.abiDecodingError
        }

        // A zero nullifier means the record was not found.
        guard nullifierHex != String(repeating: "0", count: 64) else {
            return nil
        }

        return L1Attestation(
            nullifier:      nullifierHex,
            usernameHash:   usernameHash,
            contentHashLo:  contentHashLo,
            contentHashHi:  contentHashHi,
            commitmentRoot: commitmentRoot,
            blockNumber:    blockNumber,
            timestamp:      timestamp
        )
    }

    // MARK: - AttestationSettlement reads

    /// Fetch an epoch checkpoint from AttestationSettlement.sol.
    ///
    /// Calls: `getCheckpoint(uint256 epoch) → Checkpoint`
    /// Selector: 0x633b6e9e
    ///
    /// The Checkpoint struct is ABI-encoded as 4 consecutive 32-byte words:
    ///   [0] epoch (uint256)
    ///   [1] stateRoot (bytes32)
    ///   [2] proofCount (uint256)
    ///   [3] blockNumber (uint256)
    ///
    /// - Parameter epoch: The epoch number to look up.
    /// - Returns: The checkpoint, or nil if the epoch has not been settled yet (stateRoot is zero).
    func getCheckpoint(epoch: UInt64) async throws -> L1Checkpoint? {
        try validateContractAddress(settlementContractAddress)

        let callData = ABIEncoder.encodeCall(
            functionSelector: "0x633b6e9e",
            args: [.uint256(epoch)]
        )

        let hexResult = try await ethCall(to: settlementContractAddress, data: callData)

        let clean = hexResult.hasPrefix("0x") ? String(hexResult.dropFirst(2)) : hexResult
        guard clean.count >= 256 else { // 4 words * 64 hex chars
            throw L1Error.abiDecodingError
        }

        guard
            let epochDecoded  = ABIEncoder.decodeUInt64(clean,  wordIndex: 0),
            let stateRoot     = ABIEncoder.decodeBytes32(clean,  wordIndex: 1),
            let proofCount    = ABIEncoder.decodeUInt64(clean,  wordIndex: 2),
            let blockNumber   = ABIEncoder.decodeUInt64(clean,  wordIndex: 3)
        else {
            throw L1Error.abiDecodingError
        }

        // A zero stateRoot means the checkpoint has not yet been settled.
        guard stateRoot != String(repeating: "0", count: 64) else {
            return nil
        }

        return L1Checkpoint(
            epoch:       epochDecoded,
            stateRoot:   stateRoot,
            proofCount:  proofCount,
            blockNumber: blockNumber
        )
    }

    /// Fetch the current epoch number from AttestationSettlement.sol.
    ///
    /// Calls: `getCurrentEpoch() → uint256`
    /// Selector: 0xb4a176d3
    func getCurrentEpoch() async throws -> UInt64 {
        try validateContractAddress(settlementContractAddress)

        let callData = ABIEncoder.encodeCall(
            functionSelector: "0xb4a176d3",
            args: []
        )

        let hexResult = try await ethCall(to: settlementContractAddress, data: callData)

        guard let epoch = ABIEncoder.decodeUInt256(hexResult) else {
            throw L1Error.abiDecodingError
        }

        return epoch
    }

    // MARK: - Private eth_call

    /// Execute a read-only `eth_call` against the configured JSON-RPC endpoint.
    ///
    /// - Parameters:
    ///   - to: Contract address (40 hex chars, with or without "0x").
    ///   - data: ABI-encoded call data produced by `ABIEncoder.encodeCall`.
    ///   - block: Block parameter (default "latest").
    /// - Returns: Raw hex string result from the JSON-RPC response.
    private func ethCall(
        to: String,
        data: Data,
        block: String = "latest"
    ) async throws -> String {
        let hexData = "0x" + data.hexString
        let toAddr  = to.hasPrefix("0x") ? to : "0x" + to

        let request = JSONRPCRequest(
            method: "eth_call",
            params: [
                .object(["to": toAddr, "data": hexData]),
                .string(block)
            ]
        )

        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(request)
        } catch {
            throw L1Error.rpcError("Failed to encode JSON-RPC request: \(error.localizedDescription)")
        }

        var urlRequest = URLRequest(url: rpcURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = requestData

        let responseData: Data
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw L1Error.rpcError("Non-2xx HTTP response from JSON-RPC endpoint.")
            }
            responseData = data
        } catch let error as L1Error {
            throw error
        } catch {
            throw L1Error.networkError(error)
        }

        let rpcResponse: JSONRPCResponse
        do {
            rpcResponse = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        } catch {
            throw L1Error.rpcError("Failed to decode JSON-RPC response: \(error.localizedDescription)")
        }

        if let rpcError = rpcResponse.error {
            // Detect EVM revert: code -32000 with "revert" in the message.
            if rpcError.message.lowercased().contains("revert") {
                throw L1Error.contractReverted(rpcError.message)
            }
            throw L1Error.rpcError("\(rpcError.code): \(rpcError.message)")
        }

        guard let result = rpcResponse.result else {
            throw L1Error.rpcError("JSON-RPC response contained no result and no error.")
        }

        return result
    }

    // MARK: - Private helpers

    /// Validate that the contract address is non-zero before making a call.
    ///
    /// A zero address (the default placeholder) means the contract has not yet been
    /// deployed or the L1Client has not been configured for the current environment.
    private func validateContractAddress(_ address: String) throws {
        let clean = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
        let isZero = clean.allSatisfy { $0 == "0" }
        if isZero || clean.isEmpty {
            throw L1Error.invalidContractAddress
        }
    }
}
