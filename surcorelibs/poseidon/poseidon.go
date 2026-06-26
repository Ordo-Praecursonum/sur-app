// Package poseidon wraps the iden3/go-iden3-crypto BN254 Poseidon implementation,
// exposing a minimal API used by the surcorelibs gnark prover and the CGo FFI bridge.
//
// Parameters (canonical BN254 Poseidon-128):
//
//   - Field:          BN254 scalar field r = 21888242871839275222246405745257275088548364400416034343698204186575808495617
//   - State width:    t = 3  (rate = 2, capacity = 1)
//   - Full rounds:    Rf = 8  (4 at start, 4 at end)
//   - Partial rounds: Rp = 57
//   - S-box:          x^5
//
// Canonical test vector (must match on all platforms):
//
//	HashTwo(1, 2) == 0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a
package poseidon

import (
	"errors"
	"math/big"

	iposeidon "github.com/iden3/go-iden3-crypto/poseidon"
)

// bn254R is the BN254 scalar field modulus.
var bn254R, _ = new(big.Int).SetString(
	"21888242871839275222246405745257275088548364400416034343698204186575808495617",
	10,
)

// ErrInputTooLarge is returned when an input big.Int is negative.
var ErrInputTooLarge = errors.New("poseidon: input must be non-negative")

// Hash computes Poseidon over the provided inputs interpreted as BN254 scalar
// field elements. Each value is reduced modulo r before hashing. Returns the
// digest as a *big.Int in the range [0, r).
func Hash(inputs []*big.Int) (*big.Int, error) {
	if len(inputs) == 0 {
		return nil, errors.New("poseidon: at least one input required")
	}

	// Validate and reduce inputs.
	reduced := make([]*big.Int, len(inputs))
	for i, v := range inputs {
		if v == nil || v.Sign() < 0 {
			return nil, ErrInputTooLarge
		}
		reduced[i] = new(big.Int).Mod(v, bn254R)
	}

	// iden3 Poseidon accepts up to 16 inputs directly.
	result, err := iposeidon.Hash(reduced)
	if err != nil {
		return nil, err
	}
	return result, nil
}

// HashTwo is a convenience wrapper for the two-input case.
//
// Canonical test vector: HashTwo(1, 2) must equal
// 0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a
func HashTwo(a, b *big.Int) (*big.Int, error) {
	return Hash([]*big.Int{a, b})
}
