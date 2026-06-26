//
//  KeystrokeLogsView.swift
//  Sur
//
//  View for displaying keystroke logging sessions with details,
//  hash copying, and human typing evaluation.
//

import SwiftUI
import CryptoKit

// MARK: - Keystroke Logs List View

struct KeystrokeLogsView: View {
    @State private var sessions: [KeystrokeSession] = []
    @State private var selectedSession: KeystrokeSession?
    @State private var showingDetail = false
    @State private var copiedToast = false
    @StateObject private var attestStore = TextAttestationStore.shared
    
    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        
                        Text("No Keystroke Logs")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("Start typing with the Sur Keyboard and tap the check button to create a keystroke log.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(sessions, id: \.sessionId) { session in
                            SessionRowView(session: session, attestStore: attestStore)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedSession = session
                                    showingDetail = true
                                }
                        }
                        .onDelete(perform: deleteSessions)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Keystroke Logs")
            .toolbar {
                if !sessions.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        EditButton()
                    }
                }
            }
            .sheet(isPresented: $showingDetail) {
                if let session = selectedSession {
                    SessionDetailView(session: session)
                }
            }
            .overlay {
                if copiedToast {
                    VStack {
                        Spacer()
                        Text("Copied to clipboard")
                            .padding()
                            .background(Color.black.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .padding(.bottom, 50)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .onAppear {
            loadSessions()
        }
    }
    
    private func loadSessions() {
        sessions = KeystrokeLogManager.shared.loadAllSessions()
        // Automatically attest captured sessions on-chain (eligible ones only;
        // already-attested sessions are skipped). Runs in the background.
        attestStore.autoAttest(sessions: sessions)
    }
    
    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            let session = sessions[index]
            KeystrokeLogManager.shared.deleteSession(byId: session.sessionId)
        }
        sessions.remove(atOffsets: offsets)
    }
}

// MARK: - Session Row View

struct SessionRowView: View {
    let session: KeystrokeSession
    @ObservedObject var attestStore: TextAttestationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.shortHash)
                    .font(.system(.headline, design: .monospaced))
                    .foregroundColor(.primary)

                Spacer()

                HumanScoreBadge(score: session.humanTypingScore ?? 0)
            }

            HStack {
                Image(systemName: "keyboard")
                    .foregroundColor(.secondary)
                Text("\(session.signedKeystrokes.count) keystrokes")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Text(formatDate(session.startTimestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !session.typedText.isEmpty {
                Text(session.typedText.prefix(50) + (session.typedText.count > 50 ? "..." : ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            attestationStatus
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var attestationStatus: some View {
        if !attestStore.isEligible(session) {
            Label("Too short to attest (needs ≥\(TextAttestationStore.minKeystrokes) keystrokes)",
                  systemImage: "minus.circle")
                .font(.caption2)
                .foregroundColor(.secondary)
        } else if let item = attestStore.status(forSessionId: session.sessionId) {
            HStack(spacing: 6) {
                switch item.status {
                case .pending:
                    Label("Queued for attestation", systemImage: "clock")
                        .font(.caption2).foregroundColor(.secondary)
                case .submitting:
                    ProgressView().scaleEffect(0.7)
                    Text("Attesting on-chain…").font(.caption2).foregroundColor(.orange)
                case .submitted:
                    Label("Attested on-chain", systemImage: "checkmark.seal.fill")
                        .font(.caption2).foregroundColor(.green)
                    Spacer()
                    if let tx = item.txHash {
                        Text(shorten(tx))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                case .failed:
                    Label("Attestation failed", systemImage: "xmark.circle")
                        .font(.caption2).foregroundColor(.red)
                    Spacer()
                    Button("Retry") { Task { await attestStore.submit(id: item.id) } }
                        .font(.caption2).buttonStyle(.borderless)
                }
            }
            // Show the actual reason so failures are diagnosable, not opaque.
            if item.status == .failed, let err = item.error, !err.isEmpty {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if SurChainIdentityManager.shared.registeredUsername == nil {
            Label("Register device (Account → Sur Chain) to attest",
                  systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundColor(.secondary)
        } else {
            Label("Preparing attestation…", systemImage: "hourglass")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    private func shorten(_ s: String) -> String {
        guard s.count > 12 else { return s }
        return "\(s.prefix(8))…\(s.suffix(4))"
    }

    private func formatDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Human Score Badge

struct HumanScoreBadge: View {
    let score: Double
    
    var color: Color {
        if score >= 80 {
            return .green
        } else if score >= 50 {
            return .orange
        } else {
            return .red
        }
    }
    
    var body: some View {
        Text("\(Int(score))%")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color)
            .cornerRadius(8)
    }
}

// MARK: - Session Detail View

struct SessionDetailView: View {
    let session: KeystrokeSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var attestStore = TextAttestationStore.shared
    @State private var showingZKProof = false
    @State private var showingSolidityCode = false
    @State private var copiedToast = false

    /// The attestation queue item for this session, if one exists.
    private var attestItem: AttestationItem? {
        attestStore.status(forSessionId: session.sessionId)
    }

    /// SHA-256 of the typed text (hex) — the value to paste into the explorer's
    /// "Verify Origin" page to look this content up on-chain.
    private var contentHashHex: String? {
        guard !session.typedText.isEmpty else { return nil }
        return Data(SHA256.hash(data: Data(session.typedText.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }

    var body: some View {
        NavigationStack {
            List {
                // Session Info Section
                Section("Session Info") {
                    InfoRow(label: "Session ID", value: session.sessionId)
                    InfoRow(label: "Hash", value: session.sessionHash ?? "N/A", monospaced: true)
                    InfoRow(label: "Keystrokes", value: "\(session.signedKeystrokes.count)")
                    InfoRow(label: "Duration", value: formatDuration())
                    InfoRow(label: "Started", value: formatTimestamp(session.startTimestamp))
                    if let endTime = session.endTimestamp {
                        InfoRow(label: "Ended", value: formatTimestamp(endTime))
                    }
                }

                attestationSection

                // Human Typing Analysis Section
                Section("Human Typing Analysis") {
                    HStack {
                        Text("Human Typing Score")
                        Spacer()
                        HumanScoreBadge(score: session.humanTypingScore ?? 0)
                    }
                    
                    if let analysis = getDetailedAnalysis() {
                        VStack(alignment: .leading, spacing: 8) {
                            AnalysisBar(label: "Timing", score: analysis.timingScore)
                            AnalysisBar(label: "Variation", score: analysis.variationScore)
                            AnalysisBar(label: "Coordinates", score: analysis.coordinateScore)
                            AnalysisBar(label: "Patterns", score: analysis.patternScore)
                        }
                        .padding(.vertical, 4)
                        
                        InfoRow(label: "Avg. Interval", value: String(format: "%.0f ms", analysis.averageInterKeyInterval))
                    }
                }
                
                // Typed Text Section
                if !session.typedText.isEmpty {
                    Section("Typed Text") {
                        Text(session.typedText)
                            .font(.body)
                    }
                }
                
                // Keystrokes Table Section
                Section("Keystrokes") {
                    ForEach(Array(session.signedKeystrokes.enumerated()), id: \.offset) { index, signedKeystroke in
                        KeystrokeRow(index: index, signedKeystroke: signedKeystroke)
                    }
                }
                
                // ZK Proof Section
                if session.zkProof != nil {
                    Section("Zero Knowledge Proof") {
                        Button(action: { showingZKProof = true }) {
                            HStack {
                                Image(systemName: "checkmark.shield")
                                Text("View ZK Proof")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Button(action: { showingSolidityCode = true }) {
                            HStack {
                                Image(systemName: "doc.text")
                                Text("View Solidity Verifier")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                // Actions Section
                Section {
                    Button(action: copyHash) {
                        Label("Copy Hash", systemImage: "doc.on.doc")
                    }
                    
                    Button(action: copyJSON) {
                        Label("Copy Full Log (JSON)", systemImage: "doc.on.doc.fill")
                    }
                    
                    if session.zkProof != nil {
                        Button(action: copyZKProof) {
                            Label("Copy ZK Proof (JSON)", systemImage: "checkmark.shield")
                        }
                        
                        Button(action: copyRemixFormat) {
                            Label("Copy for Remix IDE", systemImage: "terminal")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Session Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingZKProof) {
                ZKProofDetailView(proof: session.zkProof!)
            }
            .sheet(isPresented: $showingSolidityCode) {
                SolidityCodeView()
            }
            .overlay {
                if copiedToast {
                    VStack {
                        Spacer()
                        Text("Copied to clipboard")
                            .padding()
                            .background(Color.black.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .padding(.bottom, 50)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
    
    private func formatDuration() -> String {
        let endTime = session.endTimestamp ?? session.signedKeystrokes.last?.keystroke.timestamp ?? session.startTimestamp
        let duration = endTime - session.startTimestamp
        let seconds = Double(duration) / 1000.0
        return String(format: "%.1f seconds", seconds)
    }
    
    private func formatTimestamp(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
    
    private func getDetailedAnalysis() -> HumanTypingAnalysis? {
        return HumanTypingEvaluator.evaluateDetailed(session: session)
    }
    
    // MARK: - On-chain attestation section

    @ViewBuilder
    private var attestationSection: some View {
        Section("On-Chain Attestation") {
            // Status line.
            HStack {
                Text("Status")
                Spacer()
                attestationStatusLabel
            }

            // Eligibility note for short sessions.
            if !attestStore.isEligible(session) {
                Text("This session is too short to attest (needs ≥\(TextAttestationStore.minKeystrokes) keystrokes).")
                    .font(.caption).foregroundColor(.secondary)
            }

            // Device id (the pseudonymous on-chain identity).
            if let deviceID = SurChainIdentityManager.shared.registeredUsername {
                copyableRow(label: "Device id", value: deviceID)
            }

            // Content hash — paste this into the explorer's Verify Origin page.
            if let ch = contentHashHex {
                copyableRow(label: "Content hash (SHA-256)", value: ch)
            }

            // Transaction + block, once on-chain.
            if let tx = attestItem?.txHash, !tx.isEmpty {
                copyableRow(label: "Transaction hash", value: tx)
            }
            if let h = attestItem?.txHeight {
                InfoRow(label: "Block height", value: "\(h)")
            }

            // Failure reason + manual submit.
            if let item = attestItem, item.status == .failed, let err = item.error, !err.isEmpty {
                Text(err).font(.caption).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let item = attestItem, item.status == .pending || item.status == .failed {
                Button {
                    Task { await attestStore.submit(id: item.id) }
                } label: {
                    Label(item.status == .failed ? "Retry attestation" : "Submit now",
                          systemImage: "arrow.up.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var attestationStatusLabel: some View {
        if !attestStore.isEligible(session) {
            Label("Not eligible", systemImage: "minus.circle").foregroundColor(.secondary)
        } else {
            switch attestItem?.status {
            case .submitted:
                Label("On-chain", systemImage: "checkmark.seal.fill").foregroundColor(.green)
            case .submitting:
                Label("Submitting…", systemImage: "hourglass").foregroundColor(.orange)
            case .failed:
                Label("Failed", systemImage: "xmark.circle").foregroundColor(.red)
            case .pending:
                Label("Pending", systemImage: "clock").foregroundColor(.secondary)
            case nil:
                Label("Not submitted", systemImage: "clock").foregroundColor(.secondary)
            }
        }
    }

    /// A tappable row that copies its value and is text-selectable.
    private func copyableRow(label: String, value: String) -> some View {
        Button { copyValue(value) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label).font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: "doc.on.doc").font(.caption).foregroundColor(.accentColor)
                }
                Text(value)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .foregroundColor(.primary)
    }

    private func copyValue(_ value: String) {
        Pasteboard.copy(value)
        showCopiedToast()
    }

    private func copyHash() {
        Pasteboard.copy(session.sessionHash ?? "")
        showCopiedToast()
    }
    
    private func copyJSON() {
        if let json = KeystrokeLogManager.shared.exportSessionAsJSON(session) {
            Pasteboard.copy(json)
            showCopiedToast()
        }
    }
    
    private func copyZKProof() {
        if let proof = session.zkProof {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(proof),
               let json = String(data: data, encoding: .utf8) {
                Pasteboard.copy(json)
                showCopiedToast()
            }
        }
    }
    
    private func copyRemixFormat() {
        if let proof = session.zkProof {
            // Format the 5 public inputs as a JSON array for the gnark verifier
            let inputs = proof.publicInputsArray()
            Pasteboard.copy(inputs.joined(separator: "\n"))
            showCopiedToast()
        }
    }
    
    private func showCopiedToast() {
        withAnimation {
            copiedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                copiedToast = false
            }
        }
    }
}

// MARK: - Info Row

struct InfoRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Analysis Bar

struct AnalysisBar: View {
    let label: String
    let score: Double
    
    var color: Color {
        if score >= 80 {
            return .green
        } else if score >= 50 {
            return .orange
        } else {
            return .red
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(score))%")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 6)
                        .cornerRadius(3)
                    
                    Rectangle()
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(score / 100), height: 6)
                        .cornerRadius(3)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Keystroke Row

struct KeystrokeRow: View {
    let index: Int
    let signedKeystroke: SignedKeystroke
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("#\(index + 1)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .leading)
                
                Text(displayKey)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)
                
                Spacer()
                
                Text(formatTimestamp())
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("X: \(String(format: "%.1f", signedKeystroke.keystroke.xCoordinate))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Text("Y: \(String(format: "%.1f", signedKeystroke.keystroke.yCoordinate))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(signedKeystroke.motionDigest.prefix(12) + "...")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var displayKey: String {
        let key = signedKeystroke.keystroke.key
        switch key {
        case "space": return "␣"
        case "return", "enter": return "⏎"
        case "delete", "backspace": return "⌫"
        case "shift": return "⇧"
        default: return key
        }
    }
    
    private func formatTimestamp() -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(signedKeystroke.keystroke.timestamp) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}

// MARK: - ZK Proof Detail View

struct ZKProofDetailView: View {
    let proof: ZKTypingProof
    @Environment(\.dismiss) private var dismiss
    @State private var copiedToast = false
    
    var body: some View {
        NavigationStack {
            List {
                Section("Proof Info") {
                    InfoRow(label: "Version", value: proof.version)
                    InfoRow(label: "Generated At", value: formatTimestamp(proof.generatedAt))
                }
                
                Section("Cryptographic Values") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Commitment")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(proof.commitment)
                            .font(.system(.caption, design: .monospaced))
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Challenge")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(proof.challenge)
                            .font(.system(.caption, design: .monospaced))
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Response")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(proof.response)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                
                Section("Public Inputs (gnark Groth16)") {
                    InfoRow(label: "Username Hash", value: proof.publicInputs.usernameHash, monospaced: true)
                    InfoRow(label: "Content Hash Lo", value: proof.publicInputs.contentHashLo, monospaced: true)
                    InfoRow(label: "Content Hash Hi", value: proof.publicInputs.contentHashHi, monospaced: true)
                    InfoRow(label: "Nullifier", value: proof.publicInputs.nullifier, monospaced: true)
                    InfoRow(label: "Commitment Root", value: proof.publicInputs.commitmentRoot, monospaced: true)
                }
                
                Section {
                    Button(action: copyProof) {
                        Label("Copy Proof (JSON)", systemImage: "doc.on.doc")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("ZK Proof")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .overlay {
                if copiedToast {
                    VStack {
                        Spacer()
                        Text("Copied to clipboard")
                            .padding()
                            .background(Color.black.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .padding(.bottom, 50)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
    
    private func formatTimestamp(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
    
    private func copyProof() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(proof),
           let json = String(data: data, encoding: .utf8) {
            Pasteboard.copy(json)
            showCopiedToast()
        }
    }
    
    private func showCopiedToast() {
        withAnimation {
            copiedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                copiedToast = false
            }
        }
    }
}

// MARK: - Solidity Code View

struct SolidityCodeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copiedToast = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(ZKProofGenerator.generateSolidityVerifier())
                    .font(.system(.caption, design: .monospaced))
                    .padding()
            }
            .navigationTitle("Solidity Verifier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: copyCode) {
                        Image(systemName: "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .overlay {
                if copiedToast {
                    VStack {
                        Spacer()
                        Text("Copied to clipboard")
                            .padding()
                            .background(Color.black.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .padding(.bottom, 50)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
    
    private func copyCode() {
        Pasteboard.copy(ZKProofGenerator.generateSolidityVerifier())
        showCopiedToast()
    }
    
    private func showCopiedToast() {
        withAnimation {
            copiedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                copiedToast = false
            }
        }
    }
}

// MARK: - Preview

#Preview {
    KeystrokeLogsView()
}
