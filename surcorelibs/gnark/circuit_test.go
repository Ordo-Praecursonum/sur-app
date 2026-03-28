package gnark

import (
"math/big"
"testing"

"github.com/consensys/gnark-crypto/ecc"
"github.com/consensys/gnark/frontend"
"github.com/consensys/gnark/frontend/cs/r1cs"
"github.com/consensys/gnark/test"
)

// buildValidWitness creates a valid witness for testing the attestation circuit.
// It computes all MiMC hashes natively to produce values consistent with the circuit.
func buildValidWitness(t *testing.T) *AttestationCircuit {
t.Helper()

devicePubkeyX := big.NewInt(1234)
devicePubkeyY := big.NewInt(5678)

// DevicePubkeyHash = MiMC(x, y)
devicePubkeyHash := NativeMiMCHash(devicePubkeyX, devicePubkeyY)

sessionCounter := uint64(42)
blindingFactor := big.NewInt(999)

// Nullifier = MiMC(DevicePubkeyHash, SessionCounter)
nullifier := NativeMiMCHash(devicePubkeyHash, new(big.Int).SetUint64(sessionCounter))

// Commitment = MiMC(DevicePubkeyHash, BlindingFactor)
commitment := NativeMiMCHash(devicePubkeyHash, blindingFactor)

// Build a Merkle tree with the commitment as a leaf.
// All other leaves are zero; commitment is always on the left.
currentHash := commitment
var merklePath [MerkleTreeDepth]*big.Int
var merkleDir [MerkleTreeDepth]int
for i := 0; i < MerkleTreeDepth; i++ {
merklePath[i] = big.NewInt(0)
merkleDir[i] = 0
currentHash = NativeMiMCHash(currentHash, big.NewInt(0))
}
commitmentRoot := currentHash

var merklePathVars [MerkleTreeDepth]frontend.Variable
var merkleDirVars [MerkleTreeDepth]frontend.Variable
for i := 0; i < MerkleTreeDepth; i++ {
merklePathVars[i] = merklePath[i]
merkleDirVars[i] = merkleDir[i]
}

return &AttestationCircuit{
UsernameHash:     big.NewInt(111),
ContentHashLo:    big.NewInt(222),
ContentHashHi:    big.NewInt(333),
Nullifier:        nullifier,
CommitmentRoot:   commitmentRoot,
DevicePubkeyHash: devicePubkeyHash,
SessionCounter:   sessionCounter,
BlindingFactor:   blindingFactor,
Commitment:       commitment,
MerklePath:       merklePathVars,
MerkleDirections: merkleDirVars,
HumanScore:       75,
KeystrokeCount:   45,
IKIMeanMs:        150,
IKIStddevMs:      30,
}
}

func TestCircuitCompiles(t *testing.T) {
var circuit AttestationCircuit
cs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, &circuit)
if err != nil {
t.Fatalf("Circuit compilation failed: %v", err)
}
t.Logf("Circuit compiled with %d constraints", cs.GetNbConstraints())
}

func TestCircuitConstraintCount(t *testing.T) {
var circuit AttestationCircuit
cs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, &circuit)
if err != nil {
t.Fatal(err)
}
nbConstraints := cs.GetNbConstraints()
t.Logf("Circuit has %d constraints", nbConstraints)
if nbConstraints < 100 {
t.Errorf("Too few constraints: %d", nbConstraints)
}
}

func TestValidWitnessSatisfies(t *testing.T) {
assignment := buildValidWitness(t)
assert := test.NewAssert(t)
assert.ProverSucceeded(&AttestationCircuit{}, assignment, test.WithCurves(ecc.BN254))
}

func TestInvalidHumanScoreFails(t *testing.T) {
assignment := buildValidWitness(t)
assignment.HumanScore = 30
assert := test.NewAssert(t)
assert.ProverFailed(&AttestationCircuit{}, assignment, test.WithCurves(ecc.BN254))
}

func TestInvalidKeystrokeCountFails(t *testing.T) {
assignment := buildValidWitness(t)
assignment.KeystrokeCount = 1
assert := test.NewAssert(t)
assert.ProverFailed(&AttestationCircuit{}, assignment, test.WithCurves(ecc.BN254))
}

func TestInvalidIKIRangeFails(t *testing.T) {
assignment := buildValidWitness(t)
assignment.IKIMeanMs = 5
assert := test.NewAssert(t)
assert.ProverFailed(&AttestationCircuit{}, assignment, test.WithCurves(ecc.BN254))
}

func TestWrongNullifierFails(t *testing.T) {
assignment := buildValidWitness(t)
assignment.Nullifier = big.NewInt(12345)
assert := test.NewAssert(t)
assert.ProverFailed(&AttestationCircuit{}, assignment, test.WithCurves(ecc.BN254))
}

func TestWrongCommitmentRootFails(t *testing.T) {
assignment := buildValidWitness(t)
assignment.CommitmentRoot = big.NewInt(99999)
assert := test.NewAssert(t)
assert.ProverFailed(&AttestationCircuit{}, assignment, test.WithCurves(ecc.BN254))
}
