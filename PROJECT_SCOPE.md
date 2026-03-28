# Sur Protocol — Mobile Wallet Project Scope

## What This Project Is

This repository is the **iOS mobile wallet application** for Sur Protocol. It is the user-facing product: a Swift iOS app with a keyboard extension that captures keystroke sessions, generates zero-knowledge attestation proofs, manages cryptographic keys, and submits attestations to the Sur Protocol network.

This project **calls** external services — it does not build them.

---

## This Project Owns

| Component | Description | Primary Files |
|---|---|---|
| **iOS App** | SwiftUI app: wallet, account management, keystroke log history, proof UI | `Sur/` |
| **Keyboard Extension** | `UIInputViewController` that captures timing, signs session bundles | `SurKeyboard/` |
| **ZK Proof FFI** | Go static library (gnark Groth16) compiled for iOS; Swift calls `ProveAttestation` | `surcorelibs/` |
| **Key Management** | Secure Enclave key generation, App Attest, Keychain storage, BIP-44 HD wallet | `Sur/Auth/` |
| **Cosmos Client** | Swift gRPC/REST client that calls the Sur Chain project's endpoints | `Sur/Network/CosmosClient.swift` |
| **L1 Read Client** | Swift client that reads attestation status from deployed L1 contracts (read-only) | `Sur/Network/L1Client.swift` |
| **Typing Evaluator** | Behavioral biometric scoring — enforced as ZK circuit constraints | `Sur/Auth/HumanTypingEvaluator.swift` |

---

## External Projects This App Calls

### 1. Sur Chain Project (Cosmos chain — separate repository)

The Sur Chain project owns and operates the Cosmos SDK chain with `x/identity`, `x/attestation`, and `x/payment` modules. This app is a **client** of that chain.

**What this app sends to Sur Chain:**
- `MsgRegisterUsername` — register a username with an identity key
- `MsgAddDevice` — register a device with App Attest object + device commitment
- `MsgSubmitAttestation` — submit a gnark Groth16 proof for an attested session

**What this app reads from Sur Chain (via gRPC/REST):**
- `QueryGetUser` — fetch user profile and device commitment root
- `QueryGetAttestation` — look up a specific attestation record
- `QueryListAttestationsByUser` — fetch keystroke log history
- `QueryGetMerkleProof` — get Merkle inclusion proof for device commitment

**Integration contract:** See `docs/INTEGRATION.md` §1 for endpoint definitions, proto message formats, and error handling.

**Dependency note:** This app cannot perform device registration or attestation submission without the Sur Chain running. For local development, a local `surd` node must be available (see `docs/INTEGRATION.md §Development Setup`).

---

### 2. L1 Settlement Project (Solidity contracts — separate repository)

The L1 Settlement project owns `AttestationSettlement.sol`, `AttestationDirect.sol`, and the SP1 batch prover. This app is a **read-only client** of those contracts.

**What this app reads from L1:**
- `AttestationDirect.isNullifierUsed(bytes32)` — check if a nullifier has been used on-chain
- `AttestationDirect.getAttestation(bytes32)` — retrieve on-chain attestation record
- `AttestationSettlement.getCheckpoint(uint256)` — fetch epoch state root

**What this app does NOT do:**
- Deploy or upgrade any Solidity contracts
- Submit proofs directly to L1 (that is the batch prover's job, in the Sur Chain project)
- Manage gas or Ethereum wallets for contract interaction (read-only calls only)

**Integration contract:** See `docs/INTEGRATION.md` §2 for ABI fragments and contract addresses per network.

---

### 3. Developer SDK Project (separate repository — future)

The TypeScript SDK (`@surprotocol/sdk`), verification web app, and CLI tool are out of scope for this repository. That project will be created separately and will call this app's Cosmos chain endpoints.

---

## What This Project Does NOT Build

| Component | Owner | Why Excluded |
|---|---|---|
| Cosmos SDK modules (`x/identity`, `x/attestation`, `x/payment`) | Sur Chain project | Backend infrastructure — separate repository, separate team |
| SP1 Rust batch prover | Sur Chain project | Backend prover pipeline — no mobile dependency |
| `AttestationSettlement.sol`, `AttestationDirect.sol` | L1 Settlement project | Smart contracts — separate repository |
| TypeScript SDK, verification web app | Developer SDK project | Developer tooling — separate repository |
| StarkNet integration | Future project | Phase 4 — not started |
| Cosmos validator / infrastructure | Sur Chain project | DevOps — separate repository |

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────┐
│                THIS REPOSITORY (iOS)                     │
│                                                         │
│  ┌──────────────┐   ┌──────────────┐  ┌─────────────┐  │
│  │  Sur iOS App │   │ SurKeyboard  │  │ surcorelibs │  │
│  │  (SwiftUI)   │◄──│  Extension   │  │ (gnark FFI) │  │
│  │              │   │              │  │             │  │
│  │ Key Mgmt     │   │ Keystroke    │  │ Groth16     │  │
│  │ App Attest   │   │ Capture      │  │ Poseidon    │  │
│  │ HD Wallet    │   │ SE Signing   │  │ FFI Bridge  │  │
│  └──────┬───────┘   └──────────────┘  └─────────────┘  │
│         │                                               │
│  ┌──────▼──────────────────────────────┐               │
│  │          Network Clients            │               │
│  │  CosmosClient (gRPC/REST)           │               │
│  │  L1Client (read-only eth_call)      │               │
│  └──────┬─────────────────┬────────────┘               │
└─────────┼─────────────────┼─────────────────────────── ┘
          │                 │
          ▼                 ▼
┌─────────────────┐  ┌──────────────────────────┐
│  Sur Chain      │  │  L1 Settlement Project    │
│  (separate repo)│  │  (separate repo)          │
│                 │  │                          │
│  x/identity     │  │  AttestationSettlement   │
│  x/attestation  │  │  AttestationDirect       │
│  x/payment      │  │  SP1 Batch Prover        │
│  surd binary    │  │                          │
└─────────────────┘  └──────────────────────────┘
```

---

## Development Quickstart

### What you need running locally to develop this app

1. **A Sur Chain node** (from the Sur Chain project) or a testnet endpoint:
   ```
   COSMOS_GRPC=localhost:9090
   COSMOS_REST=http://localhost:1317
   ```

2. **Xcode 15.4+** with iOS 17+ simulator

3. **Go 1.22+** (to build `surcorelibs` via `make xcframework`)

4. **A testnet RPC** for L1 reads (Ethereum Sepolia or Base Sepolia):
   ```
   ETH_RPC_URL=https://sepolia.infura.io/v3/...
   ATTESTATION_DIRECT_ADDRESS=0x...  (from L1 Settlement project)
   ```

See `docs/INTEGRATION.md` for full setup instructions.

---

## Key Documentation

| File | Purpose |
|---|---|
| `docs/INTEGRATION.md` | API contracts with Sur Chain and L1 Settlement projects |
| `PROOF_CRYPTOGRAPHY.md` | Current proof format (being updated by TASK-1, TASK-2) |
| `project-scoping/docs/KEY_MANAGEMENT.md` | Four-key architecture the iOS app implements |
| `project-scoping/docs/IOS_KEYBOARD.md` | Keyboard extension signing specification |
| `project-scoping/docs/ZK_CIRCUIT.md` | gnark Groth16 circuit spec (implemented in surcorelibs/) |
| `tasks/REVIEW.md` | Team protocol compliance review — all findings |
| `tasks/TASKS-CRITICAL.md` | Blocking security and correctness fixes |
| `tasks/TASKS-HIGH.md` | Required features: iOS integration points |
| `tasks/TASKS-MEDIUM.md` | CI/CD, documentation, threshold analysis |
