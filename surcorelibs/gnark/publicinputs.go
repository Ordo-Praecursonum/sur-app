package gnark

// publicinputs.go defines the CANONICAL derivations of two public inputs that
// are computed outside the circuit and must match byte-for-byte between the
// prover (iOS / surcorelibs) and the verifier (Sur Chain x/attestation):
//
//   - UsernameHashField(username): Poseidon over the username's UTF-8 bytes
//     packed into 31-byte big-endian field limbs.  31 bytes keeps every limb
//     below the BN254 scalar field modulus (~254 bits).  Usernames are 3–32
//     bytes, so this is 1 or 2 limbs.
//
//   - SplitContentHash(h): a 32-byte content hash split into its high and low
//     128-bit halves, matching the circuit's ContentHashPriv == lo + 2^128*hi
//     constraint (ContentHashHi is the most-significant 16 bytes).
//
// The Sur Chain reimplements both with the same Poseidon parameters; any
// divergence is caught by the shared Poseidon test vector and by attestation
// verification simply failing.

import (
	"fmt"
	"math/big"

	"github.com/sur-protocol/surcorelibs/poseidon"
)

// usernameLimbBytes is the number of UTF-8 bytes packed into each BN254 field
// limb.  31 bytes = 248 bits < the 254-bit scalar field modulus.
const usernameLimbBytes = 31

// UsernameHashField computes the canonical username hash as a BN254 Fr element.
func UsernameHashField(username string) (*big.Int, error) {
	b := []byte(username)
	if len(b) == 0 {
		return nil, fmt.Errorf("UsernameHashField: empty username")
	}
	var limbs []*big.Int
	for i := 0; i < len(b); i += usernameLimbBytes {
		end := i + usernameLimbBytes
		if end > len(b) {
			end = len(b)
		}
		limbs = append(limbs, new(big.Int).SetBytes(b[i:end]))
	}
	return poseidon.Hash(limbs)
}

// Commitment computes the device commitment as the circuit does
// (circuit.go: commitment = Poseidon(DevicePubKeyX, DevicePubKeyY, BlindingFactor)):
// the nested 3-input rule HashTwo(HashTwo(x, y), blinding). This is the value the
// app sends as first_commitment / new_commitment in MsgRegisterUsername / MsgAddDevice.
func Commitment(x, y, blinding *big.Int) (*big.Int, error) {
	inner, err := poseidon.HashTwo(x, y)
	if err != nil {
		return nil, err
	}
	return poseidon.HashTwo(inner, blinding)
}

// SingleDeviceMerkleWitness returns the device-commitment Merkle root and the
// inclusion path for a user whose single device sits at leaf index 0. It mirrors
// the chain's ComputeCommitmentRoot construction exactly:
//   - leaf  = Poseidon(commitment)        (== HashTwo(commitment, 0))
//   - empty leaf = 0; node = HashTwo(l,r)
//   - the device is always the left child, so every direction bit is 0.
//
// The returned root equals the value the chain stores in the user profile, and
// the path satisfies the circuit's Merkle-inclusion constraint, so a proof built
// with this witness verifies on-chain. (Multi-device users need the path from the
// chain; this covers the common single-device case.)
func SingleDeviceMerkleWitness(x, y, blinding *big.Int) (root *big.Int, path []*big.Int, err error) {
	commitment, err := Commitment(x, y, blinding)
	if err != nil {
		return nil, nil, err
	}
	cur, err := poseidon.HashTwo(commitment, big.NewInt(0)) // leaf = Poseidon(commitment)
	if err != nil {
		return nil, nil, err
	}
	path = make([]*big.Int, MerkleDepth)
	empty := big.NewInt(0)
	for i := 0; i < MerkleDepth; i++ {
		path[i] = new(big.Int).Set(empty) // sibling at this level (empty subtree root)
		node, err := poseidon.HashTwo(cur, empty) // direction 0: current is left child
		if err != nil {
			return nil, nil, err
		}
		cur = node
		nextEmpty, err := poseidon.HashTwo(empty, empty)
		if err != nil {
			return nil, nil, err
		}
		empty = nextEmpty
	}
	return cur, path, nil
}

// SplitContentHash splits a 32-byte content hash into (lo, hi) where
// hash == hi*2^128 + lo, hi is the high 16 bytes and lo is the low 16 bytes
// (both big-endian).  This matches the circuit's content-hash reconstruction.
func SplitContentHash(hash []byte) (lo, hi *big.Int, err error) {
	if len(hash) != 32 {
		return nil, nil, fmt.Errorf("SplitContentHash: expected 32 bytes, got %d", len(hash))
	}
	hi = new(big.Int).SetBytes(hash[0:16])
	lo = new(big.Int).SetBytes(hash[16:32])
	return lo, hi, nil
}
