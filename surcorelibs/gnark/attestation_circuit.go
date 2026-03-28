// Package gnark implements the Sur Protocol attestation circuit using gnark Groth16
// over BN254. The circuit proves that a typing session is authentic without revealing
// behavioral statistics (IKI values, human score, keystroke count, typing duration).
//
// Public inputs (5 BN254 field elements):
//
//[UsernameHash, ContentHashLo, ContentHashHi, Nullifier, CommitmentRoot]
//
// Private witnesses:
//
//device public key hash, session counter, blinding factor, Merkle path,
//human score, IKI values, keystroke count
//
// The circuit enforces:
//  1. Nullifier = MiMC(DevicePubkeyHash, SessionCounter)
//  2. Commitment inclusion in Merkle tree with MiMC hash
//  3. Behavioral constraints: humanScore >= 50, IKI in [20ms, 2000ms], CV > 0
//  4. Keystroke count >= 2
//
// Note: MiMC is used as the in-circuit ZK-friendly hash because gnark v0.11
// natively supports it with both circuit and native implementations. The protocol
// Poseidon hash (TASK-2, surcorelibs/poseidon/) handles cross-project interop.
// The circuit hash will migrate to Poseidon when gnark adds a compatible gadget.
package gnark

import (
"github.com/consensys/gnark/frontend"
"github.com/consensys/gnark/std/hash/mimc"
)

// MerkleTreeDepth is the depth of the commitment Merkle tree.
const MerkleTreeDepth = 8

// AttestationCircuit defines the gnark Groth16 circuit for Sur Protocol attestations.
// All behavioral statistics are private witnesses — the verifier learns only that
// the constraints were satisfied, not the values themselves.
type AttestationCircuit struct {
// === Public Inputs (5 BN254 field elements) ===

// UsernameHash identifies the user.
UsernameHash frontend.Variable `gnark:",public"`

// ContentHashLo is the lower 128 bits of SHA-256(content).
ContentHashLo frontend.Variable `gnark:",public"`

// ContentHashHi is the upper 128 bits of SHA-256(content).
ContentHashHi frontend.Variable `gnark:",public"`

// Nullifier prevents replay attacks while remaining unlinkable.
Nullifier frontend.Variable `gnark:",public"`

// CommitmentRoot is the Merkle root of the commitment tree.
CommitmentRoot frontend.Variable `gnark:",public"`

// === Private Witnesses ===

// DevicePubkeyHash = Hash(pubkey_x, pubkey_y).
DevicePubkeyHash frontend.Variable

// SessionCounter is the monotonically increasing session counter.
SessionCounter frontend.Variable

// BlindingFactor is random for the commitment.
BlindingFactor frontend.Variable

// Commitment = Hash(DevicePubkeyHash, BlindingFactor).
Commitment frontend.Variable

// MerklePath contains the sibling hashes for Merkle inclusion proof.
MerklePath [MerkleTreeDepth]frontend.Variable

// MerkleDirections contains the direction bits (0=left, 1=right).
MerkleDirections [MerkleTreeDepth]frontend.Variable

// HumanScore is the typing evaluation score (0–100, private).
HumanScore frontend.Variable

// KeystrokeCount is the number of keystrokes (private).
KeystrokeCount frontend.Variable

// IKIMeanMs is the mean inter-key interval in milliseconds (private).
IKIMeanMs frontend.Variable

// IKIStddevMs is the standard deviation of IKI in milliseconds (private).
IKIStddevMs frontend.Variable
}

// Define implements the gnark frontend.Circuit interface.
func (c *AttestationCircuit) Define(api frontend.API) error {
// Create MiMC hasher for in-circuit hashing
hFunc, err := mimc.NewMiMC(api)
if err != nil {
return err
}

// --- Constraint 1: Nullifier derivation ---
hFunc.Reset()
hFunc.Write(c.DevicePubkeyHash, c.SessionCounter)
nullifierHash := hFunc.Sum()
api.AssertIsEqual(c.Nullifier, nullifierHash)

// --- Constraint 2: Commitment derivation ---
hFunc.Reset()
hFunc.Write(c.DevicePubkeyHash, c.BlindingFactor)
commitmentHash := hFunc.Sum()
api.AssertIsEqual(c.Commitment, commitmentHash)

// --- Constraint 3: Merkle inclusion proof ---
currentHash := c.Commitment
for i := 0; i < MerkleTreeDepth; i++ {
api.AssertIsBoolean(c.MerkleDirections[i])

left := api.Select(c.MerkleDirections[i], c.MerklePath[i], currentHash)
right := api.Select(c.MerkleDirections[i], currentHash, c.MerklePath[i])

hFunc.Reset()
hFunc.Write(left, right)
currentHash = hFunc.Sum()
}
api.AssertIsEqual(c.CommitmentRoot, currentHash)

// --- Constraint 4: Behavioral constraints (private witnesses) ---
// HumanScore in [50, 100]
api.AssertIsLessOrEqual(50, c.HumanScore)
api.AssertIsLessOrEqual(c.HumanScore, 100)

// KeystrokeCount >= 2
api.AssertIsLessOrEqual(2, c.KeystrokeCount)

// IKI mean in [20ms, 2000ms]
api.AssertIsLessOrEqual(20, c.IKIMeanMs)
api.AssertIsLessOrEqual(c.IKIMeanMs, 2000)

// IKI stddev > 0 (ensures variation)
api.AssertIsLessOrEqual(1, c.IKIStddevMs)

return nil
}
