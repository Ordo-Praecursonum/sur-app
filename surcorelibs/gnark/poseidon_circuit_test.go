// poseidon_circuit_test.go validates cross-consistency between the native
// surcorelibs/poseidon package and the in-circuit poseidonGadget.
//
// These tests are in package gnark (not gnark_test) so they can access
// the unexported poseidonGadget and bn254PoseidonPermute functions.
//
// The gnark test.IsSolved helper compiles the circuit to R1CS and runs the
// constraint solver — no Groth16 proof or trusted setup needed.  Each test
// completes in < 3 seconds.
package gnark

import (
	"math/big"
	"testing"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/r1cs"
	"github.com/consensys/gnark/test"
	"github.com/sur-protocol/surcorelibs/poseidon"
)

// --------------------------------------------------------------------------
// Test circuits
// --------------------------------------------------------------------------

// poseidon2TestCircuit asserts Out == Poseidon(A, B) in circuit.
type poseidon2TestCircuit struct {
	A   frontend.Variable `gnark:",secret"`
	B   frontend.Variable `gnark:",secret"`
	Out frontend.Variable `gnark:",public"`
}

func (c *poseidon2TestCircuit) Define(api frontend.API) error {
	computed := poseidonGadget(api, c.A, c.B)
	api.AssertIsEqual(c.Out, computed)
	return nil
}

// poseidon1TestCircuit asserts Out == Poseidon(A) in circuit (1-input gadget).
type poseidon1TestCircuit struct {
	A   frontend.Variable `gnark:",secret"`
	Out frontend.Variable `gnark:",public"`
}

func (c *poseidon1TestCircuit) Define(api frontend.API) error {
	api.AssertIsEqual(c.Out, poseidonGadget(api, c.A))
	return nil
}

// poseidon3TestCircuit asserts Out == Poseidon(Poseidon(A, B), C) in circuit.
type poseidon3TestCircuit struct {
	A   frontend.Variable `gnark:",secret"`
	B   frontend.Variable `gnark:",secret"`
	C   frontend.Variable `gnark:",secret"`
	Out frontend.Variable `gnark:",public"`
}

func (c *poseidon3TestCircuit) Define(api frontend.API) error {
	computed := poseidonGadget(api, c.A, c.B, c.C)
	api.AssertIsEqual(c.Out, computed)
	return nil
}

// --------------------------------------------------------------------------
// Helpers
// --------------------------------------------------------------------------

// nativePoseidonForTest is the same logic as nativePoseidon in prove.go.
// Duplicated here so the test has no dependency on prove.go's internal.
func nativePoseidonForTest(inputs ...*big.Int) (*big.Int, error) {
	if len(inputs) == 3 {
		inner, err := poseidon.HashTwo(inputs[0], inputs[1])
		if err != nil {
			return nil, err
		}
		return poseidon.HashTwo(inner, inputs[2])
	}
	return poseidon.Hash(inputs)
}

// isSolved compiles the circuit and checks that the witness satisfies it,
// using gnark's R1CS solver (no proving key required).
func isSolved(t *testing.T, circuit, assignment frontend.Circuit) bool {
	t.Helper()
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, circuit)
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	err = test.IsSolved(circuit, assignment, ecc.BN254.ScalarField())
	if err != nil {
		return false
	}
	_ = ccs
	return true
}

// --------------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------------

// TestPoseidonCircuit2InputCanonicalVector verifies that the in-circuit
// poseidonGadget(A, B) produces the canonical test vector for A=1, B=2.
//
//	Expected: 0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a
func TestPoseidonCircuit2InputCanonicalVector(t *testing.T) {
	want, _ := new(big.Int).SetString(
		"115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a", 16)

	// Verify the expected output natively first.
	got, err := poseidon.HashTwo(big.NewInt(1), big.NewInt(2))
	if err != nil {
		t.Fatalf("native HashTwo(1,2): %v", err)
	}
	if got.Cmp(want) != 0 {
		t.Fatalf("native HashTwo mismatch: got 0x%x, want 0x%x", got, want)
	}

	// Now verify the circuit produces the same value.
	circuit := &poseidon2TestCircuit{}
	assignment := &poseidon2TestCircuit{
		A:   big.NewInt(1),
		B:   big.NewInt(2),
		Out: want,
	}
	if !isSolved(t, circuit, assignment) {
		t.Errorf("circuit did not satisfy Poseidon(1,2) == 0x%x", want)
	}
}

// TestPoseidonCircuit2InputConsistency verifies that the circuit and native
// code agree on Poseidon(A, B) for several arbitrary inputs.
func TestPoseidonCircuit2InputConsistency(t *testing.T) {
	cases := [][2]int64{
		{0, 0},
		{1, 0},
		{0, 1},
		{100, 200},
		{1<<32 - 1, 1<<32 - 1},
	}

	for _, tc := range cases {
		a := big.NewInt(tc[0])
		b := big.NewInt(tc[1])
		native, err := nativePoseidonForTest(a, b)
		if err != nil {
			t.Fatalf("native(%d,%d): %v", tc[0], tc[1], err)
		}

		circuit := &poseidon2TestCircuit{}
		assignment := &poseidon2TestCircuit{A: a, B: b, Out: native}
		if !isSolved(t, circuit, assignment) {
			t.Errorf("circuit and native disagree on Poseidon(%d,%d)", tc[0], tc[1])
		}
	}
}

// TestPoseidonCircuit3InputConsistency verifies that the circuit's 3-input
// poseidonGadget (which uses nested 2-input calls) agrees with the native
// nativePoseidon implementation for 3 inputs.
func TestPoseidonCircuit3InputConsistency(t *testing.T) {
	cases := [][3]int64{
		{1, 2, 3},
		{42, 7, 99},    // same values used in nullifier test
		{0, 0, 0},
		{100, 200, 300},
	}

	for _, tc := range cases {
		a, b, c := big.NewInt(tc[0]), big.NewInt(tc[1]), big.NewInt(tc[2])
		native, err := nativePoseidonForTest(a, b, c)
		if err != nil {
			t.Fatalf("native(%d,%d,%d): %v", tc[0], tc[1], tc[2], err)
		}

		circuit := &poseidon3TestCircuit{}
		assignment := &poseidon3TestCircuit{A: a, B: b, C: c, Out: native}
		if !isSolved(t, circuit, assignment) {
			t.Errorf("circuit and native disagree on Poseidon(%d,%d,%d)", tc[0], tc[1], tc[2])
		}
	}
}

// TestPoseidonCircuit1InputEqualsHashTwoZero locks the invariant that the
// circuit's 1-input poseidonGadget(x) equals native HashTwo(x, 0): the gadget
// absorbs x into state[1] and leaves state[2]=0 under the t=3 permutation, which
// is identical to hashing the pair (x, 0). The Merkle-leaf wrap in
// AttestationCircuit relies on this, and the Sur Chain commitment-root builder
// MUST use HashTwo(commitment, 0) — not poseidon.Hash([commitment]) (iden3 t=2)
// — to stay consistent with the circuit.
func TestPoseidonCircuit1InputEqualsHashTwoZero(t *testing.T) {
	for _, v := range []int64{0, 1, 42, 12345} {
		x := big.NewInt(v)
		want, err := poseidon.HashTwo(x, big.NewInt(0))
		if err != nil {
			t.Fatalf("HashTwo(%d,0): %v", v, err)
		}
		circuit := &poseidon1TestCircuit{}
		assignment := &poseidon1TestCircuit{A: x, Out: want}
		if !isSolved(t, circuit, assignment) {
			t.Errorf("circuit Poseidon(%d) != HashTwo(%d, 0)", v, v)
		}
	}
}

// TestPoseidonCircuitRejectsWrongOutput verifies that the circuit correctly
// rejects a witness where Out does not match Poseidon(A, B).
func TestPoseidonCircuitRejectsWrongOutput(t *testing.T) {
	circuit := &poseidon2TestCircuit{}
	// Provide wrong Out (1 instead of Poseidon(1,2)).
	assignment := &poseidon2TestCircuit{
		A:   big.NewInt(1),
		B:   big.NewInt(2),
		Out: big.NewInt(1), // wrong
	}
	if isSolved(t, circuit, assignment) {
		t.Error("circuit accepted wrong Out for Poseidon(1,2); expected unsatisfied")
	}
}
