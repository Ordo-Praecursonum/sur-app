// Package poseidon provides a Poseidon hash function implementation over the BN254
// scalar field using the iden3 go-iden3-crypto library. This is the canonical Poseidon
// instantiation for Sur Protocol: rate=2, capacity=1, 8 full rounds, 57 partial rounds,
// S-box x^5.
//
// All in-circuit hash operations (commitment, nullifier, Merkle tree) use this
// implementation. The output must match what the Sur Chain project verifies on-chain
// and what the L1 Settlement project's PoseidonHasher.sol produces.
//
// Canonical test vector (PROOF_FORMAT.md §6.1):
//
//Poseidon(1, 2) over BN254 = 0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a
package poseidon

import (
"math/big"

iden3poseidon "github.com/iden3/go-iden3-crypto/poseidon"
)

// Hash computes the Poseidon hash of the given BN254 field elements.
// Parameters: rate=2, capacity=1, 8 full rounds, 57 partial rounds, S-box x^5.
// Returns a single BN254 field element as the digest.
func Hash(inputs ...*big.Int) (*big.Int, error) {
return iden3poseidon.Hash(inputs)
}

// HashBytes computes the Poseidon hash of raw byte slices. Each byte slice is
// interpreted as a big-endian BN254 field element. The caller must ensure each
// slice represents a value less than the BN254 scalar field modulus.
func HashBytes(inputs ...[]byte) ([]byte, error) {
elems := make([]*big.Int, len(inputs))
for i, b := range inputs {
elems[i] = new(big.Int).SetBytes(b)
}
result, err := Hash(elems...)
if err != nil {
return nil, err
}
// Return as 32-byte big-endian
buf := make([]byte, 32)
resultBytes := result.Bytes()
copy(buf[32-len(resultBytes):], resultBytes)
return buf, nil
}

// NullifierHash computes Poseidon(pk, counter) for nullifier derivation.
// The nullifier is a deterministic, unique-per-session value that prevents
// replay attacks while remaining unlinkable to the device identity.
func NullifierHash(publicKey *big.Int, counter uint64) (*big.Int, error) {
return Hash(publicKey, new(big.Int).SetUint64(counter))
}

// CommitmentHash computes Poseidon(pk, blinding) for Pedersen-style commitments.
func CommitmentHash(publicKey, blindingFactor *big.Int) (*big.Int, error) {
return Hash(publicKey, blindingFactor)
}

// MerkleHash computes Poseidon(left, right) for Merkle tree internal nodes.
func MerkleHash(left, right *big.Int) (*big.Int, error) {
return Hash(left, right)
}
