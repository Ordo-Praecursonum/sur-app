//
//  SurcoreLibsBridge.swift
//  Sur
//
//  Swift wrapper around the surcorelibs CGo FFI bridge.
//
//  The actual proving is done by the gnark Groth16 prover in surcorelibs/gnark/prove.go.
//  This file provides idiomatic Swift types and the blocking proveAttestation() entry point.
//
//  Linking requirement
//  -------------------
//  The XCFramework must be built from surcorelibs/ before this file compiles:
//
//    CC=$(xcrun --sdk iphoneos --find clang) \
//    CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
//    go build -buildmode=c-archive -o build/libsurcorelibs.a ./ffi/
//
//  Then add the resulting XCFramework to the Xcode target's "Frameworks,
//  Libraries, and Embedded Content" list and set the bridging header to
//  Sur/Sur-Bridging-Header.h.
//
//  When the XCFramework is not yet linked (development phase), all calls return
//  SurcoreLibsError.frameworkNotLinked rather than crashing.
//

import Foundation
import Security

// The surcorelibs XCFramework's C exports (ProveAttestation, ComputeCommitment,
// ComputeUsernameHash, FreeString) are made visible to Swift through the
// Objective-C bridging header (Sur/Sur-Bridging-Header.h, which #includes
// "libsurcorelibs.h"). A bridging header exposes the symbols globally — it does
// NOT create a Swift module, so there is no `import libsurcorelibs` and
// `canImport(libsurcorelibs)` is always false. The functions are therefore
// called directly below; if the framework isn't linked the build fails at the
// bridging-header #include with a clear "file not found", which is the desired
// signal during setup.

// MARK: - Error types

enum SurcoreLibsError: LocalizedError {
    /// XCFramework not yet in Xcode project — run `make xcframework` in surcorelibs/
    case frameworkNotLinked
    /// Prover returned a non-zero exit code
    case provingFailed(String)
    case jsonEncodingFailed
    case jsonDecodingFailed
    /// Proof output was not 256 bytes
    case outputSizeMismatch(Int)
    /// Proof has wrong number of public inputs
    case invalidPublicInputsCount(Int)

    var errorDescription: String? {
        switch self {
        case .frameworkNotLinked:
            return "surcorelibs XCFramework not linked — run 'make xcframework' in surcorelibs/ and add to Xcode project"
        case .provingFailed(let msg):
            return "gnark Groth16 proof generation failed: \(msg)"
        case .jsonEncodingFailed:
            return "Failed to encode ProverInput as JSON"
        case .jsonDecodingFailed:
            return "Failed to decode ProofOutput JSON from prover"
        case .outputSizeMismatch(let size):
            return "Proof output is \(size) bytes; expected 256"
        case .invalidPublicInputsCount(let count):
            return "Proof has \(count) public inputs; expected 5"
        }
    }
}

// MARK: - Wire types

/// Input to the gnark Groth16 prover.
///
/// Field names use snake_case to match ProverInput in surcorelibs/gnark/prove.go exactly.
/// Changing any CodingKey value is a breaking change requiring a coordinated Go + Swift update.
struct ProverInput: Codable {
    /// Poseidon(username_utf8_bytes) over BN254 — 0x-prefixed hex, 32 bytes.
    let usernameHash: String
    /// Low 128 bits of the content hash.
    let contentHashLo: String
    /// High 128 bits of the content hash.
    let contentHashHi: String
    /// Full 256-bit content hash (private witness for Lo/Hi split verification).
    let contentHashPriv: String
    /// P-256 public key X coordinate, reduced mod BN254 r.
    let devicePubkeyX: String
    /// P-256 public key Y coordinate, reduced mod BN254 r.
    let devicePubkeyY: String
    /// Monotonically increasing per-device session counter.
    let sessionCounter: UInt64
    /// 32-byte cryptographically random secret, reduced mod BN254 r.
    let blindingFactor: String
    /// Root of the device commitment Merkle tree (queried from Cosmos x/identity).
    let commitmentRoot: String
    /// Sibling hashes for the Merkle inclusion proof (MerkleDepth = 8 elements).
    let merklePath: [String]
    /// Direction bits per level: 0 = leaf is left child, 1 = leaf is right child.
    let merkleDirections: [Int]
    /// Secure Enclave ECDSA signature R component over SHA-256(session_data).
    let seSignatureR: String
    /// Secure Enclave ECDSA signature S component.
    let seSignatureS: String
    /// Human typing score 0–100 (circuit enforces >= 50).
    let humanScore: Int
    /// Inter-keystroke intervals in milliseconds (circuit enforces 20–2000 ms).
    let ikiValuesMs: [Int]
    /// Number of signed keystrokes (circuit enforces >= 10).
    let keystrokeCount: Int

    enum CodingKeys: String, CodingKey {
        case usernameHash    = "username_hash"
        case contentHashLo   = "content_hash_lo"
        case contentHashHi   = "content_hash_hi"
        case contentHashPriv = "content_hash_priv"
        case devicePubkeyX   = "device_pubkey_x"
        case devicePubkeyY   = "device_pubkey_y"
        case sessionCounter  = "session_counter"
        case blindingFactor  = "blinding_factor"
        case commitmentRoot  = "commitment_root"
        case merklePath      = "merkle_path"
        case merkleDirections = "merkle_directions"
        case seSignatureR    = "se_signature_r"
        case seSignatureS    = "se_signature_s"
        case humanScore      = "human_score"
        case ikiValuesMs     = "iki_values_ms"
        case keystrokeCount  = "keystroke_count"
    }
}

/// Output from the gnark Groth16 prover.
///
/// Matches ProofOutput in surcorelibs/gnark/prove.go.  `proof_bytes` crosses the
/// FFI boundary as a `0x`-prefixed hex STRING (not a JSON array and not base64):
/// Go's json.Marshal would encode a []byte as base64, so the Go side emits a hex
/// string and we decode it here.  A prior version typed this as [UInt8] and
/// failed to decode every real prover response.
struct ProofOutput: Decodable {
    /// 256-byte serialized Groth16 proof: Ar(64) || Bs(128) || Krs(64), big-endian.
    let proofBytes: [UInt8]
    /// 5 BN254 scalar field elements as 0x-prefixed hex strings.
    /// Order: [usernameHash, contentHashLo, contentHashHi, nullifier, commitmentRoot]
    let publicInputs: [String]
    /// Convenience copy of publicInputs[3]; present in the Go output.
    let nullifier: String?

    enum CodingKeys: String, CodingKey {
        case proofBytes   = "proof_bytes"
        case publicInputs = "public_inputs"
        case nullifier
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let proofHex = try c.decode(String.self, forKey: .proofBytes)
        self.proofBytes = ProofOutput.bytes(fromHex: proofHex)
        self.publicInputs = try c.decode([String].self, forKey: .publicInputs)
        self.nullifier = try c.decodeIfPresent(String.self, forKey: .nullifier)
    }

    /// Decode a `0x`-prefixed (or bare) hex string to a byte array.
    static func bytes(fromHex hex: String) -> [UInt8] {
        var s = Substring(hex)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s = s.dropFirst(2) }
        if s.count % 2 == 1 { s = Substring("0" + s) }
        var out = [UInt8]()
        out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return [] }
            out.append(b)
            idx = next
        }
        return out
    }
}

// MARK: - FFI entry point

/// Call the surcorelibs gnark Groth16 prover synchronously.
///
/// This function performs full R1CS witness assignment and Groth16 proof generation.
/// It is CPU-intensive (~2–5 seconds on an A-series chip) and must be called from a
/// background thread or async context — never from the main thread.
///
/// Memory contract: the Go runtime allocates the output and error C strings. This
/// function frees them via FreeString before returning; the caller never sees raw
/// C pointers.
///
/// - Parameter input: Structured prover input matching the Go ProverInput schema.
/// - Returns: ProofOutput containing a 256-byte proof and 5 public inputs.
/// - Throws: SurcoreLibsError
func proveAttestation(_ input: ProverInput) throws -> ProofOutput {
    // Encode ProverInput to JSON.
    let encoder = JSONEncoder()
    guard let inputData = try? encoder.encode(input),
          let inputJSONString = String(data: inputData, encoding: .utf8) else {
        throw SurcoreLibsError.jsonEncodingFailed
    }

    // Call the CGo FFI bridge. ProveAttestation and FreeString are exported from
    // surcorelibs/ffi/bridge.go and made visible to Swift via the bridging header.
    var outputPtr: UnsafeMutablePointer<CChar>? = nil
    var errPtr: UnsafeMutablePointer<CChar>? = nil

    let resultCode = inputJSONString.withCString { inputCStr in
        // cgo declares the param as non-const `char*`, imported as
        // UnsafeMutablePointer<CChar>; withCString yields an immutable pointer,
        // so bridge it with UnsafeMutablePointer(mutating:). The Go side only reads it.
        ProveAttestation(UnsafeMutablePointer(mutating: inputCStr), &outputPtr, &errPtr)
    }

    defer {
        // The Go runtime allocated these strings with C.CString; free them
        // exactly once regardless of success or failure.
        if let ptr = outputPtr { FreeString(ptr) }
        if let ptr = errPtr { FreeString(ptr) }
    }

    if resultCode != 0 {
        let errMsg = errPtr.map { String(cString: $0) } ?? "unknown error (no message from prover)"
        throw SurcoreLibsError.provingFailed(errMsg)
    }

    guard let outputCStr = outputPtr else {
        throw SurcoreLibsError.jsonDecodingFailed
    }

    // Decode the JSON proof output.
    let outputString = String(cString: outputCStr)
    guard let outputData = outputString.data(using: .utf8),
          let output = try? JSONDecoder().decode(ProofOutput.self, from: outputData) else {
        throw SurcoreLibsError.jsonDecodingFailed
    }

    // Validate the output shape — these invariants are enforced by the Go prover
    // but we re-check on the Swift side to catch any ABI or version skew early.
    guard output.proofBytes.count == 256 else {
        throw SurcoreLibsError.outputSizeMismatch(output.proofBytes.count)
    }
    guard output.publicInputs.count == 5 else {
        throw SurcoreLibsError.invalidPublicInputsCount(output.publicInputs.count)
    }

    return output
}

// MARK: - Poseidon helpers (device registration)

/// Compute the device commitment `Poseidon(devicePubKeyX, devicePubKeyY, blinding)`
/// (nested 3-input, matching the circuit and chain) via the surcorelibs FFI.
///
/// - Parameters:
///   - devicePubKeyX/Y: P-256 public key coordinates as `0x`-hex (or bare hex) strings.
///   - blinding: 32-byte blinding factor as a `0x`-hex string.
/// - Returns: the 32-byte commitment (decoded from the FFI's `0x`-hex output).
/// - Throws: `SurcoreLibsError` on failure or when the framework isn't linked.
func computeCommitment(devicePubKeyX: String, devicePubKeyY: String, blinding: String) throws -> Data {
    var outPtr: UnsafeMutablePointer<CChar>? = nil
    var errPtr: UnsafeMutablePointer<CChar>? = nil
    let rc = devicePubKeyX.withCString { x in
        devicePubKeyY.withCString { y in
            blinding.withCString { b in
                ComputeCommitment(UnsafeMutablePointer(mutating: x),
                                  UnsafeMutablePointer(mutating: y),
                                  UnsafeMutablePointer(mutating: b),
                                  &outPtr, &errPtr)
            }
        }
    }
    defer {
        if let p = outPtr { FreeString(p) }
        if let p = errPtr { FreeString(p) }
    }
    if rc != 0 {
        throw SurcoreLibsError.provingFailed(errPtr.map { String(cString: $0) } ?? "commitment failed")
    }
    guard let out = outPtr else { throw SurcoreLibsError.jsonDecodingFailed }
    return Data(ProofOutput.bytes(fromHex: String(cString: out)))
}

/// Compute the device-commitment Merkle witness for a single registered device
/// (leaf index 0) via the surcorelibs FFI. Returns the commitment root and the
/// 8-element inclusion path as `0x`-hex field-element strings (directions are all 0).
/// These feed directly into `ProverInput.commitmentRoot` / `merklePath`.
func computeMerkleWitness(devicePubKeyX: String, devicePubKeyY: String, blinding: String) throws -> (commitmentRoot: String, merklePath: [String]) {
    var outPtr: UnsafeMutablePointer<CChar>? = nil
    var errPtr: UnsafeMutablePointer<CChar>? = nil
    let rc = devicePubKeyX.withCString { x in
        devicePubKeyY.withCString { y in
            blinding.withCString { b in
                ComputeMerkleWitness(UnsafeMutablePointer(mutating: x),
                                     UnsafeMutablePointer(mutating: y),
                                     UnsafeMutablePointer(mutating: b),
                                     &outPtr, &errPtr)
            }
        }
    }
    defer {
        if let p = outPtr { FreeString(p) }
        if let p = errPtr { FreeString(p) }
    }
    if rc != 0 {
        throw SurcoreLibsError.provingFailed(errPtr.map { String(cString: $0) } ?? "merkle witness failed")
    }
    guard let out = outPtr,
          let data = String(cString: out).data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let root = json["commitment_root"] as? String,
          let path = json["merkle_path"] as? [String], path.count == 8 else {
        throw SurcoreLibsError.jsonDecodingFailed
    }
    return (root, path)
}

/// Compute the canonical username hash via the surcorelibs FFI. Returns the 32-byte
/// big-endian field element. Used to cross-check the value the chain reconstructs.
func computeUsernameHash(_ username: String) throws -> Data {
    var outPtr: UnsafeMutablePointer<CChar>? = nil
    var errPtr: UnsafeMutablePointer<CChar>? = nil
    let rc = username.withCString { u in ComputeUsernameHash(UnsafeMutablePointer(mutating: u), &outPtr, &errPtr) }
    defer {
        if let p = outPtr { FreeString(p) }
        if let p = errPtr { FreeString(p) }
    }
    if rc != 0 {
        throw SurcoreLibsError.provingFailed(errPtr.map { String(cString: $0) } ?? "username hash failed")
    }
    guard let out = outPtr else { throw SurcoreLibsError.jsonDecodingFailed }
    return Data(ProofOutput.bytes(fromHex: String(cString: out)))
}
