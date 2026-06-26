package gnark

import "testing"

// TestEmbeddedKeysFallback simulates a real device: there is no key directory on
// disk, so the loaders must fall back to the bytes embedded in the binary. A
// non-existent dir must still yield a usable proving key, constraint system, and
// verifying key — otherwise on-device attestation fails.
func TestEmbeddedKeysFallback(t *testing.T) {
	const noSuchDir = "/definitely/not/a/real/key/dir"

	if _, err := LoadConstraintSystem(noSuchDir); err != nil {
		t.Fatalf("LoadConstraintSystem fallback to embedded failed: %v", err)
	}
	if _, err := LoadProvingKey(noSuchDir); err != nil {
		t.Fatalf("LoadProvingKey fallback to embedded failed: %v", err)
	}
	if _, err := LoadVerifyingKey(noSuchDir); err != nil {
		t.Fatalf("LoadVerifyingKey fallback to embedded failed: %v", err)
	}
}

// TestEmbeddedKeysMatchDisk guards the embedded artifacts against drift: the
// embedded verifying key must hash to the same value as the on-disk one the
// chain verifies against.
func TestEmbeddedKeysMatchDisk(t *testing.T) {
	diskHash, err := VerifyingKeyHash(KeyDir())
	if err != nil {
		t.Fatalf("hash of on-disk vk: %v", err)
	}
	embeddedHash, err := VerifyingKeyHash("/definitely/not/a/real/key/dir")
	if err != nil {
		t.Fatalf("hash of embedded vk: %v", err)
	}
	if diskHash != embeddedHash {
		t.Fatalf("embedded vk (%s) differs from on-disk vk (%s); re-embed the committed keys", embeddedHash, diskHash)
	}
}
