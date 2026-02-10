//
//  ZKProofGenerator.swift
//  Sur
//
//  Zero-knowledge proof generation for proving human typing authenticity
//  without revealing the actual keystroke data.
//

import Foundation
import CryptoKit

/// Generates zero-knowledge proofs for keystroke sessions
public struct ZKProofGenerator {
    
    // MARK: - Constants
    
    /// Current proof protocol version
    public static let protocolVersion = "1.0.0"
    
    // MARK: - Public Interface
    
    /// Generate a zero-knowledge proof for a keystroke session
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
        
        // Generate random blinding factor (32 bytes)
        var blindingFactor = Data(count: 32)
        _ = blindingFactor.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        
        // Create commitment: hash(sessionHash || blindingFactor || humanScore)
        var commitmentInput = Data()
        commitmentInput.append(sessionHash.data(using: .utf8) ?? Data())
        commitmentInput.append(blindingFactor)
        commitmentInput.append(contentsOf: withUnsafeBytes(of: humanScore.bitPattern.bigEndian) { Data($0) })
        let commitment = Keccak256.hash(commitmentInput)
        let commitmentHex = commitment.map { String(format: "%02x", $0) }.joined()
        
        // Create challenge: hash(commitment || publicInputs)
        var challengeInput = Data()
        challengeInput.append(commitment)
        challengeInput.append(sessionHash.data(using: .utf8) ?? Data())
        challengeInput.append(contentsOf: withUnsafeBytes(of: Int64(session.signedKeystrokes.count).bigEndian) { Data($0) })
        challengeInput.append(contentsOf: withUnsafeBytes(of: duration.bigEndian) { Data($0) })
        challengeInput.append(session.userPublicKey.data(using: .utf8) ?? Data())
        challengeInput.append(session.devicePublicKey.data(using: .utf8) ?? Data())
        let challenge = Keccak256.hash(challengeInput)
        let challengeHex = challenge.map { String(format: "%02x", $0) }.joined()
        
        // Create response: hash(blindingFactor || challenge || allMotionDigests)
        var responseInput = Data()
        responseInput.append(blindingFactor)
        responseInput.append(challenge)
        for signedKeystroke in session.signedKeystrokes {
            responseInput.append(signedKeystroke.motionDigest.data(using: .utf8) ?? Data())
        }
        let response = Keccak256.hash(responseInput)
        let responseHex = response.map { String(format: "%02x", $0) }.joined()
        
        // Create public inputs
        let publicInputs = ZKPublicInputs(
            sessionHash: sessionHash,
            keystrokeCount: session.signedKeystrokes.count,
            typingDuration: duration,
            userPublicKey: session.userPublicKey,
            devicePublicKey: session.devicePublicKey,
            humanTypingScore: humanScore
        )
        
        return ZKTypingProof(
            version: protocolVersion,
            commitment: commitmentHex,
            challenge: challengeHex,
            response: responseHex,
            publicInputs: publicInputs,
            generatedAt: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }
    
    /// Verify a zero-knowledge proof (off-chain verification)
    /// - Parameters:
    ///   - proof: The proof to verify
    ///   - session: Optional session for additional verification
    /// - Returns: true if proof is valid
    public static func verifyProof(_ proof: ZKTypingProof, session: KeystrokeSession? = nil) -> Bool {
        // Basic validation
        guard !proof.commitment.isEmpty,
              !proof.challenge.isEmpty,
              !proof.response.isEmpty,
              !proof.publicInputs.sessionHash.isEmpty else {
            return false
        }
        
        // Verify challenge derivation
        guard let sessionHashData = proof.publicInputs.sessionHash.data(using: .utf8),
              let commitmentData = hexStringToData(proof.commitment),
              let userPubKeyData = proof.publicInputs.userPublicKey.data(using: .utf8),
              let devicePubKeyData = proof.publicInputs.devicePublicKey.data(using: .utf8) else {
            return false
        }
        
        var challengeInput = Data()
        challengeInput.append(commitmentData)
        challengeInput.append(sessionHashData)
        challengeInput.append(contentsOf: withUnsafeBytes(of: Int64(proof.publicInputs.keystrokeCount).bigEndian) { Data($0) })
        challengeInput.append(contentsOf: withUnsafeBytes(of: proof.publicInputs.typingDuration.bigEndian) { Data($0) })
        challengeInput.append(userPubKeyData)
        challengeInput.append(devicePubKeyData)
        let expectedChallenge = Keccak256.hash(challengeInput)
        let expectedChallengeHex = expectedChallenge.map { String(format: "%02x", $0) }.joined()
        
        if expectedChallengeHex != proof.challenge {
            return false
        }
        
        // If session is provided, verify public inputs match
        if let session = session {
            if proof.publicInputs.sessionHash != session.sessionHash {
                return false
            }
            if proof.publicInputs.keystrokeCount != session.signedKeystrokes.count {
                return false
            }
            if proof.publicInputs.userPublicKey != session.userPublicKey {
                return false
            }
            if proof.publicInputs.devicePublicKey != session.devicePublicKey {
                return false
            }
        }
        
        // Verify human typing score is reasonable
        if proof.publicInputs.humanTypingScore < 0 || proof.publicInputs.humanTypingScore > 100 {
            return false
        }
        
        return true
    }
    
    /// Generate Solidity verification code
    public static func generateSolidityVerifier() -> String {
        return solidityVerifierContract
    }
    
    // MARK: - Private Helpers
    
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
 * @dev Verifies zero-knowledge proofs of human typing from the Sur keyboard app.
 * 
 * This contract allows verification of typing proofs generated by the Sur app,
 * enabling on-chain attestation that content was typed by a human on a specific device.
 */
contract KeystrokeProofVerifier {
    
    // Proof protocol version
    string public constant PROTOCOL_VERSION = "1.0.0";
    
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
    
    // Struct for proof data
    struct TypingProof {
        bytes32 commitment;
        bytes32 challenge;
        bytes32 response;
        bytes32 sessionHash;
        uint256 keystrokeCount;
        uint256 typingDuration;
        bytes userPublicKey;
        bytes devicePublicKey;
        uint256 humanTypingScore;
        uint256 generatedAt;
    }
    
    // Mapping of verified proofs
    mapping(bytes32 => bool) public verifiedProofs;
    
    // Mapping of session hash to verification timestamp
    mapping(bytes32 => uint256) public verificationTimestamps;
    
    /**
     * @dev Verify a typing proof
     * @param proof The proof data to verify
     * @return True if proof is valid
     */
    function verifyProof(TypingProof calldata proof) external returns (bool) {
        // Check if proof was already verified
        if (verifiedProofs[proof.sessionHash]) {
            emit ProofRejected(proof.sessionHash, msg.sender, "Already verified");
            return true; // Already verified is still valid
        }
        
        // Verify human typing score meets minimum threshold
        if (proof.humanTypingScore < MIN_HUMAN_SCORE) {
            emit ProofRejected(proof.sessionHash, msg.sender, "Human score too low");
            return false;
        }
        
        // Verify challenge derivation
        bytes32 expectedChallenge = keccak256(abi.encodePacked(
            proof.commitment,
            proof.sessionHash,
            proof.keystrokeCount,
            proof.typingDuration,
            proof.userPublicKey,
            proof.devicePublicKey
        ));
        
        if (expectedChallenge != proof.challenge) {
            emit ProofRejected(proof.sessionHash, msg.sender, "Invalid challenge");
            return false;
        }
        
        // Verify proof timestamp is not too old (within 24 hours)
        if (proof.generatedAt < block.timestamp - 86400) {
            emit ProofRejected(proof.sessionHash, msg.sender, "Proof too old");
            return false;
        }
        
        // Mark as verified
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
     * @dev Check if a proof has been verified
     * @param sessionHash The session hash to check
     * @return True if the proof was verified
     */
    function isProofVerified(bytes32 sessionHash) external view returns (bool) {
        return verifiedProofs[sessionHash];
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
    function batchVerifyProofs(TypingProof[] calldata proofs) external returns (bool[] memory results) {
        results = new bool[](proofs.length);
        for (uint256 i = 0; i < proofs.length; i++) {
            results[i] = this.verifyProof(proofs[i]);
        }
        return results;
    }
    
    /**
     * @dev Compute the expected challenge for verification
     * @param commitment The proof commitment
     * @param sessionHash The session hash
     * @param keystrokeCount Number of keystrokes
     * @param typingDuration Duration in milliseconds
     * @param userPublicKey User's public key
     * @param devicePublicKey Device's public key
     * @return The expected challenge hash
     */
    function computeChallenge(
        bytes32 commitment,
        bytes32 sessionHash,
        uint256 keystrokeCount,
        uint256 typingDuration,
        bytes calldata userPublicKey,
        bytes calldata devicePublicKey
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            commitment,
            sessionHash,
            keystrokeCount,
            typingDuration,
            userPublicKey,
            devicePublicKey
        ));
    }
}

/**
 * @title IKeystrokeProofVerifier
 * @dev Interface for the KeystrokeProofVerifier contract
 */
interface IKeystrokeProofVerifier {
    struct TypingProof {
        bytes32 commitment;
        bytes32 challenge;
        bytes32 response;
        bytes32 sessionHash;
        uint256 keystrokeCount;
        uint256 typingDuration;
        bytes userPublicKey;
        bytes devicePublicKey;
        uint256 humanTypingScore;
        uint256 generatedAt;
    }
    
    function verifyProof(TypingProof calldata proof) external returns (bool);
    function isProofVerified(bytes32 sessionHash) external view returns (bool);
    function getVerificationTimestamp(bytes32 sessionHash) external view returns (uint256);
}
"""
