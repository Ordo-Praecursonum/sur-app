// Package gnark CGo exports for iOS FFI bridge.
// This file is only compiled when building with CGO_ENABLED=1 for iOS targets.
// It provides the C-callable ProveAttestation and FreeString functions.

//go:build cgo

package gnark

/*
#include <stdlib.h>
*/
import "C"
import (
	"unsafe"
)

// Shared keys for the CGo bridge (initialized on first call).
var cgoKeys *Keys

//export ProveAttestation
func ProveAttestation(inputJSON *C.char) *C.char {
	if cgoKeys == nil {
		var err error
		cgoKeys, err = Setup()
		if err != nil {
			errStr := `{"error":"setup failed: ` + err.Error() + `"}`
			return C.CString(errStr)
		}
	}
	result := ProveJSON(cgoKeys, C.GoString(inputJSON))
	return C.CString(result)
}

//export FreeString
func FreeString(s *C.char) {
	C.free(unsafe.Pointer(s))
}
