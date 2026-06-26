// Package main is the CGo FFI bridge that exposes the Sur Protocol gnark
// Groth16 prover to Swift via a C-callable interface.
//
// Building
// --------
// This package must be compiled with CGo enabled and buildmode=c-archive:
//
//	CC=$(xcrun --sdk iphoneos --find clang) \
//	CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
//	go build -buildmode=c-archive -o build/libsurcorelibs.a ./ffi/
//
// The compiler generates libsurcorelibs.a (static archive) and
// libsurcorelibs.h (C header) in the same output directory.
//
// Swift usage
// -----------
//
//	import libsurcorelibs
//
//	func prove(inputJSON: String) throws -> String {
//	    var outputPtr: UnsafeMutablePointer<CChar>? = nil
//	    var errPtr: UnsafeMutablePointer<CChar>? = nil
//	    let rc = ProveAttestation(inputJSON, &outputPtr, &errPtr)
//	    defer {
//	        FreeString(outputPtr)
//	        FreeString(errPtr)
//	    }
//	    guard rc == 0, let ptr = outputPtr else {
//	        throw ProveError(String(cString: errPtr!))
//	    }
//	    return String(cString: ptr)
//	}
//
// Memory contract
// ---------------
// All strings written to *outputJSON or *errOut are heap-allocated by Go's
// CGo runtime.  The Swift caller MUST call FreeString on each non-nil pointer
// exactly once, after it has finished reading the string.  Failing to call
// FreeString leaks memory.  Calling FreeString twice is undefined behavior.
//
// Thread safety
// -------------
// ProveAttestation is safe to call from any thread.  gnark's proving
// operations are internally thread-safe.  Concurrent proof generation is
// supported but will consume significant memory (≥ 256 MB per concurrent prove
// call for this circuit).
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/hex"
	"encoding/json"
	"math/big"
	"strings"
	"unsafe"

	"github.com/sur-protocol/surcorelibs/gnark"
)

// ProveAttestation is the primary FFI entry point called by the Swift side.
//
// Parameters:
//
//	inputJSON   — C string containing a JSON-encoded ProverInput.  Must not be nil.
//	outputJSON  — pointer to a C string pointer.  On success (return 0), *outputJSON
//	              points to a newly allocated C string containing a JSON-encoded
//	              ProofOutput.  The caller must free this with FreeString.
//	errOut      — pointer to a C string pointer.  On failure (return -1), *errOut
//	              points to a newly allocated C string containing the error message.
//	              The caller must free this with FreeString.
//
// Return value:
//
//	0   success; *outputJSON is set, *errOut is nil.
//	-1  failure; *errOut is set, *outputJSON is nil.
//
//export ProveAttestation
func ProveAttestation(inputJSON *C.char, outputJSON **C.char, errOut **C.char) C.int {
	// Defensively clear the output pointers so the Swift side always sees a
	// well-defined value, even if we return early.
	*outputJSON = nil
	*errOut = nil

	if inputJSON == nil {
		msg := "ProveAttestation: inputJSON must not be nil"
		*errOut = C.CString(msg)
		return -1
	}

	// Convert the C string to a Go string.  This copies the bytes; the original
	// C string is unmodified and the Swift caller retains ownership.
	goInputJSON := C.GoString(inputJSON)

	// Parse the JSON input.
	var input gnark.ProverInput
	if err := json.Unmarshal([]byte(goInputJSON), &input); err != nil {
		*errOut = C.CString("ProveAttestation: JSON parse error: " + err.Error())
		return -1
	}

	// Generate the proof.
	proofOutput, err := gnark.Prove(input)
	if err != nil {
		*errOut = C.CString("ProveAttestation: prove error: " + err.Error())
		return -1
	}

	// Serialize the proof output to JSON.
	outBytes, err := json.Marshal(proofOutput)
	if err != nil {
		*errOut = C.CString("ProveAttestation: JSON marshal error: " + err.Error())
		return -1
	}

	// Allocate a C string for the result.  The Swift caller is responsible for
	// freeing this with FreeString.
	*outputJSON = C.CString(string(outBytes))
	return 0
}

// ComputeCommitment computes the device commitment
// Poseidon(devicePubKeyX, devicePubKeyY, blindingFactor) (nested 3-input, matching
// the circuit) and writes it to *out as a 0x-prefixed 32-byte big-endian hex string.
// The Swift app uses this for first_commitment / new_commitment during device
// registration.  Inputs are hex strings (with or without 0x prefix).
//
// Returns 0 on success (*out set, *errOut nil) or -1 on failure (*errOut set).
//
//export ComputeCommitment
func ComputeCommitment(xHex, yHex, blindingHex *C.char, out **C.char, errOut **C.char) C.int {
	*out = nil
	*errOut = nil
	if xHex == nil || yHex == nil || blindingHex == nil {
		*errOut = C.CString("ComputeCommitment: nil input")
		return -1
	}
	x, err := parseHexField(C.GoString(xHex))
	if err != nil {
		*errOut = C.CString("ComputeCommitment: x: " + err.Error())
		return -1
	}
	y, err := parseHexField(C.GoString(yHex))
	if err != nil {
		*errOut = C.CString("ComputeCommitment: y: " + err.Error())
		return -1
	}
	bf, err := parseHexField(C.GoString(blindingHex))
	if err != nil {
		*errOut = C.CString("ComputeCommitment: blinding: " + err.Error())
		return -1
	}
	c, err := gnark.Commitment(x, y, bf)
	if err != nil {
		*errOut = C.CString("ComputeCommitment: " + err.Error())
		return -1
	}
	*out = C.CString(fieldTo0xHex(c))
	return 0
}

// ComputeUsernameHash computes the canonical username hash (Poseidon over the
// username's UTF-8 bytes packed into 31-byte field limbs) and writes it to *out
// as a 0x-prefixed 32-byte big-endian hex string.  Matches the value the chain
// reconstructs when verifying an attestation.
//
//export ComputeUsernameHash
func ComputeUsernameHash(username *C.char, out **C.char, errOut **C.char) C.int {
	*out = nil
	*errOut = nil
	if username == nil {
		*errOut = C.CString("ComputeUsernameHash: nil input")
		return -1
	}
	h, err := gnark.UsernameHashField(C.GoString(username))
	if err != nil {
		*errOut = C.CString("ComputeUsernameHash: " + err.Error())
		return -1
	}
	*out = C.CString(fieldTo0xHex(h))
	return 0
}

// ComputeMerkleWitness returns the commitment Merkle root and inclusion path for a
// single registered device (leaf index 0), as JSON:
//
//	{"commitment_root":"0x..","merkle_path":["0x..", ... 8 entries]}
//
// directions are all 0 (omitted; the device is always the left child). The Swift
// app feeds these into the ProverInput so the generated proof verifies on-chain.
//
//export ComputeMerkleWitness
func ComputeMerkleWitness(xHex, yHex, blindingHex *C.char, out **C.char, errOut **C.char) C.int {
	*out = nil
	*errOut = nil
	if xHex == nil || yHex == nil || blindingHex == nil {
		*errOut = C.CString("ComputeMerkleWitness: nil input")
		return -1
	}
	x, err := parseHexField(C.GoString(xHex))
	if err != nil {
		*errOut = C.CString("ComputeMerkleWitness: x: " + err.Error())
		return -1
	}
	y, err := parseHexField(C.GoString(yHex))
	if err != nil {
		*errOut = C.CString("ComputeMerkleWitness: y: " + err.Error())
		return -1
	}
	bf, err := parseHexField(C.GoString(blindingHex))
	if err != nil {
		*errOut = C.CString("ComputeMerkleWitness: blinding: " + err.Error())
		return -1
	}
	root, path, err := gnark.SingleDeviceMerkleWitness(x, y, bf)
	if err != nil {
		*errOut = C.CString("ComputeMerkleWitness: " + err.Error())
		return -1
	}
	pathHex := make([]string, len(path))
	for i, p := range path {
		pathHex[i] = fieldTo0xHex(p)
	}
	blob, err := json.Marshal(map[string]any{
		"commitment_root": fieldTo0xHex(root),
		"merkle_path":     pathHex,
	})
	if err != nil {
		*errOut = C.CString("ComputeMerkleWitness: marshal: " + err.Error())
		return -1
	}
	*out = C.CString(string(blob))
	return 0
}

// parseHexField parses a hex string (optional 0x prefix, odd length tolerated)
// into a big.Int field element.
func parseHexField(s string) (*big.Int, error) {
	s = strings.TrimSpace(s)
	s = strings.TrimPrefix(s, "0x")
	s = strings.TrimPrefix(s, "0X")
	if len(s)%2 == 1 {
		s = "0" + s
	}
	b, err := hex.DecodeString(s)
	if err != nil {
		return nil, err
	}
	return new(big.Int).SetBytes(b), nil
}

// fieldTo0xHex renders a field element as a 0x-prefixed 32-byte big-endian hex string.
func fieldTo0xHex(v *big.Int) string {
	out := make([]byte, 32)
	v.FillBytes(out)
	return "0x" + hex.EncodeToString(out)
}

// FreeString releases a C string that was allocated by ProveAttestation.
//
// The Swift caller MUST call this exactly once for each non-nil pointer
// returned via outputJSON or errOut from ProveAttestation.
//
//export FreeString
func FreeString(s *C.char) {
	if s != nil {
		C.free(unsafe.Pointer(s))
	}
}

// main is required by the `package main` declaration when building with
// -buildmode=c-archive.  It is never called.
func main() {}
