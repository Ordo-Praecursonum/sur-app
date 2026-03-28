# Sur Protocol — Quarterly Protocol Compliance Review

**Date:** 2026-03-27
**Facilitated by:** Sofia Esposito (Protocol Designer & Technical Product Lead)
**Participants:** Dmitri Vasiliev (ZK), Lena Kovacs (iOS), Marcus Webb (Security), Dr. Amara Diallo (Math), Isabelle Fontaine (Smart Contracts), Arjun Nair (Cosmos), Yuki Tanaka (Rust/SP1), Kai Oduya (Full-Stack), Priya Sundaram (DevOps)
**Reference documents:** `project-scoping/docs/PROOF_FORMAT.md`, `project-scoping/docs/ZK_CIRCUIT.md`, `project-scoping/docs/KEY_MANAGEMENT.md`, `project-scoping/docs/IOS_KEYBOARD.md`, `project-scoping/docs/L1_SETTLEMENT.md`, `project-scoping/docs/COSMOS_MODULE.md`, `project-scoping/docs/ARCHITECTURE.md`

---

## 0. Project Scope Clarification (Post-Review Decision)

> **This section was added after the review session to reflect a project boundary decision made by the team.**

Following this review, the team decided to split the Sur Protocol implementation across multiple repositories:

| Repository | Scope |
|---|---|
| **This repo (Sur iOS)** | iOS wallet app, keyboard extension, ZK proof generation (surcorelibs FFI), key management, Cosmos/L1 API clients |
| **Sur Chain project** | Cosmos SDK chain: x/identity, x/attestation, x/payment modules; surd binary; validator infrastructure |
| **L1 Settlement project** | Solidity contracts (AttestationSettlement, AttestationDirect); SP1 batch prover; Foundry tests |
| **Developer SDK project** | TypeScript SDK, verification web app, CLI tool (future) |

**Impact on task assignments from this review:**

Findings 3.1 (Cosmos chain), 3.2 (SP1 batch prover), 2.5 (L1 contracts), and 4.4 (StarkNet) are **deferred to their respective separate projects**. They remain valid findings — the gaps are real — but this iOS project does not implement them. Instead:

- The iOS app **calls** the Sur Chain project via gRPC/REST (TASK-8)
- The iOS app **reads** L1 contracts via `eth_call` (TASK-9)
- The proof format this app produces must match what those projects accept — documented in `docs/INTEGRATION.md` (TASK-12)

See `PROJECT_SCOPE.md` for the full boundary definition and `docs/INTEGRATION.md` for the API contract.

**Updated task list:** `tasks/TASKS-CRITICAL.md` (5 tasks), `tasks/TASKS-HIGH.md` (4 tasks), `tasks/TASKS-MEDIUM.md` (3 tasks).

---

## 1. Purpose — Sofia's Framing

> "I schedule these sessions because the spec is the system. If the code diverges from what we documented, one of two things happened: either the code is wrong, or the spec is wrong. Either way, something is wrong — and we need to know which.
>
> Today I'm going to walk through every major component and ask each of you: does what we documented match what was built? I want specific file names and line numbers where things diverge. Our documentation says we provide a 'cryptographic proof.' Our verification page is going to say 'a cryptographic proof verified that a real device, registered to this account, typed this exact text.' If we can't actually back that up with real ZK cryptography, we are misleading every user of this product. That's not acceptable.
>
> We have fifteen findings to work through. Let's start with the most severe."

---

## 2. Critical Findings

### 2.1 [Dmitri] ZK Proof System — Wrong Primitive

**Severity:** CRITICAL
**Owner:** Dmitri Vasiliev
**Reviewer:** Dr. Amara Diallo, Marcus Webb

**Spec says** (`PROOF_FORMAT.md §1.1`):
> "The Sur Protocol proof is a gnark Groth16 proof over BN254. The proof is 256 bytes: two G1 points (A, C) and one G2 point (B). Public inputs are 5 BN254 field elements (160 bytes)."

**Implemented** (`Sur/Auth/ZKProofGenerator.swift`, lines 1–240):
```swift
// Non-Interactive SNARK-style Proof Generation
// Protocol version: 2.0.0 (Non-interactive, Fiat-Shamir based)
// Commitment: C = Keccak-256(domain || merkleRoot || R || sessionHash)
// Nullifier: Keccak-256(domain || C || sessionHash || ...)
// Proof π: Keccak-256(R || S || nullifier || merkleRoot || motionDigests)
```

**Dmitri:**
> "This has no zero-knowledge property. A Keccak hash chain is not a SNARK. It's not even a commitment scheme with a formal hiding property. A verifier who knows the inputs can recompute every value. The zero-knowledge guarantee — that the proof reveals nothing beyond what it asserts — is completely absent. We named a hash chain a 'proof' and are shipping it as a ZK system. It is not.
>
> The 256-byte proof structure specified in `PROOF_FORMAT.md` contains BN254 elliptic curve points — group elements from an elliptic curve pairing. What's in `ZKProofGenerator.swift` is a 32-byte Keccak output. These are not the same thing by any stretch of definition. We need to replace the entire `ZKProofGenerator.swift` with a CGo FFI call to a real gnark circuit. `surcorelibs/` is the right place for this."

**Impact:** The system's core claim — "a cryptographic proof" — is false. The current scheme is a hash commitment; it has no soundness property beyond collision resistance of Keccak-256. An attacker who can collide or forge inputs breaks the entire scheme.

**Task:** TASK-1

---

### 2.2 [Dmitri + Dr. Amara] Hash Function Mismatch — Keccak-256 vs. Poseidon

**Severity:** CRITICAL
**Owner:** Dmitri Vasiliev (implementation), Dr. Amara Diallo (formal analysis)
**Reviewer:** Dr. Amara Diallo

**Spec says** (`ZK_CIRCUIT.md §3`, `PROOF_FORMAT.md §5.2`):
> "All in-circuit hash operations use Poseidon over BN254 (rate=2, capacity=1, 8 full rounds, 57 partial rounds). Keccak-256 is not used inside the circuit. Poseidon is chosen because it has ~200 constraints per hash inside a BN254 R1CS circuit, vs. >25,000 constraints for Keccak-256."

**Implemented** (`Sur/Auth/Keccak256.swift`, `Sur/Auth/ZKProofGenerator.swift`):
```swift
// All proof elements, commitment, nullifier, Merkle tree use Keccak-256
static func keccak256(_ data: Data) -> Data {
    return Data(data.bytes.sha3(.keccak256))
}
```

**Dr. Amara:**
> "Let me be precise about what this means formally. The commitment scheme `C = Keccak-256(domain || merkleRoot || R || sessionHash)` uses Keccak-256 as its hash function. What hiding property does this construction satisfy? Collision resistance only — and specifically only if `R` is uniformly random and unknown to the verifier. That's a minimal property.
>
> But my concern goes deeper. The entire reason we use Poseidon is so that the hash computation can happen **inside the ZK circuit**. If we use Keccak-256 in a real gnark Groth16 circuit — which we must eventually do — we would need approximately 27,000 R1CS constraints per Keccak call. Our attestation circuit has multiple hash calls. At 27,000 constraints each, proving time becomes measured in minutes per proof on a mobile device. Poseidon gives us ~200 constraints per call. This isn't an optimization; it's the difference between a proof system that works on a phone and one that doesn't.
>
> For the test vector in `PROOF_FORMAT.md §6.1`: `Poseidon(1, 2)` over BN254 should produce `0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a`. Until we can reproduce this value in Swift (via FFI), Go, Rust, and Solidity with matching output, cross-platform consistency cannot be claimed."

**Dmitri:**
> "The Poseidon implementation must live in `surcorelibs/poseidon/` as a Go package. Swift calls it via the FFI bridge. The Rust SP1 program uses `poseidon_bn254`. Isabelle's `PoseidonHasher.sol` contract uses the same round constants. All four must match the test vector. This is TASK-2 and it unblocks everything else."

**Task:** TASK-2

---

### 2.3 [Lena] App Attest Missing — Device Identity Unverified

**Severity:** CRITICAL
**Owner:** Lena Kovacs
**Reviewer:** Marcus Webb

**Spec says** (`KEY_MANAGEMENT.md §2`, `IOS_KEYBOARD.md §3`):
> "Device registration begins with Apple App Attest. The app calls `DCAppAttestService.generateKey()` to create an attestation key in the Secure Enclave, then `attestKey(_:clientDataHash:)` to obtain an Apple-signed attestation object. This object proves the key was generated in the Secure Enclave of a genuine, unmodified Apple device running an unmodified build of the Sur app. The attestation object is sent to the Cosmos chain as part of `MsgAddDevice`."

**Implemented** (`Sur/Auth/DeviceIDManager.swift`, lines 60–100):
```swift
// Device UUID from UIDevice.identifierForVendor
let deviceUUID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
// Device seed from HMAC-SHA256
let deviceSeed = HMAC<SHA256>.authenticationCode(for: deviceUUIDData, using: symmetricKey)
let devicePrivateKey = Data(deviceSeed)
```

**Lena:**
> "What's in `DeviceIDManager.swift` is not App Attest. It's a device UUID passed through HMAC-SHA256. `UIDevice.identifierForVendor` is a vendor-assigned identifier — it changes on restore, changes when the app is uninstalled, and provides no proof of device genuineness. A simulator has a `identifierForVendor`. A jailbroken device has one. An emulator has one. None of these can produce an App Attest object because `DCAppAttestService` will fail on non-genuine devices.
>
> The current scheme means any process that can run Swift code can generate a 'device key' that looks exactly like a legitimate one. There is no cryptographic proof that the key was generated in genuine Apple hardware. That's the entire point of App Attest, and it's completely absent."

**Marcus:**
> "To be explicit about the attack: without App Attest, an attacker can run the Sur app in a simulator, generate a valid-looking device key via HMAC-SHA256, sign keystroke sessions with it, and submit attestations as if from a real device. The Sur Chain has no way to distinguish simulator-generated attestations from genuine device attestations. The behavioral score check is the only remaining gate — and as we'll discuss in §2.6, that data is public."

**Task:** TASK-3

---

### 2.4 [Lena + Marcus] Device Private Key in UserDefaults — P0 Security Bug

**Severity:** CRITICAL (P0)
**Owner:** Lena Kovacs
**Reviewer:** Marcus Webb

**Spec says** (`KEY_MANAGEMENT.md §2.2`):
> "The Attestation Key is stored in the iOS Keychain with `kSecAttrTokenIDSecureEnclave`. The private key material never leaves Secure Enclave hardware. Signing operations are performed by the Secure Enclave co-processor."

**Implemented** (`Sur/Auth/DeviceIDManager.swift`, line 146 and surrounding code):
```swift
// Store device key in shared UserDefaults
let deviceKeyStore = UserDefaults(suiteName: appGroup)
deviceKeyStore?.set(devicePrivateKey, forKey: devicePrivateKeyKey)
// Note: In production, device private key should be stored in Keychain
```

**Lena:**
> "That comment on line 146 is acknowledgment that we knew this was wrong and didn't fix it. `UserDefaults(suiteName: 'group.com.ordo.sure.Sur')` is a plist file on disk shared across all processes in the App Group. The keyboard extension reads it. Any library with App Group access reads it. The private key is sitting in a property list. This is not a theoretical risk — it's a plaintext private key in a file that is readable by any code running in the app's sandbox. On a device with a compromised app or a malicious keyboard extension in the same app group, this key is trivially exfiltrated.
>
> This needs to move to the Keychain immediately, regardless of everything else we're discussing today. It does not require the gnark circuit to fix. It requires two Keychain API calls."

**Marcus (P0 classification):**
> "This is a P0. Let me describe the attack precisely:
> 1. Attacker installs a malicious app that shares `group.com.ordo.sure.Sur` (e.g., a malicious keyboard extension)
> 2. Malicious extension reads `UserDefaults(suiteName: 'group.com.ordo.sure.Sur')` — the device secp256k1 private key is there
> 3. Attacker extracts the 32-byte private key
> 4. Attacker can now sign arbitrary keystroke sessions as this device indefinitely
> 5. Any attestations signed with the stolen key are indistinguishable from legitimate attestations
>
> This is not an edge case. Any malicious app with App Group access exploits this. Fix: `SecKeyCreateRandomKey` with `kSecAttrTokenIDSecureEnclave`, store key reference in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and `kSecAttrAccessGroup` for App Group sharing."

**Task:** TASK-4

---

### 2.5 [Isabelle] L1 Contract Architecture Mismatch

**Severity:** CRITICAL
**Owner:** ~~Isabelle Fontaine~~ → **L1 Settlement project (separate repository)**
**Status:** DEFERRED — contract building is not in scope for this iOS project

**Finding:** `Contracts/KeystrokeProofVerifier.sol` (embedded in `Sur/Auth/ZKProofGenerator.swift`) uses the wrong architecture. The spec requires `AttestationSettlement.sol` + `AttestationDirect.sol` with real Groth16 pairing checks. The existing contract uses Keccak-256 re-derivation and exposes behavioral statistics as public calldata.

**Implemented** (`Contracts/KeystrokeProofVerifier.sol`):
```solidity
// Protocol version: 2.0.0 (SNARK-style Non-Interactive)
struct SNARKProof {
    bytes32 commitment;
    bytes32 nullifier;
    bytes32 proof;
    bytes32 sessionHash;
    uint256 keystrokeCount;    // ← should be private witness
    uint256 typingDuration;    // ← should be private witness
    bytes userPublicKey;
    bytes devicePublicKey;
    uint256 humanTypingScore;  // ← should be private witness
    bytes8  humanTypingScoreBits;
    uint256 generatedAt;
}
```

**Isabelle:**
> "The `Contracts/` directory in this iOS project should not exist at all for the L1 settlement contracts — those belong to the L1 Settlement project. What remains relevant to this iOS app: it needs to know the deployed contract addresses to make `eth_call` reads (TASK-9), and it needs to produce proofs in the exact format those contracts expect — documented in `docs/INTEGRATION.md` (TASK-12). The privacy leak in the current `SNARKProof` struct informs TASK-5 (fix behavioral data privacy in the iOS data model)."

**Resolution:** Correct L1 contract architecture is built in the L1 Settlement project. This iOS project:
- **TASK-5** (this repo): Removes behavioral data from `ZKPublicInputs` in `KeystrokeLog.swift` — the iOS data model fix
- **TASK-9** (this repo): Reads the correctly-deployed L1 contracts via read-only `eth_call`
- **TASK-12** (this repo): Documents the proof format interface contract both projects must agree on

**Task for this repo:** TASK-5 (iOS data model), TASK-9 (L1 read client), TASK-12 (integration docs)

---

### 2.6 [Marcus + Dr. Amara] Behavioral Data Privacy Leak — Public Inputs Expose Biometric Data

**Severity:** CRITICAL
**Owner:** Marcus Webb (spec and audit), Dmitri Vasiliev (circuit fix), Isabelle Fontaine (contract fix)
**Reviewer:** Dr. Amara Diallo

**Spec says** (`PROOF_FORMAT.md §1.3`):
> "Public inputs (5 BN254 field elements): `username_hash`, `content_hash_lo`, `content_hash_hi`, `nullifier`, `commitment_root`. No behavioral statistics appear as public inputs. Behavioral constraints (WPM range, IKI range, stddev minimum) are enforced as private witnesses inside the circuit."

**Implemented** (`Sur/Auth/KeystrokeLog.swift`, `ZKPublicInputs` struct):
```swift
struct ZKPublicInputs: Codable {
    let sessionHash: String
    let keystrokeCount: Int
    let typingDuration: Double      // milliseconds
    let userPublicKeyHex: String
    let devicePublicKeyHex: String
    let humanTypingScore: Double    // 0–100
}
```

And in the Solidity contract calldata: `humanTypingScore`, `keystrokeCount`, `typingDuration`, `humanTypingScoreBits` all appear as explicit fields.

**Marcus:**
> "This defeats the purpose of using ZK proofs. The zero-knowledge property exists precisely to hide these behavioral statistics. Instead, we're publishing them on-chain in every attestation.
>
> The privacy impact: a passive observer indexing all `ProofVerified` events from the Solidity contract gets `humanTypingScore`, `keystrokeCount`, and `typingDuration` for every submission by every user. Over time, this builds a biometric profile. Users who consistently type slower (lower WPM, longer duration, lower score) can be identified as such. Users with distinctive typing profiles can be fingerprinted across attestations even without knowing their identity.
>
> This also gives attackers the exact target values. If a bot trying to spoof attestations sees that a legitimate user scores 72.4 on humanTypingScore with a typingDuration of 18.3 seconds for 45 keystrokes, it can calibrate its spoofing tool accordingly."

**Dr. Amara:**
> "To state it precisely: the current `ZKPublicInputs` struct has no zero-knowledge property for behavioral data. A verifier learns `humanTypingScore`, `keystrokeCount`, and `typingDuration` directly. These should be private witnesses in the gnark circuit — constraints that the circuit checks internally, with the verifier learning only that the constraints were satisfied, not the values. The correct public inputs set, per `PROOF_FORMAT.md §1.3`, contains no behavioral statistics whatsoever."

**Task:** TASK-6

---

## 3. High-Priority Findings

### 3.1 [Arjun] Cosmos Chain Not Implemented

**Severity:** HIGH
**Owner:** ~~Arjun Nair~~ → **Sur Chain project (separate repository)**
**Status:** DEFERRED — not in scope for this iOS project

**Finding:** No Cosmos chain modules (x/identity, x/attestation, x/payment) exist in this repository.

**Resolution:** The Sur Chain project is a separate repository responsible for the full Cosmos SDK chain. This iOS app is a **client** of that chain. Instead of building the chain here, this project implements:
- **TASK-8**: Cosmos chain API client — Swift gRPC/REST client calling the chain's endpoints
- **TASK-12**: Integration documentation — API contract defining what this app sends to the chain

**Task for this repo:** TASK-8 (Cosmos API client), TASK-12 (integration docs)

---

### 3.2 [Yuki] SP1 Batch Prover Missing

**Severity:** HIGH
**Owner:** ~~Yuki Tanaka~~ → **Sur Chain project (separate repository)**
**Status:** DEFERRED — not in scope for this iOS project

**Finding:** No SP1 batch prover exists. This is expected — it is backend infrastructure, not part of the mobile wallet.

**Resolution:** The SP1 batch prover is implemented in the Sur Chain project. This iOS app only needs to produce gnark Groth16 proofs in the correct format (TASK-1) that the prover will later batch. The proof format interface is documented in TASK-12.

**Task for this repo:** TASK-1 (proof format), TASK-12 (interface contract)

---

### 3.3 [Lena] Keyboard Extension Signing Gap

**Severity:** HIGH
**Owner:** Lena Kovacs
**Reviewer:** Marcus Webb

**Spec says** (`IOS_KEYBOARD.md §4`):
> "The keyboard extension signs the session bundle directly using `SecKeyCreateSignature` with the Secure Enclave attestation key. The signed bundle is written to the App Group container. The main app reads the signed bundle and uses the signature as a ZK circuit private witness."

**Implemented** (`SurKeyboard/KeystrokeLogger.swift`):
```swift
// SHA-256 fallback for keyboard extension (CryptoSwift not available in extension)
// Note: Main app will re-hash with Keccak-256 for on-chain compatibility
let sessionData = session.sessionId + ...
let hashData = SHA256.hash(data: Data(sessionData.utf8))
```

**Lena:**
> "The keyboard extension is computing SHA-256 over session data and writing the hash. Then the main app reads it and re-hashes with Keccak-256. This means the signature chain is broken: the keyboard extension never signs anything with a private key. The hash the main app uses as a 'motion digest' is not authenticated by the keyboard extension at all — it's just a re-computation of publicly known data.
>
> The spec requires `SecKeyCreateSignature` with the Secure Enclave key. This creates a signature that cryptographically binds the session bundle to the specific device key. Without this, there's no proof the session bundle came from the keyboard extension of this device — the main app could fabricate it entirely."

**Task:** TASK-9

---

### 3.4 [Kai] TypeScript SDK Missing

**Severity:** HIGH
**Owner:** ~~Kai Oduya~~ → **Developer SDK project (separate repository)**
**Status:** DEFERRED — TypeScript SDK and verification web app are not in scope for this iOS project

**Finding:** No `@surprotocol/sdk` npm package, no verification web app, no `AttestationBadge` React component, no `sur-verify` CLI.

**Kai:**
> "The developer ecosystem doesn't exist. Any third-party app wanting to verify Sur Protocol attestations has to speak directly to Cosmos chain gRPC, implement their own content hashing, parse their own response format, and handle their own errors. That's not a protocol — that's a research project. The SDK is how the protocol becomes usable."

**Sofia:**
> "And the verification web app is how end users verify content. Every attestation we issue is supposed to generate a link like `https://verify.surprotocol.com/alice/9a3f1b2c`. That link goes nowhere right now. This is real and important — it belongs in the Developer SDK project. The iOS project's contribution is to produce attestations with the correct format that the SDK can verify. That format contract is TASK-12."

**Resolution:** TypeScript SDK, verification web app, and CLI are implemented in the Developer SDK project (future). This iOS project contributes via TASK-12 (`docs/INTEGRATION.md`), which defines the attestation format the SDK must parse.

**Task for this repo:** TASK-12 (integration docs — defines the format the Developer SDK will verify)

---

### 3.5 [Dmitri] surcorelibs Empty

**Severity:** HIGH
**Owner:** Dmitri Vasiliev (gnark FFI), Yuki Tanaka (Poseidon Rust)
**Reviewer:** Lena Kovacs (Swift FFI consumer)

**Spec says** (`ARCHITECTURE.md §3.1`):
> "`surcorelibs/` contains the Go gnark attestation circuit, the CGo FFI bridge (`ProveAttestation` C export), and Poseidon implementations for cross-platform consistency."

**Implemented:** `surcorelibs/target/` exists but is empty.

**Dmitri:**
> "This is the physical location for everything in TASK-1 and TASK-2. The Go gnark circuit, the FFI bridge, the Poseidon Go package — all of this lives in `surcorelibs/`. The fact that it's empty confirms that TASK-1 (real gnark Groth16) and TASK-2 (Poseidon) have never been started. The Makefile that builds `libsurcorelibs.a` for `arm64-apple-ios` also needs to exist here."

**Task:** TASK-11

---

## 4. Medium-Priority Findings

### 4.1 [Priya] No CI/CD Pipeline

**Severity:** MEDIUM
**Owner:** Priya Sundaram
**Reviewer:** Sofia Esposito

No `.github/workflows/` directory exists. No automated build, test, or deployment pipeline. Any code change goes straight from local development to main branch without automated validation.

**Priya:** "We have no automated proof that the gnark circuit tests pass, the Swift build succeeds, or the surcorelibs XCFramework builds correctly for arm64-apple-ios. Once we have real code in the gnark layer and the Swift FFI layer, a single engineer can break the other layer's build with no automated warning. We need `xcodebuild test`, `go test ./...` in surcorelibs, and Xcode Archive in CI before this is production-ready."

**Task:** TASK-10

---

### 4.2 [Dr. Amara] Behavioral Threshold Justification Missing

**Severity:** MEDIUM
**Owner:** Dr. Amara Diallo
**Reviewer:** Marcus Webb

The thresholds in `HumanTypingEvaluator.swift` (timing 35%, variation 25%, coordinates 20%, patterns 20%; IKI range 20ms–2000ms; CoV 0.15–1.0) are hardcoded without published justification. No document in `project-scoping/docs/` cites the academic literature that supports these specific values.

**Dr. Amara:** "The IKI range 20ms–2000ms needs a citation. My corpus study of 50,000 users found 98th-percentile lower bound at 18ms and 99.5th-percentile upper at 1,800ms — so 20ms–2000ms is approximately correct, but 'approximately correct' is not a security argument. The ZK_CIRCUIT.md needs a section that cites our published threshold derivation and explains why these values minimize spoofing risk while maintaining a false negative rate below 2% for legitimate human typists."

**Task:** TASK-11

---

### 4.3 [Marcus] 24-Hour Proof Window — Miner Timestamp Manipulation

**Severity:** MEDIUM
**Owner:** ~~Marcus Webb (spec), Arjun Nair (implementation)~~ → **Sur Chain project + L1 Settlement project**
**Status:** DEFERRED — freshness enforcement is in the Cosmos module and L1 contracts, not this iOS project

The `KeystrokeProofVerifier.sol` freshness check uses `block.timestamp`, which can be manipulated by miners/validators within ~15 seconds. The Cosmos module should use block height for freshness — not EVM timestamp.

**Marcus:** "This is a known issue with timestamp-based freshness on EVM. The Cosmos module should use block height for freshness checks — block height is not manipulable by individual validators. `proof_block_height` within N blocks of submission is the correct approach. Per `L1_SETTLEMENT.md`, the Cosmos chain is the source of truth for freshness; the L1 contract should trust the Cosmos-anchored epoch timestamp rather than `block.timestamp`. This is tracked in the Sur Chain project and L1 Settlement project, not here."

**Resolution:** The iOS app embeds a proof timestamp for display purposes only. Freshness enforcement is the chain's responsibility. No task for this repo.

**No task for this repo.**

---

### 4.4 [Rania] StarkNet Integration — Phase 4 Preparation

**Severity:** MEDIUM (Phase 4 — expected to be absent)
**Owner:** ~~Rania Aziz~~ → **Future StarkNet settlement project (separate repository)**
**Status:** DEFERRED — Phase 4 settlement expansion is not in scope for this iOS project

**Finding:** No Cairo contracts (`SurSettlement.cairo`, `SurDirect.cairo`) or StarkNet integration exist.

**Sofia:** "We documented StarkNet integration as Phase 4. This is expected to be absent. More importantly: StarkNet settlement contracts belong in a dedicated settlement project alongside L1 contracts, not in the iOS wallet. If we add StarkNet reading capability to the iOS app — equivalent to TASK-9 but for Starknet — that would be appropriate here. For now, this is fully deferred. No stubs needed in this repo; the scope boundary is clear."

**Resolution:** StarkNet contract implementation deferred to a future settlement project. The iOS app's role (if any) would be a read-only StarkNet client equivalent to TASK-9 for L1 — added when Phase 4 begins.

**No task for this repo at this time.**

---

## 5. Marcus's Consolidated Security Assessment

### P0 Findings (Immediate — Block Any External Facing Launch)

| ID | Finding | File | Attack |
|---|---|---|---|
| **P0-1** | Device private key in UserDefaults | `Sur/Auth/DeviceIDManager.swift:146` | App Group compromise yields secp256k1 private key in plaintext; attacker signs arbitrary sessions |
| **P0-2** | No ZK property in "proof" | `Sur/Auth/ZKProofGenerator.swift` | Current scheme has no soundness beyond Keccak collision resistance; no formal hiding property |
| **P0-3** | Behavioral biometric data on-chain | `Sur/Auth/KeystrokeLog.swift`, `Contracts/KeystrokeProofVerifier.sol` | Passive observer builds biometric profile from public `ProofVerified` events; attackers calibrate spoofing tools |

### P1 Findings (High — Required Before Mainnet)

| ID | Finding | File | Risk | Owner |
|---|---|---|---|---|
| **P1-1** | No Apple App Attest | `Sur/Auth/DeviceIDManager.swift` | Simulators and emulators can register as legitimate devices | This repo — TASK-3 |
| **P1-2** | Keyboard extension doesn't sign | `SurKeyboard/KeystrokeLogger.swift` | Session bundles not authenticated by the extension; main app could fabricate them | This repo — TASK-6 |
| **P1-3** | Wrong L1 contract architecture | `Contracts/KeystrokeProofVerifier.sol` | No Groth16 pairing check; incorrect public inputs | L1 Settlement project (deferred) |
| **P1-4** | Cosmos chain absent | — | No username registry, no device commitment tree, no nullifier set | Sur Chain project (deferred); this repo calls it via TASK-8 |

### P2 Findings (Medium — Required Before Public Beta)

| ID | Finding | Risk |
|---|---|---|
| **P2-1** | No CI/CD | Silent regressions across all layers |
| **P2-2** | Threshold justification missing | Security thresholds unverifiable without academic citation |
| **P2-3** | Timestamp manipulation in freshness check | ~15s manipulation window on EVM |

---

## 6. Team Decisions — Task Assignment Table

> **Scope note:** Tasks below reflect the mobile wallet scope only. Deferred items (L1 contracts, Cosmos chain modules, SP1 batch prover, TypeScript SDK, StarkNet) are tracked in their respective separate projects. See `PROJECT_SCOPE.md`.

### Critical Tasks (block any external-facing launch)

| Task | Owner | Reviewer | Blocked by | Files |
|---|---|---|---|---|
| **TASK-1**: Replace ZK with real gnark Groth16 (surcorelibs FFI) | Dmitri Vasiliev | Dr. Amara, Marcus | TASK-2 | `Sur/Auth/ZKProofGenerator.swift`, `surcorelibs/gnark/` |
| **TASK-2**: Replace Keccak-256 with Poseidon in surcorelibs | Dmitri Vasiliev | Dr. Amara | — | `surcorelibs/poseidon/`, test vectors |
| **TASK-3**: Implement Apple App Attest | Lena Kovacs | Marcus | TASK-4 | `Sur/Auth/DeviceIDManager.swift`, new `AppAttestManager.swift` |
| **TASK-4**: Fix device private key UserDefaults → Keychain (P0) | Lena Kovacs | Marcus | — (fix immediately) | `Sur/Auth/DeviceIDManager.swift:146` |
| **TASK-5**: Fix behavioral data privacy leak (iOS data model) | Dmitri (circuit), Marcus (spec) | Dr. Amara | TASK-1 | `Sur/Auth/KeystrokeLog.swift` `ZKPublicInputs` |

### High-Priority Tasks (missing architectural components)

| Task | Owner | Reviewer | Blocked by | Files |
|---|---|---|---|---|
| **TASK-6**: Fix keyboard extension signing — `SecKeyCreateSignature` | Lena Kovacs | Marcus | TASK-4 | `SurKeyboard/KeystrokeLogger.swift`, new `KeystrokeLogger+Keychain.swift` |
| **TASK-7**: Populate surcorelibs (gnark FFI + Poseidon + XCFramework) | Dmitri Vasiliev | Lena | TASK-1, TASK-2 | `surcorelibs/gnark/`, `surcorelibs/poseidon/`, `surcorelibs/Makefile` |
| **TASK-8**: Cosmos chain API client (Swift gRPC/REST) | Lena Kovacs | Arjun, Marcus | TASK-3, TASK-1 | `Sur/Network/CosmosClient.swift` and extensions |
| **TASK-9**: L1 attestation read-only integration (`eth_call`) | Lena Kovacs | Isabelle, Marcus | — | `Sur/Network/L1Client.swift` and extensions |

### Medium-Priority Tasks

| Task | Owner | Reviewer | Blocked by | Files |
|---|---|---|---|---|
| **TASK-10**: iOS CI/CD pipeline (GitHub Actions) | Priya Sundaram | Sofia | — | `.github/workflows/` |
| **TASK-11**: Behavioral threshold justification document | Dr. Amara Diallo | Marcus | — | `BEHAVIORAL_THRESHOLDS.md` |
| **TASK-12**: Integration documentation (`docs/INTEGRATION.md`) | Sofia Esposito | All | TASK-1 (proof format must be defined) | `docs/INTEGRATION.md` |

**Execution order (mobile wallet):**
- Stream A: TASK-2 → TASK-1 → TASK-7 (Dmitri; blocks all ZK and surcorelibs)
- Stream B: TASK-4 (P0 — this week) → TASK-3 → TASK-8; TASK-6 parallel after TASK-4
- Stream C: TASK-1 done → TASK-5 (behavioral privacy fix uses correct private witness pattern)
- Stream D: TASK-9 (independent, start immediately — no code deps)
- Stream E: TASK-10, TASK-11 (independent, start immediately)
- Stream F: TASK-1 done → TASK-12 (integration docs require final proof format)

**Deferred to external projects (not tracked here):**
- L1 contract architecture (`AttestationSettlement.sol`, `AttestationDirect.sol`) → L1 Settlement project
- Cosmos SDK modules (x/identity, x/attestation, x/payment) → Sur Chain project
- SP1 batch prover → Sur Chain project
- TypeScript SDK / verification web app → Developer SDK project (future)
- StarkNet settlement contracts → Future settlement project (Phase 4)

---

## 7. Sofia's Closing Statement

> "Let me summarize what we just established. This iOS wallet app:
>
> - Calls its hash chain a 'cryptographic proof' when it has no zero-knowledge property
> - Stores a private signing key in UserDefaults — a plaintext property list on disk, readable by any App Group process
> - Uses a device identifier instead of Apple App Attest for device integrity
> - Publishes the behavioral statistics that are supposed to be hidden by the ZK proof
> - Has no real connection to the Cosmos chain or L1 contracts it is supposed to call
> - Has an empty `surcorelibs/` that should contain the entire gnark proving stack
>
> We have also clarified project boundaries: this repo is the iOS wallet only. The Cosmos chain, SP1 batch prover, L1 settlement contracts, and TypeScript SDK are separate projects. That's not a retreat — that's the right architecture. But it means this project's job is to be an excellent client of those systems, and right now it isn't connected to any of them.
>
> Five critical tasks block any external-facing launch. The documentation will say 'a cryptographic proof.' We cannot ship those words until we have a real gnark Groth16 proof from surcorelibs behind them.
>
> TASK-4 — the UserDefaults private key — gets fixed this week, before any other work starts. That's a P0 security vulnerability in code that is already in the repository. Everything else follows the dependency order Dmitri laid out.
>
> The spec is the system. This wallet will call real ZK proofs, store keys in Secure Enclave, attest devices through App Attest, and talk to the chain properly. We have a clear plan. Let's execute it."

---

*Review record maintained by: Sofia Esposito*
*Next quarterly review: 2026-06-27*
*All findings documented in: `tasks/TASKS-CRITICAL.md` (5 tasks), `tasks/TASKS-HIGH.md` (4 tasks), `tasks/TASKS-MEDIUM.md` (3 tasks)*
*Project boundary: `PROJECT_SCOPE.md` — Sur iOS wallet, not chain/prover/SDK*
*API contract with partner projects: `docs/INTEGRATION.md` (created by TASK-12)*
