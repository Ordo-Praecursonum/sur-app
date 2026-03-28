# Sur Protocol — Critical Tasks

> **These 6 tasks must be complete before any external-facing integration, public documentation, or user-facing launch.**
> None are negotiable — they are gaps between the documented security model and what currently ships.
> See `tasks/REVIEW.md` for the full team discussion that produced these findings.

---

## TASK-1: Replace ZK "Proof" with Real gnark Groth16 over BN254

**Owner:** Dmitri Vasiliev
**Reviewer:** Dr. Amara Diallo, Marcus Webb
**Priority:** CRITICAL
**Complexity:** XL
**Blocked by:** TASK-2 (Poseidon must be ready for the circuit to use it)
**Blocks:** TASK-11 (surcorelibs gets populated)
**Spec reference:** `project-scoping/docs/PROOF_FORMAT.md §1.1`, `project-scoping/docs/ZK_CIRCUIT.md`

### Problem Statement

`Sur/Auth/ZKProofGenerator.swift` is named after a zero-knowledge proof system but implements a Keccak-256 hash chain. It has no zero-knowledge property: a verifier who knows the inputs (or can guess them) can recompute every value — commitment, nullifier, and proof element — without any secret witness. The "proof" is 32 bytes (a Keccak hash), not 256 bytes (two G1 points and one G2 point on BN254 as specified in `PROOF_FORMAT.md §1.1`). There is no pairing computation, no trusted setup, and no R1CS circuit. The entire file must be replaced with a CGo FFI call to a real gnark Groth16 circuit.

The documented architecture calls for:
- A gnark Groth16 circuit (`surcorelibs/gnark/attestation_circuit.go`) that proves in zero-knowledge: device commitment Merkle inclusion, nullifier correctness, Secure Enclave signature validity, behavioral statistics in human range
- A `ProveAttestation(inputJSON string) (proofBytes []byte, err error)` C export callable from Swift
- The Swift layer (`Sur/Auth/ZKProofGenerator.swift`) becomes a thin FFI call wrapper, not a cryptographic implementation

### Files to Modify / Create

| File | Action | Notes |
|---|---|---|
| `Sur/Auth/ZKProofGenerator.swift` | **Full replacement** | Replace entire file with FFI call to `ProveAttestation`; remove all Keccak-based "proof" generation |
| `surcorelibs/gnark/attestation_circuit.go` | **Create** | gnark Groth16 circuit: Merkle inclusion, nullifier (Poseidon), Secure Enclave signature (P-256 emulated), behavioral constraints |
| `surcorelibs/gnark/ffi_bridge.go` | **Create** | `//export ProveAttestation` C function; `ProverInput` JSON schema; `VerifyAttestation` |
| `surcorelibs/gnark/circuit_test.go` | **Create** | Property-based tests with random valid/invalid witnesses; benchmark constraint count and proving time |
| `surcorelibs/Makefile` | **Create** | Builds `libsurcorelibs.a` for `arm64-apple-ios` and `x86_64-apple-ios-simulator` |
| `Sur.xcodeproj/project.pbxproj` | **Modify** | Add XCFramework build phase for `libsurcorelibs.xcframework` |

### Acceptance Criteria

- [ ] `ProveAttestation(inputJSON)` callable from Swift via CGo FFI; input JSON matches `ProverInput` schema documented in `ZK_CIRCUIT.md`
- [ ] Proof output is exactly 256 bytes: `[A_x, A_y, B_x0, B_x1, B_y0, B_y1, C_x, C_y]` (two G1 points, one G2 point, each coordinate 32 bytes)
- [ ] Proof passes `groth16.Verify(vk, proof, publicWitness)` in Go unit test with the same verifying key used for `Setup`
- [ ] Proof fails `groth16.Verify` for any tampered input (invalid behavioral stats, wrong device commitment, mismatched nullifier)
- [ ] `circuit_test.go` passes with property-based tests generating 100 random valid witnesses and 100 random invalid witnesses
- [ ] Constraint count documented in PR description; proving time measured and within 8 seconds on Apple M-series (proxy for iPhone 15 Pro)
- [ ] `ZKProofGenerator.swift` contains no Keccak-based proof construction — only FFI call and result decoding
- [ ] Xcode build succeeds for `arm64-apple-ios` simulator and device targets

### Security Impact (Marcus Webb)

> "Without this task, the system has no zero-knowledge proof. The current Keccak hash chain can be verified by anyone who knows the inputs — there is no witness hidden by the proof. The soundness property — that only a party who knows a valid witness can produce a proof — does not hold. An attacker who can brute-force or guess the behavioral inputs can forge proofs. This is not a theoretical risk; it's a fundamental property that is simply absent."

---

## TASK-2: Replace Keccak-256 with Poseidon (BN254) in Circuit and Cross-Platform

**Owner:** Dmitri Vasiliev
**Reviewer:** Dr. Amara Diallo
**Priority:** CRITICAL
**Complexity:** L
**Blocked by:** None (first task in the chain)
**Blocks:** TASK-1 (circuit uses Poseidon), TASK-5 (L1 contract uses Poseidon), TASK-7 (Cosmos uses Poseidon Merkle)
**Spec reference:** `project-scoping/docs/ZK_CIRCUIT.md §3`, `project-scoping/docs/PROOF_FORMAT.md §5.2`, `project-scoping/docs/PROOF_FORMAT.md §6.1`

### Problem Statement

The entire proof pipeline — commitment, nullifier, Merkle tree — uses Keccak-256. The specification (`ZK_CIRCUIT.md §3`) requires Poseidon over BN254 for all in-circuit hash operations. The reason is fundamental: Keccak-256 requires approximately 27,000 R1CS constraints per hash call inside a BN254 circuit. Poseidon over BN254 requires approximately 220 constraints. The attestation circuit has multiple hash operations; using Keccak-256 would make proving time impractical on a mobile device (multiple minutes per proof). Poseidon is the correct primitive for ZK-friendly hashing over this field.

Cross-platform consistency is critical: `Poseidon(x, y)` must produce identical output in Go (gnark-crypto), Swift (via FFI), Rust (SP1 program), and Solidity (`PoseidonHasher.sol`). The canonical test vector from `PROOF_FORMAT.md §6.1` is `Poseidon(1, 2) = 0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a`.

### Files to Modify / Create

| File | Action | Notes |
|---|---|---|
| `surcorelibs/poseidon/poseidon.go` | **Create** | Go Poseidon implementation using `github.com/consensys/gnark-crypto/ecc/bn254/fr/poseidon`; parameters: rate=2, capacity=1, 8 full rounds, 57 partial rounds, S-box x^5 |
| `surcorelibs/poseidon/poseidon_test.go` | **Create** | Test vector validation: `Poseidon(1, 2)` == `0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a`; 20 canonical input/output pairs |
| `surcorelibs/poseidon/test_vectors.json` | **Create** | 20 canonical test vectors shared across Go, Rust, Solidity implementations |
| `Sur/Auth/Keccak256.swift` | **Retain** (narrow scope) | Keep only for content hash (SHA-256 context) and Ethereum address derivation; remove all ZK proof usage |
| `Contracts/PoseidonHasher.sol` | **Create** | Solidity Poseidon with same round constants as Go; validates against test vectors |

### Acceptance Criteria

- [ ] `surcorelibs/poseidon/poseidon_test.go` passes: `Poseidon(1, 2)` produces `0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a`
- [ ] All 20 test vectors in `test_vectors.json` produce matching output in Go
- [ ] `PoseidonHasher.sol` produces matching output for all 20 test vectors (Foundry test)
- [ ] Rust `poseidon_bn254` crate (used in TASK-8 SP1 program) produces matching output for all 20 test vectors
- [ ] Swift (via FFI after TASK-1) produces matching output for all 20 test vectors
- [ ] Any discrepancy between implementations is treated as a critical bug and blocks the release

### Notes for Reviewer (Dr. Amara Diallo)

> "Verify that the round constants are derived from `github.com/consensys/gnark-crypto/ecc/bn254/fr/poseidon` — not re-derived independently. Any independent re-derivation risks using a different seed or domain separator, producing different constants. The S-box must be `x^5` (not `x^3` as used in some older Poseidon variants). The MDS matrix for width=3 must match the reference. Cross-check: `Poseidon(0)` over BN254 is `ZERO_LEAF` used for Merkle tree padding — this value must be the same in Go and Solidity."

---

## TASK-3: Implement Apple App Attest

**Owner:** Lena Kovacs
**Reviewer:** Marcus Webb
**Priority:** CRITICAL
**Complexity:** L
**Blocked by:** TASK-4 (Keychain storage must be fixed before App Attest key is stored)
**Spec reference:** `project-scoping/docs/KEY_MANAGEMENT.md §2.2`, `project-scoping/docs/IOS_KEYBOARD.md §3`

### Problem Statement

Device registration in `Sur/Auth/DeviceIDManager.swift` uses `UIDevice.identifierForVendor` passed through `HMAC-SHA256` as the device key. This provides no proof that the key was generated in genuine Apple hardware running an unmodified build of the Sur app. A simulator, emulator, or jailbroken device can produce a valid-looking device key under this scheme.

The specification (`KEY_MANAGEMENT.md §2.2`) requires Apple App Attest:
1. `DCAppAttestService.generateKey()` — creates key in Secure Enclave, returns `keyId`
2. `attestKey(_:clientDataHash:)` — Apple signs an attestation object proving the key is in genuine Secure Enclave of an unmodified Apple device
3. The attestation object (CBOR-encoded) is sent to the Cosmos chain as part of `MsgAddDevice`
4. The Cosmos chain verifies the Apple certificate chain (`device → attestation_cert → Apple App Attest CA 1`)

### Files to Modify / Create

| File | Action | Notes |
|---|---|---|
| `Sur/Auth/DeviceIDManager.swift` | **Full replacement** | Remove `UIDevice.identifierForVendor` approach; implement `DCAppAttestService` lifecycle |
| `Sur/Auth/AppAttestManager.swift` | **Create** | `generateAndAttestKey()`, CBOR decoding of attestation object, `DCError.invalidKey` handling for device restore, certificate chain extraction for Cosmos submission |
| `Sur/Auth/AppAttestManager+CBOR.swift` | **Create** | CBOR decoding of Apple attestation object: `authData`, `attStmt`, `x5c` chain, AAGUID extraction |
| `SurTests/AppAttestManagerTests.swift` | **Create** | Unit tests with mock `DCAppAttestService`; test invalidKey recovery flow |

### Acceptance Criteria

- [ ] `DCAppAttestService.generateKey()` → `attestKey(_:clientDataHash:)` lifecycle completes successfully on a real device (simulator cannot complete this flow — App Attest requires genuine hardware)
- [ ] CBOR decoding of the Apple attestation object succeeds: `authData`, `attStmt`, `x5c` correctly parsed
- [ ] `DCError.invalidKey` is handled: app offers re-attestation flow without UX disruption (soft error, not crash)
- [ ] Attestation object bytes are included in `MsgAddDevice` proto message (even if Cosmos chain is not yet deployed — the data structure must be correct)
- [ ] No `UIDevice.identifierForVendor` or `HMAC-SHA256` device key derivation remains in `DeviceIDManager.swift`
- [ ] Unit tests pass with mock `DCAppAttestService`

### Notes for Reviewer (Marcus Webb)

> "Verify: (1) the attestation key is stored in Keychain (after TASK-4), not UserDefaults; (2) the `clientDataHash` passed to `attestKey` is the SHA-256 of the `MsgAddDevice` proto message — this binds the attestation to the specific registration message; (3) the AAGUID is not stored on-chain — it reveals device model family, which is unnecessary metadata; (4) the App Attest CA root is pinned, not fetched at runtime. App Attest attestation is one-time — verify that the app does not attempt re-attestation on every launch, only on first registration or after `DCError.invalidKey`."

---

## TASK-4: Fix Device Private Key Storage — Keychain Not UserDefaults (P0)

**Owner:** Lena Kovacs
**Reviewer:** Marcus Webb
**Priority:** CRITICAL (P0 — fix this week before any other work)
**Complexity:** S
**Blocked by:** None (this is the first fix — independent of all other tasks)
**Blocks:** TASK-3 (App Attest stores its key in Keychain, which this task establishes)
**Spec reference:** `project-scoping/docs/KEY_MANAGEMENT.md §2.2`

### Problem Statement

`Sur/Auth/DeviceIDManager.swift` stores the device secp256k1 private key in `UserDefaults(suiteName: "group.com.ordo.sure.Sur")`. This is a plaintext property list file readable by any process in the App Group — including the keyboard extension and any other app sharing the group. The comment on line 146 acknowledges this: `// Note: In production, device private key should be stored in Keychain`.

This is not a planned debt item — it is a P0 security vulnerability in code that is currently in the repository. Any malicious code with App Group access can read and exfiltrate the private key.

**Attack scenario (Marcus Webb):**
A malicious keyboard extension or app sharing `group.com.ordo.sure.Sur` reads `UserDefaults(suiteName: appGroup).data(forKey: devicePrivateKeyKey)`. It gets the raw 32-byte secp256k1 private key. It can now sign arbitrary keystroke sessions as this device indefinitely, generating valid-looking attestations with any behavioral score.

### Files to Modify

| File | Action | Notes |
|---|---|---|
| `Sur/Auth/DeviceIDManager.swift` | **Modify** | Replace all `UserDefaults` reads/writes of private key with Keychain operations |

### Required Implementation

```swift
// WRONG — current implementation:
deviceKeyStore?.set(devicePrivateKey, forKey: devicePrivateKeyKey)

// CORRECT — required implementation:
// Store in Keychain with Secure Enclave (or at minimum, Keychain with device-only protection)
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrAccount as String: devicePrivateKeyKey,
    kSecAttrAccessGroup as String: appGroupKeychainGroup,
    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    kSecValueData as String: devicePrivateKey
]
SecItemAdd(query as CFDictionary, nil)
```

For maximum security (spec requirement): use `kSecAttrTokenIDSecureEnclave` so the key never leaves hardware. This requires generating the key directly in Secure Enclave via `SecKeyCreateRandomKey` rather than deriving it via HMAC — see TASK-3 for the full App Attest approach.

### Acceptance Criteria

- [ ] `UserDefaults` contains no private key material — verified by inspecting what `UserDefaults(suiteName: appGroup)` contains after key generation
- [ ] Device private key is stored with at minimum `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` in the Keychain
- [ ] Keychain item uses `kSecAttrAccessGroup` for App Group sharing (so keyboard extension can access the public key reference for signing operations)
- [ ] Private key is not accessible after device backup restore (non-migratable)
- [ ] `SurTests/DeviceIDManagerTests.swift` verifies Keychain storage with mock `SecItem` APIs

### Notes for Reviewer (Marcus Webb)

> "This is the highest-priority fix in this entire document. It can be completed independently of all other tasks and should be done first. After the fix: verify with `grep -r 'UserDefaults' Sur/Auth/DeviceIDManager.swift` that no key material writes remain. Also verify that debug logging does not print the private key bytes — even in debug builds, private key material must not be logged."

---

## TASK-5: Replace L1 Contract Architecture to Match Spec

**Owner:** Isabelle Fontaine
**Reviewer:** Marcus Webb, Dmitri Vasiliev
**Priority:** CRITICAL
**Complexity:** XL
**Blocked by:** TASK-2 (needs Poseidon params for PoseidonHasher.sol)
**Blocks:** TASK-8 (batch prover submits to AttestationSettlement.sol)
**Spec reference:** `project-scoping/docs/L1_SETTLEMENT.md`, `project-scoping/docs/PROOF_FORMAT.md §1.2–1.3`

### Problem Statement

The current `Contracts/KeystrokeProofVerifier.sol` implements the wrong architecture on multiple dimensions:

1. **Wrong verification logic**: The contract re-derives the nullifier via `keccak256(...)` and compares it — there is no BN254 pairing check. A real Groth16 verifier performs `Pairing.pairingProd4(A, B, C, vk.IC...)`. Without the pairing check, the contract does not verify a zero-knowledge proof at all.

2. **Wrong contract names**: The spec requires `AttestationSettlement.sol` (for SP1 aggregate proofs) and `AttestationDirect.sol` (for individual gnark Groth16 proofs). `KeystrokeProofVerifier.sol` satisfies neither role.

3. **Wrong public inputs**: The `SNARKProof` struct exposes `keystrokeCount`, `typingDuration`, `humanTypingScore`, `humanTypingScoreBits` — behavioral biometric data that must be private witnesses inside the circuit, not public calldata. The correct public inputs per `PROOF_FORMAT.md §1.3` are: `[username_hash, content_hash_lo, content_hash_hi, nullifier, commitment_root]`.

4. **Missing SP1 integration**: `AttestationSettlement.sol` must call `ISP1Verifier.verifyProof(SP1_PROGRAM_VKEY, publicValues, proofBytes)` for batch epoch proofs. No SP1 integration exists.

### Files to Modify / Create

| File | Action | Notes |
|---|---|---|
| `Contracts/KeystrokeProofVerifier.sol` | **Remove** | Replaced entirely; wrong architecture |
| `Contracts/AttestationVerifier.sol` | **Create** | Auto-generated by `gnark`'s `ExportSolidity()` from the circuit's verifying key; verifies 256-byte Groth16 proof + 5 public inputs |
| `Contracts/AttestationDirect.sol` | **Create** | Individual gnark proof submission; `submitAttestation(SNARKProof calldata proof)`; nullifier set; calls `AttestationVerifier.verifyProof` |
| `Contracts/AttestationSettlement.sol` | **Create** | Epoch batch settlement; `submitCheckpoint(epochId, proof, publicValues)`; calls `ISP1Verifier.verifyProof`; stores epoch state roots; permissionless |
| `Contracts/PoseidonHasher.sol` | **Create** | Deployed Poseidon with same round constants as Go; used for Merkle leaf reconstruction in `verifyAttestation` |
| `Contracts/test/AttestationDirectTest.t.sol` | **Create** | Foundry tests: submit valid gnark proof, assert nullifier stored; submit duplicate nullifier, assert revert; submit tampered proof, assert revert |
| `Contracts/test/AttestationSettlementTest.t.sol` | **Create** | Foundry tests: submit valid SP1 proof for epoch 1, assert state root stored; submit epoch 3 before epoch 2, assert sequential enforcement revert |
| `Contracts/script/Deploy.s.sol` | **Create** | Foundry deployment script; `CREATE2` for deterministic addresses across networks |

### SNARKProof Struct — Correct Definition

```solidity
// Per PROOF_FORMAT.md §1.2
struct Groth16Proof {
    uint256[2] a;       // G1 point A (64 bytes)
    uint256[2][2] b;    // G2 point B (128 bytes)
    uint256[2] c;       // G1 point C (64 bytes)
    // Total: 256 bytes
}

// Per PROOF_FORMAT.md §1.3 — NO behavioral data
uint256[5] publicInputs; // [username_hash, content_hash_lo, content_hash_hi, nullifier, commitment_root]
```

### Acceptance Criteria

- [ ] `AttestationDirect.sol` calls `AttestationVerifier.verifyProof(a, b, c, inputs)` — a real Groth16 pairing check (not keccak re-derivation)
- [ ] No behavioral statistics (`humanTypingScore`, `keystrokeCount`, `typingDuration`) appear in any Solidity function signature, event, or storage variable
- [ ] `AttestationSettlement.sol` calls `ISP1Verifier.verifyProof(SP1_PROGRAM_VKEY, publicValues, proofBytes)`
- [ ] `forge coverage` shows 100% branch coverage on all contracts
- [ ] `PoseidonHasher.sol` passes test vectors from `surcorelibs/poseidon/test_vectors.json`
- [ ] Sequential epoch enforcement: submitting epoch N+2 before N+1 reverts with `EpochNotSequential`
- [ ] Nullifier replay protection: submitting same nullifier twice reverts with `NullifierAlreadyUsed`
- [ ] No `tx.origin`, no `block.timestamp` for security-critical logic, no `delegatecall`, no `selfdestruct`

---

## TASK-6: Fix Behavioral Data Privacy Leak — Remove Behavioral Stats from Public Inputs

**Owner:** Marcus Webb (specification and audit), Dmitri Vasiliev (circuit fix), Isabelle Fontaine (contract fix)
**Reviewer:** Dr. Amara Diallo
**Priority:** CRITICAL
**Complexity:** L
**Blocked by:** TASK-1 (circuit must be real gnark before this can be fixed at the circuit level)
**Note:** This task co-delivers with TASK-1 and TASK-5 — the circuit design and contract public inputs are fixed together
**Spec reference:** `project-scoping/docs/PROOF_FORMAT.md §1.3`, `project-scoping/docs/ZK_CIRCUIT.md §5`

### Problem Statement

`Sur/Auth/KeystrokeLog.swift` defines `ZKPublicInputs` as:
```swift
struct ZKPublicInputs: Codable {
    let sessionHash: String
    let keystrokeCount: Int
    let typingDuration: Double
    let userPublicKeyHex: String
    let devicePublicKeyHex: String
    let humanTypingScore: Double
}
```

And `Contracts/KeystrokeProofVerifier.sol` accepts `humanTypingScore`, `keystrokeCount`, `typingDuration`, and `humanTypingScoreBits` as public calldata, emitting them in `ProofVerified` events.

Per `PROOF_FORMAT.md §1.3`, the public inputs are **exactly**:
```
[username_hash, content_hash_lo, content_hash_hi, nullifier, commitment_root]
```

No behavioral statistics appear. The behavioral constraints (WPM range, IKI range, coefficient of variation minimum, pause pattern) are **private witnesses** — they are enforced inside the ZK circuit as constraints that must be satisfied, but the verifier learns only that they were satisfied, not the values. This is the zero-knowledge property.

### Privacy Impact (Dr. Amara Diallo)

> "Every `ProofVerified` event on-chain currently contains `humanTypingScore`, `keystrokeCount`, and `typingDuration`. Any blockchain indexer can build a per-user biometric profile from this data. Over N attestations, a user's average typing speed, duration patterns, and score distribution become publicly queryable. This is precisely what zero-knowledge proofs are designed to prevent. We have implemented ZK proofs while discarding their primary privacy guarantee."

### Files to Modify

| File | Action | Notes |
|---|---|---|
| `Sur/Auth/KeystrokeLog.swift` | **Modify** `ZKPublicInputs` | Replace with `[username_hash, content_hash_lo, content_hash_hi, nullifier, commitment_root]` — remove all behavioral fields |
| `Sur/Auth/ZKProofGenerator.swift` | **Modify** (after TASK-1) | gnark circuit private witnesses: `humanScore`, `keystrokeCount`, `typingDuration`, IKI array — all private; circuit enforces constraints internally |
| `Contracts/AttestationDirect.sol` | **Design** (after TASK-5) | Public inputs must be `uint256[5]` with no behavioral data; `ProofVerified` event emits only `nullifier` and `commitment_root` |

### Acceptance Criteria

- [ ] `ZKPublicInputs` struct contains exactly `[usernameHash, contentHashLo, contentHashHi, nullifier, commitmentRoot]` — no `humanTypingScore`, `keystrokeCount`, `typingDuration`, `userPublicKeyHex`, `devicePublicKeyHex`
- [ ] The gnark circuit enforces behavioral constraints as private witnesses: `humanScore >= 50`, IKI range check, timing variation check — all inside the circuit
- [ ] `ProofVerified` event in Solidity emits only: `address indexed submitter`, `bytes32 indexed nullifier`, `bytes32 commitment_root`, `uint256 timestamp`
- [ ] No behavioral statistics appear in any Solidity function signature, event, storage variable, or calldata
- [ ] `grep -r 'humanTypingScore\|keystrokeCount\|typingDuration' Contracts/` returns no matches in public-facing code
- [ ] Marcus confirms in review: passive observer indexing on-chain data cannot reconstruct behavioral statistics

### Notes for Reviewer (Dr. Amara Diallo)

> "Verify: the circuit constraint `humanScore >= MIN_HUMAN_SCORE` uses the correct threshold (50) from `ZK_CIRCUIT.md`. Verify: the IKI constraints are checked per-keystroke as individual constraints, not aggregated — the circuit should fail for any session where any inter-key interval is outside the 20ms–2000ms range, not just where the mean is outside. Verify: the Poseidon nullifier derivation inside the circuit uses `Poseidon(device_pubkey_x, device_pubkey_y, session_counter)` — not `Poseidon(sessionHash)`, which would create a different unlinkability guarantee."

---

*All critical tasks reviewed and assigned at quarterly protocol review, 2026-03-27.*
*Execution must follow Stream A (TASK-2 → TASK-1) before Stream C (TASK-5) and Stream D (TASK-7).*
*TASK-4 executes immediately — it is independent of all other tasks and is the highest-priority item.*
*See `tasks/TASKS-HIGH.md` for the next tier of tasks.*
