package gnark

// keys_embed.go bundles the committed Groth16 key artifacts directly into the
// compiled binary via go:embed.
//
// Why: on a real iOS device the prover has no access to the source tree, so the
// runtime.Caller path used by KeyDir() does not exist and the on-disk loaders
// fail ("no such file or directory") — attestation could only ever work on the
// Simulator. Embedding the artifacts makes them travel inside the XCFramework,
// so proving works on device with no filesystem dependency.
//
// The on-disk path is still preferred when present (SUR_KEY_DIR / local tree),
// which keeps CI, tests, and a future trusted-setup key swap working without
// rebuilding: the embedded bytes are only a fallback.

import _ "embed"

//go:embed keys/attestation.pk
var embeddedProvingKey []byte

//go:embed keys/attestation.ccs
var embeddedConstraints []byte

//go:embed keys/attestation.vk
var embeddedVerifyingKey []byte
