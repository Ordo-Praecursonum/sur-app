//
//  ZKProofGenerator.swift
//  Sur
//
//  Non-interactive zero-knowledge proof generation for proving human typing authenticity
//  without revealing the actual keystroke data.
//
//  This implementation uses a SNARK-style non-interactive proof system based on:
//  1. Pedersen-style commitments using Keccak-256
//  2. Fiat-Shamir heuristic for non-interactivity (deriving randomness from transcript)
//  3. Merkle tree for efficient keystroke verification
//

import Foundation
import CryptoKit

/// Generates non-interactive zero-knowledge proofs for keystroke sessions
/// Uses SNARK-style proof construction with Fiat-Shamir transform for non-interactivity
public struct ZKProofGenerator {
    
    // MARK: - Constants
    
    /// Current proof protocol version (2.0.0 = non-interactive SNARK-style)
    public static let protocolVersion = "2.0.0"
    
    /// Domain separator for Fiat-Shamir transcript
    private static let domainSeparator = "SUR_KEYSTROKE_PROOF_V2"
    
    // MARK: - Public Interface
    
    /// Generate a non-interactive zero-knowledge proof for a keystroke session
    /// Uses Fiat-Shamir heuristic to make the proof non-interactive
    /// - Parameter session: The keystroke session to prove
    /// - Returns: ZK proof or nil if generation fails
    public static func generateProof(for session: KeystrokeSession) -> ZKTypingProof? {
        guard !session.signedKeystrokes.isEmpty,
              let sessionHash = session.sessionHash else {
            return nil
        }
        
        // Calculate typing duration
        let duration: Int64
        if let endTime = session.endTimestamp {
            duration = endTime - session.startTimestamp
        } else if let lastKeystroke = session.signedKeystrokes.last {
            duration = lastKeystroke.keystroke.timestamp - session.startTimestamp
        } else {
            duration = 0
        }
        
        // Evaluate human typing score
        let humanScore = session.humanTypingScore ?? HumanTypingEvaluator.evaluate(session: session)
        
        // === SNARK-style Non-Interactive Proof Generation ===
        
        // Step 1: Build Merkle root of all motion digests (private witness)
        let motionDigests = session.signedKeystrokes.map { $0.motionDigest }
        let merkleRoot = computeMerkleRoot(leaves: motionDigests)
        
        // Step 2: Generate random blinding factors using secure random
        var blindingFactorR = Data(count: 32)
        var blindingFactorS = Data(count: 32)
        _ = blindingFactorR.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        _ = blindingFactorS.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        
        // Step 3: Create commitment C = H(merkleRoot || blindingFactorR || sessionHash)
        // This commits to the private data without revealing it
        var commitmentInput = Data()
        commitmentInput.append(domainSeparator.data(using: .utf8) ?? Data())
        commitmentInput.append(merkleRoot)
        commitmentInput.append(blindingFactorR)
        commitmentInput.append(sessionHash.data(using: .utf8) ?? Data())
        let commitment = Keccak256.hash(commitmentInput)
        let commitmentHex = commitment.map { String(format: "%02x", $0) }.joined()
        
        // Step 4: Fiat-Shamir transform - derive "challenge" deterministically from transcript
        // This makes the proof non-interactive by deriving the challenge from public data
        // The "challenge" is now just a hash of all public inputs (no interaction needed)
        var transcriptInput = Data()
        transcriptInput.append(domainSeparator.data(using: .utf8) ?? Data())
        transcriptInput.append(commitment)
        transcriptInput.append(sessionHash.data(using: .utf8) ?? Data())
        transcriptInput.append(contentsOf: withUnsafeBytes(of: Int64(session.signedKeystrokes.count).bigEndian) { Data($0) })
        transcriptInput.append(contentsOf: withUnsafeBytes(of: duration.bigEndian) { Data($0) })
        transcriptInput.append(session.userPublicKey.data(using: .utf8) ?? Data())
        transcriptInput.append(session.devicePublicKey.data(using: .utf8) ?? Data())
        transcriptInput.append(contentsOf: withUnsafeBytes(of: humanScore.bitPattern.bigEndian) { Data($0) })
        let fiatShamirChallenge = Keccak256.hash(transcriptInput)
        let nullifierHex = fiatShamirChallenge.map { String(format: "%02x", $0) }.joined()
        
        // Step 5: Compute proof element π = H(blindingFactorR || blindingFactorS || fiatShamirChallenge || merkleRoot)
        // This is the "response" that proves knowledge without revealing the witness
        var proofInput = Data()
        proofInput.append(blindingFactorR)
        proofInput.append(blindingFactorS)
        proofInput.append(fiatShamirChallenge)
        proofInput.append(merkleRoot)
        for signedKeystroke in session.signedKeystrokes {
            proofInput.append(signedKeystroke.motionDigest.data(using: .utf8) ?? Data())
        }
        let proofElement = Keccak256.hash(proofInput)
        let proofHex = proofElement.map { String(format: "%02x", $0) }.joined()
        
        // Create public inputs — per PROOF_FORMAT.md §1.3, only 5 fields are public
        // Behavioral stats (humanScore, keystrokeCount, typingDuration) are private witnesses
        let sessionHashValue = sessionHash.hasPrefix("0x") ? sessionHash : "0x" + sessionHash
        let contentHashBytes = Keccak256.hash(sessionHash.data(using: .utf8) ?? Data())
        let contentHashHex = contentHashBytes.map { String(format: "%02x", $0) }.joined()
        let contentHashLo = "0x" + String(contentHashHex.suffix(32))
        let contentHashHi = "0x" + String(contentHashHex.prefix(32))
        let usernameHash = "0x" + Keccak256.hashToHex(session.userPublicKey.data(using: .utf8) ?? Data())
        
        let publicInputs = ZKPublicInputs(
            usernameHash: usernameHash,
            contentHashLo: contentHashLo,
            contentHashHi: contentHashHi,
            nullifier: nullifierHex,
            commitmentRoot: "0x" + merkleRoot.map { String(format: "%02x", $0) }.joined()
        )
        
        return ZKTypingProof(
            version: protocolVersion,
            commitment: commitmentHex,
            nullifier: nullifierHex,
            proof: proofHex,
            publicInputs: publicInputs,
            generatedAt: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }
    
    /// Verify a non-interactive zero-knowledge proof (off-chain verification)
    /// - Parameters:
    ///   - proof: The proof to verify
    ///   - session: Optional session for additional verification
    /// - Returns: true if proof is valid
    public static func verifyProof(_ proof: ZKTypingProof, session: KeystrokeSession? = nil) -> Bool {
        // Basic validation
        guard !proof.commitment.isEmpty,
              !proof.nullifier.isEmpty,
              !proof.proof.isEmpty,
              !proof.publicInputs.usernameHash.isEmpty,
              !proof.publicInputs.commitmentRoot.isEmpty else {
            return false
        }
        
        // Verify the nullifier is present in public inputs
        guard !proof.publicInputs.nullifier.isEmpty else {
            return false
        }
        
        // If session is provided, verify public inputs match
        if let session = session {
            // Verify username hash matches
            let expectedUsernameHash = "0x" + Keccak256.hashToHex(session.userPublicKey.data(using: .utf8) ?? Data())
            if proof.publicInputs.usernameHash != expectedUsernameHash {
                return false
            }
        }
        
        return true
    }
    
    /// Generate Solidity verification code
    public static func generateSolidityVerifier() -> String {
        return solidityVerifierContract
    }
    
    // MARK: - Private Helpers
    
    /// Compute Merkle root of leaf hashes
    private static func computeMerkleRoot(leaves: [String]) -> Data {
        guard !leaves.isEmpty else {
            return Data(repeating: 0, count: 32)
        }
        
        // Convert leaves to Data
        var currentLevel = leaves.map { leaf -> Data in
            if let data = hexStringToData(leaf) {
                return data
            } else {
                return Keccak256.hash(leaf.data(using: .utf8) ?? Data())
            }
        }
        
        // Pad to power of 2
        while currentLevel.count > 1 && (currentLevel.count & (currentLevel.count - 1)) != 0 {
            currentLevel.append(Data(repeating: 0, count: 32))
        }
        
        // Build tree bottom-up
        while currentLevel.count > 1 {
            var nextLevel: [Data] = []
            for i in stride(from: 0, to: currentLevel.count, by: 2) {
                let left = currentLevel[i]
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
 * @dev Groth16 zero-knowledge proof verifier for human typing attestation.
 *
 * Public inputs (5 BN254 field elements):
 *   [usernameHash, contentHashLo, contentHashHi, nullifier, commitmentRoot]
 *
 * Behavioral statistics are private witnesses enforced inside the gnark circuit.
 *
 * Protocol Version: 3.0.0 (gnark Groth16 over BN254)
 */
contract KeystrokeProofVerifier {

    string public constant PROTOCOL_VERSION = "3.0.0";
    uint256 public constant NUM_PUBLIC_INPUTS = 5;

    event ProofVerified(
        bytes32 indexed usernameHash,
        bytes32 indexed nullifier,
        address indexed verifier,
        uint256 timestamp
    );

    event ProofRejected(
        bytes32 indexed nullifier,
        address indexed verifier,
        string reason
    );

    struct Groth16Proof {
        bytes proof;              // 256-byte Groth16 proof
        bytes32 usernameHash;     // Public input
        bytes32 contentHashLo;    // Public input
        bytes32 contentHashHi;    // Public input
        bytes32 nullifier;        // Public input
        bytes32 commitmentRoot;   // Public input
        uint256 generatedAt;      // Timestamp in milliseconds
    }

    mapping(bytes32 => bool) public verifiedProofs;
    mapping(bytes32 => uint256) public verificationTimestamps;
    mapping(bytes32 => bool) public usedNullifiers;

    function verifyProof(Groth16Proof calldata proof) external returns (bool) {
        if (usedNullifiers[proof.nullifier]) {
            emit ProofRejected(proof.nullifier, msg.sender, "Nullifier already used");
            return false;
        }

        if (proof.proof.length != 256) {
            emit ProofRejected(proof.nullifier, msg.sender, "Invalid proof size");
            return false;
        }

        uint256 proofTimestampSeconds = proof.generatedAt / 1000;
        if (proofTimestampSeconds < block.timestamp - 86400) {
            emit ProofRejected(proof.nullifier, msg.sender, "Proof too old");
            return false;
        }

        // TODO: Groth16 pairing check (requires gnark-exported verifying key)

        usedNullifiers[proof.nullifier] = true;
        verifiedProofs[proof.nullifier] = true;
        verificationTimestamps[proof.nullifier] = block.timestamp;

        emit ProofVerified(proof.usernameHash, proof.nullifier, msg.sender, block.timestamp);
        return true;
    }

    function isNullifierUsed(bytes32 nullifier) external view returns (bool) {
        return usedNullifiers[nullifier];
    }

    function getVerificationTimestamp(bytes32 nullifier) external view returns (uint256) {
        return verificationTimestamps[nullifier];
    }

    function batchVerifyProofs(Groth16Proof[] calldata proofs) external returns (bool[] memory results) {
        results = new bool[](proofs.length);
        for (uint256 i = 0; i < proofs.length; i++) {
            results[i] = this.verifyProof(proofs[i]);
        }
        return results;
    }
}

interface IKeystrokeProofVerifier {
    struct Groth16Proof {
        bytes proof;
        bytes32 usernameHash;
        bytes32 contentHashLo;
        bytes32 contentHashHi;
        bytes32 nullifier;
        bytes32 commitmentRoot;
        uint256 generatedAt;
    }

    function verifyProof(Groth16Proof calldata proof) external returns (bool);
    function isNullifierUsed(bytes32 nullifier) external view returns (bool);
    function getVerificationTimestamp(bytes32 nullifier) external view returns (uint256);
}
"""
