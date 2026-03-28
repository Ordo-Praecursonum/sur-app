# Sur Protocol — Medium-Priority Tasks

> These 4 tasks are required before public beta. They are not security regressions (those are in `TASKS-CRITICAL.md`) and do not block Phase 1 architecture work (covered in `TASKS-HIGH.md`). They address operational safety, security documentation, and a known edge case in the freshness mechanism.

---

## TASK-12: Set Up CI/CD Pipeline

**Owner:** Priya Sundaram
**Reviewer:** Sofia Esposito
**Priority:** MEDIUM
**Complexity:** M
**Blocked by:** None (independent — can start now)
**Spec reference:** `project-scoping/agents/devops-engineer.md §CI/CD`

### Problem Statement

No `.github/workflows/` directory exists. Every code change across all layers (Go circuit, Swift app, Solidity contracts, Rust batch prover) goes directly to the main branch with no automated validation. Once multiple engineers are committing across the full stack, a broken gnark circuit can ship undetected because neither the iOS build nor the Rust prover tests catch it — they live in separate layers with no automated cross-validation.

The risk grows with each task completed: as TASK-1 (gnark), TASK-5 (Solidity), TASK-7 (Cosmos), and TASK-8 (Rust) land, there are four independent build surfaces that can break each other silently without CI.

### Files to Create

```
.github/
  workflows/
    ios-build.yml          → Build and test Swift targets (xcodebuild)
    gnark-circuit.yml      → go test ./surcorelibs/... ; constraint count benchmark
    solidity-contracts.yml → forge test --match-contract Attestation -vvv ; forge coverage
    rust-batch-prover.yml  → cargo test (batch_prover) ; cargo prove build (sp1_batch_program)
    cosmos-chain.yml       → go test ./cosmos/... ; surd binary build
    integration.yml        → End-to-end test against sur-testnet-1 (on push to main only)
```

### Workflow Structure

```yaml
# ios-build.yml — triggered on every PR touching Sur/ or SurKeyboard/
name: iOS Build & Test
on:
  push:
    paths: ['Sur/**', 'SurKeyboard/**', 'SurTests/**']
  pull_request:
    paths: ['Sur/**', 'SurKeyboard/**', 'SurTests/**']
jobs:
  build:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_15.4.app
      - name: Build & Test
        run: |
          xcodebuild test \
            -scheme Sur \
            -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
            -resultBundlePath TestResults.xcresult
      - name: Upload results
        uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: TestResults.xcresult
```

```yaml
# solidity-contracts.yml — triggered on every PR touching Contracts/
name: Solidity Contract Tests
on:
  push:
    paths: ['Contracts/**']
  pull_request:
    paths: ['Contracts/**']
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1
      - name: Run tests
        run: forge test --match-contract Attestation -vvv
      - name: Coverage gate
        run: |
          COVERAGE=$(forge coverage --report summary | grep 'Branch coverage' | awk '{print $3}' | tr -d '%')
          if (( $(echo "$COVERAGE < 100" | bc -l) )); then
            echo "Branch coverage $COVERAGE% < 100%"
            exit 1
          fi
```

```yaml
# mainnet-deploy — manual approval gate (never auto-deploys)
name: Mainnet Deployment
on:
  workflow_dispatch:
    inputs:
      network:
        description: 'Target network (mainnet, base, arbitrum)'
        required: true
jobs:
  deploy:
    environment: mainnet    # requires 2 approvers in GitHub environment settings
    runs-on: ubuntu-latest
    steps:
      - name: Deploy contracts
        run: forge script Deploy.s.sol --broadcast --verify --chain-id ${{ env.CHAIN_ID }}
```

### Acceptance Criteria

- [ ] PR to `Sur/` directory triggers `ios-build.yml`; build failure blocks merge
- [ ] PR to `Contracts/` triggers `solidity-contracts.yml`; `forge coverage` < 100% branch blocks merge
- [ ] PR to `surcorelibs/` triggers `gnark-circuit.yml`; `go test ./...` failure blocks merge
- [ ] PR to `sp1_batch_program/` or `batch_prover/` triggers `rust-batch-prover.yml`; `cargo test` failure blocks merge
- [ ] PR to `cosmos/` triggers `cosmos-chain.yml`; `go test ./...` failure blocks merge
- [ ] Go module cache and Rust Cargo cache configured with `actions/cache`; build times under 5 minutes for each workflow
- [ ] Mainnet deployment workflow requires manual dispatch + 2 approvers in GitHub `mainnet` environment; never triggers automatically
- [ ] No plaintext secrets in workflow files; all credentials in GitHub Secrets with descriptive names (`ETH_DEPLOYER_PRIVATE_KEY`, `ETHERSCAN_API_KEY`, etc.)
- [ ] `docker/build-push-action` for the batch prover builds `linux/amd64` and `linux/arm64` images

---

## TASK-13: Publish Behavioral Threshold Justification

**Owner:** Dr. Amara Diallo
**Reviewer:** Marcus Webb
**Priority:** MEDIUM
**Complexity:** M
**Blocked by:** None (independent — can start now)
**Spec reference:** `project-scoping/docs/ZK_CIRCUIT.md §5`, `project-scoping/agents/mathematician-researcher.md §behavioral-biometrics-theory`

### Problem Statement

`Sur/Auth/HumanTypingEvaluator.swift` has hardcoded thresholds:
```swift
// Timing patterns (35%): inter-key intervals 20ms–2000ms
// Timing variation (25%): coefficient of variation 0.15–1.0
// Coordinate patterns (20%): normalized jump <= 0.8
// Typing patterns (20%): pauses, bursts, natural rhythm
```

These values appear without citation, without derivation, and without adversarial analysis. The current `project-scoping/docs/ZK_CIRCUIT.md` does not document the behavioral threshold section with academic references. Without published justification, external auditors and researchers cannot verify that these thresholds:
- Correctly accept 98%+ of legitimate human typists (false negative rate)
- Meaningfully reject automated typing tools (true positive rate)
- Are not gameable by a bot that knows the exact thresholds

### Deliverable

A new document `project-scoping/docs/BEHAVIORAL_THRESHOLDS.md` (or a fully populated §5 in `ZK_CIRCUIT.md`) containing:

#### Section 1 — Human Typing Performance Data

| Parameter | Lower Bound | Upper Bound | Source | Sample Size |
|---|---|---|---|---|
| WPM (words per minute) | 15 WPM | 216 WPM | [Guinness World Records 2023; Salthouse 1984 corpus] | N > 50,000 |
| IKI mean (inter-key interval) | 20ms | 2,000ms | [Bergadano et al. 2002; Karnan et al. 2011] | N > 10,000 |
| IKI coefficient of variation | 0.15 | 1.0 | [Leggett et al. 1991; Revett et al. 2005] | N > 5,000 |
| Deletion rate | 0% | 35% | [Bergadano et al. 2002 corpus analysis] | N > 10,000 |
| Pause frequency (>500ms IKI) | 2% | 40% | [Dr. Diallo corpus study, 2024] | N = 50,000 |

Cite Dr. Diallo's published corpus study: "Human Keystroke Dynamics: Empirical Bounds for Authentication Thresholds."

#### Section 2 — Adversarial Synthesis Analysis

Document the difficulty of synthesizing keystroke data that passes all thresholds simultaneously:
- GAN-based synthesis (cite published results): can match WPM and mean IKI independently; struggles with IKI coefficient of variation > 0.15 simultaneously with correct WPM
- LSTM-based synthesis: can approximate individual IKI distributions; generates overly regular patterns (CoV < 0.12) when constrained to a WPM target
- Physical keyboard automation (AutoHotkey, xdotool): easily detected — deletion rate 0%, no pauses, CoV < 0.05
- The joint distribution argument: passing all 5 constraints simultaneously increases attack cost by estimated 2–3 orders of magnitude relative to passing any single constraint

#### Section 3 — False Negative Rate Analysis

With the chosen thresholds, what fraction of legitimate human typists would fail?
- Lower WPM bound (15 WPM): excludes <0.1% of the adult population (hunt-and-peck typists under physical impairment)
- IKI CoV lower bound (0.15): excludes typists with motor neuron conditions producing highly regular timing — documented as an accepted tradeoff with mitigation path (accessibility mode)
- Target false negative rate: < 2% of unimpaired adult typists

#### Section 4 — Threshold Values Used in Circuit

Exact values implemented in gnark circuit (from `ZK_CIRCUIT.md §5`):
- `MIN_IKI_MS = 20`
- `MAX_IKI_MS = 2000`
- `MIN_IKI_COV = 15` (× 100 for integer representation, i.e., 0.15)
- `MAX_IKI_COV = 100` (× 100, i.e., 1.0)
- `MIN_HUMAN_SCORE = 50` (HumanTypingEvaluator composite score)

Justification for each value linked to Section 1 citations.

### Acceptance Criteria

- [ ] `project-scoping/docs/BEHAVIORAL_THRESHOLDS.md` (or `ZK_CIRCUIT.md §5`) contains academic citations for every threshold parameter
- [ ] Dr. Amara Diallo's corpus study cited for IKI distribution data (50,000 participants)
- [ ] At least one published paper on GAN-based or LSTM-based keystroke synthesis cited in the adversarial analysis
- [ ] False negative rate for unimpaired adult typists estimated at < 2% based on corpus data
- [ ] All threshold values in the document match the values in `Sur/Auth/HumanTypingEvaluator.swift` and (after TASK-1/TASK-6) in the gnark circuit constraints
- [ ] Marcus Webb reviews and confirms adversarial analysis is complete: no known automated tool known to pass all 5 constraints simultaneously at the time of writing
- [ ] Document available to external auditors as part of the pre-audit package

---

## TASK-14: Replace Timestamp-Based Freshness with Block-Height Freshness

**Owner:** Marcus Webb (specification), Arjun Nair (Cosmos implementation), Isabelle Fontaine (L1 update)
**Reviewer:** Isabelle Fontaine (for Arjun's changes)
**Priority:** MEDIUM
**Complexity:** S
**Blocked by:** TASK-7 (Cosmos chain must exist), TASK-5 (L1 contracts must exist)
**Spec reference:** `project-scoping/docs/L1_SETTLEMENT.md §4.3`

### Problem Statement

The current `KeystrokeProofVerifier.sol` (to be replaced by TASK-5) uses `block.timestamp` for proof freshness:
```solidity
require(block.timestamp - proof.generatedAt <= 24 hours, "Proof too old");
```

`block.timestamp` on Ethereum is controlled by the block proposer and can be manipulated within the Ethereum protocol's allowed tolerance (~12 seconds per slot on proof-of-stake Ethereum). More importantly, the 24-hour window approach is fragile: a proof generated just before the window expires, submitted to the Cosmos chain but delayed in the batch prover pipeline, could arrive at L1 stale.

The correct approach: the Cosmos chain records the block height at which a proof was submitted (`proof_submission_height`). The L1 contract trusts the Cosmos-anchored epoch timestamp (included in the SP1 proof's public values) rather than `block.timestamp`. Freshness is enforced at the Cosmos chain level (`MsgSubmitAttestation` rejects proofs older than N blocks at submission time), not re-checked at L1.

### Changes Required

**Cosmos side** (`cosmos/x/attestation/keeper/msg_server.go`):
```go
// In MsgSubmitAttestation handler:
const MAX_PROOF_AGE_BLOCKS = 100  // ~10 minutes at 6s block time

proofBlockHeight := ctx.BlockHeight() // block when proof was generated (from proof public inputs)
currentHeight := ctx.BlockHeight()

if currentHeight - proofBlockHeight > MAX_PROOF_AGE_BLOCKS {
    return nil, sdkerrors.Wrapf(ErrProofExpired,
        "proof generated at height %d, current height %d, max age %d blocks",
        proofBlockHeight, currentHeight, MAX_PROOF_AGE_BLOCKS)
}
```

**L1 side** (`Contracts/AttestationDirect.sol`):
```solidity
// Remove: require(block.timestamp - proof.generatedAt <= 24 hours)
// Add: trust the Cosmos-attested submission timestamp included in proof public values
// The SP1 aggregate proof in AttestationSettlement.sol already encodes epoch timestamps
// from the Cosmos chain, which is the authoritative source of temporal ordering
```

For `AttestationDirect.sol` (individual proofs without SP1 batch): include `cosmos_submission_height` as one of the public inputs (replacing or supplementing the current `commitment_root`), letting L1 verify freshness against the Cosmos chain's block height rather than EVM timestamp.

### Files to Modify

| File | Action | Notes |
|---|---|---|
| `cosmos/x/attestation/keeper/msg_server.go` | **Modify** | Add `MAX_PROOF_AGE_BLOCKS` check in `MsgSubmitAttestation`; reject proofs where `current_height - proof_height > 100` |
| `cosmos/x/attestation/types/params.go` | **Modify** | Add `ProofFreshnessBlocks uint64` as a governance-adjustable parameter (default: 100) |
| `Contracts/AttestationDirect.sol` | **Modify** (after TASK-5) | Remove `block.timestamp` freshness check; document that freshness is enforced on the Cosmos chain |
| `project-scoping/docs/L1_SETTLEMENT.md` | **Modify** | Update §4.3 to document block-height freshness model |

### Acceptance Criteria

- [ ] `MsgSubmitAttestation` on the Cosmos chain rejects proofs where `current_block_height - proof_submission_height > ProofFreshnessBlocks` (default 100)
- [ ] `ProofFreshnessBlocks` is a governance-adjustable parameter in `x/attestation` module params
- [ ] `AttestationDirect.sol` contains no `block.timestamp` comparison for freshness
- [ ] `L1_SETTLEMENT.md §4.3` documents the block-height model with rationale (miner timestamp manipulation mitigated)
- [ ] Cosmos module test: submit proof at block 1, advance to block 102, attempt re-submit → `ErrProofExpired`
- [ ] Marcus confirms: no freshness enforcement relies on `block.timestamp` in any security-critical path

---

## TASK-15: StarkNet Settlement Stub (Phase 4 Preparation)

**Owner:** Rania Aziz
**Reviewer:** Sofia Esposito
**Priority:** MEDIUM (Phase 4 — non-blocking for Phase 1 launch)
**Complexity:** S
**Blocked by:** None
**Spec reference:** `project-scoping/docs/ARCHITECTURE.md §7 (Phase 4)`, `project-scoping/agents/starknet-engineer.md`

### Problem Statement

The Sur Protocol architecture documents StarkNet settlement as a Phase 4 target (`ARCHITECTURE.md §7`). Currently, no Cairo contracts or StarkNet-related files exist in the repository. The question is not whether to implement Phase 4 now — it's whether to create documented stubs that:
1. Clarify the intended architecture in code (even before implementation)
2. Allow the repository structure to reflect the full protocol scope
3. Give Rania a clear starting point when Phase 4 begins

Sofia's decision at the quarterly review: create empty Cairo contract stubs now, clearly marked as Phase 4 placeholders.

### Files to Create

```
cairo/
  README.md               → Phase 4 — StarkNet Settlement (not implemented)
  SurSettlement.cairo     → Stub: epoch checkpoint contract for StarkNet
  SurDirect.cairo         → Stub: individual attestation contract for StarkNet
  Scarb.toml              → Cairo package manifest (minimal)
```

### `cairo/SurSettlement.cairo` — Stub Content

```cairo
// Sur Protocol — StarkNet Settlement Contract (Phase 4 Stub)
// Status: NOT IMPLEMENTED — Phase 4 target
// See project-scoping/docs/ARCHITECTURE.md §7 for design intent
//
// This contract will accept STARK proofs aggregated by the Sur batch prover
// and store epoch state roots on StarkNet for permissionless verification.
//
// Key differences from EVM AttestationSettlement.sol:
// - Uses STARK verification natively (no Groth16 wrapping needed)
// - Poseidon is a first-class StarkNet primitive (no custom contract needed)
// - Cairo's felt252 field is NOT BN254 — Poseidon parameters differ
//   See: ARCHITECTURE.md §7.2 for field migration plan

#[starknet::contract]
mod SurSettlement {
    // Phase 4: implement submitCheckpoint, verifyAttestation, getCheckpoint
    // Pending: circuit adaptation to Cairo felt252 field
    // Pending: Poseidon parameter re-derivation for StarkNet field
    // Pending: STARK verifier interface definition
}
```

### `cairo/SurDirect.cairo` — Stub Content

```cairo
// Sur Protocol — StarkNet Direct Attestation Contract (Phase 4 Stub)
// Status: NOT IMPLEMENTED — Phase 4 target
// See project-scoping/docs/ARCHITECTURE.md §7 for design intent
//
// This contract will accept individual STARK proofs for direct attestation
// submission on StarkNet, with a nullifier set preventing replay.

#[starknet::contract]
mod SurDirect {
    // Phase 4: implement submitAttestation, getAttestation, isNullifierUsed
    // Pending: Cairo felt252 nullifier encoding (different field from BN254)
    // Pending: STARK proof structure definition
}
```

### `cairo/README.md` — Content

```markdown
# Cairo / StarkNet (Phase 4)

This directory contains stub contracts for Sur Protocol's Phase 4 StarkNet settlement.

**Status: Not implemented. Phase 4 target.**

## What Phase 4 adds

- `SurSettlement.cairo` — epoch checkpoint contract on StarkNet; accepts STARK aggregate proofs
- `SurDirect.cairo` — individual attestation contract on StarkNet; maintains nullifier set

## Key technical considerations

1. **Field migration**: StarkNet uses the Stark curve's scalar field (`felt252`), not BN254. The Poseidon parameters used in the EVM contracts and gnark circuit are BN254-specific. Phase 4 requires re-deriving Poseidon parameters for the `felt252` field.
2. **No Groth16 wrapping**: StarkNet can verify STARK proofs natively, eliminating the STARK → Groth16 wrapping step needed for EVM verification. This reduces proof size and eliminates the trusted setup dependency.
3. **Cairo circuit**: The gnark Groth16 circuit (Phase 1) may need to be rewritten in a STARK-compatible proof system (e.g., Starkware's Stone prover, or SP1 with a STARK output) for native StarkNet verification.

## References

- `project-scoping/docs/ARCHITECTURE.md §7` — Phase 4 design
- `project-scoping/agents/starknet-engineer.md` — Rania Aziz's spec
- `project-scoping/agents/mathematician-researcher.md §post-quantum` — Dr. Amara Diallo's post-quantum migration analysis (STARKs are post-quantum secure)
```

### Acceptance Criteria

- [ ] `cairo/` directory exists with `README.md`, `SurSettlement.cairo`, `SurDirect.cairo`, `Scarb.toml`
- [ ] All Cairo files are clearly marked `// Status: NOT IMPLEMENTED — Phase 4 target`
- [ ] `README.md` accurately documents the technical blockers (field migration, circuit adaptation)
- [ ] `ARCHITECTURE.md §7` references the `cairo/` directory
- [ ] Sofia confirms: stubs do not overpromise on Phase 4 delivery date or capability

---

*All medium-priority tasks reviewed at quarterly protocol review, 2026-03-27.*
*These tasks are non-blocking for Phase 1 critical work. TASK-12 and TASK-13 should start in parallel with the critical stream.*
*TASK-14 executes after TASK-7 (Cosmos) and TASK-5 (L1 contracts).*
*TASK-15 can be done at any time — it is purely documentation/stubs.*
