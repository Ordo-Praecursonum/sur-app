# Sur Protocol — High-Priority Tasks

> These 5 tasks implement the core architectural components described in the documentation that are entirely absent from the current codebase. They do not represent security regressions (the critical tasks cover those) — they are missing features required for the documented system to exist. Complete all critical tasks first, then proceed in parallel streams as dependencies allow.

---

## TASK-7: Implement Cosmos Chain (x/identity, x/attestation, x/payment)

**Owner:** Arjun Nair
**Reviewer:** Marcus Webb, Dmitri Vasiliev
**Priority:** HIGH
**Complexity:** XL
**Blocked by:** TASK-2 (Poseidon Merkle tree required for device commitment management)
**Blocks:** TASK-8 (batch prover reads from Cosmos chain)
**Spec reference:** `project-scoping/docs/COSMOS_MODULE.md`, `project-scoping/docs/ARCHITECTURE.md §2`

### Problem Statement

The Cosmos chain is the authoritative source of truth for Sur Protocol: username registry, device commitment Merkle trees, ZK proof verification, nullifier sets, and epoch state management. Currently, no Cosmos chain exists. There is no `cosmos/` directory in the project root. The entire documented chain — `x/identity`, `x/attestation`, `x/payment`, the `surd` binary — must be built from scratch.

Without the Cosmos chain, there is no:
- Username → device commitment mapping
- ZK proof verification infrastructure (the chain embeds the gnark verifying key)
- Nullifier set (replay prevention lives on the chain)
- Epoch finalization events (the batch prover listens for these)
- `MsgRegisterUsername`, `MsgAddDevice`, `MsgSubmitAttestation` message handlers

### Files to Create

| Path | Description |
|---|---|
| `cosmos/app/app.go` | Cosmos SDK `App` struct; module registration; all keepers wired |
| `cosmos/cmd/surd/main.go` | Chain binary entry point |
| `cosmos/x/identity/module.go` | Module registration, CLI, routes |
| `cosmos/x/identity/keeper/keeper.go` | Username registry, device commitment Merkle tree management |
| `cosmos/x/identity/keeper/msg_server.go` | `MsgRegisterUsername`, `MsgAddDevice`, `MsgRevokeDevice`, `MsgRotateIdentityKey` handlers |
| `cosmos/x/identity/keeper/query_server.go` | `QueryGetUser`, `QueryGetCommitmentRoot`, `QueryGetDeviceCommitments`, `QueryGetMerkleProof` |
| `cosmos/x/identity/types/msgs.go` | Message type definitions, `ValidateBasic()` implementations |
| `cosmos/x/identity/types/keys.go` | KV store key prefixes for all state |
| `cosmos/x/attestation/keeper/keeper.go` | ZK proof verification (embeds gnark VK), nullifier set, epoch state |
| `cosmos/x/attestation/keeper/msg_server.go` | `MsgSubmitAttestation` handler (verifies gnark proof, checks nullifier, stores record, emits event) |
| `cosmos/x/attestation/keeper/epoch.go` | Epoch boundary detection, Poseidon Merkle tree over epoch attestations, `EventEpochFinalized` |
| `cosmos/x/attestation/keeper/query_server.go` | `QueryGetAttestation`, `QueryListAttestationsByUser`, `QueryGetEpochStateRoot`, `QueryGetEpochRecords` |
| `cosmos/x/payment/` | Phase 2 stub (placeholder module registration only) |
| `cosmos/proto/sur/identity/v1/` | Protobuf definitions for all `x/identity` messages, queries, state |
| `cosmos/proto/sur/attestation/v1/` | Protobuf definitions for all `x/attestation` messages, queries, state |
| `cosmos/ante/fee_decorator.go` | Custom ante handler for `x/identity` module fees |
| `cosmos/zk/verifier.go` | Wrapper around gnark `groth16.Verify`; loads VK from `go:embed`; caches loaded VK |
| `cosmos/zk/circuit_vk.bin` | Binary-embedded gnark verifying key (generated after TASK-1 trusted setup) |

### Acceptance Criteria

- [ ] `surd init` and `surd start` succeed with a single-validator genesis configuration
- [ ] `MsgRegisterUsername` stores a `UserProfile` with username hash and initial commitment root in KV store
- [ ] `MsgAddDevice` updates the Poseidon Merkle tree, recomputes commitment root, updates `UserProfile` atomically
- [ ] `MsgSubmitAttestation` verifies the embedded gnark proof via `groth16.Verify`, rejects if nullifier already in set, stores `AttestationRecord`, emits `EventAttestationSubmitted`
- [ ] Duplicate nullifier submission reverts with `ErrNullifierAlreadyUsed`
- [ ] Epoch finalization emits `EventEpochFinalized` with epoch Poseidon Merkle root over all epoch `AttestationRecord` hashes
- [ ] All gRPC queries return correct data; REST gateway serves OpenAPI spec
- [ ] Cosmos SDK simulation tests pass with randomized message sequences
- [ ] Gas cost for `MsgSubmitAttestation` benchmarked and under 200,000 gas (ZK verification is ~3ms; budget is generous)
- [ ] `buf lint` passes on all proto definitions; `buf breaking` enforces no breaking field changes

---

## TASK-8: Implement SP1 Batch Prover

**Owner:** Yuki Tanaka
**Reviewer:** Dmitri Vasiliev, Isabelle Fontaine
**Priority:** HIGH
**Complexity:** XL
**Blocked by:** TASK-7 (reads from Cosmos chain), TASK-5 (submits to AttestationSettlement.sol)
**Spec reference:** `project-scoping/docs/L1_SETTLEMENT.md §3`, `project-scoping/docs/ARCHITECTURE.md §4`

### Problem Statement

The batch prover is the bridge between the Cosmos chain and L1. Without it, the Cosmos chain can verify individual attestations but they are never aggregated into an L1 epoch checkpoint. The `AttestationSettlement.sol` contract would never receive a `submitCheckpoint` call, meaning L1 settlement doesn't exist in practice.

The SP1 program is critical for trustless L1 settlement: it verifies all gnark Groth16 proofs for an epoch **inside the ZK VM**, producing a single SP1 STARK (wrapped as a Groth16 for cheap EVM verification) that proves the entire epoch's worth of attestations without requiring the L1 contract to run each individual gnark verification.

### Files to Create

| Path | Description |
|---|---|
| `sp1_batch_program/Cargo.toml` | SP1 program crate; `sp1-zkvm = "..."`, `gnark_verify = "..."`, `poseidon_bn254 = "..."` |
| `sp1_batch_program/src/main.rs` | SP1 program: reads epoch records via `io::read()`, verifies gnark proofs, builds Poseidon Merkle tree, `io::commit(epoch_state_root)` |
| `batch_prover/Cargo.toml` | Batch prover daemon crate; `tonic`, `alloy`, `sp1-prover`, `tokio` |
| `batch_prover/src/main.rs` | Daemon entry point: polling loop, epoch queue, shutdown handler |
| `batch_prover/src/cosmos_client.rs` | `tonic`-based gRPC client for `QueryGetEpochRecords`; handles pagination |
| `batch_prover/src/prover.rs` | SP1 prover client integration; `ProverClient::local()` for dev, `::network()` for prod |
| `batch_prover/src/l1_submitter.rs` | `alloy` client; builds and broadcasts `submitCheckpoint` tx; gas estimation + 20% buffer; receipt watching |
| `batch_prover/src/metrics.rs` | Prometheus metrics: `sur_epoch_latest_settled`, `sur_settlement_lag_epochs`, `sur_proof_generation_seconds` |
| `batch_prover/Dockerfile` | Multi-stage build: builder + minimal runtime image |
| `batch_prover/k8s/deployment.yaml` | Kubernetes Deployment with `livenessProbe` checking last-successful-epoch age |

### SP1 Program Logic

```rust
// sp1_batch_program/src/main.rs — conceptual structure
fn main() {
    // Read epoch records from public input
    let records: Vec<AttestationRecord> = sp1_zkvm::io::read();
    let gnark_vk: Groth16VerifyingKey = sp1_zkvm::io::read();

    // Verify every gnark proof in the epoch
    for record in &records {
        let valid = gnark_verify::groth16::verify(&gnark_vk, &record.proof, &record.public_inputs);
        assert!(valid, "Invalid gnark proof for nullifier {:?}", record.nullifier);
    }

    // Build Poseidon Merkle tree over record hashes (deterministic sort by nullifier)
    let sorted_records = sort_by_nullifier(&records);
    let leaf_hashes: Vec<[u8; 32]> = sorted_records.iter()
        .map(|r| poseidon_hash_record(r))
        .collect();
    let epoch_state_root = build_poseidon_merkle_tree(&leaf_hashes);

    // Commit epoch state root as public output
    sp1_zkvm::io::commit(&epoch_state_root);
}
```

### Acceptance Criteria

- [ ] SP1 program compiles with `cargo prove build`; ELF binary produced; `PROGRAM_VKEY` derivable from ELF
- [ ] Given an epoch of N gnark proofs (generated by TASK-1), SP1 program verifies all N proofs inside the ZK VM without assertion failures
- [ ] Epoch Poseidon Merkle root produced by SP1 program matches the root computed independently by the Cosmos module (`EventEpochFinalized`)
- [ ] Batch prover daemon polls `QueryGetEpochRecords` every 10 seconds; detects new `EventEpochFinalized` events
- [ ] On detecting a new epoch, daemon submits inputs to SP1 prover, waits for proof, broadcasts `submitCheckpoint` to L1
- [ ] Duplicate epoch submission is skipped (epoch already in `latestSettledEpoch`)
- [ ] Daemon handles SP1 network timeout with exponential backoff retry (max 5 retries, 2^n seconds)
- [ ] `sur_settlement_lag_epochs` Prometheus metric fires PagerDuty alert when > 3
- [ ] End-to-end test: generate real gnark proof → submit to Cosmos → wait for epoch finalization → batch prover produces SP1 proof → L1 `AttestationSettlement.sol` accepts `submitCheckpoint` → `getCheckpoint(epochId)` returns correct state root

---

## TASK-9: Fix Keyboard Extension Signing — SecKeyCreateSignature Not SHA-256

**Owner:** Lena Kovacs
**Reviewer:** Marcus Webb
**Priority:** HIGH
**Complexity:** M
**Blocked by:** TASK-4 (Keychain must be fixed before Secure Enclave key is accessible in extension)
**Spec reference:** `project-scoping/docs/IOS_KEYBOARD.md §4`

### Problem Statement

`SurKeyboard/KeystrokeLogger.swift` computes SHA-256 over session data as a placeholder:
```swift
// SHA-256 fallback for keyboard extension
// Note: Main app will re-hash with Keccak-256 for on-chain compatibility
let hashData = SHA256.hash(data: Data(sessionData.utf8))
```

The main app then re-hashes this with Keccak-256. This means:
1. The keyboard extension never signs anything with a private key
2. The "motion digest" used in the proof is not authenticated by the extension — it's recomputable by anyone with the session data
3. The main app could fabricate session bundles entirely; there's no cryptographic evidence the keyboard extension was involved

The specification (`IOS_KEYBOARD.md §4`) requires the keyboard extension to call `SecKeyCreateSignature` with the Secure Enclave attestation key on the session bundle. The signature is passed to the main app, which includes it as a private witness in the gnark circuit. The circuit verifies the signature inside ZK — proving the session bundle was signed by the device's attestation key without revealing the key itself.

### Files to Modify / Create

| File | Action | Notes |
|---|---|---|
| `SurKeyboard/KeystrokeLogger.swift` | **Modify** | Replace SHA-256 hash with `SecKeyCreateSignature(.ecdsaSignatureMessageX962SHA256)` using Secure Enclave attestation key from shared Keychain |
| `SurKeyboard/KeystrokeLogger+Keychain.swift` | **Create** | Keychain access for attestation key reference in keyboard extension context; retry logic for `-34018` (Keychain daemon startup error in extensions) |
| `Sur/Auth/KeystrokeLogManager.swift` | **Modify** | Main app receives `(sessionData, signature, attestationPublicKey)` — does not re-sign or re-hash |
| `SurTests/KeystrokeLoggerSigningTests.swift` | **Create** | Test signature verification: extension signs, main app verifies using `SecKeyVerifySignature` |

### Session Bundle Signing Protocol

```swift
// In SurKeyboard/KeystrokeLogger.swift — required implementation
func finalizeSession(_ session: KBKeystrokeSession) -> SignedSessionBundle? {
    // 1. Serialize session to canonical form
    let sessionBytes = session.canonicalEncoding()

    // 2. Load attestation key from shared Keychain
    guard let attestationKey = loadAttestationKeyFromKeychain() else { return nil }

    // 3. Sign with Secure Enclave key
    var error: Unmanaged<CFError>?
    guard let signatureDER = SecKeyCreateSignature(
        attestationKey,
        .ecdsaSignatureMessageX962SHA256,
        sessionBytes as CFData,
        &error
    ) as Data? else { return nil }

    // 4. Write signed bundle to App Group container for main app
    return SignedSessionBundle(sessionData: sessionBytes, signature: signatureDER)
}
```

### Acceptance Criteria

- [ ] `SurKeyboard` extension calls `SecKeyCreateSignature` on session bundle; no SHA-256 or re-hashing in `KeystrokeLogger.swift`
- [ ] Signature passes `SecKeyVerifySignature` in the main app with the corresponding attestation public key
- [ ] Keyboard extension handles Keychain `-34018` error on extension startup with retry (up to 3 attempts with 100ms delay)
- [ ] Main app's `KeystrokeLogManager` receives `(sessionData, signature, publicKey)` tuple — removes all SHA-256 → Keccak re-hash logic
- [ ] Session bundle signing works on a real device (cannot be fully tested in simulator — Secure Enclave unavailable)
- [ ] `Sur/Auth/KeystrokeLog.swift` `SignedKeystroke` struct includes the DER-encoded extension signature as a field

---

## TASK-10: Implement TypeScript SDK (@surprotocol/sdk)

**Owner:** Kai Oduya
**Reviewer:** Sofia Esposito
**Priority:** HIGH
**Complexity:** L
**Blocked by:** None (independent of all other tasks — can start immediately)
**Spec reference:** `project-scoping/docs/VERIFICATION_GUIDE.md §2.2`, `project-scoping/docs/ARCHITECTURE.md §6`

### Problem Statement

There is no developer SDK, no verification web app, and no CLI tool. Any third-party application wanting to verify Sur Protocol attestations must implement custom Cosmos gRPC clients, parse response formats, implement content hashing, and handle errors without guidance. The documented verification experience — `[sur:alice:hash]` suffix in messages, `https://verify.surprotocol.com/alice/hash` verification links, the `AttestationBadge` React component — does not exist.

### Files to Create

```
sdk/
  packages/
    sdk/              → @surprotocol/sdk
      src/
        client.ts     → SurClient class; endpoint configuration; retry logic
        hash.ts       → computeContentHash(text: string): Promise<string>
        verify.ts     → verifyAttestation(username, contentHash, options)
        batch.ts      → batchVerify(requests: VerifyRequest[]): Promise<VerifyResult[]>
        types.ts      → AttestationResult, VerifyOptions, SurError, SurErrorCode
        index.ts      → public exports
      package.json    → @surprotocol/sdk; strict TypeScript; ESM+CJS dual build via tsup
      tsconfig.json
    react/            → @surprotocol/react
      src/
        AttestationBadge.tsx   → Server Component; fetches and renders verification result
        AttestationProvider.tsx → React Context with SurClient instance
        useAttestation.ts      → useAttestation(username, text) hook
      package.json    → @surprotocol/react; peerDeps: react, @surprotocol/sdk
  apps/
    web/              → verification web app (Next.js App Router)
      app/
        [username]/[hash]/page.tsx  → /alice/9a3f1b2c route
        layout.tsx
        page.tsx                    → home: paste text + username to verify
      package.json
  cli/                → sur-verify CLI (Go)
    main.go           → cobra CLI; verify, list, lookup commands
    go.mod
```

### Key Implementations

**`computeContentHash(text)`** — canonical content hash:
```typescript
// Uses SHA-256 (not Keccak-256) for content identification
// UTF-8 encoded, no trailing newline
export async function computeContentHash(text: string): Promise<string> {
    const encoded = new TextEncoder().encode(text);
    const hashBuffer = await crypto.subtle.digest('SHA-256', encoded);
    return Array.from(new Uint8Array(hashBuffer))
        .map(b => b.toString(16).padStart(2, '0'))
        .join('');
}
```

**`verifyAttestation(username, contentHash)`** — queries Cosmos REST:
```typescript
export async function verifyAttestation(
    username: string,
    contentHash: string,
    options?: VerifyOptions
): Promise<AttestationResult> {
    const url = `${this.endpoint}/sur/attestation/v1/attest/${username}/${contentHash}`;
    // Zod-validated response, SurErrorCode enum errors, AbortController for cancellation
}
```

### Acceptance Criteria

- [ ] `npm install @surprotocol/sdk` in a new project; `computeContentHash("hello world")` returns correct SHA-256 hash
- [ ] `verifyAttestation(username, hash)` returns `AttestationResult` with `attested: boolean`, `timestamp: number`, `nullifier: string` when Cosmos chain is running
- [ ] `AttestationBadge` renders correctly as a Next.js Server Component with no client JavaScript for the initial render
- [ ] Bundle size < 50KB gzipped (tracked in CI with `bundlesize`)
- [ ] TypeScript strict mode: `strict: true`, `noUncheckedIndexedAccess`, no `any` in public API surface
- [ ] ESM and CJS builds both work: `import { SurClient } from '@surprotocol/sdk'` and `const { SurClient } = require('@surprotocol/sdk')`
- [ ] All `SurError` instances include `code: SurErrorCode` and a human-readable message describing what went wrong and what the developer should do
- [ ] `/[username]/[hash]` route renders verification result with OpenGraph tags for social media preview
- [ ] Sofia sign-off on SDK ergonomics: install → verify in < 10 lines of code with no friction

---

## TASK-11: Populate surcorelibs (gnark FFI Bridge + Poseidon)

**Owner:** Dmitri Vasiliev (gnark FFI), Yuki Tanaka (Poseidon cross-platform)
**Reviewer:** Lena Kovacs (Swift FFI consumer)
**Priority:** HIGH
**Complexity:** L
**Blocked by:** TASK-2 (Poseidon package must exist), TASK-1 (gnark circuit must exist)
**Note:** This task is largely the completion/packaging of artifacts from TASK-1 and TASK-2 into the correct location

### Problem Statement

`surcorelibs/` contains only an empty `target/` directory. The entire purpose of `surcorelibs/` is to hold the Go static library that Swift can link against — the gnark circuit FFI bridge and the Poseidon implementation. Without this, the iOS app has no path to call gnark proving, and there is no cross-platform Poseidon available for Swift.

### Files to Create

| Path | Description |
|---|---|
| `surcorelibs/gnark/` | From TASK-1: attestation_circuit.go, ffi_bridge.go (`//export ProveAttestation`), circuit_test.go |
| `surcorelibs/poseidon/` | From TASK-2: poseidon.go, poseidon_test.go, test_vectors.json |
| `surcorelibs/go.mod` | Go module: `module surcorelibs`; requires gnark-crypto, gnark |
| `surcorelibs/Makefile` | Build targets: `make ios` → `arm64-apple-ios`; `make simulator` → `x86_64-apple-ios-simulator`; `make xcframework` → XCFramework combining both |
| `surcorelibs/libsurcorelibs.h` | C header: `extern void ProveAttestation(...)`, `extern bool VerifyAttestation(...)` |

### Makefile Build Targets

```makefile
ios:
    CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
    CC=$(XCODE_TOOLCHAIN)/usr/bin/clang \
    go build -buildmode=c-archive -o build/ios/libsurcorelibs.a .

simulator:
    CGO_ENABLED=1 GOOS=ios GOARCH=amd64 \
    go build -buildmode=c-archive -o build/simulator/libsurcorelibs.a .

xcframework:
    xcodebuild -create-xcframework \
        -library build/ios/libsurcorelibs.a \
        -library build/simulator/libsurcorelibs.a \
        -output build/libsurcorelibs.xcframework
```

### Acceptance Criteria

- [ ] `make xcframework` produces `build/libsurcorelibs.xcframework` without errors
- [ ] Xcode project links `libsurcorelibs.xcframework` in the `Sur` target build phase
- [ ] Swift can call `ProveAttestation` via `withUnsafeBytes` without crashes or memory errors (verified with Address Sanitizer)
- [ ] Poseidon test vectors pass in the Go package (`go test ./poseidon/...`)
- [ ] The XCFramework includes both `arm64-apple-ios` (device) and `x86_64-apple-ios-simulator` slices

---

*All high-priority tasks reviewed at quarterly protocol review, 2026-03-27.*
*Complete critical tasks first. High-priority tasks follow dependency order:*
*TASK-11 after TASK-1+2 | TASK-7 after TASK-2 | TASK-8 after TASK-7+5 | TASK-9 after TASK-4 | TASK-10 is independent.*
*See `tasks/TASKS-MEDIUM.md` for the next tier.*
