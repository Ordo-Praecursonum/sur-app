# Sur Protocol iOS — Critical Tasks

> **These 5 tasks must be complete before any external-facing launch of the mobile wallet.**
> They are gaps between the documented security model and what currently ships in this iOS app.
> L1 contract implementation and Cosmos chain implementation are **separate projects** — see `PROJECT_SCOPE.md`.
> See `tasks/REVIEW.md` for the full team discussion that produced these findings.

---

## TASK-1: Replace ZK "Proof" with Real gnark Groth16 over BN254 (iOS FFI)

**Owner:** Dmitri Vasiliev (circuit + FFI), Lena Kovacs (Swift integration)
**Reviewer:** Dr. Amara Diallo, Marcus Webb
**Priority:** CRITICAL
**Complexity:** XL
**Blocked by:** TASK-2 (Poseidon must be ready — circuit uses it)
**Blocks:** TASK-7 (surcorelibs gets populated with the real circuit)
**Spec reference:** `project-scoping/docs/PROOF_FORMAT.md §1.1`, `project-scoping/docs/ZK_CIRCUIT.md`

### Problem Statement

`Sur/Auth/ZKProofGenerator.swift` implements a Keccak-256 hash chain and calls it a "SNARK-style non-interactive proof." It has no zero-knowledge property: a verifier who knows the inputs can recompute every value — commitment, nullifier, and proof element — without any secret witness. The output is 32 bytes (a Keccak hash); the specification requires 256 bytes (two G1 points and one G2 point on BN254).

The correct architecture: the iOS app calls a `ProveAttestation` function compiled into `surcorelibs/` (a Go static library linked into the app as an XCFramework). That function runs a real gnark Groth16 circuit. The Swift layer becomes a thin FFI wrapper, not a cryptographic implementation.

The proof this app generates is consumed by two external projects:
- **Sur Chain project**: the Cosmos chain verifies the proof on-chain via an embedded gnark verifying key
- **L1 Settlement project**: the SP1 batch prover wraps gnark proofs into an SP1 aggregate proof for L1 settlement

The proof format must match what those projects expect: 256-byte gnark Groth16 proof + 5 BN254 public inputs (`username_hash`, `content_hash_lo`, `content_hash_hi`, `nullifier`, `commitment_root`).

### Files to Modify / Create

| File | Action | Notes |
|---|---|---|
| `Sur/Auth/ZKProofGenerator.swift` | **Full replacement** | Remove all Keccak-based proof construction; replace with FFI call to `ProveAttestation` and result decoding |
| `surcorelibs/gnark/attestation_circuit.go` | **Create** | gnark Groth16 circuit: Merkle inclusion (Poseidon), nullifier (Poseidon), Secure Enclave P-256 signature (emulated), behavioral constraints |
| `surcorelibs/gnark/ffi_bridge.go` | **Create** | `//export ProveAttestation` C function; `ProverInput` JSON schema; `VerifyAttestation` for local validation |
| `surcorelibs/gnark/circuit_test.go` | **Create** | Property-based tests: 100 random valid witnesses pass, 100 random invalid witnesses fail; constraint count + proving time benchmarks |
| `surcorelibs/Makefile` | **Create** | Builds `libsurcorelibs.a` for `arm64-apple-ios` and `x86_64-apple-ios-simulator`; assembles XCFramework |
| `Sur.xcodeproj/project.pbxproj` | **Modify** | Add XCFramework build phase for `libsurcorelibs.xcframework` |
| `SurTests/ZKProofGeneratorTests.swift` | **Create** | Swift unit tests: call `ProveAttestation` via FFI, verify 256-byte output, verify locally with `VerifyAttestation` |

### ProverInput JSON Schema (interface contract with Sur Chain project)

```json
{
  "username_hash": "0x...",          // BN254 field element (32 bytes hex)
  "content_hash_lo": "0x...",        // lower 128 bits of SHA-256 content hash
  "content_hash_hi": "0x...",        // upper 128 bits
  "device_pubkey_x": "0x...",        // P-256 x coordinate (two-limb BN254 encoding)
  "device_pubkey_y": "0x...",        // P-256 y coordinate
  "session_counter": 42,             // uint64 session counter
  "blinding_factor": "0x...",        // 32-byte random (private witness)
  "commitment_root": "0x...",        // Poseidon Merkle root from Sur Chain
  "merkle_path": ["0x...", ...],     // 8 sibling hashes (private)
  "merkle_directions": [0, 1, ...],  // 8 direction bits (private)
  "se_signature_r": "0x...",         // Secure Enclave ECDSA r (two-limb)
  "se_signature_s": "0x...",         // Secure Enclave ECDSA s (two-limb)
  "human_score": 74,                 // integer 0–100 (private witness)
  "iki_values_ms": [120, 95, ...],   // per-keystroke IKI array (private)
  "keystroke_count": 45              // private witness
}
```

### Acceptance Criteria

- [ ] `ProveAttestation(inputJSON)` callable from Swift via CGo FFI; no crash, no memory leak (verified with Address Sanitizer)
- [ ] Proof output is exactly 256 bytes: `[A_x(32), A_y(32), B_x0(32), B_x1(32), B_y0(32), B_y1(32), C_x(32), C_y(32)]`
- [ ] Proof passes `groth16.Verify(vk, proof, publicWitness)` in Go unit test
- [ ] Proof fails verification for tampered behavioral stats, wrong device commitment, mismatched nullifier
- [ ] Constraint count and proving time documented in PR; proving time < 8 seconds on Apple M-series hardware
- [ ] `ZKProofGenerator.swift` contains no Keccak-based proof construction
- [ ] Xcode build succeeds for device (`arm64-apple-ios`) and simulator targets

---

## TASK-2: Replace Keccak-256 with Poseidon (BN254) Across surcorelibs

**Owner:** Dmitri Vasiliev
**Reviewer:** Dr. Amara Diallo
**Priority:** CRITICAL
**Complexity:** L
**Blocked by:** None (first task — execute first)
**Blocks:** TASK-1 (circuit uses Poseidon), all cross-project proof verification
**Spec reference:** `project-scoping/docs/ZK_CIRCUIT.md §3`, `project-scoping/docs/PROOF_FORMAT.md §5.2 and §6.1`

### Problem Statement

Every hash operation in the proof pipeline — commitment, nullifier, Merkle tree — currently uses Keccak-256. The specification requires Poseidon over BN254 for all in-circuit operations. Keccak-256 requires ~27,000 R1CS constraints per hash call inside a BN254 circuit; Poseidon requires ~220. Using Keccak-256 would make proving impractical on a mobile device (multiple minutes per proof).

Cross-project compatibility is critical: the Poseidon output this app computes must match what the Sur Chain project verifies on-chain and what the L1 Settlement project's `PoseidonHasher.sol` produces. The canonical test vector from `PROOF_FORMAT.md §6.1` is the shared validation anchor:

```
Poseidon(1, 2) over BN254 = 0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a
```

### Files to Create

| File | Notes |
|---|---|
| `surcorelibs/poseidon/poseidon.go` | Go Poseidon via `gnark-crypto/ecc/bn254/fr/poseidon`; rate=2, cap=1, 8 full rounds, 57 partial rounds, S-box x^5 |
| `surcorelibs/poseidon/poseidon_test.go` | Test vectors: `Poseidon(1,2)` == canonical value; 20 input/output pairs |
| `surcorelibs/poseidon/test_vectors.json` | Shared test vectors — **send copy to Sur Chain and L1 Settlement projects** for cross-project validation |

`Sur/Auth/Keccak256.swift` is retained for Ethereum address derivation and content hashing only — all ZK proof operations switch to Poseidon via FFI.

### Cross-Project Coordination

The `test_vectors.json` file produced by this task must be shared with:
- **Sur Chain project** — to validate their Solidity `PoseidonHasher.sol` produces matching output
- **L1 Settlement project** — to validate their Rust `poseidon_bn254` crate in the SP1 program

Any discrepancy in test vector output is a critical cross-project bug that breaks attestation verification.

### Acceptance Criteria

- [ ] `Poseidon(1, 2)` in Go produces `0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a`
- [ ] All 20 test vectors pass in Go
- [ ] `test_vectors.json` created and shared with partner projects for cross-platform validation
- [ ] `Sur/Auth/Keccak256.swift` no longer used in any ZK proof path; only in Ethereum address/content hash context

---

## TASK-3: Implement Apple App Attest

**Owner:** Lena Kovacs
**Reviewer:** Marcus Webb
**Priority:** CRITICAL
**Complexity:** L
**Blocked by:** TASK-4 (Keychain storage must be correct before App Attest key is stored there)
**Spec reference:** `project-scoping/docs/KEY_MANAGEMENT.md §2.2`, `project-scoping/docs/IOS_KEYBOARD.md §3`

### Problem Statement

`Sur/Auth/DeviceIDManager.swift` uses `UIDevice.current.identifierForVendor` passed through `HMAC-SHA256` as the device "key." This provides no cryptographic proof that the key was generated in genuine Apple hardware. A simulator, emulator, or jailbroken device produces an identical-looking result.

The Sur Chain project will verify App Attest objects submitted by this app as part of `MsgAddDevice`. The attestation object must be produced by `DCAppAttestService` — only genuine, unmodified Apple devices on unmodified iOS can produce a valid Apple-signed attestation.

### Files to Modify / Create

| File | Action | Notes |
|---|---|---|
| `Sur/Auth/DeviceIDManager.swift` | **Full replacement** | Remove `UIDevice.identifierForVendor` + HMAC approach |
| `Sur/Auth/AppAttestManager.swift` | **Create** | `DCAppAttestService` lifecycle: `generateKey()`, `attestKey(_:clientDataHash:)`, `generateAssertion(_:clientDataHash:)` |
| `Sur/Auth/AppAttestManager+CBOR.swift` | **Create** | CBOR decoding of Apple attestation object: `authData`, `attStmt`, `x5c` chain extraction |
| `SurTests/AppAttestManagerTests.swift` | **Create** | Mock `DCAppAttestService`; test `invalidKey` recovery flow |

### What the attestation object is used for

The attestation object bytes are included in `MsgAddDevice` (sent to the Sur Chain project) so that the chain can verify:
- The device key was generated in Secure Enclave of a genuine Apple device
- The build was an unmodified, production-signed build of the Sur app
- The specific app bundle ID matches the registered Sur app

The `clientDataHash` passed to `attestKey` must be `SHA256(MsgAddDevice proto bytes)` — binding the attestation to this specific registration.

### Acceptance Criteria

- [ ] Full `DCAppAttestService` lifecycle implemented; works on real device (simulator cannot complete attestation)
- [ ] CBOR attestation object decoded: `authData`, `x5c` chain correctly parsed
- [ ] `DCError.invalidKey` handled: re-attestation flow offered without crash
- [ ] `clientDataHash` = `SHA256(MsgAddDevice bytes)` — attestation is bound to the registration message
- [ ] AAGUID not included in `MsgAddDevice` payload (privacy — reveals device model family)
- [ ] No `UIDevice.identifierForVendor` or `HMAC-SHA256` device key derivation remains

---

## TASK-4: Fix Device Private Key Storage — Keychain Not UserDefaults (P0)

**Owner:** Lena Kovacs
**Reviewer:** Marcus Webb
**Priority:** CRITICAL — P0, fix immediately before any other work
**Complexity:** S
**Blocked by:** Nothing — execute first
**Blocks:** TASK-3 (App Attest uses Keychain correctly only after this is fixed)
**Spec reference:** `project-scoping/docs/KEY_MANAGEMENT.md §2.2`

### Problem Statement

`Sur/Auth/DeviceIDManager.swift` stores the device secp256k1 private key in `UserDefaults(suiteName: "group.com.ordo.sure.Sur")`. A comment on line 146 acknowledges this: `// Note: In production, device private key should be stored in Keychain`. This is a P0 security vulnerability — the key is a plaintext property list entry readable by any process in the App Group.

**Attack (Marcus Webb):**
Any process in `group.com.ordo.sure.Sur` — including the keyboard extension, or any malicious app sharing the group — reads `UserDefaults.data(forKey: devicePrivateKeyKey)` and gets the 32-byte secp256k1 signing key. The attacker can sign arbitrary keystroke sessions as this device indefinitely. The Sur Chain sees valid-looking attestations from the stolen key.

### Required Change

```swift
// REMOVE — current (plaintext UserDefaults):
UserDefaults(suiteName: appGroup)?.set(devicePrivateKey, forKey: devicePrivateKeyKey)

// ADD — correct (Keychain with device-only protection):
SecItemAdd([
    kSecClass: kSecClassGenericPassword,
    kSecAttrAccount: devicePrivateKeyKey,
    kSecAttrAccessGroup: appGroupKeychainGroup,
    kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    kSecValueData: devicePrivateKey
] as CFDictionary, nil)
```

For the final architecture (after TASK-3): generate the key directly in Secure Enclave via `SecKeyCreateRandomKey` with `kSecAttrTokenIDSecureEnclave` — private key material never leaves hardware.

### Acceptance Criteria

- [ ] `UserDefaults` contains no private key material — verify by inspecting what `UserDefaults(suiteName: appGroup)` contains after key generation
- [ ] Private key stored in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- [ ] Key not included in iCloud backup (device-only, non-migratable)
- [ ] Keyboard extension can read the public key reference from Keychain for signing; cannot read private key bytes
- [ ] `grep -r "UserDefaults" Sur/Auth/DeviceIDManager.swift` returns zero lines writing key material

---

## TASK-5: Fix Behavioral Data Privacy — Remove Biometric Stats from Public Inputs

**Owner:** Marcus Webb (specification), Dmitri Vasiliev (circuit), Lena Kovacs (iOS data model)
**Reviewer:** Dr. Amara Diallo
**Priority:** CRITICAL
**Complexity:** M
**Blocked by:** TASK-1 (real gnark circuit needed to move stats to private witnesses)
**Note:** This co-delivers with TASK-1 — the circuit and iOS data model are redesigned together
**Spec reference:** `project-scoping/docs/PROOF_FORMAT.md §1.3`

### Problem Statement

`Sur/Auth/KeystrokeLog.swift` defines `ZKPublicInputs` as:
```swift
struct ZKPublicInputs: Codable {
    let sessionHash: String
    let keystrokeCount: Int        // behavioral stat — should be PRIVATE
    let typingDuration: Double     // behavioral stat — should be PRIVATE
    let userPublicKeyHex: String
    let devicePublicKeyHex: String
    let humanTypingScore: Double   // behavioral stat — should be PRIVATE
}
```

Per `PROOF_FORMAT.md §1.3`, the **only** public inputs are:
```
[username_hash, content_hash_lo, content_hash_hi, nullifier, commitment_root]
```

Behavioral statistics — `humanTypingScore`, `keystrokeCount`, `typingDuration`, IKI values — are **private witnesses** enforced as constraints inside the gnark circuit. The verifier (and anyone observing the on-chain data) learns only that the constraints were satisfied, not the values themselves.

This is the fundamental privacy guarantee of using zero-knowledge proofs. The current struct discards it entirely by publishing these values.

**Note on the L1 contract side:** The current `Contracts/KeystrokeProofVerifier.sol` also exposes these values in its `SNARKProof` struct. Fixing that contract is the responsibility of the **L1 Settlement project** — this task covers the iOS app's data model and the gnark circuit's public/private split.

### Files to Modify

| File | Action | Notes |
|---|---|---|
| `Sur/Auth/KeystrokeLog.swift` | **Modify** `ZKPublicInputs` | Replace all fields with exactly `[usernameHash, contentHashLo, contentHashHi, nullifier, commitmentRoot]` |
| `Sur/Auth/ZKProofGenerator.swift` | **Modify** (after TASK-1) | `humanScore`, `keystrokeCount`, `typingDuration`, IKI array → gnark circuit private witnesses; not sent as public inputs |
| `Sur/Auth/KeystrokeLogManager.swift` | **Modify** | Remove any code that puts behavioral stats in a public-facing struct or network request |

### What to communicate to partner projects

When this task is complete, notify the Sur Chain project and L1 Settlement project:
- The public inputs this app sends are now exactly `[username_hash, content_hash_lo, content_hash_hi, nullifier, commitment_root]`
- Their verifiers must accept exactly 5 public inputs with no behavioral data
- Any integration that reads `humanTypingScore` or `keystrokeCount` from proof calldata is broken by design

### Acceptance Criteria

- [ ] `ZKPublicInputs` struct has exactly 5 fields: `usernameHash`, `contentHashLo`, `contentHashHi`, `nullifier`, `commitmentRoot`
- [ ] gnark circuit enforces behavioral constraints internally: `humanScore >= 50`, IKI range [20ms, 2000ms], coefficient of variation [0.15, 1.0]
- [ ] `grep -r "humanTypingScore\|keystrokeCount\|typingDuration" Sur/Auth/KeystrokeLog.swift` returns no results in public-facing types
- [ ] Marcus confirms: no behavioral stats flow to any network request or public data structure
- [ ] Dr. Amara confirms: circuit constraints match threshold values in `ZK_CIRCUIT.md §5`

---

*All critical tasks reviewed at quarterly protocol review, 2026-03-27.*
*Execution order: TASK-4 immediately (P0, no deps) → TASK-2 → TASK-1 (with TASK-5) → TASK-3.*
*L1 contract architecture and Cosmos chain implementation are tracked in their respective project repositories.*
*See `tasks/TASKS-HIGH.md` for the next tier.*
