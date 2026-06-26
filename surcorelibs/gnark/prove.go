package gnark

import (
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"strings"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/backend/groth16"
	groth16bn254 "github.com/consensys/gnark/backend/groth16/bn254"
	"github.com/consensys/gnark/frontend"
	"github.com/sur-protocol/surcorelibs/poseidon"
)

// ProverInput is the JSON-serializable input schema for the iOS FFI bridge.
// The Swift side encodes this as a JSON string and passes it to ProveAttestation.
//
// All field element values are hex strings, with or without 0x prefix.
// They represent BN254 scalar field elements (big-endian, up to 32 bytes).
//
// The schema must remain stable: changing field names or types is a
// breaking change that requires a coordinated Swift + Go update.
type ProverInput struct {
	// Public inputs (will appear in PublicInputs of ProofOutput, same order).
	UsernameHash  string `json:"username_hash"`
	ContentHashLo string `json:"content_hash_lo"`
	ContentHashHi string `json:"content_hash_hi"`

	// Device Secure Enclave P-256 public key coordinates (BN254 field elements,
	// reduced mod r).  Private witnesses; not transmitted in proof output.
	DevicePubKeyX string `json:"device_pubkey_x"`
	DevicePubKeyY string `json:"device_pubkey_y"`

	// Session binding.
	SessionCounter uint64 `json:"session_counter"`
	BlindingFactor string `json:"blinding_factor"` // 32-byte random secret, mod r

	// CommitmentRoot queried from Cosmos x/identity before proof generation.
	CommitmentRoot string `json:"commitment_root"`

	// Merkle path for device commitment inclusion proof (MerkleDepth elements).
	MerklePath       []string `json:"merkle_path"`
	MerkleDirections []int    `json:"merkle_directions"` // 0=left, 1=right per level

	// P-256 ECDSA signature from the Secure Enclave over SHA-256(session_data).
	// Reserved for the ECDSA sub-circuit in a future revision.
	SESignatureR string `json:"se_signature_r"`
	SESignatureS string `json:"se_signature_s"`

	// Behavioral statistics (private witnesses; constrained by the circuit).
	HumanScore     int   `json:"human_score"`
	IKIValuesMs    []int `json:"iki_values_ms"`
	KeystrokeCount int   `json:"keystroke_count"`

	// ContentHashPriv is the full 256-bit content hash as a hex string.
	// The circuit verifies that ContentHashLo and ContentHashHi are its halves.
	ContentHashPriv string `json:"content_hash_priv"`
}

// ProofOutput is the result of a successful Groth16 proving operation.
// It is serialized to JSON and returned to the Swift caller.
//
// Wire encoding contract (INTEGRATION.md §2.3, §6.2): every byte string crosses
// the FFI boundary as a `0x`-prefixed lowercase hex string — never base64.  A
// previous version typed ProofBytes as []byte, which Go's json.Marshal encodes
// as base64; the Swift decoder expected a hex string and failed on every call.
type ProofOutput struct {
	// ProofBytes is the 256-byte serialized Groth16 proof as a 0x-prefixed hex
	// string (512 hex digits):
	//   [0:64]    Ar  (G1 point: 32-byte X || 32-byte Y, big-endian)
	//   [64:192]  Bs  (G2 point: A1||A0 for X, A1||A0 for Y, each 32 bytes)
	//   [192:256] Krs (G1 point: 32-byte X || 32-byte Y, big-endian)
	// See PROOF_FORMAT.md §1.2 for the byte map.
	ProofBytes string `json:"proof_bytes"`

	// PublicInputs holds the 5 BN254 scalar field elements as 0x-prefixed
	// hex strings, in the order defined by the circuit:
	//   [0] UsernameHash
	//   [1] ContentHashLo
	//   [2] ContentHashHi
	//   [3] Nullifier
	//   [4] CommitmentRoot
	PublicInputs []string `json:"public_inputs"`

	// Nullifier is a convenience copy of PublicInputs[3] (the anti-replay
	// token), so the Swift tx builder need not index into the array.
	Nullifier string `json:"nullifier"`
}

// RawProof decodes ProofBytes (a 0x-hex string) back to the 256 raw bytes.
func (o *ProofOutput) RawProof() ([]byte, error) {
	s := strings.TrimPrefix(strings.TrimPrefix(o.ProofBytes, "0x"), "0X")
	return hex.DecodeString(s)
}

// Prove generates a Groth16 proof for the given ProverInput.
//
// The function:
//  1. Parses all inputs and converts hex strings to big.Int field elements.
//  2. Computes the Poseidon nullifier natively (same library as the circuit,
//     so results are guaranteed identical) to populate the public input.
//  3. Assigns the full witness (public + private).
//  4. Compiles the circuit, runs groth16.Setup, and generates the proof.
//  5. Serializes the proof to the PROOF_FORMAT.md 256-byte wire format.
//
// Trusted setup note: this function calls groth16.Setup internally for
// demonstration purposes.  Production deployments MUST use a proving key
// derived from the multi-party ceremony (see ZK_CIRCUIT.md).
func Prove(input ProverInput) (*ProofOutput, error) {
	// --- Parse all hex field elements ---
	usernameHash, err := hexToBigInt(input.UsernameHash)
	if err != nil {
		return nil, fmt.Errorf("prove: username_hash: %w", err)
	}
	contentHashLo, err := hexToBigInt(input.ContentHashLo)
	if err != nil {
		return nil, fmt.Errorf("prove: content_hash_lo: %w", err)
	}
	contentHashHi, err := hexToBigInt(input.ContentHashHi)
	if err != nil {
		return nil, fmt.Errorf("prove: content_hash_hi: %w", err)
	}
	contentHashPriv, err := hexToBigInt(input.ContentHashPriv)
	if err != nil {
		return nil, fmt.Errorf("prove: content_hash_priv: %w", err)
	}
	devicePubKeyX, err := hexToBigInt(input.DevicePubKeyX)
	if err != nil {
		return nil, fmt.Errorf("prove: device_pubkey_x: %w", err)
	}
	devicePubKeyY, err := hexToBigInt(input.DevicePubKeyY)
	if err != nil {
		return nil, fmt.Errorf("prove: device_pubkey_y: %w", err)
	}
	blindingFactor, err := hexToBigInt(input.BlindingFactor)
	if err != nil {
		return nil, fmt.Errorf("prove: blinding_factor: %w", err)
	}
	commitmentRoot, err := hexToBigInt(input.CommitmentRoot)
	if err != nil {
		return nil, fmt.Errorf("prove: commitment_root: %w", err)
	}
	sessionCounter := new(big.Int).SetUint64(input.SessionCounter)

	// Validate Merkle path length.
	if len(input.MerklePath) != MerkleDepth {
		return nil, fmt.Errorf("prove: merkle_path must have %d elements, got %d",
			MerkleDepth, len(input.MerklePath))
	}
	if len(input.MerkleDirections) != MerkleDepth {
		return nil, fmt.Errorf("prove: merkle_directions must have %d elements, got %d",
			MerkleDepth, len(input.MerkleDirections))
	}

	// Parse Merkle path elements.
	var merklePath [MerkleDepth]*big.Int
	var merkleDirections [MerkleDepth]int
	for i := 0; i < MerkleDepth; i++ {
		merklePath[i], err = hexToBigInt(input.MerklePath[i])
		if err != nil {
			return nil, fmt.Errorf("prove: merkle_path[%d]: %w", i, err)
		}
		d := input.MerkleDirections[i]
		if d != 0 && d != 1 {
			return nil, fmt.Errorf("prove: merkle_directions[%d] must be 0 or 1, got %d", i, d)
		}
		merkleDirections[i] = d
	}

	// --- Validate behavioral constraints client-side before proving ---
	// These checks mirror the circuit constraints so we fail fast without
	// wasting proving time on an invalid witness.
	if input.HumanScore < MinHumanScore || input.HumanScore > 100 {
		return nil, fmt.Errorf("prove: human_score %d not in [%d, 100]",
			input.HumanScore, MinHumanScore)
	}
	if input.KeystrokeCount < MinKeystrokeCount {
		return nil, fmt.Errorf("prove: keystroke_count %d < minimum %d",
			input.KeystrokeCount, MinKeystrokeCount)
	}
	if len(input.IKIValuesMs) == 0 {
		return nil, errors.New("prove: iki_values_ms must not be empty")
	}
	ikiMin, ikiMax := input.IKIValuesMs[0], input.IKIValuesMs[0]
	for _, v := range input.IKIValuesMs[1:] {
		if v < ikiMin {
			ikiMin = v
		}
		if v > ikiMax {
			ikiMax = v
		}
	}
	if ikiMin < MinIKIMs {
		return nil, fmt.Errorf("prove: iki_min %d ms < minimum %d ms", ikiMin, MinIKIMs)
	}
	if ikiMax > MaxIKIMs {
		return nil, fmt.Errorf("prove: iki_max %d ms > maximum %d ms", ikiMax, MaxIKIMs)
	}

	// --- Compute nullifier natively ---
	// Poseidon(UsernameHash, SessionCounter, BlindingFactor).
	// Uses gnark-crypto's BN254 Poseidon — identical to what the circuit uses —
	// so this value will satisfy the in-circuit nullifier constraint exactly.
	nullifier, err := nativePoseidon(usernameHash, sessionCounter, blindingFactor)
	if err != nil {
		return nil, fmt.Errorf("prove: nullifier: %w", err)
	}

	// --- Assign the full witness ---
	assignment := &AttestationCircuit{
		// Public inputs.
		UsernameHash:   usernameHash,
		ContentHashLo:  contentHashLo,
		ContentHashHi:  contentHashHi,
		Nullifier:      nullifier,
		CommitmentRoot: commitmentRoot,

		// Private witnesses.
		DevicePubKeyX:   devicePubKeyX,
		DevicePubKeyY:   devicePubKeyY,
		SessionCounter:  sessionCounter,
		BlindingFactor:  blindingFactor,
		HumanScore:      input.HumanScore,
		IKIMin:          ikiMin,
		IKIMax:          ikiMax,
		KeystrokeCount:  input.KeystrokeCount,
		ContentHashPriv: contentHashPriv,
	}
	for i := 0; i < MerkleDepth; i++ {
		assignment.MerklePath[i] = merklePath[i]
		assignment.MerkleDirections[i] = merkleDirections[i]
	}

	// --- Load the fixed constraint system + proving key ---
	// One committed key is shared by every prover and verifier in the system.
	// (Previously this ran groth16.Setup() per call, minting a fresh random key
	// each time so no proof could verify against a stored verifying key.)
	dir := KeyDir()
	ccs, err := LoadConstraintSystem(dir)
	if err != nil {
		return nil, fmt.Errorf("prove: load constraint system (run `go run ./cmd/setup`): %w", err)
	}
	pk, err := LoadProvingKey(dir)
	if err != nil {
		return nil, fmt.Errorf("prove: load proving key (run `go run ./cmd/setup`): %w", err)
	}

	// --- Full witness ---
	fullWitness, err := frontend.NewWitness(assignment, ecc.BN254.ScalarField())
	if err != nil {
		return nil, fmt.Errorf("prove: witness: %w", err)
	}

	// --- Prove ---
	proof, err := groth16.Prove(ccs, pk, fullWitness)
	if err != nil {
		return nil, fmt.Errorf("prove: groth16: %w", err)
	}

	// --- Serialize proof to 256-byte wire format ---
	proofBytes, err := serializeProof(proof)
	if err != nil {
		return nil, fmt.Errorf("prove: serialize: %w", err)
	}

	// --- Public inputs as hex strings ---
	// Build them directly from the known values rather than parsing the witness
	// binary — this avoids gnark witness API version skew.
	nullifierHex := "0x" + nullifier.Text(16)
	publicInputs := []string{
		"0x" + usernameHash.Text(16),
		"0x" + contentHashLo.Text(16),
		"0x" + contentHashHi.Text(16),
		nullifierHex,
		"0x" + commitmentRoot.Text(16),
	}

	return &ProofOutput{
		ProofBytes:   "0x" + hex.EncodeToString(proofBytes),
		PublicInputs: publicInputs,
		Nullifier:    nullifierHex,
	}, nil
}

// --------------------------------------------------------------------------
// Internal helpers
// --------------------------------------------------------------------------

// nativePoseidon computes Poseidon(inputs...) in a way that is consistent
// with the in-circuit poseidonGadget in circuit.go.
//
// For 1 or 2 inputs: delegates to iden3's Hash (t=3, Rf=8, Rp=57) directly.
//
// For 3 inputs: uses nested 2-input hashes — Poseidon(Poseidon(a,b),c) —
// which mirrors the circuit's 3-input case.  iden3's Hash([a,b,c]) uses a
// different parameter set (t=4, Rp=60), so we cannot use it here.
//
// This ensures the nullifier computed natively equals the nullifier the
// circuit derives from the private witnesses, satisfying the constraint:
//
//	Nullifier == Poseidon(Poseidon(UsernameHash, SessionCounter), BlindingFactor)
func nativePoseidon(inputs ...*big.Int) (*big.Int, error) {
	if len(inputs) == 3 {
		inner, err := poseidon.HashTwo(inputs[0], inputs[1])
		if err != nil {
			return nil, err
		}
		return poseidon.HashTwo(inner, inputs[2])
	}
	return poseidon.Hash(inputs)
}

// hexToBigInt parses a hex string (with or without 0x prefix) to a *big.Int.
// Odd-length strings are left-padded with a zero nibble so that values like
// "0x2" parse correctly — field elements are numbers, not byte arrays, so a
// leading zero nibble is semantically meaningless and must be accepted.
func hexToBigInt(s string) (*big.Int, error) {
	s = strings.TrimSpace(s)
	s = strings.TrimPrefix(s, "0x")
	s = strings.TrimPrefix(s, "0X")
	if s == "" {
		return nil, errors.New("empty hex string")
	}
	if len(s)%2 == 1 {
		s = "0" + s
	}
	b, err := hex.DecodeString(s)
	if err != nil {
		return nil, fmt.Errorf("invalid hex: %w", err)
	}
	return new(big.Int).SetBytes(b), nil
}

// serializeProof serializes a Groth16 proof to the 256-byte wire format
// (PROOF_FORMAT.md §1.2 / EIP-197 layout):
//
//	[0:32]    Ar.X         big-endian 32-byte BN254 Fq element
//	[32:64]   Ar.Y
//	[64:96]   Bs.X.A1      (imaginary part of Fp2 X coord)
//	[96:128]  Bs.X.A0      (real part of Fp2 X coord)
//	[128:160] Bs.Y.A1
//	[160:192] Bs.Y.A0
//	[192:224] Krs.X
//	[224:256] Krs.Y
//
// We marshal the three curve points directly rather than using
// proof.WriteTo: gnark v0.10's WriteTo uses point compression and appends the
// Pedersen commitment fields (164 bytes compressed), which is neither 256 bytes
// nor the layout the EVM/Solidity verifier expects.  bn254 G1/G2 Marshal emits
// uncompressed big-endian coordinates with the A1-first Fp2 ordering the gnark
// Solidity verifier and the EIP-197 precompile use.  Our circuit uses no
// in-circuit commitments, so Ar||Bs||Krs is the complete proof.
func serializeProof(proof groth16.Proof) ([]byte, error) {
	p, ok := proof.(*groth16bn254.Proof)
	if !ok {
		return nil, fmt.Errorf("serializeProof: expected *bn254.Proof, got %T", proof)
	}
	out := make([]byte, 0, 256)
	ar := p.Ar.Marshal()   // 64 bytes (G1 uncompressed)
	bs := p.Bs.Marshal()   // 128 bytes (G2 uncompressed)
	krs := p.Krs.Marshal() // 64 bytes (G1 uncompressed)
	out = append(out, ar...)
	out = append(out, bs...)
	out = append(out, krs...)
	if len(out) != 256 {
		return nil, fmt.Errorf("serializeProof: got %d bytes, expected 256", len(out))
	}
	return out, nil
}

// DeserializeProof reconstructs a Groth16 proof from the 256-byte wire format
// produced by serializeProof.  It is the inverse of serializeProof and is used
// by Verify (and mirrored by the Sur Chain verifier).
func DeserializeProof(b []byte) (groth16.Proof, error) {
	if len(b) != 256 {
		return nil, fmt.Errorf("DeserializeProof: expected 256 bytes, got %d", len(b))
	}
	p := &groth16bn254.Proof{}
	if err := p.Ar.Unmarshal(b[0:64]); err != nil {
		return nil, fmt.Errorf("DeserializeProof: Ar: %w", err)
	}
	if err := p.Bs.Unmarshal(b[64:192]); err != nil {
		return nil, fmt.Errorf("DeserializeProof: Bs: %w", err)
	}
	if err := p.Krs.Unmarshal(b[192:256]); err != nil {
		return nil, fmt.Errorf("DeserializeProof: Krs: %w", err)
	}
	return p, nil
}
