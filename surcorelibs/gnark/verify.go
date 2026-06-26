package gnark

// verify.go is the off-chain counterpart to Prove.  It verifies a serialized
// 256-byte Groth16 proof against the fixed verifying key and the canonical
// 5-element public-inputs vector.  It exists so that:
//
//   - completeness/soundness tests can assert valid proofs verify and tampered
//     proofs do not, without a chain or a contract; and
//   - the exact public-witness construction is documented in one place, which
//     the Sur Chain verifier (a separate module) mirrors field-for-field.
//
// The public inputs are, in this fixed order (see AttestationCircuit):
//
//	[0] UsernameHash
//	[1] ContentHashLo
//	[2] ContentHashHi
//	[3] Nullifier
//	[4] CommitmentRoot

import (
	"fmt"
	"math/big"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/backend/groth16"
	"github.com/consensys/gnark/backend/witness"
	"github.com/consensys/gnark/frontend"
)

// NumPublicInputs is the number of public field elements in an attestation proof.
const NumPublicInputs = 5

// Verify checks a Groth16 proof against the fixed verifying key loaded from
// KeyDir().  proofBytes must be the 256-byte wire format produced by Prove
// (see serializeProof); publicInputs must be exactly NumPublicInputs BN254 Fr
// elements in the canonical order above.
//
// It returns nil iff the proof is valid.  A non-nil error means either a
// malformed input or a failed verification — callers that need to distinguish
// "invalid proof" from "bad input" should pre-validate lengths.
func Verify(proofBytes []byte, publicInputs []*big.Int) error {
	vk, err := LoadVerifyingKey(KeyDir())
	if err != nil {
		return fmt.Errorf("verify: load vk: %w", err)
	}
	return VerifyWithKey(vk, proofBytes, publicInputs)
}

// VerifyWithKey is Verify with an explicitly supplied verifying key, so the
// key can be loaded once and reused across many verifications.
func VerifyWithKey(vk groth16.VerifyingKey, proofBytes []byte, publicInputs []*big.Int) error {
	if len(proofBytes) != 256 {
		return fmt.Errorf("verify: proof must be 256 bytes, got %d", len(proofBytes))
	}
	if len(publicInputs) != NumPublicInputs {
		return fmt.Errorf("verify: expected %d public inputs, got %d", NumPublicInputs, len(publicInputs))
	}

	proof, err := DeserializeProof(proofBytes)
	if err != nil {
		return fmt.Errorf("verify: deserialize proof: %w", err)
	}

	pubWitness, err := PublicWitness(publicInputs)
	if err != nil {
		return fmt.Errorf("verify: build public witness: %w", err)
	}

	if err := groth16.Verify(proof, vk, pubWitness); err != nil {
		return fmt.Errorf("verify: groth16: %w", err)
	}
	return nil
}

// PublicWitness builds the gnark public witness from the 5 public inputs.
//
// It assigns only the public fields of AttestationCircuit (in declaration
// order) and extracts the public part, which yields the same ordered public
// vector the circuit was compiled with.  The Sur Chain verifier reproduces this
// exact ordering with its own minimal struct; any divergence is caught by the
// shared Poseidon test vector and the verifying-key hash.
func PublicWitness(publicInputs []*big.Int) (witness.Witness, error) {
	if len(publicInputs) != NumPublicInputs {
		return nil, fmt.Errorf("PublicWitness: expected %d inputs, got %d", NumPublicInputs, len(publicInputs))
	}
	assignment := &AttestationCircuit{
		UsernameHash:   publicInputs[0],
		ContentHashLo:  publicInputs[1],
		ContentHashHi:  publicInputs[2],
		Nullifier:      publicInputs[3],
		CommitmentRoot: publicInputs[4],
	}
	w, err := frontend.NewWitness(assignment, ecc.BN254.ScalarField(), frontend.PublicOnly())
	if err != nil {
		return nil, err
	}
	return w, nil
}
