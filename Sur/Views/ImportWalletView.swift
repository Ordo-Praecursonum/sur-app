//
//  ImportWalletView.swift
//  Sur
//
//  View for importing an existing wallet using mnemonic
//

import SwiftUI

/// View for importing an existing wallet
struct ImportWalletView: View {
    
    // MARK: - Properties
    
    @EnvironmentObject private var authManager: AuthenticationManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var currentStep: ImportStep = .mnemonic
    @State private var mnemonicInput: String = ""
    @State private var useBiometric = true
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var showError = false
    @FocusState private var isTextEditorFocused: Bool
    
    // MARK: - Types
    
    enum ImportStep {
        case mnemonic
        case security
        case complete
    }
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            ProgressView(value: progressValue)
                .progressViewStyle(.linear)
                .tint(.orange)
                .padding(.horizontal)
            
            switch currentStep {
            case .mnemonic:
                mnemonicInputView
            case .security:
                securitySetupView
            case .complete:
                completionView
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(currentStep != .mnemonic)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if currentStep != .mnemonic {
                    Button("Back") {
                        withAnimation {
                            goBack()
                        }
                    }
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isTextEditorFocused = false
                }
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "An error occurred")
        }
    }
    
    // MARK: - Mnemonic Input View
    
    private var mnemonicInputView: some View {
        VStack(spacing: 24) {
            // Instructions
            VStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.orange)
                    .padding(.top, 24)
                
                Text("Enter Recovery Phrase")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Enter your 12 or 24 word recovery phrase to restore your wallet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            // Mnemonic text editor
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $mnemonicInput)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 150)
                    .padding(12)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .focused($isTextEditorFocused)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                
                HStack {
                    Text("Words: \(wordCount)")
                        .font(.caption)
                        .foregroundColor(isValidWordCount ? .green : .secondary)
                    
                    Spacer()
                    
                    if !mnemonicInput.isEmpty {
                        Button(action: { mnemonicInput = "" }) {
                            Text("Clear")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .padding(.horizontal)
            
            // Validation status
            if !mnemonicInput.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: isValidMnemonic ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(isValidMnemonic ? .green : .red)
                    Text(isValidMnemonic ? "Valid recovery phrase" : "Invalid recovery phrase")
                        .font(.subheadline)
                        .foregroundColor(isValidMnemonic ? .green : .red)
                }
            }
            
            Spacer()
            
            // Continue button
            Button(action: {
                withAnimation {
                    currentStep = .security
                }
            }) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .background(isValidMnemonic ?
                LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing) :
                LinearGradient(colors: [.gray], startPoint: .leading, endPoint: .trailing)
            )
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .disabled(!isValidMnemonic)
        }
    }
    
    // MARK: - Security Setup View
    
    private var securitySetupView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Icon
            Image(systemName: authManager.biometricType.iconName)
                .font(.system(size: 60))
                .foregroundStyle(.orange)
                .padding(.bottom, 16)
            
            // Title and description
            VStack(spacing: 12) {
                Text("Secure Your Wallet")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Choose how you want to protect access to your wallet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            Spacer()
            
            // Security options
            VStack(spacing: 16) {
                if authManager.isBiometricAvailable {
                    SecurityOptionRow(
                        icon: authManager.biometricType.iconName,
                        title: "Use \(authManager.biometricType.displayName)",
                        description: "Quick and secure access",
                        isSelected: useBiometric
                    ) {
                        useBiometric = true
                    }
                }
                
                SecurityOptionRow(
                    icon: "lock.open",
                    title: "No Additional Security",
                    description: "Access without authentication",
                    isSelected: !useBiometric
                ) {
                    useBiometric = false
                }
            }
            .padding(.horizontal)
            
            Spacer()
            
            // Import button
            Button(action: { importWallet() }) {
                if isImporting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    Text("Import Wallet")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .background(
                LinearGradient(
                    colors: [.orange, .red],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .disabled(isImporting)
        }
    }
    
    // MARK: - Completion View
    
    private var completionView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)
            
            VStack(spacing: 12) {
                Text("Wallet Imported!")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("Your wallet has been successfully restored")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            // Address display
            if let address = authManager.publicAddress {
                VStack(spacing: 8) {
                    Text("Your Ethereum Address")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(address)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .textSelection(.enabled)
                }
                .padding(.horizontal)
            }
            
            Spacer()
            
            // Done button
            Button(action: { dismiss() }) {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .background(
                LinearGradient(
                    colors: [.orange, .red],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
    
    // MARK: - Helper Properties
    
    private var progressValue: Double {
        switch currentStep {
        case .mnemonic: return 0.33
        case .security: return 0.66
        case .complete: return 1.0
        }
    }
    
    private var navigationTitle: String {
        switch currentStep {
        case .mnemonic: return "Import Wallet"
        case .security: return "Security Setup"
        case .complete: return "Complete"
        }
    }
    
    private var normalizedMnemonic: String {
        mnemonicInput
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
    
    private var wordCount: Int {
        normalizedMnemonic.isEmpty ? 0 : normalizedMnemonic.split(separator: " ").count
    }
    
    private var isValidWordCount: Bool {
        [12, 15, 18, 21, 24].contains(wordCount)
    }
    
    private var isValidMnemonic: Bool {
        MnemonicGenerator.validateMnemonic(normalizedMnemonic)
    }
    
    // MARK: - Actions
    
    private func importWallet() {
        isImporting = true
        
        Task {
            do {
                try await authManager.importWallet(
                    mnemonic: normalizedMnemonic,
                    useBiometric: useBiometric
                )
                
                await MainActor.run {
                    isImporting = false
                    withAnimation {
                        currentStep = .complete
                    }
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
    
    private func goBack() {
        switch currentStep {
        case .mnemonic:
            break
        case .security:
            currentStep = .mnemonic
        case .complete:
            currentStep = .security
        }
    }
}

#Preview {
    NavigationStack {
        ImportWalletView()
            .environmentObject(AuthenticationManager.shared)
    }
}
