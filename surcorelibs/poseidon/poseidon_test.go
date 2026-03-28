package poseidon

import (
"encoding/json"
"math/big"
"os"
"testing"
)

// TestVector represents a single Poseidon test vector for cross-project validation.
type TestVector struct {
Inputs   []string `json:"inputs"`
Expected string   `json:"expected"`
Label    string   `json:"label"`
}

// TestVectorsFile is the top-level structure for the shared test vectors JSON.
type TestVectorsFile struct {
Description string       `json:"description"`
Parameters  Parameters   `json:"parameters"`
Vectors     []TestVector `json:"vectors"`
}

// Parameters describes the Poseidon instantiation parameters.
type Parameters struct {
Field         string `json:"field"`
Rate          int    `json:"rate"`
Capacity      int    `json:"capacity"`
FullRounds    int    `json:"full_rounds"`
PartialRounds int    `json:"partial_rounds"`
SBox          string `json:"sbox"`
}

// canonicalTestVector is the anchor from PROOF_FORMAT.md §6.1.
const canonicalExpected = "0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a"

func TestPoseidonCanonical(t *testing.T) {
result, err := Hash(big.NewInt(1), big.NewInt(2))
if err != nil {
t.Fatalf("Hash(1, 2) error: %v", err)
}
got := "0x" + result.Text(16)
if got != canonicalExpected {
t.Fatalf("Poseidon(1, 2) = %s; want %s", got, canonicalExpected)
}
}

func TestPoseidonBytes(t *testing.T) {
input1 := big.NewInt(1).Bytes()
input2 := big.NewInt(2).Bytes()
resultBytes, err := HashBytes(input1, input2)
if err != nil {
t.Fatalf("HashBytes(1, 2) error: %v", err)
}
resultBig := new(big.Int).SetBytes(resultBytes)
got := "0x" + resultBig.Text(16)
if got != canonicalExpected {
t.Fatalf("HashBytes(1, 2) = %s; want %s", got, canonicalExpected)
}
}

func TestNullifierHash(t *testing.T) {
pk := big.NewInt(12345)

n1, err := NullifierHash(pk, 0)
if err != nil {
t.Fatal(err)
}
n2, err := NullifierHash(pk, 1)
if err != nil {
t.Fatal(err)
}

// Different counters must produce different nullifiers
if n1.Cmp(n2) == 0 {
t.Fatal("NullifierHash must produce different outputs for different counters")
}

// Same inputs must produce same output (deterministic)
n1Again, _ := NullifierHash(pk, 0)
if n1.Cmp(n1Again) != 0 {
t.Fatal("NullifierHash must be deterministic")
}
}

func TestMerkleHash(t *testing.T) {
left := big.NewInt(100)
right := big.NewInt(200)

h, err := MerkleHash(left, right)
if err != nil {
t.Fatal(err)
}

// Non-zero result
if h.Sign() == 0 {
t.Fatal("MerkleHash should not return zero for non-zero inputs")
}

// Order matters (not commutative for Poseidon)
hReverse, _ := MerkleHash(right, left)
if h.Cmp(hReverse) == 0 {
t.Fatal("MerkleHash should not be commutative")
}
}

func TestCommitmentHash(t *testing.T) {
pk := big.NewInt(42)
blinding := big.NewInt(999)

c, err := CommitmentHash(pk, blinding)
if err != nil {
t.Fatal(err)
}
if c.Sign() == 0 {
t.Fatal("CommitmentHash should not return zero for non-zero inputs")
}
}

// TestAllVectors loads test_vectors.json and verifies all vectors.
func TestAllVectors(t *testing.T) {
data, err := os.ReadFile("test_vectors.json")
if err != nil {
t.Fatalf("Failed to read test_vectors.json: %v", err)
}

var tvf TestVectorsFile
if err := json.Unmarshal(data, &tvf); err != nil {
t.Fatalf("Failed to parse test_vectors.json: %v", err)
}

if len(tvf.Vectors) < 20 {
t.Fatalf("Expected at least 20 test vectors, got %d", len(tvf.Vectors))
}

for _, tv := range tvf.Vectors {
t.Run(tv.Label, func(t *testing.T) {
inputs := make([]*big.Int, len(tv.Inputs))
for i, s := range tv.Inputs {
val, ok := new(big.Int).SetString(s, 0)
if !ok {
t.Fatalf("Invalid input %q", s)
}
inputs[i] = val
}

result, err := Hash(inputs...)
if err != nil {
t.Fatalf("Hash error: %v", err)
}
got := "0x" + result.Text(16)

if got != tv.Expected {
t.Errorf("Poseidon(%v) = %s; want %s", tv.Inputs, got, tv.Expected)
}
})
}
}
