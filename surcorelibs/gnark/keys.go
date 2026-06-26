package gnark

// keys.go centralises the Groth16 key lifecycle for the attestation circuit.
//
// A working ZK system needs ONE fixed (proving key, verifying key) pair that
// the prover (iOS / surcorelibs) and the verifier (Sur Chain x/attestation,
// and the settlement contracts) all agree on.  Previously Prove() called
// groth16.Setup() on every invocation, producing a fresh random key each time,
// so no proof could ever verify against a stored verifying key.
//
// This file generates the key set once (GenerateKeys), persists it to disk
// (gnark/keys/), and loads it for proving and verifying.  The on-disk keys are
// committed to the repository so prover and verifier are byte-identical.
//
// Production note: the committed key is a DEVELOPMENT key produced by a single
// local groth16.Setup.  A production deployment MUST replace it with the output
// of a multi-party trusted-setup ceremony (see ZK_CIRCUIT.md).  The ceremony
// changes only the bytes of these files; the loading code is unchanged.
//
// The verifying key hash (sha256 over the canonical serialization) is the value
// the chain stores as `verification_key_hash` and the iOS app embeds, so all
// parties can detect a key mismatch immediately.

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/backend/groth16"
	"github.com/consensys/gnark/constraint"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/r1cs"
)

// Key artifact filenames within the key directory.
const (
	provingKeyFile   = "attestation.pk"
	verifyingKeyFile = "attestation.vk"
	constraintsFile  = "attestation.ccs"
	vkHashFile       = "attestation_vk.sha256"
)

// KeyDir resolves the directory holding the committed key artifacts.
//
// Resolution order:
//  1. The SUR_KEY_DIR environment variable, if set (used by CI and the chain).
//  2. The `keys` directory next to this source file (used by tests and the
//     local toolchain), located via runtime.Caller so it works regardless of
//     the process working directory.
func KeyDir() string {
	if dir := os.Getenv("SUR_KEY_DIR"); dir != "" {
		return dir
	}
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		return "keys"
	}
	return filepath.Join(filepath.Dir(thisFile), "keys")
}

// CompileCircuit compiles the AttestationCircuit to a BN254 R1CS.
// Compilation is deterministic, so the same circuit always yields the same
// constraint system (and thus a key generated from it stays compatible).
func CompileCircuit() (constraint.ConstraintSystem, error) {
	return frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, &AttestationCircuit{})
}

// GenerateKeys compiles the circuit, runs a single groth16.Setup, and writes
// the constraint system, proving key, verifying key, and verifying-key hash to
// dir.  It is invoked by cmd/setup and by tests that need a guaranteed-present
// key set.  Existing files are overwritten.
func GenerateKeys(dir string) error {
	ccs, err := CompileCircuit()
	if err != nil {
		return fmt.Errorf("GenerateKeys: compile: %w", err)
	}
	pk, vk, err := groth16.Setup(ccs)
	if err != nil {
		return fmt.Errorf("GenerateKeys: setup: %w", err)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("GenerateKeys: mkdir: %w", err)
	}
	if err := writeTo(filepath.Join(dir, constraintsFile), ccs); err != nil {
		return err
	}
	if err := writeTo(filepath.Join(dir, provingKeyFile), pk); err != nil {
		return err
	}
	if err := writeTo(filepath.Join(dir, verifyingKeyFile), vk); err != nil {
		return err
	}

	// Persist the verifying-key hash so prover, chain, and contracts can detect
	// a key mismatch without comparing the full multi-megabyte key.
	var vkBuf bytes.Buffer
	if _, err := vk.WriteTo(&vkBuf); err != nil {
		return fmt.Errorf("GenerateKeys: serialize vk for hash: %w", err)
	}
	sum := sha256.Sum256(vkBuf.Bytes())
	if err := os.WriteFile(filepath.Join(dir, vkHashFile), []byte(fmt.Sprintf("%x\n", sum)), 0o644); err != nil {
		return fmt.Errorf("GenerateKeys: write vk hash: %w", err)
	}
	return nil
}

// keyReader opens a key artifact, preferring the on-disk copy in dir (used by
// CI, tests, and a future trusted-setup key swap) and falling back to the bytes
// embedded in the binary (used on a real device, where dir does not exist).
func keyReader(dir, file string, embedded []byte) (io.Reader, func(), error) {
	if f, err := os.Open(filepath.Join(dir, file)); err == nil {
		return f, func() { f.Close() }, nil
	}
	if len(embedded) == 0 {
		return nil, nil, fmt.Errorf("key %q not found in %q and not embedded", file, dir)
	}
	return bytes.NewReader(embedded), func() {}, nil
}

// LoadConstraintSystem reads the committed BN254 R1CS (disk, else embedded).
func LoadConstraintSystem(dir string) (constraint.ConstraintSystem, error) {
	r, closer, err := keyReader(dir, constraintsFile, embeddedConstraints)
	if err != nil {
		return nil, fmt.Errorf("LoadConstraintSystem: %w", err)
	}
	defer closer()
	ccs := groth16.NewCS(ecc.BN254)
	if _, err := ccs.ReadFrom(r); err != nil {
		return nil, fmt.Errorf("LoadConstraintSystem: read: %w", err)
	}
	return ccs, nil
}

// LoadProvingKey reads the committed proving key (disk, else embedded).
func LoadProvingKey(dir string) (groth16.ProvingKey, error) {
	r, closer, err := keyReader(dir, provingKeyFile, embeddedProvingKey)
	if err != nil {
		return nil, fmt.Errorf("LoadProvingKey: %w", err)
	}
	defer closer()
	pk := groth16.NewProvingKey(ecc.BN254)
	if _, err := pk.ReadFrom(r); err != nil {
		return nil, fmt.Errorf("LoadProvingKey: read: %w", err)
	}
	return pk, nil
}

// LoadVerifyingKey reads the committed verifying key (disk, else embedded).
func LoadVerifyingKey(dir string) (groth16.VerifyingKey, error) {
	r, closer, err := keyReader(dir, verifyingKeyFile, embeddedVerifyingKey)
	if err != nil {
		return nil, fmt.Errorf("LoadVerifyingKey: %w", err)
	}
	defer closer()
	vk := groth16.NewVerifyingKey(ecc.BN254)
	if _, err := vk.ReadFrom(r); err != nil {
		return nil, fmt.Errorf("LoadVerifyingKey: read: %w", err)
	}
	return vk, nil
}

// VerifyingKeyHash returns the lowercase hex sha256 of the canonical verifying
// key serialization in dir.  This is the value mirrored on-chain.
func VerifyingKeyHash(dir string) (string, error) {
	vk, err := LoadVerifyingKey(dir)
	if err != nil {
		return "", err
	}
	var buf bytes.Buffer
	if _, err := vk.WriteTo(&buf); err != nil {
		return "", fmt.Errorf("VerifyingKeyHash: serialize: %w", err)
	}
	sum := sha256.Sum256(buf.Bytes())
	return fmt.Sprintf("%x", sum), nil
}

// writeTo serializes a gnark artifact (ccs/pk/vk all implement io.WriterTo) to
// path.  Used for the committed development key set.
func writeTo(path string, w io.WriterTo) error {
	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("writeTo %s: %w", path, err)
	}
	defer f.Close()
	if _, err := w.WriteTo(f); err != nil {
		return fmt.Errorf("writeTo %s: serialize: %w", path, err)
	}
	return nil
}
