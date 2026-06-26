// Command setup generates the committed Groth16 key set for the Sur attestation
// circuit: the constraint system, proving key, verifying key, and verifying-key
// hash.  Run it whenever the circuit changes:
//
//	go run ./cmd/setup            # writes to gnark/keys (default KeyDir)
//	go run ./cmd/setup ./out      # writes to ./out
//
// The output is a DEVELOPMENT key produced by a single local groth16.Setup.
// Production keys come from a multi-party ceremony (see ZK_CIRCUIT.md); they
// replace only the bytes of these files.
package main

import (
	"fmt"
	"os"

	"github.com/sur-protocol/surcorelibs/gnark"
)

func main() {
	dir := gnark.KeyDir()
	if len(os.Args) > 1 {
		dir = os.Args[1]
	}

	fmt.Printf("Generating attestation Groth16 key set in %s ...\n", dir)
	if err := gnark.GenerateKeys(dir); err != nil {
		fmt.Fprintf(os.Stderr, "setup failed: %v\n", err)
		os.Exit(1)
	}

	hash, err := gnark.VerifyingKeyHash(dir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "setup: read vk hash: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("done. verifying key sha256 = %s\n", hash)
}
