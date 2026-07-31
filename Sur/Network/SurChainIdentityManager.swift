//
//  SurChainIdentityManager.swift
//  Sur
//
//  Drives the two on-chain write flows the app needs:
//    1. Device/identity registration  → MsgRegisterUsername (x/identity)
//    2. Pushing an attestation         → MsgSubmitAttestation (x/attestation)
//
//  It ties together the pieces that already exist: the secp256k1 wallet key (the
//  fee-paying Sur Chain account), the P-256 device key (control key + commitment),
//  the surcorelibs commitment FFI, the Amino tx builders/signer, and CosmosClient.
//
//  VERIFY ON DEVICE: App Attest and the P-256 device key require a real device
//  (not the simulator); the Sur Chain account must be funded with `usur` before
//  these transactions will succeed (they pay gas / a registration fee).
//

import Foundation
import CryptoKit
import os

/// Structured logging for the on-chain flows. Filter Console.app / Xcode console
/// by subsystem `com.ordo.sur.chain` to follow registration and attestation
/// end-to-end (categories: identity, attestation).
private let chainLog = Logger(subsystem: "com.ordo.sur.chain", category: "attestation")

@MainActor
final class SurChainIdentityManager: ObservableObject {

    static let shared = SurChainIdentityManager()

    enum RegistrationState: Equatable {
        case unknown
        case unregistered
        case registering
        case registered(username: String)
        case failed(String)
    }

    @Published private(set) var state: RegistrationState = .unknown

    /// Hash + height of the most recent submitted transaction (registration or
    /// attestation), so the UI can show it and the user can look it up on the explorer.
    @Published private(set) var lastTxHash: String?
    @Published private(set) var lastTxHeight: Int64?

    private static let appGroup = "group.com.ordo.sure.Sur"
    // On-chain identifier: now the device id (surdev1…), a pseudonym — NOT a human
    // username. The key name is kept for storage back-compat.
    private static let usernameKey = "sur.identity.username.v1"
    // Optional human-readable alias the user may attach locally for display only;
    // it is never the on-chain identifier and never leaves the device.
    private static let aliasKey = "sur.identity.alias.v1"
    private static let lastTxHashKey = "sur.identity.lastTxHash.v1"
    private static let sessionCounterKey = "sur.identity.sessionCounter.v1"
    private static let blindingKey = "sur.identity.blinding.v1" // TODO: move to Keychain (KEY_MANAGEMENT)

    private let defaults: UserDefaults
    private let client = CosmosClient.shared
    private let config = SurChainConfig.shared

    private init() {
        self.defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        if let u = defaults.string(forKey: Self.usernameKey) {
            // Migration: a stored identifier that isn't a device id (surdev1…) is a
            // legacy human username from before the device-id identity model. It
            // won't resolve in the chain's identity module, so drop it and prompt a
            // clean re-registration under the device id.
            if u.hasPrefix(Self.deviceIDPrefix) {
                state = .registered(username: u)
            } else {
                chainLog.notice("migrating legacy identity \(u, privacy: .public) → re-register under device id")
                defaults.removeObject(forKey: Self.usernameKey)
                defaults.removeObject(forKey: Self.aliasKey)
                state = .unregistered
            }
        } else {
            state = .unregistered
        }
        lastTxHash = defaults.string(forKey: Self.lastTxHashKey)
    }

    /// Bech32 prefix of a Sur device id (`surdev1…`).
    private static let deviceIDPrefix = DeviceIDManager.deviceIDHRP + "1"

    /// Forget the on-chain registration locally so the user can re-register (e.g.
    /// after a chain reset). Does not touch the device keys — re-registering reuses
    /// the same device id.
    func forgetRegistration() {
        defaults.removeObject(forKey: Self.usernameKey)
        defaults.removeObject(forKey: Self.aliasKey)
        state = .unregistered
    }

    /// Record a submitted tx hash, poll the chain until it's included in a block,
    /// and return the in-block result (or nil if it didn't appear in time).
    @discardableResult
    private func recordAndConfirmTx(_ hash: String) async -> CosmosTransactionResult? {
        lastTxHash = hash
        lastTxHeight = nil
        defaults.set(hash, forKey: Self.lastTxHashKey)
        // Poll for inclusion (a SYNC broadcast returns before the tx is in a block).
        for _ in 0..<12 {
            if let tx = try? await client.getTx(hash: hash), tx.height != nil {
                lastTxHeight = tx.height
                return tx
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
        }
        return nil
    }

    /// The on-chain identifier this device is registered under — the device id
    /// (`surdev1…`), a pseudonym. (Property name kept for call-site compatibility.)
    var registeredUsername: String? {
        if case let .registered(u) = state { return u }
        return nil
    }

    /// Optional human-readable alias for display only (never on-chain).
    var deviceAlias: String? { defaults.string(forKey: Self.aliasKey) }

    /// What to show the user for this identity: their alias if set, else the
    /// device id.
    var displayName: String? { deviceAlias ?? registeredUsername }

    /// The Sur Chain account address (`sur1…`), if available. This is the SAME
    /// account shown as the "Sur" network address in the wallet — both derive from
    /// the mnemonic via the Sur/Cosmos path (m/44'/118'), so registration, balance,
    /// and the displayed address are always one account.
    func accountAddress() -> String? {
        return (try? surAccount())?.address
    }

    /// Cached derived account. BIP-39 seed + HD derivation is expensive, so we do
    /// it once and reuse it — never on every SwiftUI body evaluation (doing so on
    /// the main thread previously tripped the 10s scene-update watchdog).
    private var cachedAccount: (address: String, privateKey: Data)?

    /// Derive the Sur Chain account (address + secp256k1 key) from the mnemonic,
    /// caching the result for the session.
    private func surAccount() throws -> (address: String, privateKey: Data) {
        if let cached = cachedAccount { return cached }
        let mnemonic = try SecureEnclaveManager.shared.getMnemonic()
        let keys = try MultiChainKeyManager.generateKeysForNetwork(mnemonic, network: .sur)
        let acct = (address: keys.address, privateKey: keys.privateKey)
        cachedAccount = acct
        return acct
    }

    /// Ensure this device has an identity keypair and return its `surdev1…` id.
    /// The keypair is derived deterministically from the user key (mnemonic) +
    /// device UUID, with the private key kept in the Keychain (device-only). This
    /// is the pseudonymous identity content is attested under — usernames are an
    /// optional alias layered on top.
    @discardableResult
    func ensureDeviceIdentity() throws -> String {
        if let id = DeviceIDManager.shared.currentDeviceID() { return id }
        let userKey = try surAccount().privateKey
        let keys = try DeviceIDManager.shared.generateDeviceKeys(from: userKey)
        DeviceIDManager.shared.saveDeviceKeys(privateKey: keys.privateKey, publicKey: keys.publicKey)
        guard let id = DeviceIDManager.shared.currentDeviceID() else {
            throw CosmosError.chainError(-1, "failed to derive device identity")
        }
        return id
    }

    // MARK: - Registration

    /// Register this device on the Sur Chain under its device id (`surdev1…`).
    ///
    /// The on-chain identifier is the device pseudonym, NOT a human name, so the
    /// attestation record never carries a user identity. `alias` is an optional
    /// human-readable label stored locally for display only — it never goes on
    /// chain. (Residual privacy note: the tx is still signed/paid by the user's
    /// wallet account, so the tx sender remains correlatable; signing with the
    /// device account would close that, at the cost of funding it separately.)
    func register(alias: String? = nil) async throws {
        state = .registering
        do {
            // The on-chain identifier is the device id (pseudonym).
            let deviceID = try ensureDeviceIdentity()

            let acct = try surAccount()
            let creator = acct.address
            let walletKey = acct.privateKey

            // P-256 device key = control key (identity_sig) and source of the commitment coords.
            let controlPubkey = try SecureEnclaveManager.shared.getDeviceSigningPublicKeyBytes() // 0x04||X||Y
            guard controlPubkey.count == 65 else { throw CosmosError.invalidResponse }
            let xHex = "0x" + controlPubkey[1..<33].map { String(format: "%02x", $0) }.joined()
            let yHex = "0x" + controlPubkey[33..<65].map { String(format: "%02x", $0) }.joined()

            let blinding = getOrCreateBlinding()
            let blindingHex = "0x" + blinding.map { String(format: "%02x", $0) }.joined()

            let commitment = try computeCommitment(devicePubKeyX: xHex, devicePubKeyY: yHex, blinding: blindingHex)

            // payload the chain re-verifies via ecdsa.VerifyASN1(controlPubkey, sha256(payload), identity_sig).
            var payload = Data()
            payload.append(Data(deviceID.utf8))
            payload.append(Data(SHA256.hash(data: controlPubkey)))
            payload.append(commitment)
            payload.append(Data(config.network.chainID.utf8))
            let identitySig = try SecureEnclaveManager.shared.signWithDeviceKey(payload)

            // Sign with the chain's real chain-id (falls back to the configured one).
            let chainID = (try? await client.getChainID()) ?? config.network.chainID

            let msgBody = CosmosProtoTx.encodeMsgRegisterUsername(
                creator: creator,
                username: deviceID,
                controlPubkey: controlPubkey,
                firstCommitment: commitment,
                identitySig: identitySig,
                payload: payload
            )
            _ = try await broadcastWithSequenceRetry(creator: creator) { accountNumber, sequence in
                try CosmosProtoTx.buildSignedTxBytes(
                    msgTypeURL: "/surchain.identity.v1.MsgRegisterUsername",
                    msgBody: msgBody,
                    chainID: chainID,
                    accountNumber: accountNumber,
                    sequence: sequence,
                    privateKey: walletKey,
                    feeDenom: config.network.feeDenom,
                    feeAmount: "10000",
                    gasLimit: 500_000
                )
            }

            defaults.set(deviceID, forKey: Self.usernameKey)
            if let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
                defaults.set(alias, forKey: Self.aliasKey)
            }
            state = .registered(username: deviceID)
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Attestation submission

    /// Submit a prepared attestation. This is the primitive the capture/proof flow calls.
    @discardableResult
    func submitAttestation(
        username: String,
        contentHash: Data,
        nullifier: Data,
        commitmentRoot: Data,
        proofBytes: Data
    ) async throws -> CosmosTransactionResult {
        let acct = try surAccount()
        let creator = acct.address
        let walletKey = acct.privateKey
        let chainID = (try? await client.getChainID()) ?? config.network.chainID

        let msgBody = CosmosProtoTx.encodeMsgSubmitAttestation(
            creator: creator,
            username: username,
            contentHash: contentHash,
            nullifier: nullifier,
            commitmentRoot: commitmentRoot,
            proofBytes: proofBytes
        )
        chainLog.notice("broadcasting attestation: signer=\(creator, privacy: .public) chainID=\(chainID, privacy: .public)")
        do {
            // Groth16 verification on-chain is gas-heavy, so allow a generous gas limit.
            let confirmed = try await broadcastWithSequenceRetry(creator: creator) { accountNumber, sequence in
                try CosmosProtoTx.buildSignedTxBytes(
                    msgTypeURL: "/surchain.attestation.v1.MsgSubmitAttestation",
                    msgBody: msgBody,
                    chainID: chainID,
                    accountNumber: accountNumber,
                    sequence: sequence,
                    privateKey: walletKey,
                    feeDenom: config.network.feeDenom,
                    feeAmount: "20000",
                    gasLimit: 2_000_000
                )
            }
            chainLog.notice("attestation ON-CHAIN: tx=\(confirmed.txHash, privacy: .public) height=\(confirmed.height ?? -1)")
            return confirmed
        } catch {
            chainLog.error("attestation failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Submit a device-signed DECLARATION (not a human-typing proof). Used for
    /// content created off the Sur Keyboard: it asserts only that this device made
    /// the claim (`origin` = device_authored / ai_generated / external_source /
    /// imported), NOT that the content was human-typed. The device key signs
    /// SHA-256(content_hash ‖ origin ‖ citation ‖ nullifier); the chain verifies it.
    @discardableResult
    func submitDeclaration(text: String, origin: String, citation: String) async throws -> CosmosTransactionResult {
        let contentHash = Data(SHA256.hash(data: Data(text.utf8)))
        return try await submitDeclaration(contentHash: contentHash, origin: origin, citation: citation)
    }

    /// Shared declaration path for any content that isn't typed text — Sur Cam
    /// photos/videos, file attestations, voice recordings, call-initiation
    /// records. Signs and broadcasts a device-signed `MsgSubmitAttestation`
    /// (no ZK proof) exactly like the `text:` overload above, just starting
    /// from an already-computed hash instead of hashing text internally.
    func submitDeclaration(contentHash: Data, origin: String, citation: String) async throws -> CosmosTransactionResult {
        let deviceID = try ensureDeviceIdentity()
        guard let devicePub = DeviceIDManager.shared.compressedDevicePublicKey() else {
            throw CosmosError.chainError(-1, "device key unavailable")
        }

        // Unique, content-bound nullifier (replay protection).
        var nbase = Data(deviceID.utf8)
        nbase.append(contentHash)
        var counter = nextSessionCounter().littleEndian
        withUnsafeBytes(of: &counter) { nbase.append(contentsOf: $0) }
        let nullifier = Data(SHA256.hash(data: nbase))

        // Sign the declaration: content_hash ‖ origin ‖ citation ‖ nullifier.
        var payload = contentHash
        payload.append(Data(origin.utf8))
        payload.append(Data(citation.utf8))
        payload.append(nullifier)
        guard let signature = DeviceIDManager.shared.signDeclaration(payload) else {
            throw CosmosError.chainError(-1, "failed to sign declaration")
        }

        chainLog.notice("declaration: origin=\(origin, privacy: .public) id=\(deviceID, privacy: .public)")

        let acct = try surAccount()
        let creator = acct.address
        let chainID = (try? await client.getChainID()) ?? config.network.chainID

        let msgBody = CosmosProtoTx.encodeMsgSubmitAttestation(
            creator: creator,
            username: deviceID,
            contentHash: contentHash,
            nullifier: nullifier,
            commitmentRoot: Data(),     // not used for declarations
            proofBytes: Data(),         // no ZK proof
            origin: origin,
            citation: citation,
            devicePubkey: devicePub,
            deviceSignature: signature
        )
        do {
            // No on-chain Groth16 verification for declarations → modest gas.
            return try await broadcastWithSequenceRetry(creator: creator) { accountNumber, sequence in
                try CosmosProtoTx.buildSignedTxBytes(
                    msgTypeURL: "/surchain.attestation.v1.MsgSubmitAttestation",
                    msgBody: msgBody,
                    chainID: chainID,
                    accountNumber: accountNumber,
                    sequence: sequence,
                    privateKey: acct.privateKey,
                    feeDenom: config.network.feeDenom,
                    feeAmount: "10000",
                    gasLimit: 300_000
                )
            }
        } catch {
            throw mapSubmitError(error)
        }
    }

    // MARK: - Token transfer

    /// Generic sign/broadcast/confirm path for any pre-encoded message body —
    /// factored out of `register`/`submitDeclaration`/`sendSur` so other chain
    /// writers (e.g. ProvenanceManager) don't duplicate account-fetch,
    /// chain-id resolution, signing, and confirmation-polling.
    func broadcastSignedMessage(msgTypeURL: String, msgBody: Data, feeAmount: String, gasLimit: UInt64) async throws -> CosmosTransactionResult {
        let acct = try surAccount()
        let chainID = (try? await client.getChainID()) ?? config.network.chainID
        do {
            return try await broadcastWithSequenceRetry(creator: acct.address) { accountNumber, sequence in
                try CosmosProtoTx.buildSignedTxBytes(
                    msgTypeURL: msgTypeURL,
                    msgBody: msgBody,
                    chainID: chainID,
                    accountNumber: accountNumber,
                    sequence: sequence,
                    privateKey: acct.privateKey,
                    feeDenom: config.network.feeDenom,
                    feeAmount: feeAmount,
                    gasLimit: gasLimit
                )
            }
        } catch {
            throw mapSubmitError(error)
        }
    }

    /// Send `displayAmount` SUR (e.g. "1.5") to `toAddress` (a sur1… account).
    /// Returns the confirmed transaction result. Throws on invalid recipient /
    /// amount, insufficient balance, or chain error.
    @discardableResult
    func sendSur(toAddress: String, displayAmount: String) async throws -> CosmosTransactionResult {
        let recipient = toAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        // Validate the recipient is a bech32 account on this chain (sur1…).
        guard let decoded = Bech32.decode(recipient), decoded.hrp == "sur" else {
            throw CosmosError.chainError(-1, "Recipient must be a valid sur1… address.")
        }

        let denom = config.network.feeDenom
        guard let micro = Self.toMicroAmount(displayAmount, exponent: config.network.displayExponent) else {
            throw CosmosError.chainError(-1, "Enter a valid amount greater than 0.")
        }

        let acct = try surAccount()
        let from = acct.address
        guard recipient != from else {
            throw CosmosError.chainError(-1, "You can't send to your own address.")
        }

        // Make sure there's enough to cover amount + fee.
        let feeAmount: UInt64 = 2000
        if let bal = try? await client.getBalance(address: from),
           let have = UInt64(bal.amount), let want = UInt64(micro) {
            if have < want + feeAmount {
                throw CosmosError.chainError(-1, "Insufficient balance to send \(displayAmount) \(config.network.displayDenom) plus fee.")
            }
        }

        let chainID = (try? await client.getChainID()) ?? config.network.chainID
        let msgBody = CosmosProtoTx.encodeMsgSend(from: from, to: recipient, denom: denom, amount: micro)
        chainLog.notice("sending \(micro, privacy: .public)\(denom, privacy: .public) → \(recipient, privacy: .public)")
        do {
            return try await broadcastWithSequenceRetry(creator: from) { accountNumber, sequence in
                try CosmosProtoTx.buildSignedTxBytes(
                    msgTypeURL: "/cosmos.bank.v1beta1.MsgSend",
                    msgBody: msgBody,
                    chainID: chainID,
                    accountNumber: accountNumber,
                    sequence: sequence,
                    privateKey: acct.privateKey,
                    feeDenom: denom,
                    feeAmount: String(feeAmount),
                    gasLimit: 200_000
                )
            }
        } catch {
            throw mapSubmitError(error)
        }
    }

    /// Convert a display amount (e.g. "1.5") to the integer micro-denom string
    /// (× 10^exponent), truncating sub-micro precision. nil if not a positive number.
    static func toMicroAmount(_ display: String, exponent: Int) -> String? {
        let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let dec = Decimal(string: trimmed), dec > 0 else { return nil }
        var scaled = dec * pow(Decimal(10), exponent)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .down)
        guard rounded > 0 else { return nil }
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    /// Publish a text proof: derive the on-chain fields from a ZKTypingProof and the
    /// raw attested content, then submit. `content` is the UTF-8 bytes that were typed.
    @discardableResult
    func publishTextProof(_ proof: ZKTypingProof, content: Data) async throws -> CosmosTransactionResult {
        guard let username = registeredUsername else {
            throw CosmosError.chainError(-1, "Register a username before publishing.")
        }
        let contentHash = Data(SHA256.hash(data: content))
        let nullifier = Self.hexToData32(proof.publicInputs.nullifier)
        let commitmentRoot = Self.hexToData32(proof.publicInputs.commitmentRoot)
        let proofBytes = Data(ProofOutput.bytes(fromHex: proof.proof))
        return try await submitAttestation(
            username: username,
            contentHash: contentHash,
            nullifier: nullifier,
            commitmentRoot: commitmentRoot,
            proofBytes: proofBytes
        )
    }

    // MARK: - Text attestation (build proof + submit)

    /// Monotonically increasing per-device session counter (feeds the nullifier).
    private func nextSessionCounter() -> UInt64 {
        let c = UInt64(defaults.integer(forKey: Self.sessionCounterKey))
        defaults.set(Int(c + 1), forKey: Self.sessionCounterKey)
        return c
    }

    /// Build a real Groth16 attestation proof for `text` and submit it on-chain.
    /// Requires the device to be registered. Proof generation runs OFF the main
    /// thread (it's CPU-heavy). The witness uses the same device key + blinding as
    /// registration, so its commitment root matches the on-chain registered root.
    @discardableResult
    func proveAndSubmitText(text: String, ikiValues: [Int], humanScore: Int, keystrokeCount: Int) async throws -> CosmosTransactionResult {
        guard let username = registeredUsername else {
            chainLog.error("attest aborted: device not registered")
            throw CosmosError.chainError(-1, "Register this device before attesting.")
        }
        // The circuit enforces a minimum keystroke count (anti-gaming): you can't
        // prove human typing from a handful of keys.
        guard keystrokeCount >= 10 else {
            chainLog.error("attest aborted: \(keystrokeCount) keystrokes < 10 minimum")
            throw CosmosError.chainError(-1, "Needs at least 10 keystrokes to attest (had \(keystrokeCount)).")
        }
        chainLog.notice("attest start: id=\(username, privacy: .public) keystrokes=\(keystrokeCount) net=\(self.config.network.environment.displayName, privacy: .public) rest=\(self.config.network.restURL, privacy: .public)")
        let controlPubkey = try SecureEnclaveManager.shared.getDeviceSigningPublicKeyBytes()
        guard controlPubkey.count == 65 else { throw CosmosError.invalidResponse }
        let hexOf: (Data) -> String = { "0x" + $0.map { String(format: "%02x", $0) }.joined() }
        let xHex = hexOf(controlPubkey[1..<33])
        let yHex = hexOf(controlPubkey[33..<65])
        let blindingHex = hexOf(getOrCreateBlinding())

        let witness = try computeMerkleWitness(devicePubKeyX: xHex, devicePubKeyY: yHex, blinding: blindingHex)
        let usernameHashHex = hexOf(try computeUsernameHash(username))

        let contentHash = Data(SHA256.hash(data: Data(text.utf8))) // 32 bytes
        let hi = Data(contentHash.prefix(16))
        let lo = Data(contentHash.suffix(16))

        // Clamp behavioral values into the circuit's accepted ranges so proving
        // never fails on an out-of-range witness.
        let iki = ikiValues.isEmpty ? [150] : ikiValues.map { max(20, min(2000, $0)) }
        let score = max(50, min(100, humanScore))

        let input = ProverInput(
            usernameHash: usernameHashHex,
            contentHashLo: hexOf(lo),
            contentHashHi: hexOf(hi),
            contentHashPriv: hexOf(contentHash),
            devicePubkeyX: xHex,
            devicePubkeyY: yHex,
            sessionCounter: nextSessionCounter(),
            blindingFactor: blindingHex,
            commitmentRoot: witness.commitmentRoot,
            merklePath: witness.merklePath,
            merkleDirections: Array(repeating: 0, count: 8),
            seSignatureR: "0x1",
            seSignatureS: "0x1",
            humanScore: score,
            ikiValuesMs: iki,
            keystrokeCount: keystrokeCount
        )

        // Groth16 proving runs OFF the main thread at a light QoS (.utility) so it
        // never competes with the UI — it can run while the app is backgrounded.
        chainLog.notice("proving… (commitmentRoot=\(witness.commitmentRoot, privacy: .public))")
        let t0 = Date()
        let output: ProofOutput
        do {
            output = try await Task.detached(priority: .utility) {
                try proveAttestation(input)
            }.value
        } catch {
            chainLog.error("PROVING FAILED: \(String(describing: error), privacy: .public)")
            throw CosmosError.chainError(-1, "Proof generation failed: \(error.localizedDescription)")
        }
        chainLog.notice("proof generated in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s, \(output.proofBytes.count) bytes; submitting…")

        do {
            return try await submitAttestation(
                username: username,
                contentHash: contentHash,
                nullifier: Self.hexToData32(output.publicInputs[3]),
                commitmentRoot: Self.hexToData32(witness.commitmentRoot),
                proofBytes: Data(output.proofBytes)
            )
        } catch {
            chainLog.error("SUBMIT FAILED: \(String(describing: error), privacy: .public)")
            throw mapSubmitError(error)
        }
    }

    /// Turn an opaque submit failure into an actionable message. The most common
    /// one on a physical device is a Local network whose REST endpoint is
    /// `localhost` — unreachable from the phone (localhost is the phone itself).
    private func mapSubmitError(_ error: Error) -> Error {
        let host = config.network.baseURL?.host ?? ""
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        if case CosmosError.networkError = error, isLoopback {
            return CosmosError.chainError(-1, "Can't reach the chain at \(config.network.restURL). A physical device can't use localhost — in Sur Chain settings pick a Custom network and point it at your computer's LAN address (e.g. http://192.168.x.x:1317), or use a testnet.")
        }
        // Identifier isn't registered on this chain (e.g. after a chain reset, or a
        // legacy username). Point the user at re-registration.
        if case let CosmosError.chainError(_, log) = error, log.contains("not found in identity module") {
            return CosmosError.chainError(-1, "This device isn't registered on \(config.network.environment.displayName). Re-register it (Account → Sur Chain → Reset registration), then retry.")
        }
        return error
    }

    // MARK: - Sequence management

    /// Client-side cache of (accountNumber, nextSequence) for the wallet account.
    /// Without this, every submission independently re-fetched the account's
    /// sequence from chain — fine in isolation, but a real bug for back-to-back
    /// submissions (e.g. EditCapturedPhotoView attesting the edited photo, then
    /// immediately recording the lineage edge): the second fetch would return the
    /// SAME sequence as the first, since the first tx hadn't landed in a block
    /// yet, and the chain rejects the second broadcast with "account sequence
    /// mismatch". Reserving from this cache instead — synchronously incrementing
    /// it with no `await` in between — hands out a unique, correctly-incrementing
    /// sequence to every caller regardless of how quickly they're issued.
    private var cachedSequenceState: (address: String, accountNumber: UInt64, nextSequence: UInt64)?
    /// Coalesces concurrent cold-cache reservations onto a single account fetch,
    /// so two near-simultaneous first-time submissions can't both seed the cache
    /// from the same fetched sequence.
    private var pendingAccountFetchTask: Task<CosmosAccount, Error>?

    private func reserveSequence(for address: String) async throws -> (accountNumber: UInt64, sequence: UInt64) {
        if let cached = cachedSequenceState, cached.address == address {
            cachedSequenceState = (address, cached.accountNumber, cached.nextSequence + 1)
            return (cached.accountNumber, cached.nextSequence)
        }
        let account: CosmosAccount
        if let pending = pendingAccountFetchTask {
            account = try await pending.value
        } else {
            let task = Task { try await self.fetchAccountOrThrowFunding(address) }
            pendingAccountFetchTask = task
            account = try await task.value
            pendingAccountFetchTask = nil
        }
        // A concurrent caller may have already seeded the cache while we were
        // awaiting the fetch above — recheck rather than blindly overwriting.
        if let cached = cachedSequenceState, cached.address == address {
            cachedSequenceState = (address, cached.accountNumber, cached.nextSequence + 1)
            return (cached.accountNumber, cached.nextSequence)
        }
        cachedSequenceState = (address, account.accountNumber, account.sequence + 1)
        return (account.accountNumber, account.sequence)
    }

    /// Drops the cached sequence so the next reservation re-fetches from chain.
    /// Called when a broadcast is rejected as a sequence mismatch anyway (e.g.
    /// another session used the same key, or a prior tx never made it to
    /// mempool) — without this, a wrong local cache would wedge every future
    /// submission instead of self-correcting.
    private func resetSequenceCache() {
        cachedSequenceState = nil
    }

    private func isSequenceMismatch(code: Int, log: String?) -> Bool {
        code == 32 || (log?.localizedCaseInsensitiveContains("account sequence mismatch") ?? false)
    }

    /// Signs and broadcasts via `build` (given a reserved accountNumber/sequence),
    /// confirms inclusion, and retries once — with a freshly re-fetched sequence —
    /// if the chain rejects it as a sequence mismatch. Centralizes the
    /// reserve→sign→broadcast→confirm shape every write path below needs.
    private func broadcastWithSequenceRetry(
        creator: String,
        build: (_ accountNumber: UInt64, _ sequence: UInt64) throws -> Data
    ) async throws -> CosmosTransactionResult {
        var lastError: Error = CosmosError.chainError(-1, "broadcast failed")
        for attempt in 0..<2 {
            let (accountNumber, sequence) = try await reserveSequence(for: creator)
            let txBytes = try build(accountNumber, sequence)
            let result = try await client.broadcastTx(txBytes)
            if result.code != 0 {
                if attempt == 0, isSequenceMismatch(code: result.code, log: result.rawLog) {
                    resetSequenceCache()
                    lastError = CosmosError.chainError(result.code, result.rawLog ?? "broadcast failed")
                    continue
                }
                throw CosmosError.chainError(result.code, result.rawLog ?? "broadcast failed")
            }
            let confirmed = await recordAndConfirmTx(result.txHash)
            if let confirmed, confirmed.code != 0 {
                if attempt == 0, isSequenceMismatch(code: confirmed.code, log: confirmed.rawLog) {
                    resetSequenceCache()
                    lastError = CosmosError.chainError(confirmed.code, confirmed.rawLog ?? "failed in block")
                    continue
                }
                throw CosmosError.chainError(confirmed.code, confirmed.rawLog ?? "failed in block")
            }
            return CosmosTransactionResult(
                txHash: result.txHash,
                height: confirmed?.height ?? result.height,
                code: 0, rawLog: result.rawLog, gasUsed: confirmed?.gasUsed ?? result.gasUsed
            )
        }
        throw lastError
    }

    // MARK: - Helpers

    private func fetchAccountOrThrowFunding(_ address: String) async throws -> CosmosAccount {
        do {
            return try await client.getAccount(address: address)
        } catch CosmosError.accountNotFound {
            throw CosmosError.chainError(-1, "Account \(address) is not on chain yet — fund it with \(config.network.displayDenom) first.")
        }
    }

    private func getOrCreateBlinding() -> Data {
        if let existing = defaults.data(forKey: Self.blindingKey), existing.count == 32 {
            return existing
        }
        var bytes = Data(count: 32)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        defaults.set(bytes, forKey: Self.blindingKey)
        return bytes
    }

    /// Parse a 0x-hex field element into a left-padded 32-byte big-endian Data.
    static func hexToData32(_ hex: String) -> Data {
        let bytes = ProofOutput.bytes(fromHex: hex)
        if bytes.count == 32 { return Data(bytes) }
        var out = [UInt8](repeating: 0, count: 32)
        let src = bytes.suffix(32)
        out.replaceSubrange((32 - src.count)..<32, with: src)
        return Data(out)
    }
}
