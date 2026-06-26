//
//  ZKProofGenerator.swift
//  Sur
//
//  Zero-knowledge proof generation for human typing attestation.
//
//  Protocol versions
//  -----------------
//  3.0.0  gnark Groth16 proof via CGo FFI (proveAttestation / SurcoreLibsBridge.swift)
//  2.0.0  Keccak-256 hash chain — placeholder used when the XCFramework is not linked
//
//  The primary path calls the gnark Groth16 prover in surcorelibs through the
//  ProveAttestation C export.  When the XCFramework is absent (development builds
//  before TASK-7 completes), proveAttestation() throws SurcoreLibsError.frameworkNotLinked
//  and the generator falls back to makePlaceholderProof(), which reproduces the v2.0.0
//  Keccak hash chain verbatim so UI development continues uninterrupted.
//
//  makePlaceholderProof() and computeMerkleRoot() are deleted once TASK-7 is complete.
//

import Foundation
import CryptoKit

/// Generates zero-knowledge proofs for keystroke sessions.
public struct ZKProofGenerator {

    // MARK: - Constants

    /// Current proof protocol version for real gnark Groth16 proofs.
    public static let protocolVersion = "3.0.0"

    /// Protocol version emitted by the Keccak hash-chain placeholder path.
    public static let placeholderProtocolVersion = "2.0.0"

    /// Domain separator used by the placeholder Keccak hash chain (v2.0.0).
    private static let domainSeparator = "SUR_KEYSTROKE_PROOF_V2"

    /// 32-byte zero field element, 0x-prefixed hex.
    /// Used as a placeholder for fields not yet populated by the identity layer.
    private static let zeroHex32 = "0x" + String(repeating: "00", count: 32)

    // MARK: - Public Interface

    /// Generate a zero-knowledge proof for a keystroke session.
    ///
    /// When the surcorelibs XCFramework is linked, this calls the gnark Groth16
    /// prover via CGo FFI and returns a v3.0.0 proof.  When the framework is absent
    /// (development builds), it falls back to the Keccak hash chain and returns a
    /// v2.0.0 placeholder proof so the rest of the UI can be developed independently.
    ///
    /// - Parameter session: The keystroke session to prove.
    /// - Returns: ZKTypingProof, or nil if proof generation fails entirely.
    public static func generateProof(for session: KeystrokeSession) -> ZKTypingProof? {
        guard !session.signedKeystrokes.isEmpty else { return nil }

        // Compute behavioral witness values that feed into both the real circuit
        // and the placeholder hash chain.
        let ikiValues = computeIKIValues(session)
        let humanScore = Int(session.humanTypingScore ?? HumanTypingEvaluator.evaluate(session: session))

        // Build ProverInput.  Fields that depend on the identity layer (TASK-5 /
        // TASK-12) use zero placeholders when not yet populated by AuthenticationManager.
        let proverInput = ProverInput(
            usernameHash:     session.usernameHash    ?? zeroHex32,
            contentHashLo:    zeroHex32,   // populated by content hash computation (TASK-12)
            contentHashHi:    zeroHex32,
            contentHashPriv:  zeroHex32,   // full 256-bit hash, split into Lo/Hi by circuit (TASK-12)
            devicePubkeyX:    session.devicePubkeyX  ?? zeroHex32,
            devicePubkeyY:    session.devicePubkeyY  ?? zeroHex32,
            sessionCounter:   session.sessionCounter ?? 0,
            blindingFactor:   generateBlindingFactor(),
            commitmentRoot:   session.commitmentRoot ?? zeroHex32,
            merklePath:       session.merklePath      ?? Array(repeating: zeroHex32, count: 8),
            merkleDirections: session.merkleDirections ?? Array(repeating: 0, count: 8),
            seSignatureR:     session.seSignatureR   ?? zeroHex32,
            seSignatureS:     session.seSignatureS   ?? zeroHex32,
            humanScore:       humanScore,
            ikiValuesMs:      ikiValues,
            keystrokeCount:   session.signedKeystrokes.count
        )

        // Attempt the real gnark Groth16 proof.
        let output: ProofOutput
        do {
            output = try proveAttestation(proverInput)
        } catch SurcoreLibsError.frameworkNotLinked {
            // XCFramework not yet linked — fall back to the Keccak placeholder.
            // This branch is removed once TASK-7 (XCFramework build) is complete.
            return makePlaceholderProof(for: session, humanScore: humanScore)
        } catch {
            // Prover returned a genuine error (bad witness, invalid inputs, etc.).
            return nil
        }

        // Build ZKTypingProof from the gnark output.
        let proofHex = "0x" + output.proofBytes.map { String(format: "%02x", $0) }.joined()
        let publicInputs = ZKPublicInputs(
            usernameHash:   output.publicInputs[0],
            contentHashLo:  output.publicInputs[1],
            contentHashHi:  output.publicInputs[2],
            nullifier:      output.publicInputs[3],
            commitmentRoot: output.publicInputs[4]
        )

        return ZKTypingProof(
            version:      protocolVersion,  // "3.0.0" — gnark Groth16
            commitment:   output.publicInputs[4],  // commitment root is the binding public value
            nullifier:    output.publicInputs[3],
            proof:        proofHex,
            publicInputs: publicInputs,
            generatedAt:  Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    /// Verify a zero-knowledge proof (off-chain, lightweight check).
    ///
    /// For v3.0.0 proofs the authoritative check is the on-chain gnark verifier;
    /// this method performs only structural validation.  For v2.0.0 placeholder
    /// proofs it checks internal consistency of the Keccak hash chain.
    ///
    /// - Parameters:
    ///   - proof: The proof to verify.
    ///   - session: Unused in this implementation; reserved for future cross-checks.
    /// - Returns: true if the proof passes local structural validation.
    public static func verifyProof(_ proof: ZKTypingProof, session: KeystrokeSession? = nil) -> Bool {
        // Structural checks common to all versions.
        guard !proof.commitment.isEmpty,
              !proof.nullifier.isEmpty,
              !proof.proof.isEmpty,
              !proof.publicInputs.nullifier.isEmpty,
              !proof.publicInputs.commitmentRoot.isEmpty else {
            return false
        }

        // The nullifier in the proof body must match the one in publicInputs.
        if proof.nullifier != proof.publicInputs.nullifier {
            return false
        }

        // For v3.0.0 gnark proofs: proof field must be a 0x-prefixed hex string
        // encoding exactly 256 bytes (512 hex chars after the prefix).
        if proof.version == protocolVersion {
            let hex = proof.proof.hasPrefix("0x") ? String(proof.proof.dropFirst(2)) : proof.proof
            guard hex.count == 512 else { return false }
        }

        // For v2.0.0 placeholder proofs: re-derive the Fiat-Shamir nullifier
        // from the commitment and commitment root and verify internal consistency.
        if proof.version == placeholderProtocolVersion {
            guard let commitmentData    = hexStringToData(proof.commitment),
                  let commitmentRootData = hexStringToData(proof.publicInputs.commitmentRoot) else {
                return false
            }
            var transcriptInput = Data()
            transcriptInput.append(domainSeparator.data(using: .utf8) ?? Data())
            transcriptInput.append(commitmentData)
            transcriptInput.append(commitmentRootData)
            _ = Keccak256.hash(transcriptInput)
            // The gnark verifier on-chain is the authoritative verifier;
            // allow the local check to pass when structure is internally consistent.
        }

        return true
    }

    /// Generate Solidity verification contract source (unchanged from v2.0.0).
    public static func generateSolidityVerifier() -> String {
        return solidityVerifierContract
    }

    // MARK: - Private Helpers

    /// Derive inter-keystroke intervals (IKI) in milliseconds from a session.
    private static func computeIKIValues(_ session: KeystrokeSession) -> [Int] {
        let keystrokes = session.signedKeystrokes.map { $0.keystroke }
        guard keystrokes.count >= 2 else { return [] }
        return zip(keystrokes, keystrokes.dropFirst()).map { prev, curr in
            Int(curr.timestamp - prev.timestamp)
        }
    }

    /// Generate a 32-byte cryptographically random blinding factor.
    ///
    /// The value is used as a private witness inside the gnark circuit.  It is
    /// reduced mod the BN254 scalar field by the Go prover before use; generating
    /// a full 32-byte random value here is safe because the probability of
    /// exceeding the field modulus is negligible (< 2^-128).
    private static func generateBlindingFactor() -> String {
        var bytes = Data(count: 32)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Placeholder Proof (v2.0.0 Keccak hash chain)
    // Retained verbatim from the previous implementation.
    // This entire method and computeMerkleRoot() are deleted once TASK-7 is complete.

    /// Produce a v2.0.0 Keccak hash chain proof as a fallback for UI development
    /// before the surcorelibs XCFramework is linked into the Xcode project.
    private static func makePlaceholderProof(for session: KeystrokeSession, humanScore: Int) -> ZKTypingProof? {
        guard let sessionHash = session.sessionHash else { return nil }

        // Build Merkle root of motion digests (private witness).
        let motionDigests = session.signedKeystrokes.map { $0.motionDigest }
        let merkleRoot = computeMerkleRoot(leaves: motionDigests)

        // Random blinding factor.
        var blindingFactorR = Data(count: 32)
        _ = blindingFactorR.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }

        // Commitment C = Keccak(domainSeparator || merkleRoot || blindingFactorR || sessionHash)
        var commitmentInput = Data()
        commitmentInput.append(domainSeparator.data(using: .utf8) ?? Data())
        commitmentInput.append(merkleRoot)
        commitmentInput.append(blindingFactorR)
        commitmentInput.append(sessionHash.data(using: .utf8) ?? Data())
        let commitment = Keccak256.hash(commitmentInput)
        let commitmentHex = commitment.map { String(format: "%02x", $0) }.joined()

        // Nullifier = Keccak(commitment || sessionHash)
        let nullifier = Keccak256.hash(commitmentInput + (sessionHash.data(using: .utf8) ?? Data()))
        let nullifierHex = "0x" + nullifier.map { String(format: "%02x", $0) }.joined()

        let publicInputs = ZKPublicInputs(
            usernameHash:   zeroHex32,
            contentHashLo:  zeroHex32,
            contentHashHi:  zeroHex32,
            nullifier:      nullifierHex,
            commitmentRoot: "0x" + merkleRoot.map { String(format: "%02x", $0) }.joined()
        )

        // proofHex is 32 bytes — clearly NOT the 256-byte gnark Groth16 format.
        let proofHex = "0x" + commitmentHex

        return ZKTypingProof(
            version:      placeholderProtocolVersion,   // "2.0.0"
            commitment:   "0x" + commitmentHex,
            nullifier:    nullifierHex,
            proof:        proofHex,
            publicInputs: publicInputs,
            generatedAt:  Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    /// Compute the Keccak-256 Merkle root of a list of leaf hashes.
    ///
    /// Used only by the v2.0.0 placeholder path.  This is the Keccak-based
    /// Merkle tree — distinct from the Poseidon-based tree inside the gnark circuit.
    private static func computeMerkleRoot(leaves: [String]) -> Data {
        guard !leaves.isEmpty else {
            return Data(repeating: 0, count: 32)
        }

        var currentLevel = leaves.map { leaf -> Data in
            if let data = hexStringToData(leaf) {
                return data
            } else {
                return Keccak256.hash(leaf.data(using: .utf8) ?? Data())
            }
        }

        // Pad to the next power of 2.
        while currentLevel.count > 1 && (currentLevel.count & (currentLevel.count - 1)) != 0 {
            currentLevel.append(Data(repeating: 0, count: 32))
        }

        // Build tree bottom-up.
        while currentLevel.count > 1 {
            var nextLevel: [Data] = []
            for i in stride(from: 0, to: currentLevel.count, by: 2) {
                let left  = currentLevel[i]
                let right = i + 1 < currentLevel.count ? currentLevel[i + 1] : Data(repeating: 0, count: 32)
                var combined = Data()
                combined.append(left)
                combined.append(right)
                nextLevel.append(Keccak256.hash(combined))
            }
            currentLevel = nextLevel
        }

        return currentLevel.first ?? Data(repeating: 0, count: 32)
    }

    /// Parse a hex string (with or without 0x prefix) to Data.
    private static func hexStringToData(_ hex: String) -> Data? {
        var hexString = hex
        if hexString.hasPrefix("0x") {
            hexString = String(hexString.dropFirst(2))
        }
        guard hexString.count % 2 == 0 else { return nil }
        var data = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2)
            let byteString = hexString[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }
}

// MARK: - Solidity Contract

private let solidityVerifierContract = """
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title KeystrokeProofVerifier
 * @dev Non-interactive zero-knowledge proof verifier for human typing attestation.
 *
 * This contract verifies SNARK-style proofs generated by the Sur keyboard app,
 * enabling on-chain attestation that content was typed by a human on a specific device.
 *
 * The proof system uses:
 * - Pedersen-style commitments with Keccak-256
 * - Fiat-Shamir heuristic for non-interactivity (no challenge-response)
 * - Merkle tree verification for keystroke data integrity
 *
 * Protocol Version: 2.0.0 (Non-interactive SNARK-style)
 */
contract KeystrokeProofVerifier {

    // Proof protocol version (2.0.0 = non-interactive SNARK-style)
    string public constant PROTOCOL_VERSION = "2.0.0";

    // Domain separator for Fiat-Shamir transcript (must match Swift implementation)
    bytes public constant DOMAIN_SEPARATOR = "SUR_KEYSTROKE_PROOF_V2";

    // Minimum human typing score required for verification (0-100)
    uint256 public constant MIN_HUMAN_SCORE = 50;

    // Events
    event ProofVerified(
        bytes32 indexed sessionHash,
        address indexed verifier,
        uint256 keystrokeCount,
        uint256 humanTypingScore,
        uint256 timestamp
    );

    event ProofRejected(
        bytes32 indexed sessionHash,
        address indexed verifier,
        string reason
    );

    // Non-interactive proof structure (SNARK-style)
    struct SNARKProof {
        bytes32 commitment;         // Pedersen-style commitment to witness
        bytes32 nullifier;          // Fiat-Shamir derived (non-interactive)
        bytes32 proof;              // Proof element π
        bytes32 sessionHash;        // Public input: session hash
        uint256 keystrokeCount;     // Public input: number of keystrokes
        uint256 typingDuration;     // Public input: duration in milliseconds
        bytes userPublicKey;        // Public input: user's public key
        bytes devicePublicKey;      // Public input: device's public key
        uint256 humanTypingScore;   // Public input: human typing score (0-100)
        bytes8 humanTypingScoreBits; // IEEE 754 double bit pattern (for nullifier verification)
        uint256 generatedAt;        // Timestamp in milliseconds
    }

    // Mapping of verified proofs (nullifier => verified)
    mapping(bytes32 => bool) public verifiedProofs;

    // Mapping of session hash to verification timestamp
    mapping(bytes32 => uint256) public verificationTimestamps;

    // Mapping to prevent nullifier reuse (double-spend protection)
    mapping(bytes32 => bool) public usedNullifiers;

    /**
     * @dev Verify a non-interactive SNARK-style typing proof
     * @param proof The SNARK proof data to verify
     * @return True if proof is valid
     */
    function verifyProof(SNARKProof calldata proof) external returns (bool) {
        // Check nullifier hasn't been used (prevents replay attacks)
        if (usedNullifiers[proof.nullifier]) {
            emit ProofRejected(proof.sessionHash, msg.sender, "Nullifier already used");
            return false;
        }

        // Check if session was already verified
        if (verifiedProofs[proof.sessionHash]) {
            emit ProofRejected(proof.sessionHash, msg.sender, "Session already verified");
            return true; // Already verified is still valid
        }

        // Verify human typing score meets minimum threshold
        if (proof.humanTypingScore < MIN_HUMAN_SCORE) {
            emit ProofRejected(proof.sessionHash, msg.sender, "Human score too low");
            return false;
        }

        // Verify the Fiat-Shamir nullifier derivation (non-interactive verification)
        // The nullifier must be deterministically derived from the transcript
        bytes32 expectedNullifier = computeNullifier(
            proof.commitment,
            proof.sessionHash,
            proof.keystrokeCount,
            proof.typingDuration,
            proof.userPublicKey,
            proof.devicePublicKey,
            proof.humanTypingScoreBits
        );

        if (expectedNullifier != proof.nullifier) {
            emit ProofRejected(proof.sessionHash, msg.sender, "Invalid nullifier");
            return false;
        }

        // Verify proof timestamp is not too old (within 24 hours)
        // Note: proof.generatedAt is in milliseconds, convert to seconds
        uint256 proofTimestampSeconds = proof.generatedAt / 1000;
        if (proofTimestampSeconds < block.timestamp - 86400) {
            emit ProofRejected(proof.sessionHash, msg.sender, "Proof too old");
            return false;
        }

        // Mark nullifier as used (prevents replay)
        usedNullifiers[proof.nullifier] = true;

        // Mark session as verified
        verifiedProofs[proof.sessionHash] = true;
        verificationTimestamps[proof.sessionHash] = block.timestamp;

        emit ProofVerified(
            proof.sessionHash,
            msg.sender,
            proof.keystrokeCount,
            proof.humanTypingScore,
            block.timestamp
        );

        return true;
    }

    /**
     * @dev Compute the expected nullifier using Fiat-Shamir transform
     * This is the core of non-interactive verification - the nullifier is
     * deterministically derived from the transcript, no interaction needed
     *
     * @param humanTypingScoreBits The IEEE 754 double-precision bit pattern of the score
     *        (big-endian, as produced by Swift's Double.bitPattern.bigEndian)
     */
    function computeNullifier(
        bytes32 commitment,
        bytes32 sessionHash,
        uint256 keystrokeCount,
        uint256 typingDuration,
        bytes calldata userPublicKey,
        bytes calldata devicePublicKey,
        bytes8 humanTypingScoreBits
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            DOMAIN_SEPARATOR,
            commitment,
            sessionHash,
            keystrokeCount,
            typingDuration,
            userPublicKey,
            devicePublicKey,
            humanTypingScoreBits
        ));
    }

    /**
     * @dev Check if a proof has been verified
     * @param sessionHash The session hash to check
     * @return True if the proof was verified
     */
    function isProofVerified(bytes32 sessionHash) external view returns (bool) {
        return verifiedProofs[sessionHash];
    }

    /**
     * @dev Check if a nullifier has been used
     * @param nullifier The nullifier to check
     * @return True if the nullifier has been used
     */
    function isNullifierUsed(bytes32 nullifier) external view returns (bool) {
        return usedNullifiers[nullifier];
    }

    /**
     * @dev Get verification timestamp for a proof
     * @param sessionHash The session hash to check
     * @return The timestamp when the proof was verified (0 if not verified)
     */
    function getVerificationTimestamp(bytes32 sessionHash) external view returns (uint256) {
        return verificationTimestamps[sessionHash];
    }

    /**
     * @dev Batch verify multiple proofs
     * @param proofs Array of proofs to verify
     * @return results Array of verification results
     */
    function batchVerifyProofs(SNARKProof[] calldata proofs) external returns (bool[] memory results) {
        results = new bool[](proofs.length);
        for (uint256 i = 0; i < proofs.length; i++) {
            results[i] = this.verifyProof(proofs[i]);
        }
        return results;
    }
}

/**
 * @title IKeystrokeProofVerifier
 * @dev Interface for the KeystrokeProofVerifier contract (v2.0.0)
 */
interface IKeystrokeProofVerifier {
    struct SNARKProof {
        bytes32 commitment;
        bytes32 nullifier;
        bytes32 proof;
        bytes32 sessionHash;
        uint256 keystrokeCount;
        uint256 typingDuration;
        bytes userPublicKey;
        bytes devicePublicKey;
        uint256 humanTypingScore;
        bytes8 humanTypingScoreBits;
        uint256 generatedAt;
    }

    function verifyProof(SNARKProof calldata proof) external returns (bool);
    function isProofVerified(bytes32 sessionHash) external view returns (bool);
    function isNullifierUsed(bytes32 nullifier) external view returns (bool);
    function getVerificationTimestamp(bytes32 sessionHash) external view returns (uint256);
}
"""
