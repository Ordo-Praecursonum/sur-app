# Proof Generation & Cryptographic Methods

This document describes the cryptographic algorithms and proof systems implemented in the Sur project, along with the exact files and line numbers where each component lives.

---

## Overview

Sur implements a **SNARK-style non-interactive zero-knowledge proof** system to prove that a user typed content naturally (i.e., not a bot). The proof is generated on-device and can be verified both off-chain and on-chain via a Solidity smart contract.

Protocol version: `2.0.0`
Domain separator: `"SUR_KEYSTROKE_PROOF_V2"`

---

## End-to-End Pipeline

```
User Types → Keystroke Logger
    ↓
[Keystroke: key, timestamp, x, y]
    ↓
Keccak-256(serialized keystroke) → keystroke hash
    ↓
secp256k1 ECDSA sign (user key + device key) → [userSig, deviceSig]
    ↓
Motion Digest = Keccak-256(userSig || deviceSig)
    ↓
[SignedKeystroke] × N → KeystrokeSession
    ↓
Session Hash = Keccak-256(sessionId || startTimestamp || userPubKey || devicePubKey || motionDigests)
    ↓
Human Score = HumanTypingEvaluator (timing 35%, variation 25%, coordinates 20%, patterns 20%)
    ↓
ZK PROOF GENERATION (SNARK-style, Fiat-Shamir):
  1. Merkle Root  = Keccak-256 tree over motionDigests
  2. Blinding R, S = SecRandomCopyBytes(32 bytes each)
  3. Commitment C = Keccak-256(domain || merkleRoot || R || sessionHash)
  4. Nullifier    = Keccak-256(domain || C || sessionHash || keyCount || duration || userPubKey || devicePubKey || humanScore)
  5. Proof π     = Keccak-256(R || S || nullifier || merkleRoot || motionDigests)
    ↓
ZKTypingProof { version, commitment, nullifier, proof π, publicInputs, generatedAt }
    ↓
On-Chain Verification (Solidity):
  1. Nullifier not already used (replay protection)
  2. Re-derive and compare nullifier (Fiat-Shamir check)
  3. humanTypingScore >= 50
  4. Proof age <= 24 hours
  5. Mark nullifier as used
```

---

## Components

### 1. ZK Proof Generation

**File:** `Sur/Auth/ZKProofGenerator.swift`

| Step | Algorithm | Lines |
|------|-----------|-------|
| Commitment (Pedersen-style) | `C = Keccak-256(domain \|\| merkleRoot \|\| R \|\| sessionHash)` | 66–74 |
| Fiat-Shamir challenge / Nullifier | `Keccak-256(domain \|\| C \|\| sessionHash \|\| keyCount \|\| duration \|\| userPubKey \|\| devicePubKey \|\| score)` | 76–89 |
| Proof element π | `Keccak-256(R \|\| S \|\| nullifier \|\| merkleRoot \|\| motionDigests)` | 91–102 |
| Off-chain verification | Re-derives nullifier, checks score range (0–100), checks metadata | 124–183 |
| Merkle tree (Keccak-256) | Bottom-up, pads leaves to power-of-2 | 192–227 |

Blinding factors R and S are 32-byte values from `SecRandomCopyBytes`, providing randomness that prevents the proof element from being recomputed without the private randomness.

---

### 2. ZK Proof Structs

**File:** `Sur/Auth/KeystrokeLog.swift`

| Struct | Lines | Description |
|--------|-------|-------------|
| `Keystroke` | 15–45 | Raw input: key, timestamp (ms), x/y coordinates. Serialized as `"key\|ts\|x\|y"`, hashed with Keccak-256 |
| `SignedKeystroke` | 48–67 | Adds user + device secp256k1 signatures. Motion digest = `Keccak-256(userSig \|\| deviceSig)` |
| `KeystrokeSession` | 70–158 | Groups N signed keystrokes; stores session hash, human score, ZK proof, public keys |
| `ZKTypingProof` | 164–264 | Final proof object: version, commitment, nullifier, proof π, publicInputs, generatedAt. Includes `remixFormat()` for direct Solidity input |
| `ZKPublicInputs` | 267–301 | Public data for on-chain verification: sessionHash, keystrokeCount, typingDuration, public keys, humanTypingScore |
| `KeystrokeSigner` | 306–415 | Signs each keystroke with both user and device keys (secp256k1 ECDSA, 64-byte R‖S compact) |

---

### 3. Hash Functions

#### Keccak-256

**File:** `Sur/Auth/Keccak256.swift`
**Library:** CryptoSwift (`sha3(.keccak256)`)
**Output:** 32 bytes

Used for: session hash, commitment, nullifier, proof element, Merkle node hashing, keystroke hashing, motion digests, and Ethereum address generation.

> Note: Keccak-256 uses padding `0x01`, not `0x06` (SHA3-256). These are distinct algorithms.

#### SHA-256

**Library:** Apple CryptoKit
Used for: HMAC-SHA512 in BIP-32 key derivation, HMAC-SHA256 for device seed.

#### RIPEMD-160

**File:** `Sur/Auth/RIPEMD160.swift` (lines 23–112)
**Custom implementation.** Output: 20 bytes.
Used for: Bitcoin and Cosmos address generation (Hash160 = RIPEMD-160(SHA-256(pubkey))).

Algorithm details:
- 80-round compression function
- Parallel left and right message schedules
- Per-round rotation constants K, K'
- Rotation schedules r[], rPrime[], s[], sPrime[]

---

### 4. Signature Scheme — secp256k1 ECDSA

**File:** `Sur/Auth/Secp256k1.swift`
**Library:** P256K (libsecp256k1 binding)

| Operation | Lines | Details |
|-----------|-------|---------|
| Public key derivation | 40–71 | 32-byte private → 65-byte uncompressed (0x04 ‖ X ‖ Y) or 33-byte compressed |
| ECDSA sign | 197–265 | Output: 64-byte compact (R ‖ S) |
| Signature normalization | 484–524 | Enforces low-S (S ≤ n/2). Replaces high S with n−S. Required by BIP-62 / Ethereum |
| Signature verification | 274–313 | Input: 64-byte sig, 32-byte hash, 65-byte pubkey → boolean |
| Modular arithmetic | 142–195 | `addModN()` for BIP-32 child key derivation |
| Key validation | 119–134 | Checks: 32 bytes, non-zero, < curve order n |

Curve order n/2 (low-S boundary):
`0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0`

---

### 5. Signature Scheme — Ed25519

**File:** `Sur/Auth/Ed25519.swift`
**Library:** Apple CryptoKit (`Curve25519`)

Used for: Solana key derivation (SLIP-10 path `m/44'/501'/0'/0'`).

- `derivePublicKey()`: 32-byte seed → 32-byte public key
- `deriveKeypair()`: returns both seed and public key

---

### 6. Key Derivation

#### BIP-39 Mnemonic

**File:** `Sur/Auth/MnemonicGenerator.swift`
- 2048-word English wordlist
- Entropy sizes: 128–256 bits (12–24 words)
- Seed generation: PBKDF2-HMAC-SHA512 (BIP-39 standard)

#### BIP-32 / BIP-44 HD Derivation

**File:** `Sur/Auth/MultiChainKeyManager.swift`

Master key: `HMAC-SHA512(key="Bitcoin seed", data=seed)`
Child key derivation: `HMAC-SHA512` of parent key + index at each level.

| Network | BIP-44 Path | Curve | Address Encoding |
|---------|-------------|-------|-----------------|
| Ethereum | `m/44'/60'/0'/0/0` | secp256k1 | Keccak-256 → last 20 bytes, EIP-55 checksum |
| Bitcoin | `m/84'/0'/0'/0/0` | secp256k1 | SHA-256 → RIPEMD-160, Bech32 (bc1) |
| BSC | `m/44'/60'/0'/0/0` | secp256k1 | Same as Ethereum |
| Tron | `m/44'/195'/0'/0/0` | secp256k1 | Similar to Ethereum, T prefix |
| Cosmos | `m/44'/118'/0'/0/0` | secp256k1 | RIPEMD-160(SHA-256(pubkey)), Bech32 |
| Solana | `m/44'/501'/0'/0'` | Ed25519 (SLIP-10) | Base58 |
| OriginTrail | `m/44'/60'/0'/0/0` | secp256k1 | ERC-20 on Ethereum |

**File:** `Sur/Auth/EthereumKeyManager.swift` — single-chain Ethereum variant (lines 62–142).

#### Device Key

**File:** `Sur/Auth/DeviceIDManager.swift` (lines 94–127)

1. Device UUID from `UIDevice.current.identifierForVendor`
2. Device seed = `HMAC-SHA256(userPrivateKey, deviceUUID)`
3. Device private key = seed (validated as secp256k1 scalar)
4. Device public key = secp256k1 derivation

This key signs each keystroke alongside the user key, cryptographically binding the data to a specific device.

---

### 7. Human Typing Evaluator

**File:** `Sur/Auth/HumanTypingEvaluator.swift`

Produces a score 0–100 (IEEE 754 double, also encoded as `bytes8` bit pattern for Solidity).

| Factor | Weight | Criterion |
|--------|--------|-----------|
| Timing patterns | 35% | Inter-key intervals 20ms–2000ms; average 100–400ms |
| Timing variation | 25% | Coefficient of variation 0.15–1.0 (too consistent = bot) |
| Coordinate patterns | 20% | Normalized jump ≤ 0.8 |
| Typing patterns | 20% | Natural pauses and bursts; pause threshold 300ms |

A score < 50 causes on-chain proof rejection.

---

### 8. On-Chain Verifier (Solidity)

**File:** `Contracts/KeystrokeProofVerifier.sol`

```solidity
struct SNARKProof {
    bytes32 commitment;          // Pedersen-style commitment
    bytes32 nullifier;           // Fiat-Shamir derived challenge
    bytes32 proof;               // Proof element π
    bytes32 sessionHash;
    uint256 keystrokeCount;
    uint256 typingDuration;      // milliseconds
    bytes   userPublicKey;
    bytes   devicePublicKey;
    uint256 humanTypingScore;    // 0–100
    bytes8  humanTypingScoreBits; // IEEE 754 double bit pattern
    uint256 generatedAt;         // milliseconds since epoch
}
```

**Verification steps** (lines 327–387):
1. Check nullifier not already in `usedNullifiers` mapping (replay protection)
2. Re-derive expected nullifier with `keccak256(...)` and compare
3. Assert `humanTypingScore >= MIN_HUMAN_SCORE` (50)
4. Assert `block.timestamp - generatedAt <= 24 hours`
5. Mark nullifier as used (`usedNullifiers[nullifier] = true`)
6. Emit `ProofVerified` event

---

### 9. Keystroke Logging (Keyboard Extension vs Main App)

| Aspect | Main App (`KeystrokeLogManager.swift`) | Keyboard Extension (`SurKeyboard/KeystrokeLogger.swift`) |
|--------|----------------------------------------|----------------------------------------------------------|
| Hash | Keccak-256 (CryptoSwift) | SHA-256 (CryptoKit) — recomputed by main app |
| Signing | Full secp256k1 ECDSA | Motion digest as placeholder |
| Storage | Shared UserDefaults (`group.com.ordo.sure.Sur`) | Same group |

---

### 10. Secure Storage

**File:** `Sur/Auth/SecureEnclaveManager.swift`

- iOS Keychain with Secure Enclave protection
- Optional biometric gating (Face ID / Touch ID)
- Keys stored: `com.ordo.sur.privateKey`, `com.ordo.sur.mnemonic`, `com.ordo.sur.publicAddress`

---

### 11. Address Encoding Utilities

| Encoding | File | Used For |
|----------|------|---------|
| Bech32 | `Sur/Auth/Bech32.swift` | Cosmos (`cosmos1…`), Bitcoin (`bc1…`) |
| Base58 | (MultiChainKeyManager) | Solana |
| EIP-55 checksum | `Sur/Auth/EthereumKeyManager.swift` lines 144+ | Ethereum mixed-case address |

---

## Key Files at a Glance

| File | Responsibility |
|------|---------------|
| `Sur/Auth/ZKProofGenerator.swift` | Core ZK proof generation and off-chain verification |
| `Sur/Auth/KeystrokeLog.swift` | Proof/session/keystroke data structures |
| `Contracts/KeystrokeProofVerifier.sol` | On-chain Solidity verifier |
| `Sur/Auth/Secp256k1.swift` | secp256k1 ECDSA signing, verification, key derivation |
| `Sur/Auth/Ed25519.swift` | Ed25519 key derivation (Solana) |
| `Sur/Auth/Keccak256.swift` | Keccak-256 hash wrapper |
| `Sur/Auth/RIPEMD160.swift` | RIPEMD-160 implementation |
| `Sur/Auth/MultiChainKeyManager.swift` | BIP-44 multi-chain HD wallet derivation |
| `Sur/Auth/EthereumKeyManager.swift` | Ethereum-specific key/address generation |
| `Sur/Auth/DeviceIDManager.swift` | Device-bound signing key generation |
| `Sur/Auth/MnemonicGenerator.swift` | BIP-39 mnemonic generation and seed derivation |
| `Sur/Auth/HumanTypingEvaluator.swift` | Human typing score computation |
| `Sur/Auth/KeystrokeLogManager.swift` | Session lifecycle and proof orchestration |
| `SurKeyboard/KeystrokeLogger.swift` | Keyboard extension keystroke capture |
| `Sur/Auth/SecureEnclaveManager.swift` | Secure Enclave / Keychain storage |
| `Sur/Auth/Bech32.swift` | Bech32 encoding for Cosmos/Bitcoin addresses |
| `Sur/Auth/BlockchainNetwork.swift` | Network definitions and BIP-44 coin types |
