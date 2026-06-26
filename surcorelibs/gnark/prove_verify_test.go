package gnark_test

// prove_verify_test.go exercises the three properties of the device proof that
// can be checked by running code:
//
//   - Completeness: a proof built from a fully consistent witness verifies
//     against the fixed verifying key.
//   - Soundness (negative): a proof verified against tampered public inputs, or
//     a tampered proof, is rejected.
//   - Determinism of the public-inputs contract: the prover-reported public
//     inputs match the values the witness was built from.
//
// (Zero-knowledge and unconditional knowledge-soundness are properties of
// Groth16 + the circuit, argued in docs, not asserted here.)
//
// The witness builder mirrors the circuit's Poseidon usage exactly, including
// the subtle 1-input leaf hash: the circuit computes leaf = Poseidon(commitment)
// as a t=3 permutation with zero padding, which equals HashTwo(commitment, 0)
// natively — NOT poseidon.Hash([commitment]) (iden3 t=2). Getting this wrong
// makes the Merkle-inclusion constraint unsatisfiable.

import (
	"math/big"
	"testing"

	"github.com/sur-protocol/surcorelibs/gnark"
	"github.com/sur-protocol/surcorelibs/poseidon"
)

// ensureKeys makes sure the committed key set is present; a fresh checkout has
// it, but regenerate defensively so the test is self-sufficient.
func ensureKeys(t *testing.T) {
	t.Helper()
	if _, err := gnark.LoadVerifyingKey(gnark.KeyDir()); err != nil {
		if genErr := gnark.GenerateKeys(gnark.KeyDir()); genErr != nil {
			t.Fatalf("ensureKeys: %v", genErr)
		}
	}
}

func hashTwo(t *testing.T, a, b *big.Int) *big.Int {
	t.Helper()
	h, err := poseidon.HashTwo(a, b)
	if err != nil {
		t.Fatalf("HashTwo: %v", err)
	}
	return h
}

// consistentInput builds a ProverInput whose Merkle root and nullifier are
// computed exactly as the circuit derives them, plus the matching expected
// public inputs vector [usernameHash, contentHashLo, contentHashHi, nullifier,
// commitmentRoot].
func consistentInput(t *testing.T) (gnark.ProverInput, []*big.Int) {
	t.Helper()

	x := big.NewInt(11)         // device pubkey X
	y := big.NewInt(22)         // device pubkey Y
	bf := big.NewInt(33)        // blinding factor
	uh := big.NewInt(44)        // username hash
	var counter uint64 = 7      // session counter
	lo := big.NewInt(2)         // content hash low 128 bits
	hi := big.NewInt(0)         // content hash high 128 bits
	priv := big.NewInt(2)       // lo + 2^128*hi

	// commitment = Poseidon(X, Y, bf) = HashTwo(HashTwo(X, Y), bf)
	commitment := hashTwo(t, hashTwo(t, x, y), bf)
	// leaf = Poseidon(commitment) == HashTwo(commitment, 0)  (t=3, zero-padded)
	current := hashTwo(t, commitment, big.NewInt(0))

	// Walk the tree: direction 0 means current is the left child.
	depth := gnark.MerkleDepth
	path := make([]string, depth)
	dirs := make([]int, depth)
	for i := 0; i < depth; i++ {
		sib := big.NewInt(int64(101 + i))
		path[i] = "0x" + sib.Text(16)
		dirs[i] = 0
		current = hashTwo(t, current, sib) // node = Poseidon(current, sibling)
	}
	root := current

	// nullifier = Poseidon(usernameHash, sessionCounter, bf) (nested 3-input)
	nullifier := hashTwo(t, hashTwo(t, uh, new(big.Int).SetUint64(counter)), bf)

	in := gnark.ProverInput{
		UsernameHash:    "0x" + uh.Text(16),
		ContentHashLo:   "0x" + lo.Text(16),
		ContentHashHi:   "0x" + hi.Text(16),
		ContentHashPriv: "0x" + priv.Text(16),
		DevicePubKeyX:   "0x" + x.Text(16),
		DevicePubKeyY:   "0x" + y.Text(16),
		SessionCounter:  counter,
		BlindingFactor:  "0x" + bf.Text(16),
		CommitmentRoot:  "0x" + root.Text(16),
		MerklePath:      path,
		MerkleDirections: dirs,
		SESignatureR:    "0x1",
		SESignatureS:    "0x1",
		HumanScore:      75,
		IKIValuesMs:     []int{100, 150, 200, 120, 90, 180, 140, 110, 160, 130},
		KeystrokeCount:  10,
	}
	expectedPublic := []*big.Int{uh, lo, hi, nullifier, root}
	return in, expectedPublic
}

func TestProveVerifyCompleteness(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping Groth16 prove/verify in short mode")
	}
	ensureKeys(t)

	in, expectedPublic := consistentInput(t)
	out, err := gnark.Prove(in)
	if err != nil {
		t.Fatalf("completeness: Prove on a consistent witness failed: %v", err)
	}

	// The prover-reported nullifier must equal what we derived.
	gotNullifier, ok := new(big.Int).SetString(trim0x(out.PublicInputs[3]), 16)
	if !ok {
		t.Fatalf("could not parse nullifier %q", out.PublicInputs[3])
	}
	if gotNullifier.Cmp(expectedPublic[3]) != 0 {
		t.Fatalf("nullifier mismatch: prover 0x%x, expected 0x%x", gotNullifier, expectedPublic[3])
	}

	raw, err := out.RawProof()
	if err != nil {
		t.Fatalf("RawProof: %v", err)
	}
	if len(raw) != 256 {
		t.Fatalf("proof = %d bytes, want 256", len(raw))
	}

	if err := gnark.Verify(raw, expectedPublic); err != nil {
		t.Fatalf("completeness: a valid proof failed to verify: %v", err)
	}
}

func TestVerifyRejectsTamperedPublicInput(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping Groth16 prove/verify in short mode")
	}
	ensureKeys(t)

	in, expectedPublic := consistentInput(t)
	out, err := gnark.Prove(in)
	if err != nil {
		t.Fatalf("Prove: %v", err)
	}
	raw, err := out.RawProof()
	if err != nil {
		t.Fatalf("RawProof: %v", err)
	}

	// Sanity: untampered verifies.
	if err := gnark.Verify(raw, expectedPublic); err != nil {
		t.Fatalf("control: valid proof failed to verify: %v", err)
	}

	// Tamper each public input in turn; every one must be rejected.
	for i := range expectedPublic {
		bad := make([]*big.Int, len(expectedPublic))
		copy(bad, expectedPublic)
		bad[i] = new(big.Int).Add(bad[i], big.NewInt(1))
		if err := gnark.Verify(raw, bad); err == nil {
			t.Errorf("soundness: verify accepted a proof with tampered public input %d", i)
		}
	}
}

// TestSingleDeviceWitnessProvesAndVerifies confirms that the Merkle witness the
// FFI hands the app (SingleDeviceMerkleWitness) yields a proof that verifies — i.e.
// the app can build a valid attestation for a single registered device.
func TestSingleDeviceWitnessProvesAndVerifies(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping Groth16 prove/verify in short mode")
	}
	ensureKeys(t)

	x := big.NewInt(11)
	y := big.NewInt(22)
	bf := big.NewInt(33)
	var counter uint64 = 0
	uh, err := gnark.UsernameHashField("el-2")
	if err != nil {
		t.Fatal(err)
	}

	root, path, err := gnark.SingleDeviceMerkleWitness(x, y, bf)
	if err != nil {
		t.Fatalf("SingleDeviceMerkleWitness: %v", err)
	}
	pathHex := make([]string, len(path))
	dirs := make([]int, len(path))
	for i, p := range path {
		pathHex[i] = "0x" + p.Text(16)
		dirs[i] = 0
	}

	lo := big.NewInt(2)
	hi := big.NewInt(0)
	nullifier := hashTwo(t, hashTwo(t, uh, new(big.Int).SetUint64(counter)), bf)

	in := gnark.ProverInput{
		UsernameHash:     "0x" + uh.Text(16),
		ContentHashLo:    "0x" + lo.Text(16),
		ContentHashHi:    "0x" + hi.Text(16),
		ContentHashPriv:  "0x2",
		DevicePubKeyX:    "0x" + x.Text(16),
		DevicePubKeyY:    "0x" + y.Text(16),
		SessionCounter:   counter,
		BlindingFactor:   "0x" + bf.Text(16),
		CommitmentRoot:   "0x" + root.Text(16),
		MerklePath:       pathHex,
		MerkleDirections: dirs,
		SESignatureR:     "0x1",
		SESignatureS:     "0x1",
		HumanScore:       75,
		IKIValuesMs:      []int{100, 150, 200, 120, 90, 180, 140, 110, 160, 130},
		KeystrokeCount:   10,
	}
	out, err := gnark.Prove(in)
	if err != nil {
		t.Fatalf("Prove with single-device witness failed: %v", err)
	}
	raw, err := out.RawProof()
	if err != nil {
		t.Fatal(err)
	}
	pub := []*big.Int{uh, lo, hi, nullifier, root}
	if err := gnark.Verify(raw, pub); err != nil {
		t.Fatalf("proof from single-device witness failed to verify: %v", err)
	}
}

func TestVerifyRejectsTamperedProof(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping Groth16 prove/verify in short mode")
	}
	ensureKeys(t)

	in, expectedPublic := consistentInput(t)
	out, err := gnark.Prove(in)
	if err != nil {
		t.Fatalf("Prove: %v", err)
	}
	raw, err := out.RawProof()
	if err != nil {
		t.Fatalf("RawProof: %v", err)
	}

	// Flip a byte in the proof; it must no longer verify.
	tampered := make([]byte, len(raw))
	copy(tampered, raw)
	tampered[0] ^= 0xff
	if err := gnark.Verify(tampered, expectedPublic); err == nil {
		t.Error("soundness: verify accepted a tampered proof")
	}
}

func trim0x(s string) string {
	if len(s) >= 2 && (s[:2] == "0x" || s[:2] == "0X") {
		return s[2:]
	}
	return s
}
