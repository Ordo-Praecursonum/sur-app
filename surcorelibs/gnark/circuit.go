// Package gnark implements the Sur Protocol attestation circuit and proving
// infrastructure using gnark Groth16 over BN254.
//
// Circuit overview
// ----------------
// The AttestationCircuit proves in zero knowledge that:
//
//  1. The prover knows a P-256 device public key whose Poseidon commitment
//     is a member of the on-chain device commitment Merkle tree (depth 8).
//
//  2. The Nullifier public input equals
//     Poseidon(UsernameHash, SessionCounter, BlindingFactor),
//     binding the proof to exactly one (device, session) pair.
//
//  3. Behavioral constraints are satisfied:
//     - HumanScore in [50, 100]
//     - KeystrokeCount >= 10
//     - IKIMin >= 20 ms
//     - IKIMax <= 2000 ms
//
//  4. ContentHashLo and ContentHashHi are the low/high 128-bit halves of
//     the private ContentHashPriv value.
//
// Public inputs (5 BN254 scalar field elements, fixed order):
//
//	0: UsernameHash
//	1: ContentHashLo
//	2: ContentHashHi
//	3: Nullifier
//	4: CommitmentRoot
//
// In-circuit Poseidon
// -------------------
// gnark v0.10.0 does not include a std/hash/poseidon package.  The Poseidon
// permutation is implemented here as a gnark gadget using the round constants
// and MDS matrix from gnark-crypto v0.12.1 for BN254 (t=3, Rf=8, Rp=57,
// S-box=x^5).  The constants are generated at build time by the file
// poseidon_params.go in this package, which is produced by the go:generate
// directive in that file.  The canonical test vector in
// poseidon/poseidon_test.go validates cross-consistency.
//
//go:generate go run ../cmd/gen_poseidon_params/main.go poseidon_constants_gen.go
package gnark

import (
	"math/big"

	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/std/math/bits"
)

// MerkleDepth is the fixed depth of the device commitment Merkle tree.
// Depth 8 supports 2^8 = 256 device commitments per user.
// Changing this constant requires a new trusted setup ceremony.
const MerkleDepth = 8

// Behavioral thresholds enforced as private-witness range constraints.
// These values are part of the circuit definition and cannot be changed
// without a new trusted setup ceremony.
const (
	// MinHumanScore is the minimum acceptable behavioral quality score (0–100).
	MinHumanScore = 50

	// MinKeystrokeCount is the minimum number of keystrokes per session.
	MinKeystrokeCount = 10

	// MinIKIMs is the minimum allowed inter-keystroke interval in milliseconds.
	// Below 20 ms is physically impossible for human fingers.
	MinIKIMs = 20

	// MaxIKIMs is the maximum allowed inter-keystroke interval in milliseconds.
	// Above 2000 ms indicates the session has stalled.
	MaxIKIMs = 2000
)

// AttestationCircuit is the top-level gnark circuit for Sur Protocol
// attestation proofs.
//
// Field tags:
//   - `gnark:",public"` — verifier-visible; appears in the Groth16 IC vector
//   - No tag             — private witness; zero-knowledge
//
// Constraint count estimate (BN254 Groth16 R1CS):
//
//	inCircuitPoseidon3(×2):       ~480 R1CS constraints
//	inCircuitPoseidon1(×1):       ~240
//	inCircuitPoseidon2(×8 Merkle):~1920
//	Range checks (bits):          ~320
//	Content hash split:           ~256
//	Total:                        ~3216
//
// On iPhone 15 Pro this circuit proves in approximately 3–8 seconds.
// The P-256 ECDSA sub-circuit (~35 000 constraints via emulated arithmetic)
// is deferred to a subsequent circuit revision.
type AttestationCircuit struct {
	// -------------------------------------------------------------------------
	// Public inputs — 5 BN254 scalar field elements.
	// The order here determines the Groth16 IC vector index assignment and
	// must match the Solidity verifier's uint[5] input parameter exactly.
	// -------------------------------------------------------------------------

	// UsernameHash binds the proof to a username.  It is computed OFF-circuit
	// (see UsernameHashField) as Poseidon over the username's UTF-8 bytes packed
	// into BN254 field limbs, so the Sur Chain can recompute it cheaply with the
	// same Poseidon parameters.  The circuit does not re-derive it from the raw
	// username; it only feeds it into the nullifier constraint below.  Binding to
	// the actual username is enforced by the chain: it recomputes UsernameHash
	// from the submitted username and supplies it as this public input, so a
	// proof made for a different username fails verification.
	UsernameHash frontend.Variable `gnark:",public"`

	// ContentHashLo is the lower 128 bits of SHA-256(message_text).
	// SHA-256 is 256 bits; BN254 scalar field is ~254 bits.  Splitting into
	// two 128-bit halves avoids information loss from modular reduction.
	ContentHashLo frontend.Variable `gnark:",public"`

	// ContentHashHi is the upper 128 bits of SHA-256(message_text).
	ContentHashHi frontend.Variable `gnark:",public"`

	// Nullifier is the anti-replay token, constrained in-circuit to equal
	// Poseidon(UsernameHash, SessionCounter, BlindingFactor).
	// Unique per (device, session); the chain rejects duplicate nullifiers.
	Nullifier frontend.Variable `gnark:",public"`

	// CommitmentRoot is the Poseidon Merkle root of the user's registered
	// device commitment tree, queried from Cosmos x/identity before proving.
	CommitmentRoot frontend.Variable `gnark:",public"`

	// -------------------------------------------------------------------------
	// Private witnesses — zero-knowledge
	// -------------------------------------------------------------------------

	// DevicePubKeyX / Y are the P-256 Secure Enclave public key coordinates,
	// each encoded as a BN254 scalar field element (big-endian 32 bytes, mod r).
	// P-256 field size ≠ BN254 scalar field; coordinates ≥ r are reduced mod r.
	DevicePubKeyX frontend.Variable
	DevicePubKeyY frontend.Variable

	// SessionCounter is a monotonically increasing uint64, incremented after
	// each successful attestation.  Encoded as a BN254 field element.
	SessionCounter frontend.Variable

	// BlindingFactor is a 32-byte random secret generated at device registration
	// and stored in the iOS Keychain.  Used in both the device commitment leaf
	// and the nullifier derivation.
	BlindingFactor frontend.Variable

	// Behavioral statistics — constrained to human-plausible ranges.
	// The verifier learns nothing about these values.
	HumanScore     frontend.Variable // [50, 100]
	IKIMin         frontend.Variable // >= 20 ms
	IKIMax         frontend.Variable // <= 2000 ms
	KeystrokeCount frontend.Variable // >= 10

	// ContentHashPriv is the full 256-bit content hash before splitting.
	// The circuit verifies: ContentHashPriv == ContentHashLo + 2^128 * ContentHashHi.
	ContentHashPriv frontend.Variable

	// Merkle inclusion path for the device commitment.
	// MerklePath[i] is the sibling hash at depth i from the leaf.
	// MerkleDirections[i] is 0 (left child) or 1 (right child).
	MerklePath       [MerkleDepth]frontend.Variable
	MerkleDirections [MerkleDepth]frontend.Variable
}

// Define implements frontend.Circuit.  All R1CS constraints are specified here.
// This method is called by frontend.Compile; it must not access any runtime
// state — all constants must be known at circuit-compile time.
func (c *AttestationCircuit) Define(api frontend.API) error {
	// -------------------------------------------------------------------------
	// 1. Nullifier constraint
	//
	//    Nullifier == Poseidon(UsernameHash, SessionCounter, BlindingFactor)
	//
	//    Uses 3-input Poseidon.  The blinding factor prevents any party from
	//    pre-computing the nullifier without the device's Keychain secret.
	// -------------------------------------------------------------------------
	derivedNullifier := poseidonGadget(api,
		c.UsernameHash,
		c.SessionCounter,
		c.BlindingFactor,
	)
	api.AssertIsEqual(c.Nullifier, derivedNullifier)

	// -------------------------------------------------------------------------
	// 2. Device commitment Merkle inclusion
	//
	//    commitment = Poseidon(DevicePubKeyX, DevicePubKeyY, BlindingFactor)
	//    leaf       = Poseidon(commitment)        ← second-preimage protection
	//    Walk MerkleDepth=8 levels; assert final hash == CommitmentRoot.
	// -------------------------------------------------------------------------
	commitment := poseidonGadget(api,
		c.DevicePubKeyX,
		c.DevicePubKeyY,
		c.BlindingFactor,
	)
	// Wrap the commitment in a single-input Poseidon to prevent second-preimage
	// attacks on the Merkle tree construction.
	leaf := poseidonGadget(api, commitment)

	current := leaf
	for i := 0; i < MerkleDepth; i++ {
		sibling := c.MerklePath[i]
		direction := c.MerkleDirections[i]

		// api.Select(selector, ifOne, ifZero):
		//   direction=1 (right child): left=sibling, right=current
		//   direction=0 (left child):  left=current, right=sibling
		left := api.Select(direction, sibling, current)
		right := api.Select(direction, current, sibling)
		current = poseidonGadget(api, left, right)
	}
	api.AssertIsEqual(c.CommitmentRoot, current)

	// -------------------------------------------------------------------------
	// 3. Content hash split
	//
	//    ContentHashPriv == ContentHashLo + 2^128 * ContentHashHi
	//    Each half is verified to be exactly 128 bits via binary decomposition.
	// -------------------------------------------------------------------------
	two128 := frontend.Variable(new(big.Int).Lsh(big.NewInt(1), 128))
	reconstructed := api.Add(c.ContentHashLo, api.Mul(c.ContentHashHi, two128))
	api.AssertIsEqual(c.ContentHashPriv, reconstructed)

	// Range-check both halves to 128 bits to prevent overflow.
	bits.ToBinary(api, c.ContentHashLo, bits.WithNbDigits(128))
	bits.ToBinary(api, c.ContentHashHi, bits.WithNbDigits(128))

	// -------------------------------------------------------------------------
	// 4. Behavioral range constraints
	// -------------------------------------------------------------------------

	// HumanScore in [50, 100]: 7 bits covers [0, 127].
	assertGe(api, c.HumanScore, MinHumanScore, 7)
	assertLe(api, c.HumanScore, 100, 7)

	// KeystrokeCount >= 10: no upper bound.
	assertGe(api, c.KeystrokeCount, MinKeystrokeCount, 32)

	// IKI bounds: [20, 2000] ms.
	assertGe(api, c.IKIMin, MinIKIMs, 32)
	assertLe(api, c.IKIMax, MaxIKIMs, 32)

	return nil
}

// --------------------------------------------------------------------------
// Poseidon gadget — iden3 optimized algorithm
// --------------------------------------------------------------------------

// poseidonGadget computes the BN254 Poseidon hash of 1, 2, or 3 inputs
// inside a gnark circuit, returning a single BN254 scalar field element.
//
// Algorithm: iden3 optimized Poseidon (same as circomlib poseidon.circom).
//   - Field:          BN254 scalar field
//   - State width:    t = 3 (capacity=1, rate=2)
//   - Full rounds:    Rf = 8
//   - Partial rounds: Rp = 57
//   - S-box:          x^5
//
// Absorption matches iden3's Hash() call convention:
//   - state[0] = 0 (capacity, initialised to 0)
//   - state[1..n] = inputs[0..n-1]
//   - state is then permuted once; output is state[0] (capacity element).
//
// For >2 inputs the iden3 library uses t=len(inputs)+1 (different parameter
// set); this gadget only supports ≤2 inputs per permutation call. For 3
// inputs the circuit absorbs [input0, input1] then permutes, then absorbs
// [input2] and permutes again (sponge with rate=2, same as iden3.Hash for
// separate calls but not the library's 3-input path — see note below).
//
// IMPORTANT: the iden3 library's Hash([a,b,c]) uses t=4 (a different Poseidon
// instance). This gadget instead uses the sponge approach with t=3, Rf=8,
// Rp=57, which matches what the native surcorelibs/poseidon package uses for
// HashTwo (2 inputs) and single inputs. For 3-input hashes we use two
// sequential permutations, consistent across circuit and native code.
//
// Output: state[0] after the final permutation (capacity element), matching
// iden3's return convention.
func poseidonGadget(api frontend.API, inputs ...frontend.Variable) frontend.Variable {
	var state [3]frontend.Variable
	state[0] = frontend.Variable(0)
	state[1] = frontend.Variable(0)
	state[2] = frontend.Variable(0)

	// Absorb inputs into rate portion (state[1], state[2]) then permute.
	// Matches iden3's Hash for 1 and 2 inputs:
	//   state[0] = initState (0)
	//   copy(state[1:], inp)
	switch len(inputs) {
	case 1:
		state[1] = inputs[0]
		// state[2] stays 0 (padding)
		state = bn254PoseidonPermute(api, state)
	case 2:
		state[1] = inputs[0]
		state[2] = inputs[1]
		state = bn254PoseidonPermute(api, state)
	case 3:
		// Nested 2-input hashes: Poseidon(Poseidon(a, b), c).
		// This uses only the t=3 permutation (matching iden3's 2-input Hash)
		// and is fully consistent with nativePoseidon in prove.go.
		// iden3's Hash([a,b,c]) uses t=4 (different parameter set); we avoid
		// that here to keep the circuit self-consistent with a single t=3 gadget.
		inner := poseidonGadget(api, inputs[0], inputs[1])
		return poseidonGadget(api, inner, inputs[2])
	default:
		// General absorb/squeeze loop (rate=2).
		for start := 0; start < len(inputs); start += 2 {
			if start < len(inputs) {
				state[1] = api.Add(state[1], inputs[start])
			}
			if start+1 < len(inputs) {
				state[2] = api.Add(state[2], inputs[start+1])
			}
			state = bn254PoseidonPermute(api, state)
		}
	}
	// iden3 returns state[0] (the capacity element, updated during permutation).
	return state[0]
}

// bn254PoseidonPermute applies the iden3 optimized BN254 Poseidon permutation.
//
// This exactly mirrors iden3's HashWithStateEx for t=3, nRoundsF=8, nRoundsP=57:
//
//  1. Initial ARK: state += C[0..2]
//  2. First half full rounds (nRoundsF/2 - 1 = 3 rounds, i=0..2):
//     exp5state → ARK(C[(i+1)*t]) → mix(M)
//  3. Transition full round:
//     exp5state → ARK(C[nRoundsF/2 * t]) → mix(P)
//  4. Partial rounds (nRoundsP=57, i=0..56):
//     exp5(state[0]) → state[0]+=C[(nRoundsF/2+1)*t+i] → sparse mix with S
//  5. Second half full rounds (nRoundsF/2 - 1 = 3 rounds, i=0..2):
//     exp5state → ARK(C[(nRoundsF/2+1)*t+nRoundsP+i*t]) → mix(M)
//  6. Final round:
//     exp5state → mix(M)  (no ARK)
//
// Constants C, S, M, P are from poseidonParams() (poseidon_params.go).
func bn254PoseidonPermute(api frontend.API, state [3]frontend.Variable) [3]frontend.Variable {
	C, S, M, P := poseidonParams()

	const (
		t  = 3
		rf = 8
		rp = 57
	)

	// 1. Initial ARK: state += C[0..2]
	for i := 0; i < t; i++ {
		state[i] = api.Add(state[i], C[i])
	}

	// 2. First-half full rounds (rf/2 - 1 = 3 rounds)
	for r := 0; r < rf/2-1; r++ {
		state = poseidonExp5State(api, state)
		for i := 0; i < t; i++ {
			state[i] = api.Add(state[i], C[(r+1)*t+i])
		}
		state = poseidonMatMul(api, state, M)
	}

	// 3. Transition full round: S-box all → ARK → mix with P
	state = poseidonExp5State(api, state)
	for i := 0; i < t; i++ {
		state[i] = api.Add(state[i], C[(rf/2)*t+i])
	}
	state = poseidonMatMul(api, state, P)

	// 4. Partial rounds
	for i := 0; i < rp; i++ {
		state[0] = poseidonSbox(api, state[0])
		state[0] = api.Add(state[0], C[(rf/2+1)*t+i])
		// Sparse linear layer:
		//   newState[0] = sum_j S[5i+j] * state[j]
		//   state[k]   += old_state[0] * S[5i+t+k-1]  for k=1,2
		base := (2*t - 1) * i
		oldState0 := state[0]
		newState0 := api.Mul(S[base+0], state[0])
		newState0 = api.Add(newState0, api.Mul(S[base+1], state[1]))
		newState0 = api.Add(newState0, api.Mul(S[base+2], state[2]))
		state[1] = api.Add(state[1], api.Mul(oldState0, S[base+t+0]))
		state[2] = api.Add(state[2], api.Mul(oldState0, S[base+t+1]))
		state[0] = newState0
	}

	// 5. Second-half full rounds (rf/2 - 1 = 3 rounds)
	for r := 0; r < rf/2-1; r++ {
		state = poseidonExp5State(api, state)
		arkBase := (rf/2+1)*t + rp + r*t
		for i := 0; i < t; i++ {
			state[i] = api.Add(state[i], C[arkBase+i])
		}
		state = poseidonMatMul(api, state, M)
	}

	// 6. Final round: S-box all → mix(M), no ARK
	state = poseidonExp5State(api, state)
	state = poseidonMatMul(api, state, M)

	return state
}

// poseidonExp5State applies x^5 to all 3 state elements.
func poseidonExp5State(api frontend.API, state [3]frontend.Variable) [3]frontend.Variable {
	for i := range state {
		state[i] = poseidonSbox(api, state[i])
	}
	return state
}

// poseidonSbox computes x^5 using 3 multiplications:
//
//	x2 = x * x
//	x4 = x2 * x2
//	x5 = x4 * x
func poseidonSbox(api frontend.API, x frontend.Variable) frontend.Variable {
	x2 := api.Mul(x, x)
	x4 := api.Mul(x2, x2)
	return api.Mul(x4, x)
}

// poseidonMatMul multiplies a 3x3 matrix by the state vector (mat * state).
//
// out[i] = sum_j mat[j][i] * state[j]
//
// Note: iden3's mix() uses the transposed convention — row j of mat multiplies
// state[j], accumulating into out[i].  This matches mix(state, t, M) in iden3.
func poseidonMatMul(api frontend.API, state [3]frontend.Variable, mat [3][3]frontend.Variable) [3]frontend.Variable {
	var out [3]frontend.Variable
	for i := 0; i < 3; i++ {
		out[i] = api.Mul(mat[0][i], state[0])
		for j := 1; j < 3; j++ {
			out[i] = api.Add(out[i], api.Mul(mat[j][i], state[j]))
		}
	}
	return out
}

// --------------------------------------------------------------------------
// Range constraint helpers
// --------------------------------------------------------------------------

// assertGe enforces x >= threshold inside the circuit.
//
// Method: diff = x - threshold; decompose diff to nbBits binary digits.
// This asserts diff ∈ [0, 2^nbBits), which combined with the subtraction
// proves x ≥ threshold (assuming x < threshold + 2^nbBits, i.e., the domain
// is bounded by nbBits above the threshold).
func assertGe(api frontend.API, x frontend.Variable, threshold, nbBits int) {
	diff := api.Sub(x, threshold)
	bits.ToBinary(api, diff, bits.WithNbDigits(nbBits))
}

// assertLe enforces x <= threshold inside the circuit.
//
// Method: diff = threshold - x; decompose diff to nbBits binary digits.
// This asserts diff ∈ [0, 2^nbBits), proving x ≤ threshold.
func assertLe(api frontend.API, x frontend.Variable, threshold, nbBits int) {
	diff := api.Sub(threshold, x)
	bits.ToBinary(api, diff, bits.WithNbDigits(nbBits))
}

// --------------------------------------------------------------------------
// Compile-time interface check
// --------------------------------------------------------------------------

// Verify at compile time that AttestationCircuit implements frontend.Circuit.
var _ frontend.Circuit = (*AttestationCircuit)(nil)
