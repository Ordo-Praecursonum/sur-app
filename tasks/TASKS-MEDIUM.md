# Sur Protocol iOS — Medium-Priority Tasks

> These 3 tasks are required before public beta. They address CI/CD for the iOS app, formal justification of behavioral thresholds, and the integration documentation that partner projects (Sur Chain, L1 Settlement) depend on to build their verifiers correctly.

---

## TASK-10: iOS CI/CD Pipeline

**Owner:** Priya Sundaram
**Reviewer:** Sofia Esposito
**Priority:** MEDIUM
**Complexity:** M
**Blocked by:** None — can start immediately
**Spec reference:** `project-scoping/agents/devops-engineer.md §CI/CD`

### Problem Statement

No `.github/workflows/` directory exists. Every code change goes directly to the main branch with no automated validation. As the ZK circuit (TASK-1), keyboard signing (TASK-6), and Cosmos client (TASK-8) land, regressions will be invisible without CI. The surcorelibs Go build is especially fragile: a broken Go compile does not surface until someone builds the XCFramework manually.

This CI/CD pipeline covers **only this repository** (iOS app + surcorelibs). CI/CD for the Sur Chain project and L1 Settlement project are their own responsibility.

### Files to Create

```
.github/
  workflows/
    ios-build.yml          → xcodebuild: build + unit tests on iOS Simulator
    surcorelibs.yml        → go test ./surcorelibs/...; make xcframework (verify it compiles)
    pr-checks.yml          → runs both workflows on every PR; blocks merge on failure
```

### Workflow Definitions

```yaml
# .github/workflows/ios-build.yml
name: iOS Build & Test
on:
  push:
    branches: [main]
    paths: ['Sur/**', 'SurKeyboard/**', 'SurTests/**', 'SurUITests/**']
  pull_request:
    paths: ['Sur/**', 'SurKeyboard/**', 'SurTests/**', 'SurUITests/**']

jobs:
  build-and-test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode 15
        run: sudo xcode-select -s /Applications/Xcode_15.4.app
      - name: Cache DerivedData
        uses: actions/cache@v4
        with:
          path: ~/Library/Developer/Xcode/DerivedData
          key: ${{ runner.os }}-deriveddata-${{ hashFiles('Sur.xcodeproj/project.pbxproj') }}
      - name: Build & Test
        run: |
          xcodebuild test \
            -project Sur.xcodeproj \
            -scheme Sur \
            -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.5' \
            -resultBundlePath TestResults.xcresult \
            CODE_SIGNING_ALLOWED=NO
      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: TestResults-${{ github.sha }}
          path: TestResults.xcresult
```

```yaml
# .github/workflows/surcorelibs.yml
name: surcorelibs Build & Test
on:
  push:
    branches: [main]
    paths: ['surcorelibs/**']
  pull_request:
    paths: ['surcorelibs/**']

jobs:
  test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: '1.22'
          cache-dependency-path: surcorelibs/go.sum
      - name: Run Go tests
        run: cd surcorelibs && go test ./... -v -count=1
      - name: Verify XCFramework builds
        run: cd surcorelibs && make xcframework
        # This confirms the CGo FFI compiles for iOS targets
```

### Branch Protection Rules (configure in GitHub repository settings)

- `main` branch: require PR; require `iOS Build & Test` and `surcorelibs Build & Test` to pass; no direct pushes
- Minimum 1 reviewer approval required before merge
- No force-push to `main`

### Secrets Required (add in GitHub repository Settings → Secrets)

| Secret | Purpose |
|---|---|
| — | No secrets needed for build/test; no deployment in this repo |

No deployment pipeline needed — this is a mobile app; releases go through Apple App Store Connect (manual process outside CI).

### Acceptance Criteria

- [ ] Every PR touching `Sur/` or `SurKeyboard/` runs `xcodebuild test` and blocks merge on failure
- [ ] Every PR touching `surcorelibs/` runs `go test ./...` and `make xcframework`, blocks merge on failure
- [ ] DerivedData cached between runs; Go modules cached; build time under 8 minutes per workflow
- [ ] `main` branch requires PR + CI pass; no direct pushes
- [ ] Test result bundles uploaded as artifacts on every run (accessible for debugging failures)

---

## TASK-11: Behavioral Threshold Justification Document

**Owner:** Dr. Amara Diallo
**Reviewer:** Marcus Webb
**Priority:** MEDIUM
**Complexity:** M
**Blocked by:** None — can start immediately
**Spec reference:** `project-scoping/docs/ZK_CIRCUIT.md §5`, `project-scoping/agents/mathematician-researcher.md §behavioral-biometrics-theory`

### Problem Statement

`Sur/Auth/HumanTypingEvaluator.swift` has hardcoded thresholds:
```swift
// inter-key intervals: 20ms–2000ms
// coefficient of variation: 0.15–1.0
// coordinate jump: normalized <= 0.8
// minimum human score: 50 / 100
```

These values appear without citation, without derivation, and without adversarial analysis. External auditors, the Sur Chain project (which governs these thresholds as module parameters), and the L1 Settlement project (which encodes them in circuit constraints) all need a citable, peer-reviewed basis for these values.

### Deliverable

New file: `project-scoping/docs/BEHAVIORAL_THRESHOLDS.md`

#### Section 1 — Human Typing Performance Data (with citations)

| Parameter | Bound | Value | Source |
|---|---|---|---|
| WPM lower | min | 15 WPM | Salthouse (1984), Guinness World Records |
| WPM upper | max | 216 WPM | Guinness World Records 2023 |
| IKI lower bound | min | 20ms | Bergadano et al. (2002); Karnan et al. (2011) |
| IKI upper bound | max | 2,000ms | Leggett et al. (1991) |
| IKI coefficient of variation lower | min | 0.15 | Revett et al. (2005); Dr. Diallo corpus study (2024) |
| IKI coefficient of variation upper | max | 1.0 | Dr. Diallo corpus study (2024) — p99.9 |
| Deletion rate upper | max | 35% | Bergadano et al. (2002) corpus analysis |
| Pause frequency (IKI > 500ms) | range | 2%–40% | Dr. Diallo corpus study (2024) |

Cite: Dr. Diallo, "Human Keystroke Dynamics: Empirical Bounds for Authentication Thresholds" (corpus of 50,000 users).

#### Section 2 — Adversarial Synthesis Analysis

Document the difficulty of synthesizing keystroke data that passes all constraints simultaneously:

- **Physical automation** (AutoHotkey, xdotool): IKI CoV < 0.05; deletion rate 0%; trivially detected
- **GAN synthesis** (published results — cite): matches WPM and mean IKI independently; IKI CoV > 0.15 while hitting a WPM target has not been demonstrated simultaneously in published literature
- **LSTM synthesis** (published results — cite): generates overly regular timing (CoV < 0.12) when constrained to WPM range
- **Joint distribution argument**: any single constraint can be synthesized; the joint distribution over all 5 simultaneously increases adversarial cost by an estimated 2–3 orders of magnitude

#### Section 3 — False Negative Rate

With chosen bounds, what fraction of legitimate human typists fail?
- Lower WPM (15): excludes < 0.1% of adults (extreme physical impairment)
- IKI CoV lower bound (0.15): excludes users with motor neuron conditions producing hyper-regular timing — documented as accepted tradeoff; accessibility mode pathway noted
- Target: < 2% false negative rate for unimpaired adult typists

#### Section 4 — Exact Values Used in Implementation

Cross-reference with `Sur/Auth/HumanTypingEvaluator.swift`:
```
MIN_IKI_MS = 20
MAX_IKI_MS = 2000
MIN_IKI_COV = 0.15
MAX_IKI_COV = 1.0
MIN_HUMAN_SCORE = 50
TIMING_WEIGHT = 0.35
VARIATION_WEIGHT = 0.25
COORDINATE_WEIGHT = 0.20
PATTERN_WEIGHT = 0.20
```

Note to Sur Chain project: these values are currently hardcoded in the iOS app. They will need to become governance-adjustable parameters in the `x/attestation` module. This document is the justification for their initial values.

### Acceptance Criteria

- [ ] `project-scoping/docs/BEHAVIORAL_THRESHOLDS.md` created with all 4 sections
- [ ] Every threshold value has a published citation or Dr. Diallo's corpus study as source
- [ ] At least one GAN/LSTM synthesis paper cited in adversarial analysis
- [ ] False negative rate < 2% stated with supporting data
- [ ] All values match `Sur/Auth/HumanTypingEvaluator.swift` — any discrepancy found during writing triggers an update to the Swift file (doc is the truth)
- [ ] Marcus confirms: no known automated tool demonstrated passing all 5 constraints simultaneously at time of writing
- [ ] Document shared with Sur Chain project as input for `x/attestation` module parameter defaults

---

## TASK-12: Integration Documentation

**Owner:** Sofia Esposito (structure and prose), Arjun Nair (Cosmos API contract review), Isabelle Fontaine (L1 ABI review)
**Reviewer:** Lena Kovacs (iOS implementation perspective)
**Priority:** MEDIUM
**Complexity:** M
**Blocked by:** TASK-3 (App Attest format finalised), TASK-1 (proof format finalised)
**Note:** Produce a first draft immediately using the specs; update with exact values as TASK-1 and TASK-3 complete

### Problem Statement

The Sur Protocol is split across multiple repositories. This iOS app depends on the Sur Chain project and L1 Settlement project for core functionality. Without clear API contracts documented in this repository, those partner projects cannot build verifiers that accept what this app sends. Currently:

- The Sur Chain project does not know exactly what `MsgAddDevice` must contain from the iOS side
- The L1 Settlement project does not know exactly what proof format (256 bytes, 5 public inputs) they must accept
- Any engineer picking up this iOS project has no guide for what external services to run locally

### Deliverable: `docs/INTEGRATION.md`

This file is the **integration contract** — the single source of truth for what this iOS app sends to external systems and what it expects back.

#### Chapter 1 — Sur Chain Project Interface

**1.1 gRPC / REST endpoints this app calls**

```
Base gRPC: grpc.surprotocol.com:9090   (configurable)
Base REST: https://api.surprotocol.com  (configurable)
Chain ID: sur-1
Fee denom: usur
```

**1.2 `MsgRegisterUsername`**
```protobuf
message MsgRegisterUsername {
  string creator = 1;           // bech32 Cosmos address of the user
  string username = 2;          // 3–32 chars, lowercase alphanumeric + underscore
  bytes  identity_pubkey = 3;   // 65-byte uncompressed secp256k1 public key
}
```
Expected response: `MsgRegisterUsernameResponse { username_hash: bytes }`
Error cases this app handles: `ErrUsernameAlreadyTaken`, `ErrInvalidUsername`, `ErrInsufficientFees`

**1.3 `MsgAddDevice`**
```protobuf
message MsgAddDevice {
  string creator = 1;
  string username = 2;
  bytes  device_pubkey = 3;          // 65-byte uncompressed P-256 public key (from Secure Enclave)
  bytes  app_attest_object = 4;      // CBOR-encoded Apple App Attest attestation object
  bytes  device_commitment = 5;      // Poseidon(device_pubkey_x, device_pubkey_y, blinding_factor)
  bytes  client_data_hash = 6;       // SHA-256 of this message's canonical encoding (bound to attestation)
}
```
Expected response: `MsgAddDeviceResponse { commitment_root: bytes, device_index: uint64 }`

**1.4 `MsgSubmitAttestation`**
```protobuf
message MsgSubmitAttestation {
  string creator = 1;
  string username = 2;
  bytes  proof = 3;               // 256-byte gnark Groth16 proof (see §1.5)
  bytes  public_inputs = 4;       // 160-byte public inputs (5 × 32-byte BN254 field elements)
  uint64 session_counter = 5;     // monotonically increasing per device
}
```
Public inputs layout (from `PROOF_FORMAT.md §1.3`):
```
Offset  Size  Field
0       32    username_hash
32      32    content_hash_lo   (low 128 bits of SHA-256 content hash)
64      32    content_hash_hi   (high 128 bits)
96      32    nullifier         (Poseidon(device_pubkey_x, device_pubkey_y, session_counter))
128     32    commitment_root   (Poseidon Merkle root of device commitments)
```

**1.5 Proof format (from `PROOF_FORMAT.md §1.1`)**

The 256-byte gnark Groth16 proof:
```
Offset  Size  Field
0       64    A  (G1 point: x[32] || y[32])
64      128   B  (G2 point: x0[32] || x1[32] || y0[32] || y1[32])
192     64    C  (G1 point: x[32] || y[32])
```
All coordinates are big-endian 32-byte BN254 field elements.

**1.6 REST query endpoints this app reads**
```
GET /sur/identity/v1/user/{username}
GET /sur/identity/v1/commitment_root/{username}
GET /sur/identity/v1/merkle_proof/{username}/{device_pubkey_hex}
GET /sur/attestation/v1/attestations/{username}?limit=20&offset=0
GET /sur/attestation/v1/attestation/{nullifier_hex}
```

**1.7 Error codes this app handles**

| Cosmos error code | Sur error | User-facing message |
|---|---|---|
| `ErrUsernameAlreadyTaken` | `SurError.usernameUnavailable` | "This username is already taken. Choose a different one." |
| `ErrDeviceAlreadyRegistered` | `SurError.deviceAlreadyRegistered` | "This device is already registered to this account." |
| `ErrNullifierAlreadyUsed` | `SurError.proofAlreadySubmitted` | "This proof has already been submitted." |
| `ErrProofExpired` | `SurError.proofExpired` | "This proof is too old. Generate a new attestation." |
| `ErrInvalidProof` | `SurError.invalidProof` | "Proof verification failed. Please try again." |

#### Chapter 2 — L1 Settlement Project Interface

**2.1 Contracts this app reads (read-only)**

| Contract | Network | Address | Source |
|---|---|---|---|
| `AttestationDirect` | Ethereum mainnet | TBD (from L1 project) | L1 Settlement project |
| `AttestationDirect` | Ethereum Sepolia | TBD | L1 Settlement project |
| `AttestationSettlement` | Base mainnet | TBD | L1 Settlement project |

Update `Sur/Network/l1_contracts.json` when the L1 Settlement project deploys.

**2.2 ABI functions this app calls**

```solidity
// All read-only (eth_call, no signing)
function isNullifierUsed(bytes32 nullifier) external view returns (bool);
function getAttestation(bytes32 nullifier) external view returns (AttestationRecord memory);
function latestSettledEpoch() external view returns (uint256);
function getCheckpoint(uint256 epochId) external view returns (EpochCheckpoint memory);
```

**2.3 What the L1 Settlement project must accept from this app**

The gnark Groth16 proof submitted via `MsgSubmitAttestation` (to the Cosmos chain) is eventually batched by the SP1 prover and submitted to `AttestationSettlement.submitCheckpoint`. The L1 contract must verify proofs with:
- Proof: 256-byte gnark Groth16 (as defined in §1.5)
- Public inputs: exactly 5 BN254 field elements in the order defined in §1.4
- No behavioral statistics in any public input

The L1 Settlement project must use the same gnark verifying key as the Cosmos chain. Changes to the gnark circuit (TASK-1) require the L1 Settlement project to update their `AttestationVerifier.sol`.

#### Chapter 3 — Development Setup

**3.1 Running locally**

Prerequisites:
```bash
# 1. Clone and start the Sur Chain project locally
git clone <sur-chain-repo>
cd sur-chain && make start-local   # starts surd on localhost:9090 and localhost:1317

# 2. Configure this iOS app
# In Xcode scheme → Run → Environment Variables:
COSMOS_GRPC=localhost:9090
COSMOS_REST=http://localhost:1317
ETH_RPC_URL=https://sepolia.infura.io/v3/<your-key>
```

**3.2 Testnet endpoints**
```
Sur testnet gRPC: grpc.testnet.surprotocol.com:9090
Sur testnet REST: https://api.testnet.surprotocol.com
Ethereum Sepolia: https://rpc.ankr.com/eth_sepolia
```

**3.3 Proof format compatibility test**

Before any release, run the cross-project compatibility test:
1. Generate a gnark Groth16 proof using `surcorelibs/gnark/circuit_test.go`
2. Submit it to the local Sur Chain node via `MsgSubmitAttestation`
3. Verify the chain accepts it (non-zero receipt, no `ErrInvalidProof`)
4. Share the test proof bytes + public inputs with the L1 Settlement project to verify their Solidity verifier accepts them

### Acceptance Criteria

- [ ] `docs/INTEGRATION.md` created with all 3 chapters
- [ ] Proto message definitions in §1 match the proto files generated by the Sur Chain project (verify with Arjun)
- [ ] Proof format in §1.5 matches `PROOF_FORMAT.md §1.1` exactly (no drift)
- [ ] ABI fragment in §2.2 matches the deployed `AttestationDirect.sol` (verify with Isabelle)
- [ ] §3 development setup tested: a new engineer can follow it and successfully connect to local Sur Chain within 30 minutes
- [ ] Sofia confirms: no jargon in user-facing error messages; no marketing language in technical sections
- [ ] Shared with Sur Chain and L1 Settlement project teams for review

---

*All medium-priority tasks reviewed at quarterly protocol review, 2026-03-27.*
*TASK-10 and TASK-11 are independent — start both immediately.*
*TASK-12 produce a first draft now; update §1.5 when TASK-1 proof format is finalised.*
*Cosmos chain implementation, SP1 batch prover, Solidity contracts, and TypeScript SDK are tracked in their respective project repositories.*
