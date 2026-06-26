# GitHub Actions Workflows

## ios-ci.yml — iOS CI

Runs on every push to `main`/`develop` and on pull requests targeting `main`.

Four jobs run in this pipeline:

1. **surcorelibs Go Tests** (`macos-14`) — Generates Poseidon constants, runs Poseidon and gnark circuit input-validation tests, and verifies the FFI bridge compiles. This job is a gate for all downstream jobs.

2. **iOS Build** (`macos-14`) — Installs CocoaPods dependencies, then builds the `Sur` scheme against the iPhone 16 simulator using Xcode 16. Code signing is disabled for CI.

3. **iOS Unit Tests** (`macos-14`) — Runs the `SurTests` scheme against the iPhone 16 simulator. Depends on surcorelibs tests passing.

4. **Build surcorelibs XCFramework** (`macos-14`) — Runs `make xcframework` to produce `libsurcorelibs.xcframework` and uploads it as a build artifact (7-day retention). Marked `continue-on-error` until the full ZK circuit is complete.

## security-scan.yml — Security Scan

Runs on every push to `main` and on a weekly Monday 8am UTC schedule.

- **Scan for Secrets** — runs `gitleaks` across full git history to detect accidentally committed credentials.
- **Go Security Audit** — runs `govulncheck` against the `surcorelibs` module to surface known CVEs in Go dependencies. Advisory only (`continue-on-error`); does not block the build.

## pr-checks.yml — PR Checks

Runs on every pull request targeting `main` or `develop`.

- **Go Lint** — runs `golangci-lint v1.57` with a 5-minute timeout against `surcorelibs`.
- **Verify Poseidon Test Vector** — runs `TestCanonicalVector` in isolation to confirm the Poseidon hash implementation matches the canonical reference vector. This check must pass on every PR.

---

### Runner notes

All iOS and XCFramework jobs use `macos-14` (Apple Silicon) to match arm64 device architecture and keep cross-compilation overhead low. Security and lint jobs use `ubuntu-latest` for cost efficiency.

### Required secrets

| Secret | Used by |
|---|---|
| `GITHUB_TOKEN` | `gitleaks-action` (auto-provided by GitHub) |

No additional secrets are required for CI builds. Distribution signing credentials (App Store Connect API key, provisioning profiles) will be added when the release workflow is introduced.
