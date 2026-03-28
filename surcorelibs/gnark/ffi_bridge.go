package gnark

import (
"bytes"
"encoding/json"
"fmt"
"math/big"

"github.com/consensys/gnark-crypto/ecc"
bn254mimc "github.com/consensys/gnark-crypto/ecc/bn254/fr/mimc"
"github.com/consensys/gnark/backend/groth16"
"github.com/consensys/gnark/constraint"
"github.com/consensys/gnark/frontend"
"github.com/consensys/gnark/frontend/cs/r1cs"
)

// ProverInput is the JSON schema for the FFI bridge.
// This matches the interface contract documented in TASK-1.
type ProverInput struct {
UsernameHash   string   `json:"username_hash"`
ContentHashLo  string   `json:"content_hash_lo"`
ContentHashHi  string   `json:"content_hash_hi"`
DevicePubkeyX  string   `json:"device_pubkey_x"`
DevicePubkeyY  string   `json:"device_pubkey_y"`
SessionCounter uint64   `json:"session_counter"`
BlindingFactor string   `json:"blinding_factor"`
CommitmentRoot string   `json:"commitment_root"`
MerklePath     []string `json:"merkle_path"`
MerkleDir      []int    `json:"merkle_directions"`
HumanScore     int      `json:"human_score"`
IKIMeanMs      int      `json:"iki_mean_ms"`
IKIStddevMs    int      `json:"iki_stddev_ms"`
KeystrokeCount int      `json:"keystroke_count"`
}

// ProverOutput is the result returned from ProveAttestation.
type ProverOutput struct {
// Proof is the serialized Groth16 proof bytes.
Proof []byte `json:"proof"`
// Nullifier computed during proving (hex).
Nullifier string `json:"nullifier"`
Error     string `json:"error,omitempty"`
}

// Keys holds the compiled circuit, proving key, and verifying key.
type Keys struct {
CS constraint.ConstraintSystem
PK groth16.ProvingKey
VK groth16.VerifyingKey
}

// Setup compiles the circuit and runs the trusted setup.
// In production, the proving/verifying keys come from an MPC ceremony.
func Setup() (*Keys, error) {
var circuit AttestationCircuit
cs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, &circuit)
if err != nil {
return nil, fmt.Errorf("compile circuit: %w", err)
}

pk, vk, err := groth16.Setup(cs)
if err != nil {
return nil, fmt.Errorf("groth16 setup: %w", err)
}

return &Keys{CS: cs, PK: pk, VK: vk}, nil
}

// hexToBigInt converts a hex string (with or without 0x prefix) to big.Int.
func hexToBigInt(s string) (*big.Int, error) {
if len(s) >= 2 && s[:2] == "0x" {
s = s[2:]
}
v, ok := new(big.Int).SetString(s, 16)
if !ok {
return nil, fmt.Errorf("invalid hex: %s", s)
}
return v, nil
}

// NativeMiMCHash computes MiMC(a, b) using gnark-crypto's native BN254 MiMC.
// This is the out-of-circuit counterpart of the in-circuit MiMC hash.
func NativeMiMCHash(a, b *big.Int) *big.Int {
h := bn254mimc.NewMiMC()
aBytes := a.Bytes()
bBytes := b.Bytes()
// Pad to 32 bytes
aPad := make([]byte, 32)
bPad := make([]byte, 32)
copy(aPad[32-len(aBytes):], aBytes)
copy(bPad[32-len(bBytes):], bBytes)
h.Write(aPad)
h.Write(bPad)
result := h.Sum(nil)
return new(big.Int).SetBytes(result)
}

// Prove generates a Groth16 proof from the given prover input.
func Prove(keys *Keys, input *ProverInput) (*ProverOutput, error) {
// Parse hex inputs
usernameHash, err := hexToBigInt(input.UsernameHash)
if err != nil {
return nil, fmt.Errorf("username_hash: %w", err)
}
contentHashLo, err := hexToBigInt(input.ContentHashLo)
if err != nil {
return nil, fmt.Errorf("content_hash_lo: %w", err)
}
contentHashHi, err := hexToBigInt(input.ContentHashHi)
if err != nil {
return nil, fmt.Errorf("content_hash_hi: %w", err)
}
blindingFactor, err := hexToBigInt(input.BlindingFactor)
if err != nil {
return nil, fmt.Errorf("blinding_factor: %w", err)
}
commitmentRoot, err := hexToBigInt(input.CommitmentRoot)
if err != nil {
return nil, fmt.Errorf("commitment_root: %w", err)
}
devicePubkeyX, err := hexToBigInt(input.DevicePubkeyX)
if err != nil {
return nil, fmt.Errorf("device_pubkey_x: %w", err)
}
devicePubkeyY, err := hexToBigInt(input.DevicePubkeyY)
if err != nil {
return nil, fmt.Errorf("device_pubkey_y: %w", err)
}

// Compute DevicePubkeyHash = MiMC(pubkey_x, pubkey_y) natively
devicePubkeyHash := NativeMiMCHash(devicePubkeyX, devicePubkeyY)

// Compute Nullifier = MiMC(DevicePubkeyHash, SessionCounter) natively
nullifier := NativeMiMCHash(devicePubkeyHash, new(big.Int).SetUint64(input.SessionCounter))

// Compute Commitment = MiMC(DevicePubkeyHash, BlindingFactor) natively
commitment := NativeMiMCHash(devicePubkeyHash, blindingFactor)

// Parse Merkle path
var merklePath [MerkleTreeDepth]frontend.Variable
var merkleDir [MerkleTreeDepth]frontend.Variable
for i := 0; i < MerkleTreeDepth; i++ {
if i < len(input.MerklePath) {
mp, err := hexToBigInt(input.MerklePath[i])
if err != nil {
return nil, fmt.Errorf("merkle_path[%d]: %w", i, err)
}
merklePath[i] = mp
} else {
merklePath[i] = big.NewInt(0)
}
if i < len(input.MerkleDir) {
merkleDir[i] = input.MerkleDir[i]
} else {
merkleDir[i] = 0
}
}

// Build witness assignment
assignment := &AttestationCircuit{
UsernameHash:     usernameHash,
ContentHashLo:    contentHashLo,
ContentHashHi:    contentHashHi,
Nullifier:        nullifier,
CommitmentRoot:   commitmentRoot,
DevicePubkeyHash: devicePubkeyHash,
SessionCounter:   input.SessionCounter,
BlindingFactor:   blindingFactor,
Commitment:       commitment,
MerklePath:       merklePath,
MerkleDirections: merkleDir,
HumanScore:       input.HumanScore,
KeystrokeCount:   input.KeystrokeCount,
IKIMeanMs:        input.IKIMeanMs,
IKIStddevMs:      input.IKIStddevMs,
}

witness, err := frontend.NewWitness(assignment, ecc.BN254.ScalarField())
if err != nil {
return nil, fmt.Errorf("new witness: %w", err)
}

proof, err := groth16.Prove(keys.CS, keys.PK, witness)
if err != nil {
return nil, fmt.Errorf("prove: %w", err)
}

// Serialize proof
var buf bytes.Buffer
_, err = proof.WriteTo(&buf)
if err != nil {
return nil, fmt.Errorf("serialize proof: %w", err)
}

return &ProverOutput{
Proof:     buf.Bytes(),
Nullifier: "0x" + nullifier.Text(16),
}, nil
}

// Verify checks a Groth16 proof against the verifying key and public inputs.
func Verify(keys *Keys, proofBytes []byte, usernameHash, contentHashLo, contentHashHi, nullifier, commitmentRoot *big.Int) error {
proof := groth16.NewProof(ecc.BN254)
if _, err := proof.ReadFrom(bytes.NewReader(proofBytes)); err != nil {
return fmt.Errorf("deserialize proof: %w", err)
}

// Build public witness
assignment := &AttestationCircuit{
UsernameHash:   usernameHash,
ContentHashLo:  contentHashLo,
ContentHashHi:  contentHashHi,
Nullifier:      nullifier,
CommitmentRoot: commitmentRoot,
}

witness, err := frontend.NewWitness(assignment, ecc.BN254.ScalarField(), frontend.PublicOnly())
if err != nil {
return fmt.Errorf("public witness: %w", err)
}

return groth16.Verify(proof, keys.VK, witness)
}

// ProveJSON is the JSON-based entry point for FFI.
// It takes a JSON string and returns a JSON string.
func ProveJSON(keys *Keys, inputJSON string) string {
var input ProverInput
if err := json.Unmarshal([]byte(inputJSON), &input); err != nil {
errJSON, _ := json.Marshal(ProverOutput{Error: fmt.Sprintf("parse input: %v", err)})
return string(errJSON)
}

output, err := Prove(keys, &input)
if err != nil {
errJSON, _ := json.Marshal(ProverOutput{Error: err.Error()})
return string(errJSON)
}

resultJSON, _ := json.Marshal(output)
return string(resultJSON)
}
