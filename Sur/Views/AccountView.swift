//
//  AccountView.swift
//  Sur
//
//  Account view displaying wallet address and network selection
//

import SwiftUI
import CryptoKit

/// Account view displaying the user's wallet information
struct AccountView: View {
    
    // MARK: - Properties
    
    @EnvironmentObject private var authManager: AuthenticationManager
    @State private var showRecoveryPhrase = false
    @State private var showDeleteConfirmation = false
    @State private var showCopiedToast = false
    @State private var showNetworkSelector = false
    @State private var recoveryPhrase: String?
    @State private var isLoadingPhrase = false
    @State private var showError = false
    @State private var errorMessage: String?
    @State private var showSignMessageDialog = false
    @State private var messageToSign = ""
    @State private var signedSignature: String?
    @State private var signedSignatureDER: String?
    @State private var messageHash: String?
    @State private var showSignatureResult = false
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            List {
                // Network & Address Section
                Section {
                    VStack(alignment: .center, spacing: 16) {
                        // Network selector button
                        Button(action: { showNetworkSelector = true }) {
                            HStack(spacing: 12) {
                                // Network icon with network-specific color
                                ZStack {
                                    Circle()
                                        .fill(authManager.selectedNetwork.color)
                                        .frame(width: 44, height: 44)
                                    
                                    Image(systemName: authManager.selectedNetwork.iconName)
                                        .font(.system(size: 20))
                                        .foregroundColor(.white)
                                }
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(authManager.selectedNetwork.displayName)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text(authManager.selectedNetwork.symbol)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        
                        Divider()
                        
                        // Address
                        if let address = authManager.publicAddress {
                            VStack(spacing: 8) {
                                Text("Your \(authManager.selectedNetwork.displayName) Address")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Text(address)
                                    .font(.system(.caption, design: .monospaced))
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(.primary)
                                
                                // Copy button with orange accent
                                Button(action: { copyAddress(address) }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.on.doc")
                                        Text("Copy Address")
                                    }
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        
                        // Device Public Key
                        if let devicePublicKey = authManager.devicePublicKey {
                            Divider()
                                .padding(.vertical, 8)
                            
                            VStack(spacing: 8) {
                                Text("Device Public Key")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Text(authManager.shortDevicePublicKey ?? DeviceIDManager.shortenDevicePublicKey(devicePublicKey))
                                    .font(.system(.caption, design: .monospaced))
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(.primary)
                                
                                // Copy button with orange accent
                                Button(action: { copyDevicePublicKey(devicePublicKey) }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.on.doc")
                                        Text("Copy Device Key")
                                    }
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                }
                                .buttonStyle(.plain)
                                
                                // Sign message button with orange accent
                                Button(action: { showSignMessageDialog = true }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "signature")
                                        Text("Sign a Message")
                                    }
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Sign a message with device private key")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                
                // Security Section
                Section {
                    HStack {
                        Label("Security", systemImage: "lock.shield")
                        Spacer()
                        Text(authManager.isBiometricEnabled ? 
                             authManager.biometricType.displayName : "None")
                            .foregroundColor(.secondary)
                    }
                    
                    Button(action: { showRecoveryPhrase = true }) {
                        HStack {
                            Label("View Recovery Phrase", systemImage: "key")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)
                } header: {
                    Text("Wallet Security")
                }
                
                // App Settings Section
                Section {
                    NavigationLink {
                        KeyboardSettingsView()
                    } label: {
                        Label("Keyboard Settings", systemImage: "keyboard")
                    }
                } header: {
                    Text("App Settings")
                }
                
                // About Section
                Section {
                    HStack {
                        Label("Version", systemImage: "info.circle")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("About")
                }
                
                // Danger Zone
                Section {
                    Button(action: { authManager.lock() }) {
                        Label("Lock Wallet", systemImage: "lock")
                    }
                    
                    Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                        Label("Delete Wallet", systemImage: "trash")
                    }
                } header: {
                    Text("Actions")
                } footer: {
                    Text("Deleting your wallet will remove all data from this device. Make sure you have backed up your recovery phrase.")
                }
            }
            .navigationTitle("Sur Keyboard")
            .tint(.orange)
            .overlay {
                if showCopiedToast {
                    VStack {
                        Spacer()
                        Text("Address Copied!")
                            .font(.subheadline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color(.systemGray6))
                            .clipShape(Capsule())
                            .padding(.bottom, 100)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .sheet(isPresented: $showNetworkSelector) {
                NetworkSelectorSheet(
                    selectedNetwork: $authManager.selectedNetwork,
                    isPresented: $showNetworkSelector
                )
            }
            .sheet(isPresented: $showRecoveryPhrase) {
                RecoveryPhraseSheet(
                    isPresented: $showRecoveryPhrase,
                    recoveryPhrase: $recoveryPhrase,
                    isLoading: $isLoadingPhrase,
                    loadPhrase: loadRecoveryPhrase
                )
            }
            .sheet(isPresented: $showSignMessageDialog) {
                SignMessageSheet(
                    isPresented: $showSignMessageDialog,
                    messageToSign: $messageToSign,
                    onSign: signMessage
                )
            }
            .sheet(isPresented: $showSignatureResult) {
                SignatureResultSheet(
                    isPresented: $showSignatureResult,
                    signature: signedSignature ?? "",
                    signatureDER: signedSignatureDER,
                    message: messageToSign,
                    messageHash: messageHash ?? ""
                )
            }
            .onChange(of: showSignatureResult) { _, newValue in
                if !newValue {
                    // Clear sensitive data when sheet is dismissed
                    messageToSign = ""
                    signedSignature = nil
                }
            }
            .alert("Delete Wallet", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    authManager.signOut(deleteWallet: true)
                }
            } message: {
                Text("Are you sure you want to delete your wallet? This action cannot be undone. Make sure you have backed up your recovery phrase.")
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage ?? "An error occurred")
            }
        }
    }
    
    // MARK: - Actions
    
    private func copyAddress(_ address: String) {
        UIPasteboard.general.string = address
        
        withAnimation {
            showCopiedToast = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showCopiedToast = false
            }
        }
    }
    
    private func copyDevicePublicKey(_ devicePublicKey: Data) {
        let publicKeyHex = devicePublicKey.map { String(format: "%02x", $0) }.joined()
        UIPasteboard.general.string = publicKeyHex
        
        withAnimation {
            showCopiedToast = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showCopiedToast = false
            }
        }
    }
    
    private func loadRecoveryPhrase() {
        isLoadingPhrase = true
        
        Task {
            do {
                let phrase = try await authManager.getMnemonic()
                await MainActor.run {
                    recoveryPhrase = phrase
                    isLoadingPhrase = false
                }
            } catch {
                await MainActor.run {
                    isLoadingPhrase = false
                    errorMessage = error.localizedDescription
                    showRecoveryPhrase = false
                    showError = true
                }
            }
        }
    }
    
    private func signMessage() {
        guard !messageToSign.isEmpty else {
            errorMessage = "Please enter a message to sign"
            showError = true
            return
        }
        
        guard let devicePrivateKey = DeviceIDManager.shared.getStoredDevicePrivateKey() else {
            errorMessage = "Device private key not found"
            showError = true
            return
        }
        
        // Hash the message using SHA-256 (standard practice for ECDSA signing)
        guard let messageData = messageToSign.data(using: .utf8) else {
            errorMessage = "Failed to encode message"
            showError = true
            return
        }
        
        let messageHash = SHA256.hash(data: messageData)
        let messageHashData = Data(messageHash)
        
        // Store the message hash as hex for display
        let messageHashHex = messageHashData.map { String(format: "%02x", $0) }.joined()
        self.messageHash = messageHashHex
        
        // Sign the message hash with device private key
        guard let signature = Secp256k1.sign(messageHash: messageHashData, with: devicePrivateKey) else {
            errorMessage = "Failed to sign message"
            showError = true
            return
        }
        
        // Convert signature to hex string (compact R+S format)
        let signatureHex = signature.map { String(format: "%02x", $0) }.joined()
        signedSignature = signatureHex
        
        // Also convert to DER format for external tool compatibility
        if let derSignature = Secp256k1.convertToDER(signature: signature) {
            let derHex = derSignature.map { String(format: "%02x", $0) }.joined()
            signedSignatureDER = derHex
        } else {
            // DER conversion failure is non-critical - compact format is still available
            // External tools that support compact R+S format can still verify the signature
            #if DEBUG
            print("[AccountView] DER conversion failed, only compact signature available")
            #endif
        }
        
        // Close the sign dialog and show the result
        showSignMessageDialog = false
        showSignatureResult = true
    }
}

// MARK: - Sign Message Sheet

struct SignMessageSheet: View {
    @Binding var isPresented: Bool
    @Binding var messageToSign: String
    let onSign: () -> Void
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Enter Message to Sign")
                        .font(.headline)
                    
                    Text("Enter the message you want to sign with your device private key. The message will be hashed using SHA-256 before signing.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    TextEditor(text: $messageToSign)
                        .font(.body)
                        .frame(minHeight: 150)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding()
                
                Spacer()
                
                Button(action: {
                    onSign()
                }) {
                    Text("Sign Message")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            LinearGradient(
                                colors: [.orange, .red],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .disabled(messageToSign.isEmpty)
            }
            .navigationTitle("Sign Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        messageToSign = ""
                        isPresented = false
                    }
                    .foregroundColor(.orange)
                }
            }
        }
    }
}

// MARK: - Signature Result Sheet

struct SignatureResultSheet: View {
    @Binding var isPresented: Bool
    let signature: String
    let signatureDER: String?
    let message: String
    let messageHash: String
    @State private var showCopied = false
    @State private var showCopiedDER = false
    @State private var showPrivateKeyCopied = false
    @State private var showPublicKeyCopied = false
    @State private var showHashCopied = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Success indicator
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.green)
                        .padding(.top, 24)
                    
                    Text("Message Signed Successfully")
                        .font(.headline)
                    
                    // Signing algorithm info
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Signing Algorithm")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Text("ECDSA on secp256k1 curve")
                            .font(.body)
                            .foregroundColor(.secondary)
                        
                        Text("Message is hashed using SHA-256, then signed with the device private key using ECDSA (Elliptic Curve Digital Signature Algorithm) on the secp256k1 curve. This is the same algorithm used by Bitcoin and Ethereum.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    
                    // Original message
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Original Message")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(message)
                            .font(.system(.body, design: .monospaced))
                            .padding()
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(.horizontal)
                    
                    // Message Hash (SHA-256)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Message Hash (SHA-256)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(messageHash)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .padding()
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        
                        Button(action: {
                            UIPasteboard.general.string = messageHash
                            withAnimation {
                                showHashCopied = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation {
                                    showHashCopied = false
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: "doc.on.doc")
                                Text(showHashCopied ? "Copied!" : "Copy Hash")
                            }
                            .font(.caption)
                            .foregroundColor(.orange)
                        }
                    }
                    .padding(.horizontal)
                    
                    // Signature (Compact R+S format - 64 bytes)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Signature - Compact Format (R+S, 64 bytes)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(signature)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .padding()
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        
                        Button(action: {
                            UIPasteboard.general.string = signature
                            withAnimation {
                                showCopied = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation {
                                    showCopied = false
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: "doc.on.doc")
                                Text(showCopied ? "Copied!" : "Copy Compact Signature")
                            }
                            .font(.caption)
                            .foregroundColor(.orange)
                        }
                    }
                    .padding(.horizontal)
                    
                    // Signature (DER format for external tools)
                    if let derSig = signatureDER {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Signature - DER Format (for external tools)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text(derSig)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(nil)
                                .multilineTextAlignment(.leading)
                                .padding()
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            
                            Button(action: {
                                UIPasteboard.general.string = derSig
                                withAnimation {
                                    showCopiedDER = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    withAnimation {
                                        showCopiedDER = false
                                    }
                                }
                            }) {
                                HStack {
                                    Image(systemName: "doc.on.doc")
                                    Text(showCopiedDER ? "Copied!" : "Copy DER Signature")
                                }
                                .font(.caption)
                                .foregroundColor(.orange)
                            }
                            
                            Text("⚠️ Important: When using external tools, enter the ORIGINAL MESSAGE (not the hash) in the Input field. The tool will hash it automatically.")
                                .font(.caption2)
                                .foregroundColor(.orange)
                                .fontWeight(.semibold)
                                .padding(.top, 4)
                            
                            // Verification guide
                            VStack(alignment: .leading, spacing: 4) {
                                Text("External Tool Verification Steps:")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 8)
                                
                                Text("1. Input: Enter '\(message)' (the message text, NOT the hash)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                
                                Text("2. Curve: Select secp256k1")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                
                                Text("3. Hash: Select SHA-256")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                
                                Text("4. Public Key: Use the uncompressed public key below")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                
                                Text("5. Signature: Use the DER format signature above")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        }
                        .padding(.horizontal)
                    }
                    
                    // Device Public Key
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Device Public Key (For Verification)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if let devicePublicKey = DeviceIDManager.shared.getStoredDevicePublicKey() {
                            let publicKeyHex = devicePublicKey.map { String(format: "%02x", $0) }.joined()
                            
                            Text(publicKeyHex)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(nil)
                                .multilineTextAlignment(.leading)
                                .padding()
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            
                            Button(action: {
                                UIPasteboard.general.string = publicKeyHex
                                withAnimation {
                                    showPublicKeyCopied = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    withAnimation {
                                        showPublicKeyCopied = false
                                    }
                                }
                            }) {
                                HStack {
                                    Image(systemName: "doc.on.doc")
                                    Text(showPublicKeyCopied ? "Copied!" : "Copy Public Key")
                                }
                                .font(.caption)
                                .foregroundColor(.orange)
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    // Device Private Key (for testing on external sites)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Device Private Key (For Testing)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("⚠️ Keep this secret! Only use on trusted verification sites for testing.")
                            .font(.caption2)
                            .foregroundColor(.red)
                            .padding(.vertical, 4)
                        
                        if let devicePrivateKey = DeviceIDManager.shared.getStoredDevicePrivateKey() {
                            let privateKeyHex = devicePrivateKey.map { String(format: "%02x", $0) }.joined()
                            
                            Text(privateKeyHex)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(nil)
                                .multilineTextAlignment(.leading)
                                .padding()
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            
                            Button(action: {
                                UIPasteboard.general.string = privateKeyHex
                                withAnimation {
                                    showPrivateKeyCopied = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    withAnimation {
                                        showPrivateKeyCopied = false
                                    }
                                }
                            }) {
                                HStack {
                                    Image(systemName: "doc.on.doc")
                                    Text(showPrivateKeyCopied ? "Copied!" : "Copy Private Key")
                                }
                                .font(.caption)
                                .foregroundColor(.orange)
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    Spacer()
                }
            }
            .navigationTitle("Signature Result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                    .foregroundColor(.orange)
                }
            }
        }
    }
}

// MARK: - Network Selector Sheet

struct NetworkSelectorSheet: View {
    @Binding var selectedNetwork: BlockchainNetwork
    @Binding var isPresented: Bool
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(BlockchainNetwork.allCases) { network in
                    Button(action: {
                        selectedNetwork = network
                        isPresented = false
                    }) {
                        HStack(spacing: 16) {
                            // Network icon with network-specific color
                            ZStack {
                                Circle()
                                    .fill(network.color)
                                    .frame(width: 44, height: 44)
                                
                                Image(systemName: network.iconName)
                                    .font(.system(size: 20))
                                    .foregroundColor(.white)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(network.displayName)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                
                                Text(network.symbol)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if network == selectedNetwork {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.orange)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Select Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                    .foregroundColor(.orange)
                }
            }
        }
    }
}

// MARK: - Recovery Phrase Sheet

struct RecoveryPhraseSheet: View {
    @Binding var isPresented: Bool
    @Binding var recoveryPhrase: String?
    @Binding var isLoading: Bool
    let loadPhrase: () -> Void
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if isLoading {
                    Spacer()
                    ProgressView("Authenticating...")
                    Spacer()
                } else if let phrase = recoveryPhrase {
                    // Warning banner
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text("Never share your recovery phrase with anyone")
                            .font(.subheadline)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.top)
                    
                    // Mnemonic words grid
                    let words = phrase.split(separator: " ").map(String.init)
                    
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 12) {
                            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                                HStack(spacing: 4) {
                                    Text("\(index + 1).")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .frame(width: 24, alignment: .trailing)
                                    Text(word)
                                        .font(.system(.body, design: .monospaced))
                                        .fontWeight(.medium)
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(.horizontal)
                    }
                    
                    Spacer()
                    
                    // Copy button
                    Button(action: {
                        UIPasteboard.general.string = phrase
                    }) {
                        HStack {
                            Image(systemName: "doc.on.doc")
                            Text("Copy to Clipboard")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray6))
                        .foregroundColor(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                } else {
                    Spacer()
                    
                    VStack(spacing: 16) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(.orange)
                        
                        Text("Authenticate to view your recovery phrase")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button(action: loadPhrase) {
                            Text("Authenticate")
                                .font(.headline)
                                .padding()
                                .padding(.horizontal, 24)
                                .background(
                                    LinearGradient(
                                        colors: [.orange, .red],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .padding()
                    
                    Spacer()
                }
            }
            .navigationTitle("Recovery Phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        recoveryPhrase = nil
                        isPresented = false
                    }
                    .foregroundColor(.orange)
                }
            }
            .onDisappear {
                recoveryPhrase = nil
            }
        }
    }
}

// MARK: - Keyboard Settings View

struct KeyboardSettingsView: View {
    @StateObject private var settings = AppSettings.shared
    
    var body: some View {
        List {
            Section {
                Toggle(isOn: $settings.isHapticFeedbackEnabled) {
                    Label("Haptic Feedback", systemImage: "hand.tap")
                }
                .tint(.orange)
            } header: {
                Text("Keyboard Settings")
            } footer: {
                Text("When enabled, you'll feel a gentle vibration when pressing keys.")
            }
            
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Keyboard Setup", systemImage: "keyboard")
                        .font(.headline)
                    
                    Text("To use the Sur Keyboard:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        SetupStepView(number: 1, text: "Open Settings")
                        SetupStepView(number: 2, text: "Go to General → Keyboard")
                        SetupStepView(number: 3, text: "Tap Keyboards → Add New Keyboard")
                        SetupStepView(number: 4, text: "Select \"SurKeyboard\"")
                    }
                    .padding(.vertical, 4)
                    
                    Button(action: openKeyboardSettings) {
                        Label("Open Keyboard Settings", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                .padding(.vertical, 8)
            } header: {
                Text("Getting Started")
            }
        }
        .navigationTitle("Keyboard Settings")
        .tint(.orange)
    }
    
    private func openKeyboardSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

#Preview {
    AccountView()
        .environmentObject(AuthenticationManager.shared)
}
