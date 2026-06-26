# docs/INTEGRATION.md — Sur iOS Integration Contract

**Document version:** 1.0
**Date:** 2026-03-28
**Status:** Authoritative API contract for the Sur iOS wallet project

This document is the authoritative specification of every API boundary between the Sur iOS app and its two external dependencies: the Sur Chain project and the L1 Settlement project. Any change to these interfaces requires updating this document and coordinating with the respective team.

---

## 1. Overview

### Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│                    THIS REPOSITORY (iOS / Swift)                      │
│                                                                        │
│  ┌──────────────────────────────────┐   ┌────────────────────────┐    │
│  │       Sur iOS App (SwiftUI)      │   │  surcorelibs (Go FFI)  │    │
│  │                                  │   │                        │    │
│  │  Key Management (Secure Enclave) │◄──│  gnark Groth16 prover  │    │
│  │  App Attest (device registration)│   │  Poseidon BN254        │    │
│  │  HD Wallet (BIP-44 multi-chain)  │   │  ProveAttestation()    │    │
│  │  HumanTypingEvaluator            │   │  (TASK-1 FFI bridge)   │    │
│  │  ZKProofGenerator (placeholder)  │   └────────────────────────┘    │
│  │                                  │                                  │
│  │  ┌──────────────────────────┐    │   ┌────────────────────────┐    │
│  │  │ SurKeyboard Extension    │    │   │    KeystrokeSession     │    │
│  │  │ UIInputViewController    │───►│   │    ZKTypingProof        │    │
│  │  │ Keystroke capture + sign │    │   │    ZKBehavioralWitness  │    │
│  │  └──────────────────────────┘    │   └────────────────────────┘    │
│  │                                  │                                  │
│  │  ┌──────────────────────────────────────────────────────────┐     │
│  │  │              Network Clients                              │     │
│  │  │  CosmosClient  gRPC :9090 / REST :1317                   │     │
│  │  │  L1Client      read-only eth_call (JSON-RPC)             │     │
│  │  └──────────────────────┬──────────────────┬───────────────┘     │
│  └─────────────────────────┼──────────────────┼─────────────────────┘
│                             │                  │
│            COSMOS gRPC/REST │                  │ eth_call JSON-RPC
│                             ▼                  ▼
│  ┌──────────────────────┐       ┌─────────────────────────────────┐
│  │  Sur Chain Project   │       │   L1 Settlement Project         │
│  │  (separate repo)     │       │   (separate repo)               │
│  │                      │       │                                 │
│  │  x/identity module   │       │  AttestationDirect.sol          │
│  │  x/attestation module│       │  AttestationSettlement.sol      │
│  │  surd binary         │       │  SP1 batch prover (Rust)        │
│  └──────────────────────┘       └─────────────────────────────────┘
```

**Three systems, two integration boundaries:**

- **Boundary 1 (Sur iOS ↔ Sur Chain):** Cosmos gRPC and REST. The iOS app submits identity and attestation transactions and reads chain state. Specified in Section 3.

- **Boundary 2 (Sur iOS ↔ L1 Settlement):** Read-only `eth_call` JSON-RPC against deployed Solidity contracts. The iOS app reads nullifier status and attestation records. The iOS app never writes to L1 directly — that is the batch prover's job. Specified in Section 4.

---

## 2. Proof Format (BN254 Groth16)

All proofs submitted to the Sur Chain are gnark Groth16 proofs over the BN254 (alt-BN128) elliptic curve. This section defines the serialization format that Swift, Go (surcorelibs), Rust (SP1 batch prover), and Solidity (PoseidonHasher.sol) must all agree on.

### 2.1 Proof Byte Layout (256 bytes)

A Groth16 proof over BN254 consists of three elliptic curve points:
- **A**: a G1 point (x, y), each coordinate 32 bytes in BN254 Fq
- **B**: a G2 point (x0, x1, y0, y1), each coefficient 32 bytes in BN254 Fq2
- **C**: a G1 point (x, y), each coordinate 32 bytes in BN254 Fq

```
Offset  Size  Field      Description
------  ----  ---------  ---------------------------------------------------
0       32    Ax         G1 point A, x-coordinate, big-endian BN254 Fq element
32      32    Ay         G1 point A, y-coordinate, big-endian BN254 Fq element
64      32    Bx0        G2 point B, x real part, big-endian BN254 Fq element
96      32    Bx1        G2 point B, x imaginary part, big-endian BN254 Fq element
128     32    By0        G2 point B, y real part, big-endian BN254 Fq element
160     32    By1        G2 point B, y imaginary part, big-endian BN254 Fq element
192     32    Cx         G1 point C, x-coordinate, big-endian BN254 Fq element
224     32    Cy         G1 point C, y-coordinate, big-endian BN254 Fq element
------  ----
Total   256   bytes
```

This layout matches gnark's `backend/groth16/bn254.Proof.WriteTo()` output. It also matches the EIP-197 precompile convention used on Ethereum, making proof verification in Solidity straightforward.

**BN254 field modulus (Fq):**
`0x30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47`

**BN254 scalar field modulus (Fr):**
`0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001`

All field elements must satisfy `0 <= element < modulus`. Proofs with field elements outside this range must be rejected as malformed.

### 2.2 Public Inputs Layout (5 x 32-byte BN254 Fr elements, 160 bytes)

Public inputs are BN254 scalar field elements (Fr), each 32 bytes, big-endian. They are transmitted alongside the proof bytes as a separate structure.

```
Index  Offset  Field              Description
-----  ------  -----------------  -----------------------------------------
0      0       username_hash      Poseidon(username_bytes_as_field_elements)
1      32      content_hash_lo    Low 128 bits of Poseidon(content)
2      64      content_hash_hi    High 128 bits of Poseidon(content)
3      96      nullifier          Poseidon(device_pubkey_x, device_pubkey_y, session_counter)
4      128     commitment_root    Root of device commitment Merkle tree (Poseidon leaves)
-----  ------
Total  160     bytes
```

**username_hash** binds the proof to a specific registered username. Computed by the gnark circuit over the UTF-8 bytes of the username, treated as field elements.

**content_hash_lo / content_hash_hi** bind the proof to the attested content. The split into two 128-bit values avoids SHA-256's 256-bit output exceeding the BN254 Fr modulus (254 bits). The circuit verifies that `content_hash_lo || content_hash_hi` reconstructs the correct SHA-256 hash of the session content.

**nullifier** is `Poseidon(device_pubkey_x, device_pubkey_y, session_counter)`. It is unique per device-session combination and is stored permanently in the chain's nullifier set after first use. Replay attacks are prevented at the chain level by checking this set before proof verification.

**commitment_root** is the Merkle root of the user's device commitment tree at the time of proof generation. The tree uses Poseidon hashing at depth 8 (up to 256 devices per user). The circuit proves that a device commitment `Poseidon(device_pubkey_x, device_pubkey_y, blinding_factor)` is included in this root via a Merkle path, without revealing which device.

### 2.3 Encoding Conventions

- All multi-byte integers and field elements are **big-endian**.
- Hex strings are prefixed with `0x` and use lowercase hex digits.
- Proof bytes and public inputs are transmitted as `bytes` (raw binary) in protobuf messages and as `0x`-prefixed hex strings in JSON.
- No base64 encoding is used at any interface boundary in this system.

---

## 3. Sur Chain Integration

The iOS app communicates with the Sur Chain via standard Cosmos SDK RPC endpoints.

### 3.1 Endpoint Base URL Convention

```
gRPC:             {COSMOS_GRPC_HOST}:9090
REST (gRPC-GW):   {COSMOS_REST_HOST}:1317
Tendermint RPC:   {COSMOS_TENDERMINT_HOST}:26657
```

**Environment-specific base URLs:**

| Environment | gRPC | REST |
|---|---|---|
| Local development | `localhost:9090` | `http://localhost:1317` |
| Devnet | `grpc.devnet.surprotocol.xyz:9090` | `https://rest.devnet.surprotocol.xyz` |
| Testnet | `grpc.testnet.surprotocol.xyz:9090` | `https://rest.testnet.surprotocol.xyz` |
| Mainnet | TBD | TBD |

The iOS app resolves the active environment via `CosmosClient.activeEnvironment` and uses the corresponding base URLs. Switching environments requires re-registering the device (commitments are chain-specific).

### 3.2 MsgRegisterUsername

Register a new username and the first device commitment. This is the first transaction a new user sends; it creates their identity on-chain.

**Protobuf message:**
```protobuf
message MsgRegisterUsername {
    string username         = 1;  // 3–32 chars, pattern: ^[a-z0-9_-]+$
    bytes  control_pubkey   = 2;  // 65 bytes: uncompressed P-256 public key (0x04 || X || Y)
    bytes  first_commitment = 3;  // 32 bytes: Poseidon(device_pubkey_x, device_pubkey_y, blinding_factor)
    bytes  identity_sig     = 4;  // ECDSA P-256 signature over payload
    bytes  payload          = 5;  // SHA-256(username || SHA-256(control_pubkey) || first_commitment
                                  //          || chain_id || block_height)
                                  // block_height must be within the last 100 blocks
}
```

**REST endpoint:**
```
POST /cosmos/tx/v1beta1/txs
```

**Body (JSON):**
```json
{
  "tx": {
    "body": {
      "messages": [{
        "@type": "/surprotocol.identity.v1.MsgRegisterUsername",
        "username": "alice",
        "control_pubkey": "0x04...",
        "first_commitment": "0x...",
        "identity_sig": "0x...",
        "payload": "0x..."
      }],
      "memo": "",
      "timeout_height": "0"
    },
    "auth_info": {
      "signer_infos": [...],
      "fee": { "amount": [{"denom": "usur", "amount": "1005000"}], "gas_limit": "100000" }
    },
    "signatures": [...]
  },
  "mode": "BROADCAST_MODE_SYNC"
}
```

**Fee:** Registration fee (default 1,000,000 usur = 1 SUR) + gas fee (~80,000 gas * 0.025 usur/gas ≈ 2,000 usur). Total typical fee: ~1,002,000 usur.

**Successful response:**
```json
{
  "tx_response": {
    "height": "12345",
    "txhash": "ABCDEF...",
    "code": 0,
    "raw_log": "[]",
    "logs": [{"events": [{"type": "EventUsernameRegistered", "attributes": [...]}]}]
  }
}
```

**App Attest object format**: The `first_commitment` must be computed as `Poseidon(device_pubkey_x, device_pubkey_y, blinding_factor)` where:
- `device_pubkey_x`, `device_pubkey_y` are the P-256 Secure Enclave key coordinates, each encoded as a BN254 field element using the two-limb encoding specified in Section 6
- `blinding_factor` is a 32-byte random value generated at device setup and stored in the Keychain

**Error codes (from chain):**
```
ErrUsernameTaken      (1001): username already registered
ErrInvalidUsername    (1002): username format invalid (not ^[a-z0-9_-]+$)
ErrInvalidPubkey      (1003): control_pubkey not a valid P-256 point
ErrInvalidSignature   (1004): identity_sig failed ECDSA P-256 verification
ErrStalePayload       (1005): payload.block_height not within last 100 blocks
ErrInvalidCommitment  (1006): first_commitment is 32 zero bytes
```

### 3.3 MsgAddDevice

Add a second (or subsequent) device commitment to an existing username. This allows a user registered on one device to attest from a second device without re-registering their username.

**Protobuf message:**
```protobuf
message MsgAddDevice {
    string username        = 1;
    bytes  new_commitment  = 2;  // 32 bytes: Poseidon(new_device_pubkey_x, new_device_pubkey_y, new_blinding_factor)
    bytes  control_pubkey  = 3;  // 65 bytes: uncompressed P-256, must hash to stored control_key_hash
    bytes  identity_sig    = 4;  // ECDSA P-256 signature over payload
    bytes  payload         = 5;  // SHA-256(username || new_commitment || "add" || chain_id || block_height)
}
```

**App Attest object format**: The new device performs App Attest key registration before submitting this message. The App Attest attestation object (`DCAppAttestService.attestKey`) is stored off-chain by the app; only the commitment (a Poseidon hash of the new device's public key and blinding factor) is sent on-chain.

**REST endpoint:** `POST /cosmos/tx/v1beta1/txs` (same structure as MsgRegisterUsername, different `@type`).

**Fee:** Add-device fee (default 100,000 usur = 0.1 SUR) + gas fee.

**Error codes:**
```
ErrUnknownUsername    (1007): username not registered
ErrInvalidPubkey      (1003): control_pubkey doesn't match stored hash
ErrInvalidSignature   (1004): identity_sig verification failed
ErrDuplicateDevice    (1008): new_commitment already in active device set
ErrMaxDevicesReached  (1009): user already has 256 active devices
```

### 3.4 MsgSubmitAttestation

Submit a gnark Groth16 proof of a human-typed session. This is the primary transaction that the keyboard extension's proof eventually reaches.

**Protobuf message:**
```protobuf
message MsgSubmitAttestation {
    string username           = 1;  // Must be registered in x/identity
    bytes  content_hash       = 2;  // 32 bytes: SHA-256(attested_content_utf8)
    bytes  nullifier          = 3;  // 32 bytes: Poseidon(device_pubkey_x, device_pubkey_y, session_counter)
    bytes  proof              = 4;  // 256 bytes: gnark Groth16 proof (see Section 2.1)
    bytes  commitment_root    = 5;  // 32 bytes: commitment root at time of proof generation
    int64  proof_block_height = 6;  // Cosmos block height when commitment_root was queried
}
```

**Public inputs vector** (derived by chain from the message fields, not transmitted separately):
```
[username_hash, content_hash_lo, content_hash_hi, nullifier, commitment_root]
```
The chain reconstructs `username_hash = Poseidon(username_bytes)` and splits `content_hash` into lo/hi halves to form the public inputs vector used in Groth16 verification.

**REST endpoint:** `POST /cosmos/tx/v1beta1/txs`

**Fee:** ~100,000 gas * 0.025 usur/gas ≈ 2,500 usur (no module-level fee beyond gas).

**Proof byte encoding in JSON:** Hex-encoded with `0x` prefix.

**Processing sequence on chain (from `x/attestation`):**
1. Freshness check: `proof_block_height` within `[current_height - 100, current_height]`
2. Nullifier check: nullifier not already in NullifierSet
3. Username check: username exists in `x/identity`
4. Commitment root check: `commitment_root` matches stored root at `proof_block_height`
5. ZK proof verification: gnark Groth16 verify with stored verification key
6. Store: add nullifier to NullifierSet, create AttestationRecord, emit event

**Error codes:**
```
ErrStaleProof           (2001): proof_block_height too old (> 100 blocks)
ErrNullifierAlreadyUsed (2002): this session already attested
ErrUnknownUsername      (2003): username not registered
ErrInvalidCommitmentRoot(2004): root doesn't match stored root at that height
ErrInvalidProof         (2005): gnark Groth16 verification failed
ErrInvalidContentHash   (2006): content_hash is 32 zero bytes
ErrInvalidNullifier     (2007): nullifier is 32 zero bytes
```

### 3.5 Read Endpoints

All read endpoints are available via REST (gRPC-gateway). The iOS app uses these for pre-proof queries and for the keystroke log history UI.

**Get user profile:**
```
GET /cosmos/identity/v1/user/{username}

Response:
{
  "found": true,
  "username": "alice",
  "commitment_root": "0x...",  // 32 bytes hex — needed before generating ZK proof
  "device_count": 2,
  "registered_at": 1709900000
}
```

**Get device commitments (for Merkle path construction):**
```
GET /cosmos/identity/v1/commitments/{username}

Response:
{
  "commitments": [
    {"index": 0, "commitment": "0x...", "active": true},
    {"index": 1, "commitment": "0x...", "active": true}
  ],
  "commitment_root": "0x..."
}
```

**Get commitment root at a specific block height (required before proof generation):**
```
GET /cosmos/identity/v1/commitment_root/{username}?block_height={height}

Response:
{
  "commitment_root": "0x...",
  "block_height": 12345,
  "block_hash": "0x..."
}
```
The iOS app fetches this immediately before calling `ProveAttestation` in surcorelibs. The `block_height` value is included in `MsgSubmitAttestation.proof_block_height`.

**Verify an attestation:**
```
GET /cosmos/attestation/v1/attestation/{username}/{content_hash_hex}

Response:
{
  "attested": true,
  "username": "alice",
  "content_hash": "0x...",
  "timestamp": 1709900000,
  "block_height": 12346
}
```

**List user's attestations:**
```
GET /cosmos/attestation/v1/attestations/{username}?limit=20&offset=0

Response:
{
  "attestations": [
    {"content_hash": "0x...", "timestamp": 1709900000, "block_height": 12346},
    ...
  ],
  "total": 47
}
```

**Get Merkle proof for L1 verification:**
```
GET /cosmos/attestation/v1/merkle_proof/{username}/{content_hash_hex}/{epoch_id}

Response:
{
  "found": true,
  "leaf_hash": "0x...",
  "path": ["0x...", "0x..."],
  "path_indices": [false, true],
  "epoch_root": "0x..."
}
```

### 3.6 Error Codes

All Cosmos SDK error responses follow this format:

```json
{
  "code": 1004,
  "message": "invalid signature: ECDSA P-256 verification failed",
  "details": []
}
```

HTTP status codes:
- `200 OK`: transaction broadcast accepted (does not mean tx succeeded — check `tx_response.code`)
- `400 Bad Request`: malformed request body
- `404 Not Found`: queried resource does not exist
- `500 Internal Server Error`: node error; retry with exponential backoff

Transaction result codes (`tx_response.code`):
- `0`: success
- Non-zero: failure; `raw_log` contains the error string

The iOS app should surface Cosmos error codes to the user only at a high level. The specific error codes in §3.2–§3.4 are used internally by `CosmosClient.swift` to present actionable error messages (e.g., error 1001 → "This username is already taken").

---

## 4. L1 Settlement Integration

The iOS app is a **read-only client** of the L1 settlement contracts. It uses `eth_call` (no gas, no transaction signing) to read nullifier status and attestation records. It never submits proofs directly to L1.

### 4.1 Contract Addresses

Contract addresses are populated after deployment. Until deployed, use the placeholder values below.

| Network | AttestationDirect | AttestationSettlement |
|---|---|---|
| Ethereum Mainnet | TBD | TBD |
| Ethereum Sepolia (testnet) | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` |
| Base Mainnet | TBD | TBD |
| Base Sepolia (testnet) | `0x0000000000000000000000000000000000000000` | `0x0000000000000000000000000000000000000000` |

Contract addresses are configured in `L1Client.swift` via environment-specific constants. A chain upgrade that redeploys contracts requires an app update to publish new addresses — there is no on-chain registry used by the iOS app.

### 4.2 isNullifierUsed(bytes32)

Check whether a nullifier has been used on the L1 `AttestationDirect` contract. The iOS app uses this to verify final L1 settlement status for high-stakes attestations submitted directly to L1 (rather than via the Cosmos batch path).

**Function signature:**
```solidity
function isNullifierUsed(bytes32 nullifier) external view returns (bool)
```

**ABI encoding for eth_call:**
```
Function selector: keccak256("isNullifierUsed(bytes32)")[0:4]
                 = 0x1e6d2e59

Call data: 0x1e6d2e59
           {nullifier_32_bytes_zero_padded}

Example (nullifier = 0xabc...):
  data: 0x1e6d2e59abc1234...0000  (function selector + 32-byte nullifier)
```

**eth_call JSON-RPC:**
```json
{
  "jsonrpc": "2.0",
  "method": "eth_call",
  "params": [
    {
      "to": "0x{ATTESTATION_DIRECT_ADDRESS}",
      "data": "0x1e6d2e59{nullifier_hex_32_bytes}"
    },
    "latest"
  ],
  "id": 1
}
```

**Response decoding:**
```
Result: "0x{32_bytes_ABI_encoded_bool}"
        "0x0000000000000000000000000000000000000000000000000000000000000000" → false (not used)
        "0x0000000000000000000000000000000000000000000000000000000000000001" → true (used)
```

**Swift decoding:**
```swift
// L1Client.swift
let resultHex = response.result  // "0x0000...0001"
let isUsed = resultHex.hasSuffix("1")
```

### 4.3 getAttestation(bytes32)

Retrieve an on-chain attestation record from `AttestationDirect`. Returns null struct if the attestation does not exist.

**Function signature:**
```solidity
function getAttestation(bytes32 nullifier) external view returns (
    bool exists,
    bytes32 usernameHash,
    bytes32 contentHashLo,
    bytes32 contentHashHi,
    uint256 timestamp,
    uint256 blockNumber
)
```

**Function selector:** `keccak256("getAttestation(bytes32)")[0:4]`

**Return struct layout (ABI-decoded, 6 values):**
```
Offset  Size  Type     Field
0       32    bool     exists (1 = attested, 0 = not found)
32      32    bytes32  usernameHash
64      32    bytes32  contentHashLo
96      32    bytes32  contentHashHi
128     32    uint256  timestamp (Unix seconds)
160     32    uint256  blockNumber
```

Total return bytes: 192.

**Swift decoding:**
```swift
// L1Client.swift
struct L1Attestation {
    let exists: Bool
    let usernameHash: Data      // 32 bytes
    let contentHashLo: Data     // 32 bytes
    let contentHashHi: Data     // 32 bytes
    let timestamp: UInt64       // Unix seconds
    let blockNumber: UInt64
}

func decodeGetAttestation(_ hex: String) -> L1Attestation {
    let bytes = Data(hex: hex)
    return L1Attestation(
        exists: bytes[31] == 1,
        usernameHash: bytes[32..<64],
        contentHashLo: bytes[64..<96],
        contentHashHi: bytes[96..<128],
        timestamp: UInt64(bigEndianBytes: bytes[152..<160]),
        blockNumber: UInt64(bigEndianBytes: bytes[184..<192])
    )
}
```

### 4.4 getCheckpoint(uint256)

Retrieve an epoch checkpoint from `AttestationSettlement`. The iOS app uses this to display L1 settlement status in the attestation history view — whether a specific epoch has been finalized to L1.

**Function signature:**
```solidity
function getCheckpoint(uint256 epochId) external view returns (
    bool exists,
    bytes32 stateRoot,
    uint256 timestamp,
    uint256 batchSize,
    bool l1Settled
)
```

**Function selector:** `keccak256("getCheckpoint(uint256)")[0:4]`

**Return struct layout (5 values, 160 bytes):**
```
Offset  Size  Type     Field
0       32    bool     exists
32      32    bytes32  stateRoot (Poseidon Merkle root of all epoch attestations)
64      32    uint256  timestamp (when epoch was finalized)
96      32    uint256  batchSize (number of attestations in epoch)
128     32    bool     l1Settled (whether SP1 proof has been accepted by this contract)
```

**eth_call JSON-RPC:**
```json
{
  "jsonrpc": "2.0",
  "method": "eth_call",
  "params": [
    {
      "to": "0x{ATTESTATION_SETTLEMENT_ADDRESS}",
      "data": "0x{selector}{epoch_id_32_bytes_big_endian}"
    },
    "latest"
  ],
  "id": 1
}
```

### 4.5 eth_call JSON-RPC Format

All L1 reads use the standard `eth_call` JSON-RPC method. The iOS app sends HTTP POST requests to the configured Ethereum RPC endpoint.

**Full request format:**
```json
{
  "jsonrpc": "2.0",
  "method": "eth_call",
  "params": [
    {
      "to": "0x{contract_address}",
      "data": "0x{function_selector_4_bytes}{abi_encoded_arguments}"
    },
    "latest"
  ],
  "id": {request_id}
}
```

**RPC endpoint configuration (L1Client.swift):**
```swift
enum L1Network {
    case ethereumSepolia
    case baseSepolia
    case ethereumMainnet
    case baseMainnet

    var rpcURL: URL {
        switch self {
        case .ethereumSepolia:
            return URL(string: ProcessInfo.processInfo.environment["ETH_RPC_URL"]
                ?? "https://sepolia.infura.io/v3/YOUR_KEY")!
        // ...
        }
    }
}
```

**Error handling:** `eth_call` returns HTTP 200 even for contract reverts. The `error` field in the JSON response indicates a revert or RPC error:
```json
{"jsonrpc": "2.0", "error": {"code": -32000, "message": "execution reverted"}, "id": 1}
```
The iOS app maps all non-null `error` responses to `L1ClientError.rpcError(String)` and surfaces them as "L1 read failed" in the UI without retrying automatically.

---

## 5. Poseidon Test Vector (Cross-Platform Consistency Gate)

All systems that compute Poseidon hashes must agree exactly. The following test vector is the canonical consistency check:

```
Input:   Poseidon([1, 2])
         (two BN254 Fr field elements: 0x01 and 0x02)

Expected output:
  0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a

Parameters:
  Curve:          BN254 (alt-BN128)
  Field:          Fr (scalar field, modulus = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001)
  Rate:           2 (two field elements per permutation call)
  Capacity:       1
  Full rounds:    8
  Partial rounds: 57
  S-box:          x^5
  MDS matrix:     standard BN254 Poseidon MDS from https://github.com/iden3/circomlib
```

**This value must match in all of these implementations:**

| System | File | Function |
|---|---|---|
| Go (surcorelibs) | `surcorelibs/poseidon/poseidon.go` | `Hash([]fr.Element{one, two})` |
| Rust (SP1 batch prover) | `sp1_batch_program/src/poseidon.rs` | `poseidon_hash(&[Fr::one(), Fr::from(2)])` |
| Solidity | `PoseidonHasher.sol` | `poseidon([1, 2])` |
| Swift (surcorelibs FFI) | `surcorelibs/bridge.go` | Called via `PoseidonHash` CGo export |

**Test procedure**: During CI, each implementation runs `Poseidon([1, 2])` and asserts the output equals `0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a`. A mismatch in any implementation means that commitment, nullifier, and Merkle root computations will diverge, producing proofs that fail on-chain verification.

If the Poseidon implementation is updated (e.g., to use different round constants), this test vector must be recomputed and updated in all implementations simultaneously. A circuit that uses the old constants cannot verify proofs generated with new constants — a new trusted setup is required.

---

## 6. ProverInput / ProofOutput Schema

This section specifies the JSON schema for the interface between the Swift app layer and the Go FFI bridge in `surcorelibs`. This interface will be active once TASK-1 (gnark FFI bridge) is complete. Until then, `ZKProofGenerator.swift` produces placeholder proofs.

### 6.1 ProverInput (Swift → Go FFI)

The Swift app assembles a `ProverInput` struct from the completed keystroke session, the queried commitment root and Merkle path, and the device keys. It serializes this to JSON and passes it to `ProveAttestation` via the CGo bridge.

```json
{
  "username_hash": "0x...",
  "content_hash_lo": "0x...",
  "content_hash_hi": "0x...",
  "device_pubkey_x": "0x...",
  "device_pubkey_y": "0x...",
  "session_counter": 42,
  "blinding_factor": "0x...",
  "commitment_root": "0x...",
  "merkle_path": ["0x...", "0x...", "0x...", "0x...", "0x...", "0x...", "0x...", "0x..."],
  "merkle_directions": [0, 1, 0, 0, 1, 1, 0, 1],
  "se_signature_r": "0x...",
  "se_signature_s": "0x...",
  "human_score": 74,
  "iki_values_ms": [120, 95, 180, 210, 88, 143, 167, 92, 201, 115],
  "keystroke_count": 45
}
```

**Field descriptions:**

| Field | Type | Description |
|---|---|---|
| `username_hash` | `"0x" + 32 bytes hex` | `Poseidon(username_utf8_bytes)`, computed in Go |
| `content_hash_lo` | `"0x" + 16 bytes hex` | Low 128 bits of SHA-256(content) |
| `content_hash_hi` | `"0x" + 16 bytes hex` | High 128 bits of SHA-256(content) |
| `device_pubkey_x` | `"0x" + 32 bytes hex` | P-256 Secure Enclave public key X coordinate, big-endian |
| `device_pubkey_y` | `"0x" + 32 bytes hex` | P-256 Secure Enclave public key Y coordinate, big-endian |
| `session_counter` | `uint64` | Monotonically increasing, stored in Keychain; incremented after each proof |
| `blinding_factor` | `"0x" + 32 bytes hex` | Random 32 bytes generated at device registration, stored in Keychain |
| `commitment_root` | `"0x" + 32 bytes hex` | Poseidon Merkle root queried from Cosmos before proof generation |
| `merkle_path` | `["0x..." × 8]` | Sibling hashes at each level of the Merkle tree, bottom-up |
| `merkle_directions` | `[0|1 × 8]` | 0 = sibling is left child, 1 = sibling is right child |
| `se_signature_r` | `"0x" + 32 bytes hex` | P-256 ECDSA signature R component over SHA-256(session_data) |
| `se_signature_s` | `"0x" + 32 bytes hex` | P-256 ECDSA signature S component, low-S normalized |
| `human_score` | `uint8 in [0, 100]` | Output of `HumanTypingEvaluator.evaluate()`, must be >= 50 |
| `iki_values_ms` | `[uint32]` | All inter-keystroke intervals in milliseconds, in order |
| `keystroke_count` | `uint32` | Total number of keystrokes in session, must be >= 10 |

**Constraints enforced by the circuit** (not just the Swift layer):
- `human_score >= 50` — hard constraint; proof generation fails if not satisfied
- All `iki_values_ms[i] >= 20` (MinMeanIKIms in circuit)
- `keystroke_count >= 10`
- `merkle_path.length == 8` (fixed tree depth)
- `merkle_directions.length == 8`

**P-256 → BN254 two-limb encoding**: P-256 coordinates are 256-bit values. BN254 Fr is 254 bits. The gnark circuit uses emulated field arithmetic (`sw_emulated`) to handle P-256 arithmetic natively inside the BN254 circuit. The iOS app passes raw big-endian P-256 coordinates; the FFI bridge encodes them as pairs of BN254 Fr elements internally. The Swift layer does not perform this encoding.

### 6.2 ProofOutput (Go FFI → Swift)

```json
{
  "proof_bytes": "0x...",
  "public_inputs": {
    "username_hash": "0x...",
    "content_hash_lo": "0x...",
    "content_hash_hi": "0x...",
    "nullifier": "0x...",
    "commitment_root": "0x..."
  },
  "proving_time_ms": 4823,
  "error": null
}
```

| Field | Type | Description |
|---|---|---|
| `proof_bytes` | `"0x" + 256 bytes hex` | Raw Groth16 proof bytes per Section 2.1 |
| `public_inputs.username_hash` | `"0x" + 32 bytes hex` | BN254 Fr element |
| `public_inputs.content_hash_lo` | `"0x" + 32 bytes hex` | BN254 Fr element |
| `public_inputs.content_hash_hi` | `"0x" + 32 bytes hex` | BN254 Fr element |
| `public_inputs.nullifier` | `"0x" + 32 bytes hex` | BN254 Fr element = Poseidon(pk_x, pk_y, counter) |
| `public_inputs.commitment_root` | `"0x" + 32 bytes hex` | BN254 Fr element |
| `proving_time_ms` | `uint32` | Wall-clock proving time for telemetry |
| `error` | `string or null` | Non-null if proof generation failed; contains error message |

On error, `proof_bytes` and `public_inputs` are absent. The Swift caller must check `error != null` before accessing proof fields.

**Swift mapping**: `ProofOutput` maps directly to `ZKTypingProof` in `KeystrokeLog.swift`:
```swift
// Sur/Auth/KeystrokeLog.swift
let zkProof = ZKTypingProof(
    version: "2.0.0",
    commitment: proofOutput.proof_bytes,   // the full 256-byte Groth16 proof
    nullifier: proofOutput.public_inputs.nullifier,
    proof: proofOutput.proof_bytes,
    publicInputs: ZKPublicInputs(
        usernameHash: proofOutput.public_inputs.username_hash,
        contentHashLo: proofOutput.public_inputs.content_hash_lo,
        contentHashHi: proofOutput.public_inputs.content_hash_hi,
        nullifier: proofOutput.public_inputs.nullifier,
        commitmentRoot: proofOutput.public_inputs.commitment_root
    ),
    generatedAt: Int64(Date().timeIntervalSince1970 * 1000)
)
```

---

## 7. Error Propagation

How errors from external systems surface in the iOS UI:

```
Chain error (gRPC/REST)
    ↓
CosmosClient.swift: maps tx_response.code and HTTP errors to CosmosClientError
    ↓
AuthenticationManager.swift: receives CosmosClientError, maps to user-facing AttestationError
    ↓
SwiftUI view: displays localized error string to user

L1 read error (eth_call)
    ↓
L1Client.swift: maps JSON-RPC error to L1ClientError
    ↓
AttestationHistoryViewModel.swift: receives L1ClientError, displays "L1 status unavailable"
    (L1 read failures are non-blocking; Sur Chain attestation is the primary record)
```

**Error severity classification:**

| Error | User-visible message | App behavior |
|---|---|---|
| `ErrUsernameTaken` | "This username is already taken. Try another." | Prompt for new username |
| `ErrInvalidProof` | "Proof verification failed. Please try again." | Retry once; if repeated, escalate |
| `ErrNullifierAlreadyUsed` | "This session has already been submitted." | Inform user; no retry |
| `ErrStaleProof` | "The proof expired before submission. Generating a new one..." | Auto-retry proof generation |
| L1 RPC error | "L1 status unavailable" | Non-blocking; Sur Chain status shown instead |
| `ProofOutput.error != null` | "Proof generation failed. Please try again." | Retry once |

**Retry policy for transient errors**: Network errors (HTTP 5xx, gRPC Unavailable) are retried with exponential backoff: 1 s, 2 s, 4 s, 8 s (max 3 retries). Application-level errors (proof invalid, nullifier used) are not retried — they indicate a state problem that retrying cannot fix.

---

## 8. Version Compatibility

### 8.1 Circuit Version Compatibility

The gnark Groth16 verifying key is stored on-chain in `x/attestation` params as `verification_key_hash`. A proof generated by an iOS app version using circuit version N cannot be verified by a chain running circuit version M where N ≠ M.

**Migration procedure for circuit upgrades:**
1. New circuit is compiled and MPC ceremony is run (separate repository)
2. New verifying key is proposed via governance vote on Sur Chain
3. After governance approval, `verification_key_hash` is updated in chain state
4. iOS app is updated to use the new verification key embedded in surcorelibs
5. Apps running old circuit version will have their proofs rejected after the governance change takes effect (the chain transitions at a specific block height)
6. Old proofs submitted before the transition block remain valid in historical state

### 8.2 API Version Compatibility

Cosmos REST endpoints are versioned at `/v1/`. If a breaking change is required, a `/v2/` path is added. The iOS app must support at least the current and previous API version during the transition period.

L1 contract ABI changes require a contract upgrade (proxy pattern or new deployment). ABI changes are coordinated with an iOS app update that updates the function selectors and return type decoders in `L1Client.swift`.

### 8.3 Minimum Supported Chain Version

The iOS app declares a minimum supported chain version in `CosmosClient.swift`. On connection, the app queries the chain's software version via:
```
GET /cosmos/base/node/v1beta1/config
```
If the chain version is below the minimum, the app displays an error: "The Sur network is being upgraded. Please try again later."
