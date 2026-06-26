package gnark_test

import (
	"math/big"
	"testing"

	"github.com/sur-protocol/surcorelibs/gnark"
	"github.com/sur-protocol/surcorelibs/poseidon"
)

// TestCommitmentMatchesNestedHashTwo confirms the exported Commitment helper
// equals the circuit's nested 3-input rule HashTwo(HashTwo(x,y), blinding) — the
// same construction the device-registration flow and the chain rely on.
func TestCommitmentMatchesNestedHashTwo(t *testing.T) {
	x := big.NewInt(11)
	y := big.NewInt(22)
	bf := big.NewInt(33)

	got, err := gnark.Commitment(x, y, bf)
	if err != nil {
		t.Fatalf("Commitment: %v", err)
	}

	inner, err := poseidon.HashTwo(x, y)
	if err != nil {
		t.Fatal(err)
	}
	want, err := poseidon.HashTwo(inner, bf)
	if err != nil {
		t.Fatal(err)
	}
	if got.Cmp(want) != 0 {
		t.Fatalf("commitment mismatch: got 0x%x want 0x%x", got, want)
	}
}

// TestUsernameHashFieldDeterministic is a light check that the username hash is
// stable and non-zero (the chain recomputes it identically during verification).
func TestUsernameHashFieldDeterministic(t *testing.T) {
	a, err := gnark.UsernameHashField("alice")
	if err != nil {
		t.Fatal(err)
	}
	b, err := gnark.UsernameHashField("alice")
	if err != nil {
		t.Fatal(err)
	}
	if a.Cmp(b) != 0 {
		t.Fatal("username hash not deterministic")
	}
	if a.Sign() == 0 {
		t.Fatal("username hash unexpectedly zero")
	}
}
