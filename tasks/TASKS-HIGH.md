# Sur Protocol iOS — High-Priority Tasks

> These 4 tasks implement the missing integration points and signing infrastructure required for the documented mobile wallet to function. Cosmos chain implementation and SP1 batch prover are **separate projects** — the tasks here are about this iOS app calling those systems correctly.
> Complete all critical tasks first.

---

## TASK-6: Fix Keyboard Extension Signing — SecKeyCreateSignature Not SHA-256

**Owner:** Lena Kovacs
**Reviewer:** Marcus Webb
**Priority:** HIGH
**Complexity:** M
**Blocked by:** TASK-4 (Keychain must be fixed so Secure Enclave key is accessible in extension)
**Spec reference:** `project-scoping/docs/IOS_KEYBOARD.md §4`

### Problem Statement

`SurKeyboard/KeystrokeLogger.swift` computes SHA-256 over session data as a placeholder:
```swift
// SHA-256 fallback for keyboard extension
// Note: Main app will re-hash with Keccak-256 for on-chain compatibility
let hashData = SHA256.hash(data: Data(sessionData.utf8))
```

The main app then re-hashes this with Keccak-256. This means the keyboard extension never signs anything with a private key. The "motion digest" used in the proof is not authenticated by the extension — it's recomputable from public data. The main app could fabricate any session bundle.

The spec (`IOS_KEYBOARD.md §4`) requires the keyboard extension to call `SecKeyCreateSignature` with the Secure Enclave attestation key. The resulting signature is passed to the main app as a ZK circuit **private witness** — the circuit verifies the Secure Enclave signature inside ZK, proving the session came from the registered device, without revealing the key.

### Files to Modify / Create

| File | Action | Notes |
|---|---|---|
| `SurKeyboard/KeystrokeLogger.swift` | **Modify** | Replace SHA-256 with `SecKeyCreateSignature(.ecdsaSignatureMessageX962SHA256)` using Secure Enclave key from shared Keychain |
| `SurKeyboard/KeystrokeLogger+Keychain.swift` | **Create** | Keychain access in extension context; retry logic for `-34018` (Keychain daemon errors at extension startup) |
| `Sur/Auth/KeystrokeLogManager.swift` | **Modify** | Main app receives `(sessionData, signatureDER, attestationPublicKey)` — removes all SHA-256 → Keccak re-hash logic |
| `Sur/Auth/KeystrokeLog.swift` | **Modify** | `SignedKeystroke` struct includes `extensionSignatureDER: Data` field; this becomes a gnark circuit private witness in TASK-1 |
| `SurTests/KeyboardSigningTests.swift` | **Create** | Verify signature round-trip: extension signs, main app verifies with `SecKeyVerifySignature` |

### Session Bundle Signing Protocol

```swift
// SurKeyboard/KeystrokeLogger.swift — required pattern
func finalizeSession(_ session: KBKeystrokeSession) -> SignedSessionBundle? {
    let sessionBytes = session.canonicalEncoding()      // deterministic serialization
    guard let attestationKey = loadAttestationKey() else { return nil }  // from Keychain

    var cfError: Unmanaged<CFError>?
    guard let signatureDER = SecKeyCreateSignature(
        attestationKey,
        .ecdsaSignatureMessageX962SHA256,
        sessionBytes as CFData,
        &cfError
    ) as Data? else { return nil }

    return SignedSessionBundle(sessionData: sessionBytes, signatureDER: signatureDER)
}
```

### Acceptance Criteria

- [ ] `SurKeyboard` calls `SecKeyCreateSignature` on the session bundle; no SHA-256 hash written to App Group
- [ ] Signature passes `SecKeyVerifySignature` in the main app with the corresponding Keychain public key
- [ ] Keyboard extension handles `-34018` Keychain error with retry (up to 3 attempts, 100ms apart)
- [ ] Main app `KeystrokeLogManager` removes all SHA-256 → Keccak re-hash logic
- [ ] `SignedKeystroke` includes `extensionSignatureDER: Data` — used as private witness in TASK-1 circuit
- [ ] Works on real device (Secure Enclave unavailable in simulator)

---

## TASK-7: Populate surcorelibs (gnark FFI Bridge + Poseidon)

**Owner:** Dmitri Vasiliev (gnark circuit + Poseidon Go), Lena Kovacs (Xcode integration)
**Reviewer:** Lena Kovacs (Swift FFI consumer)
**Priority:** HIGH
**Complexity:** L
**Blocked by:** TASK-1 (circuit must exist), TASK-2 (Poseidon package must exist)
**Note:** This task is the packaging step — TASK-1 and TASK-2 produce the artifacts; this task puts them in the right place and builds the XCFramework

### Problem Statement

`surcorelibs/` contains only an empty `target/` directory. It must become the Go static library that Swift links against via CGo FFI. Without it, the iOS app has no path to call real gnark proving, and there is no cross-platform Poseidon for Swift to use.

### Files to Create

| Path | Description |
|---|---|
| `surcorelibs/gnark/` | From TASK-1: `attestation_circuit.go`, `ffi_bridge.go` (`//export ProveAttestation`, `//export VerifyAttestation`), `circuit_test.go` |
| `surcorelibs/poseidon/` | From TASK-2: `poseidon.go`, `poseidon_test.go`, `test_vectors.json` |
| `surcorelibs/go.mod` | `module surcorelibs`; requires `gnark`, `gnark-crypto` |
| `surcorelibs/Makefile` | `make ios` (arm64-apple-ios), `make simulator` (x86_64-apple-ios-simulator), `make xcframework` |
| `surcorelibs/libsurcorelibs.h` | C header: `extern void ProveAttestation(...)`, `extern bool VerifyAttestation(...)` |

### Makefile Build Targets

```makefile
XCODE_TOOLCHAIN := $(shell xcode-select -p)

ios:
	CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
	CC=$(XCODE_TOOLCHAIN)/usr/bin/clang \
	go build -buildmode=c-archive -o build/ios/libsurcorelibs.a ./...

simulator:
	CGO_ENABLED=1 GOOS=ios GOARCH=amd64 \
	go build -buildmode=c-archive -o build/simulator/libsurcorelibs.a ./...

xcframework:
	xcodebuild -create-xcframework \
		-library build/ios/libsurcorelibs.a -headers libsurcorelibs.h \
		-library build/simulator/libsurcorelibs.a -headers libsurcorelibs.h \
		-output build/libsurcorelibs.xcframework
```

### Acceptance Criteria

- [ ] `make xcframework` succeeds; `build/libsurcorelibs.xcframework` produced
- [ ] Xcode project links `libsurcorelibs.xcframework` in the `Sur` target build phase
- [ ] Swift calls `ProveAttestation` from `Sur/Auth/ZKProofGenerator.swift` without crash (Address Sanitizer clean)
- [ ] `go test ./poseidon/...` and `go test ./gnark/...` both pass
- [ ] XCFramework includes device slice (`arm64-apple-ios`) and simulator slice (`x86_64-apple-ios-simulator`)

---

## TASK-8: Cosmos Chain API Client (Swift gRPC + REST)

**Owner:** Lena Kovacs (Swift implementation), Arjun Nair (API contract review)
**Reviewer:** Marcus Webb
**Priority:** HIGH
**Complexity:** M
**Blocked by:** TASK-3 (App Attest needed to form `MsgAddDevice`), TASK-1 (ZK proof needed to form `MsgSubmitAttestation`)
**Spec reference:** `project-scoping/docs/COSMOS_MODULE.md`, `docs/INTEGRATION.md §1`

### Problem Statement

The iOS app needs to communicate with the Sur Chain project (a separate repository) to register usernames, add devices, submit attestations, and query attestation history. Currently, the app has no Cosmos network client — `Sur/Auth/MultiChainKeyManager.swift` can derive a Cosmos key, but nothing sends transactions or queries the chain.

This task builds the Swift client layer that calls the Sur Chain project's gRPC and REST endpoints. The app does **not** implement any chain logic — it is a pure API client.

### Required Interactions

| Operation | Direction | Protocol | Message / Endpoint |
|---|---|---|---|
| Register username | App → Chain | gRPC tx | `MsgRegisterUsername` |
| Add device | App → Chain | gRPC tx | `MsgAddDevice` (includes App Attest object) |
| Submit attestation | App → Chain | gRPC tx | `MsgSubmitAttestation` (includes gnark proof) |
| Query user profile | App ← Chain | REST GET | `GET /sur/identity/v1/user/{username}` |
| Query attestation history | App ← Chain | REST GET | `GET /sur/attestation/v1/attestations/{username}` |
| Query device Merkle proof | App ← Chain | REST GET | `GET /sur/identity/v1/merkle_proof/{username}/{device_key}` |
| Get commitment root | App ← Chain | REST GET | `GET /sur/identity/v1/commitment_root/{username}` |

### Files to Create

| File | Description |
|---|---|
| `Sur/Network/CosmosClient.swift` | Main client: endpoint configuration, connection management, retry logic |
| `Sur/Network/CosmosClient+Identity.swift` | `registerUsername()`, `addDevice()`, `queryUserProfile()`, `queryMerkleProof()` |
| `Sur/Network/CosmosClient+Attestation.swift` | `submitAttestation()`, `queryAttestations()`, `queryAttestation()` |
| `Sur/Network/CosmosTxBuilder.swift` | Build and sign Cosmos `TxBody`, `AuthInfo`, `SignDoc` in Swift; secp256k1 signing |
| `Sur/Network/ProtoMessages/` | Generated Swift protobuf types for `MsgRegisterUsername`, `MsgAddDevice`, `MsgSubmitAttestation` and their responses |
| `Sur/Network/CosmosError.swift` | Maps Cosmos SDK gRPC error codes to `SurError` domain errors with user-facing messages |
| `Sur/Views/CosmosConnectionView.swift` | Settings UI: enter RPC endpoint, test connection, display chain status |
| `SurTests/CosmosClientTests.swift` | Mock network client tests; verify proto serialization round-trips |

### Configuration

The Cosmos endpoint is user-configurable (different users may run their own nodes or use public RPC):
```swift
struct CosmosConfig {
    var grpcEndpoint: String = "grpc.surprotocol.com:9090"
    var restEndpoint: String = "https://api.surprotocol.com"
    var chainID: String = "sur-1"
    var feeDenom: String = "usur"
}
```

Store in `UserDefaults` (endpoint config only — no key material).

### Transaction Signing

Cosmos transactions require secp256k1 signing with the Cosmos tx key (derivation path `m/44'/118'/0'/0/0` from the BIP-44 mnemonic — already implemented in `MultiChainKeyManager.swift`). The signing flow:

```swift
// 1. Build TxBody with message
// 2. Fetch account sequence from chain (GET /cosmos/auth/v1beta1/accounts/{address})
// 3. Construct SignDoc (chainID, accountNumber, sequence, fee, TxBody bytes)
// 4. Sign SignDoc bytes with secp256k1 Cosmos key
// 5. Broadcast signed tx (POST /cosmos/tx/v1beta1/txs)
// 6. Poll for tx inclusion or handle broadcast error
```

### Acceptance Criteria

- [ ] `CosmosClient.registerUsername(username:)` constructs, signs, and broadcasts `MsgRegisterUsername`; returns tx hash
- [ ] `CosmosClient.addDevice(attestationObject:devicePublicKey:)` includes CBOR App Attest object in `MsgAddDevice`
- [ ] `CosmosClient.submitAttestation(proof:publicInputs:)` includes 256-byte gnark proof in `MsgSubmitAttestation`
- [ ] All queries return typed Swift structs (not raw JSON); validated with Zod-equivalent (Codable + custom validation)
- [ ] gRPC errors mapped to user-facing `SurError` messages (e.g., `ErrUsernameAlreadyTaken` → "This username is already registered. Choose a different one.")
- [ ] Retry logic: exponential backoff for network errors; no retry for deterministic errors (`ErrUsernameAlreadyTaken`)
- [ ] `CosmosConnectionView` allows the user to configure a custom RPC endpoint (for self-hosted nodes or testnet)
- [ ] Unit tests pass with mock HTTP responses

---

## TASK-9: L1 Attestation Read-Only Integration

**Owner:** Lena Kovacs (Swift implementation), Isabelle Fontaine (ABI contract review)
**Reviewer:** Marcus Webb
**Priority:** HIGH
**Complexity:** S
**Blocked by:** None — can start in parallel with other tasks
**Spec reference:** `project-scoping/docs/L1_SETTLEMENT.md §2.3`, `docs/INTEGRATION.md §2`

### Problem Statement

The iOS app should be able to show users whether their attestations have been settled on L1 — a stronger finality guarantee than Cosmos chain confirmation alone. Currently there is no L1 read client in the app. This is a **read-only** integration: the app calls `eth_call` on deployed L1 contracts (deployed and maintained by the L1 Settlement project). It does not sign or broadcast any Ethereum transactions.

### Required Read Operations

```
AttestationDirect.isNullifierUsed(bytes32 nullifier) → bool
AttestationDirect.getAttestation(bytes32 nullifier) → AttestationRecord
AttestationSettlement.getCheckpoint(uint256 epochId) → EpochCheckpoint
AttestationSettlement.latestSettledEpoch() → uint256
```

### Files to Create

| File | Description |
|---|---|
| `Sur/Network/L1Client.swift` | Ethereum JSON-RPC client for `eth_call`; no signing, no key material |
| `Sur/Network/L1Client+Attestation.swift` | `isNullifierUsed()`, `getAttestation()`, `getCheckpoint()` — ABI-encoded reads |
| `Sur/Network/L1Config.swift` | Contract addresses per network (Ethereum mainnet, Base, Arbitrum, Sepolia testnet); configurable |
| `Sur/Views/L1StatusView.swift` | Shows L1 settlement status for a given attestation: "Pending", "Settled on Ethereum", "Settled on Base" |
| `SurTests/L1ClientTests.swift` | Mock JSON-RPC responses; verify ABI decoding |

### ABI Fragments (provided by L1 Settlement project)

```json
[
  {
    "name": "isNullifierUsed",
    "type": "function",
    "stateMutability": "view",
    "inputs": [{"name": "nullifier", "type": "bytes32"}],
    "outputs": [{"name": "", "type": "bool"}]
  },
  {
    "name": "latestSettledEpoch",
    "type": "function",
    "stateMutability": "view",
    "inputs": [],
    "outputs": [{"name": "", "type": "uint256"}]
  }
]
```

### Configuration

Contract addresses come from the L1 Settlement project. Store in a bundled `l1_contracts.json`:
```json
{
  "1": { "AttestationDirect": "0x...", "AttestationSettlement": "0x..." },
  "11155111": { "AttestationDirect": "0x...", "AttestationSettlement": "0x..." }
}
```

Update this file when the L1 Settlement project deploys new contract versions.

### Acceptance Criteria

- [ ] `L1Client.isNullifierUsed(nullifier)` makes an `eth_call` and returns `Bool` without signing anything
- [ ] `L1Client.getCheckpoint(epochId)` decodes the `EpochCheckpoint` ABI struct correctly
- [ ] `L1StatusView` shows "Settled" badge when nullifier is confirmed on L1
- [ ] No Ethereum private keys or signing in this file — read-only only
- [ ] Works on testnet (Sepolia) and mainnet with endpoint configured via `L1Config`
- [ ] Unit tests mock JSON-RPC and verify ABI decoding of return values

---

*All high-priority tasks reviewed at quarterly protocol review, 2026-03-27.*
*Execution order: TASK-4 (P0) → TASK-6 (keyboard) | TASK-2 → TASK-1 → TASK-7 | TASK-8 after TASK-3 and TASK-1 | TASK-9 independent.*
*Cosmos chain implementation and SP1 batch prover are tracked in the Sur Chain project repository.*
*See `tasks/TASKS-MEDIUM.md` for the next tier.*
