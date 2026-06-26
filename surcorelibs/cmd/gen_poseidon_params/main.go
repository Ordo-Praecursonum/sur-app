// gen_poseidon_params extracts BN254 Poseidon t=3 constants from the iden3
// library and writes poseidon_constants_gen.go for the in-circuit gadget.
//
// The native hash (poseidon/poseidon.go) delegates to iden3's optimized
// Poseidon directly.  The in-circuit gadget must implement the SAME algorithm
// so that circuit outputs match native outputs.  This generator ensures both
// use identical constants (C, S, M, P) from the same source.
//
// Run via:
//
//	cd surcorelibs && go generate ./gnark/
//
// Algorithm: iden3 "optimized" BN254 Poseidon
// (Grassi et al. 2019, §3.2 optimized variant for partial rounds)
//
//	t = 3   (rate=2, capacity=1)
//	Rf = 8  (full rounds: 4 before + 4 after partial rounds)
//	Rp = 57 (partial rounds)
//	S-box: x^5
//
// Constants per t=3 instance:
//
//	C[81]       round constants (initial ARK + full/partial round ARKs)
//	S[285]      sparse linear layer for partial rounds ((2t-1)*Rp = 5*57)
//	M[3][3]     MDS matrix (full rounds)
//	P[3][3]     pre-P matrix (transition from full to partial rounds)
package main

import (
	"bufio"
	"fmt"
	"log"
	"math/big"
	"os"
	"regexp"
	"strings"

	"github.com/sur-protocol/surcorelibs/poseidon"
)

func main() {
	log.SetFlags(0)
	log.SetPrefix("gen_poseidon_params: ")

	// ---- 1. Verify canonical test vector --------------------------------
	want, _ := new(big.Int).SetString(
		"115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a",
		16,
	)
	got, err := poseidon.HashTwo(big.NewInt(1), big.NewInt(2))
	if err != nil {
		log.Fatalf("Poseidon(1,2) failed: %v", err)
	}
	if got.Cmp(want) != 0 {
		log.Fatalf("Poseidon(1,2) mismatch:\n  got  0x%x\n  want 0x%x", got, want)
	}
	log.Printf("canonical test vector OK: Poseidon(1,2) = 0x%x", got)

	// ---- 2. Locate iden3 constants.go in the Go module cache ------------
	iden3Constants := findIden3Constants()
	log.Printf("iden3 constants: %s", iden3Constants)

	// ---- 3. Parse constants for t=3 (index 1) ---------------------------
	parsed, err := parseIden3Constants(iden3Constants)
	if err != nil {
		log.Fatalf("parse iden3 constants: %v", err)
	}
	if len(parsed.C) != 81 {
		log.Fatalf("C[1]: expected 81 elements, got %d", len(parsed.C))
	}
	if len(parsed.S) != 285 {
		log.Fatalf("S[1]: expected 285 elements, got %d", len(parsed.S))
	}
	if len(parsed.M) != 9 {
		log.Fatalf("M[1]: expected 9 elements (3x3), got %d", len(parsed.M))
	}
	if len(parsed.P) != 9 {
		log.Fatalf("P[1]: expected 9 elements (3x3), got %d", len(parsed.P))
	}
	log.Printf("parsed: C=%d S=%d M=%d P=%d", len(parsed.C), len(parsed.S), len(parsed.M), len(parsed.P))

	// ---- 4. Determine output path ---------------------------------------
	outPath := "poseidon_constants_gen.go"
	if len(os.Args) > 1 {
		outPath = os.Args[1]
	}

	// ---- 5. Write generated file ----------------------------------------
	src := generateSource(got, parsed)
	if err := os.WriteFile(outPath, []byte(src), 0o644); err != nil {
		log.Fatalf("write %s: %v", outPath, err)
	}
	log.Printf("wrote %s", outPath)
}

// parsedConstants holds the t=3 constants extracted from iden3.
type parsedConstants struct {
	C []string // 81 hex strings
	S []string // 285 hex strings
	M []string // 9 hex strings  (row-major: M[row][col])
	P []string // 9 hex strings  (row-major: P[row][col])
}

// findIden3Constants locates iden3's poseidon/constants.go in the module cache.
func findIden3Constants() string {
	gopath := os.Getenv("GOPATH")
	if gopath == "" {
		gopath = os.Getenv("HOME") + "/go"
	}
	candidates := []string{
		gopath + "/pkg/mod/github.com/iden3/go-iden3-crypto@v0.0.17/poseidon/constants.go",
	}
	for _, p := range candidates {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	log.Fatalf("cannot find iden3 poseidon/constants.go; install via: go get github.com/iden3/go-iden3-crypto@v0.0.17")
	return ""
}

// parseIden3Constants extracts the t=3 (index 1) C, S, M, P arrays from iden3's
// constants.go file.  The file stores constants as nested string arrays; we
// extract the second inner array (index 1) from each of the four sections.
func parseIden3Constants(path string) (*parsedConstants, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	hexRe := regexp.MustCompile(`"([0-9a-fA-F]{10,})"`) // hex strings ≥10 chars

	type secState int
	const (
		secScanning secState = iota
		secInOuter           // inside outer array, skipping index-0
		secCapturing         // inside index-1 inner array
		secDone
	)

	type section struct {
		name    string
		marker  string
		state   secState
		depth   int
		result  []string
	}

	secs := []*section{
		{name: "C", marker: "C: [][]string{"},
		{name: "S", marker: "S: [][]string{"},
		{name: "M", marker: "M: [][][]string{"},
		{name: "P", marker: "P: [][][]string{"},
	}

	scanner := bufio.NewScanner(f)
	buf := make([]byte, 8*1024*1024)
	scanner.Buffer(buf, len(buf))

	for scanner.Scan() {
		line := scanner.Text()
		opens := strings.Count(line, "{")
		closes := strings.Count(line, "}")

		for _, sec := range secs {
			switch sec.state {
			case secScanning:
				if strings.Contains(line, sec.marker) {
					sec.state = secInOuter
					sec.depth = opens - closes
				}

			case secInOuter:
				sec.depth += opens - closes
				// When depth drops back to 1 after being ≥2, the index-0
				// inner array has just closed.  The next open starts index-1.
				if sec.depth == 1 && closes > 0 {
					sec.state = secCapturing
				}

			case secCapturing:
				sec.depth += opens - closes
				// Capture hex strings on this line.
				for _, m := range hexRe.FindAllStringSubmatch(line, -1) {
					sec.result = append(sec.result, m[1])
				}
				// When depth drops back to 1, the index-1 inner array closed.
				if sec.depth <= 1 && closes > 0 {
					sec.state = secDone
				}
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}

	result := &parsedConstants{}
	for _, sec := range secs {
		switch sec.name {
		case "C":
			result.C = sec.result
		case "S":
			result.S = sec.result
		case "M":
			result.M = sec.result
		case "P":
			result.P = sec.result
		}
	}
	return result, nil
}

// arr1D formats n hex strings as a [n]frontend.Variable literal.
func arr1D(hexStrs []string, size int) string {
	var b strings.Builder
	fmt.Fprintf(&b, "[%d]frontend.Variable{\n", size)
	for _, h := range hexStrs {
		fmt.Fprintf(&b, "\t\tfrontend.Variable(mustHexBigInt(%q)),\n", h)
	}
	b.WriteString("\t}")
	return b.String()
}

// matrix3x3 formats 9 hex strings as a [3][3]frontend.Variable literal.
func matrix3x3(hexStrs []string) string {
	if len(hexStrs) != 9 {
		log.Fatalf("matrix3x3: expected 9 elements, got %d", len(hexStrs))
	}
	var b strings.Builder
	b.WriteString("[3][3]frontend.Variable{\n")
	for row := 0; row < 3; row++ {
		b.WriteString("\t\t{")
		for col := 0; col < 3; col++ {
			fmt.Fprintf(&b, "frontend.Variable(mustHexBigInt(%q)), ", hexStrs[row*3+col])
		}
		b.WriteString("},\n")
	}
	b.WriteString("\t}")
	return b.String()
}

func generateSource(testVec *big.Int, p *parsedConstants) string {
	return fmt.Sprintf(`// Code generated by cmd/gen_poseidon_params. DO NOT EDIT.
//
// BN254 Poseidon constants for the in-circuit optimized gadget.
//
// Source: github.com/iden3/go-iden3-crypto v0.0.17 poseidon/constants.go
// Parameters: t=3, Rf=8, Rp=57, S-box=x^5 (BN254 scalar field)
// Native test vector verified: Poseidon(1,2) = 0x%x
//
// The in-circuit gadget (poseidonGadget in circuit.go) implements the same
// optimized Poseidon algorithm as the iden3 library, ensuring circuit outputs
// and native outputs are identical for any input.
//
// Re-run via: cd surcorelibs && go generate ./gnark/
package gnark

import (
	"math/big"

	"github.com/consensys/gnark/frontend"
)

// mustHexBigInt parses a hex string into a *big.Int for use as a frontend.Variable.
// Called only at package-init time; panics on malformed constants.
func mustHexBigInt(h string) *big.Int {
	b, ok := new(big.Int).SetString(h, 16)
	if !ok {
		panic("poseidon_constants_gen: invalid hex constant: " + h)
	}
	return b
}

// bn254PoseidonC returns the 81 round constants C for BN254 t=3 Poseidon.
//
// Index layout (iden3 poseidon.go conventions, nRoundsF=8, nRoundsP=57, t=3):
//
//	C[0..2]   initial AddRoundKey (before first S-box application)
//	C[3..11]  ARK for full rounds 1-3 of first half (3 rounds × 3 elements)
//	C[12..14] ARK for transition full round (mix with P instead of M)
//	C[15..71] scalar ARK for partial rounds 0-56 (one per round, state[0] only)
//	C[72..80] ARK for second-half full rounds 0-2 (3 rounds × 3 elements)
func bn254PoseidonC() [81]frontend.Variable {
	return %s
}

// bn254PoseidonS returns the 285 sparse linear layer constants for partial rounds.
//
// Layout: S[(2t-1)*i + j] = S[5i+j] for round i in [0,57), j in [0,5).
//   j=0,1,2: coefficients for newState[0] = sum_j S[5i+j] * state[j]
//   j=3,4:   coefficients for state[k] += old_state[0] * S[5i+2+k] (k=1,2)
func bn254PoseidonS() [285]frontend.Variable {
	return %s
}

// bn254PoseidonMDS returns the 3x3 MDS matrix M used in all full rounds
// and the final round (no ARK before final mix).
func bn254PoseidonMDS() [3][3]frontend.Variable {
	return %s
}

// bn254PoseidonP returns the 3x3 P matrix applied in the transition round
// (the nRoundsF/2-th full round, mixing with P instead of M).
func bn254PoseidonP() [3][3]frontend.Variable {
	return %s
}
`,
		testVec,
		arr1D(p.C, 81),
		arr1D(p.S, 285),
		matrix3x3(p.M),
		matrix3x3(p.P),
	)
}
