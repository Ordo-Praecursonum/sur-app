// Command genfixture produces a real attestation proof fixture for the Sur
// Chain's x/attestation verification tests.  Because the chain is a separate Go
// module that only needs to VERIFY (not prove), it cannot import the prover; it
// consumes this committed fixture plus a copy of the verifying key instead.
//
// Usage:
//
//	go run ./cmd/genfixture <chain-keeper-dir>
//
// where <chain-keeper-dir> is the SurChain x/attestation/keeper directory. It
// writes:
//
//	<dir>/keys/attestation.vk                 (copy of the verifying key)
//	<dir>/testdata/attestation_fixture.json   (proof + public message fields)
//
// The fixture's public inputs are derived with the canonical UsernameHashField
// and SplitContentHash helpers, so the chain reconstructs the identical public
// inputs from (username, content_hash) and the proof verifies.
package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"os"
	"path/filepath"

	"github.com/sur-protocol/surcorelibs/gnark"
	"github.com/sur-protocol/surcorelibs/poseidon"
)

// fixtureJSON mirrors the fields of MsgSubmitAttestation that the chain needs,
// all as 0x-prefixed hex (except username).
type fixtureJSON struct {
	Username       string `json:"username"`
	ContentHashHex string `json:"content_hash"`    // 32 bytes
	NullifierHex   string `json:"nullifier"`        // 32 bytes
	CommitmentRoot string `json:"commitment_root"`  // 32 bytes
	ProofHex       string `json:"proof_bytes"`      // 256 bytes
	VKSHA256       string `json:"vk_sha256"`        // for sanity cross-check
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: genfixture <chain-keeper-dir>")
		os.Exit(1)
	}
	keeperDir := os.Args[1]
	keysDir := filepath.Join(keeperDir, "keys")
	testdataDir := filepath.Join(keeperDir, "testdata")
	for _, d := range []string{keysDir, testdataDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			fatal("mkdir %s: %v", d, err)
		}
	}

	must := func(h *big.Int, err error) *big.Int {
		if err != nil {
			fatal("poseidon: %v", err)
		}
		return h
	}
	hashTwo := func(a, b *big.Int) *big.Int { return must(poseidon.HashTwo(a, b)) }

	// --- Public binding values ---
	username := "alice"
	contentHash := make([]byte, 32)
	contentHash[0] = 0x01 // keep < r and clearly non-zero
	for i := 1; i < 32; i++ {
		contentHash[i] = byte(i)
	}
	uh := must(gnark.UsernameHashField(username))
	lo, hi, err := gnark.SplitContentHash(contentHash)
	if err != nil {
		fatal("split content hash: %v", err)
	}
	priv := new(big.Int).SetBytes(contentHash)

	// --- Device witness + consistent Merkle root ---
	x := big.NewInt(11)
	y := big.NewInt(22)
	bf := big.NewInt(33)
	var counter uint64 = 7

	commitment := hashTwo(hashTwo(x, y), bf)
	current := hashTwo(commitment, big.NewInt(0)) // leaf = Poseidon(commitment)
	depth := gnark.MerkleDepth
	path := make([]string, depth)
	dirs := make([]int, depth)
	for i := 0; i < depth; i++ {
		sib := big.NewInt(int64(101 + i))
		path[i] = "0x" + sib.Text(16)
		dirs[i] = 0
		current = hashTwo(current, sib)
	}
	root := current

	in := gnark.ProverInput{
		UsernameHash:     "0x" + uh.Text(16),
		ContentHashLo:    "0x" + lo.Text(16),
		ContentHashHi:    "0x" + hi.Text(16),
		ContentHashPriv:  "0x" + priv.Text(16),
		DevicePubKeyX:    "0x" + x.Text(16),
		DevicePubKeyY:    "0x" + y.Text(16),
		SessionCounter:   counter,
		BlindingFactor:   "0x" + bf.Text(16),
		CommitmentRoot:   "0x" + root.Text(16),
		MerklePath:       path,
		MerkleDirections: dirs,
		SESignatureR:     "0x1",
		SESignatureS:     "0x1",
		HumanScore:       75,
		IKIValuesMs:      []int{100, 150, 200, 120, 90, 180, 140, 110, 160, 130},
		KeystrokeCount:   10,
	}

	out, err := gnark.Prove(in)
	if err != nil {
		fatal("prove: %v", err)
	}
	rawProof, err := out.RawProof()
	if err != nil {
		fatal("raw proof: %v", err)
	}

	// nullifier (public[3]) and root (public[4]) as 32-byte big-endian.
	nullifier := fieldHexToBytes32(out.PublicInputs[3])
	rootBytes := fieldHexToBytes32(out.PublicInputs[4])

	vkHash, err := gnark.VerifyingKeyHash(gnark.KeyDir())
	if err != nil {
		fatal("vk hash: %v", err)
	}

	fx := fixtureJSON{
		Username:       username,
		ContentHashHex: "0x" + hex.EncodeToString(contentHash),
		NullifierHex:   "0x" + hex.EncodeToString(nullifier),
		CommitmentRoot: "0x" + hex.EncodeToString(rootBytes),
		ProofHex:       "0x" + hex.EncodeToString(rawProof),
		VKSHA256:       vkHash,
	}
	blob, err := json.MarshalIndent(fx, "", "  ")
	if err != nil {
		fatal("marshal fixture: %v", err)
	}
	fixturePath := filepath.Join(testdataDir, "attestation_fixture.json")
	if err := os.WriteFile(fixturePath, blob, 0o644); err != nil {
		fatal("write fixture: %v", err)
	}

	// Copy the verifying key for the chain to embed.
	if err := copyFile(filepath.Join(gnark.KeyDir(), "attestation.vk"), filepath.Join(keysDir, "attestation.vk")); err != nil {
		fatal("copy vk: %v", err)
	}

	fmt.Printf("wrote %s\nwrote %s\nvk sha256 = %s\n", fixturePath, filepath.Join(keysDir, "attestation.vk"), vkHash)
}

// fieldHexToBytes32 parses a 0x-hex field element and returns its 32-byte
// big-endian (left-padded) representation.
func fieldHexToBytes32(s string) []byte {
	if len(s) >= 2 && (s[:2] == "0x" || s[:2] == "0X") {
		s = s[2:]
	}
	if len(s)%2 == 1 {
		s = "0" + s
	}
	b, err := hex.DecodeString(s)
	if err != nil {
		fatal("bad field hex %q: %v", s, err)
	}
	out := make([]byte, 32)
	copy(out[32-len(b):], b)
	return out
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
