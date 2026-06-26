package poseidon_test

import (
	"math/big"
	"testing"

	"github.com/sur-protocol/surcorelibs/poseidon"
)

// TestHashTwoCanonicalVector verifies the canonical cross-platform test vector.
//
// This is the single most important test in the entire surcorelibs package.
// If this test fails, ALL proofs will fail on-chain verification because the
// nullifier and commitment values will not match what the circuit computes.
//
// The expected value is specified in PROOF_FORMAT.md §6.1 and must be verified
// independently against the gnark-crypto reference implementation, the Swift FFI
// output, the Rust SP1 crate, and the Solidity Poseidon contract before any
// network deployment.
//
//	Expected: Poseidon(1, 2) = 0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a
func TestHashTwoCanonicalVector(t *testing.T) {
	expected, ok := new(big.Int).SetString(
		"115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a",
		16,
	)
	if !ok {
		t.Fatal("failed to parse expected hex constant")
	}

	got, err := poseidon.HashTwo(big.NewInt(1), big.NewInt(2))
	if err != nil {
		t.Fatalf("HashTwo(1, 2) returned error: %v", err)
	}

	if got.Cmp(expected) != 0 {
		t.Errorf("HashTwo(1, 2) mismatch\n  got:      0x%x\n  expected: 0x%x", got, expected)
	}
}

// TestHashZero checks that hashing a single zero element does not panic or error.
func TestHashZero(t *testing.T) {
	got, err := poseidon.Hash([]*big.Int{big.NewInt(0)})
	if err != nil {
		t.Fatalf("Hash(0) returned error: %v", err)
	}
	if got == nil {
		t.Fatal("Hash(0) returned nil")
	}
	// Result must be in [0, r)
	r, _ := new(big.Int).SetString(
		"21888242871839275222246405745257275088548364400416034343698204186575808495617",
		10,
	)
	if got.Sign() < 0 || got.Cmp(r) >= 0 {
		t.Errorf("Hash(0) result out of field range: %x", got)
	}
}

// TestHashModularReduction verifies that an input equal to r+1 is correctly
// reduced to 1 before hashing, producing the same result as Hash(1).
func TestHashModularReduction(t *testing.T) {
	r, _ := new(big.Int).SetString(
		"21888242871839275222246405745257275088548364400416034343698204186575808495617",
		10,
	)
	rPlus1 := new(big.Int).Add(r, big.NewInt(1))

	hashOne, err := poseidon.Hash([]*big.Int{big.NewInt(1)})
	if err != nil {
		t.Fatalf("Hash(1) error: %v", err)
	}
	hashRPlus1, err := poseidon.Hash([]*big.Int{rPlus1})
	if err != nil {
		t.Fatalf("Hash(r+1) error: %v", err)
	}

	if hashOne.Cmp(hashRPlus1) != 0 {
		t.Errorf("Hash(1) != Hash(r+1): reduction not applied\n  Hash(1):   0x%x\n  Hash(r+1): 0x%x", hashOne, hashRPlus1)
	}
}

// TestHashDeterminism checks that calling Hash twice with the same inputs
// produces the same output.
func TestHashDeterminism(t *testing.T) {
	a, b := big.NewInt(42), big.NewInt(1337)

	h1, err := poseidon.HashTwo(a, b)
	if err != nil {
		t.Fatal(err)
	}
	h2, err := poseidon.HashTwo(a, b)
	if err != nil {
		t.Fatal(err)
	}
	if h1.Cmp(h2) != 0 {
		t.Errorf("non-deterministic output: %x vs %x", h1, h2)
	}
}

// TestHashNilInput verifies that a nil input returns an error rather than panicking.
func TestHashNilInput(t *testing.T) {
	_, err := poseidon.Hash([]*big.Int{nil})
	if err == nil {
		t.Error("expected error for nil input, got nil")
	}
}

// TestHashNegativeInput verifies that a negative input returns an error.
func TestHashNegativeInput(t *testing.T) {
	_, err := poseidon.Hash([]*big.Int{big.NewInt(-1)})
	if err == nil {
		t.Error("expected error for negative input, got nil")
	}
}

// TestHashEmptyInputs verifies that an empty input slice returns an error.
func TestHashEmptyInputs(t *testing.T) {
	_, err := poseidon.Hash([]*big.Int{})
	if err == nil {
		t.Error("expected error for empty input, got nil")
	}
}

// TestHashCollisionResistance verifies that different inputs produce different outputs.
func TestHashCollisionResistance(t *testing.T) {
	h12, _ := poseidon.HashTwo(big.NewInt(1), big.NewInt(2))
	h21, _ := poseidon.HashTwo(big.NewInt(2), big.NewInt(1))
	if h12.Cmp(h21) == 0 {
		t.Error("HashTwo(1,2) == HashTwo(2,1): Poseidon is not order-sensitive")
	}
}
