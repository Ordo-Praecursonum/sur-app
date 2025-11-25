//
//  CreateWalletView.swift
//  Sur
//
//  View for creating a new wallet with mnemonic
//

import SwiftUI

/// View for creating a new wallet
struct CreateWalletView: View {
    
    // MARK: - Properties
    
    @EnvironmentObject private var authManager: AuthenticationManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var currentStep: WalletCreationStep = .security
    @State private var useBiometric = true
    @State private var generatedMnemonic: String = ""
    @State private var mnemonicWords: [String] = []
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var hasBackedUp = false
    
    // MARK: - Types
    
    enum WalletCreationStep {
        case security
        case mnemonic
        case confirm
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
            case .security:
                securitySetupView
            case .mnemonic:
                mnemonicDisplayView
            case .confirm:
                confirmationView
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(currentStep != .security)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if currentStep != .security {
                    Button("Back") {
                        withAnimation {
                            goBack()
                        }
                    }
                }
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "An error occurred")
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
            
            // Continue button
            Button(action: { createWallet() }) {
                if isCreating {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    Text("Create Wallet")
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
            .disabled(isCreating)
        }
    }
    
    // MARK: - Mnemonic Display View
    
    private var mnemonicDisplayView: some View {
        VStack(spacing: 24) {
            // Warning banner
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Important!")
                        .font(.headline)
                    Text("Write down these words in order. This is your only way to recover your wallet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.top)
            
            // Mnemonic words grid
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    ForEach(Array(mnemonicWords.enumerated()), id: \.offset) { index, word in
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
            
            // Backup confirmation
            Button(action: { hasBackedUp.toggle() }) {
                HStack {
                    Image(systemName: hasBackedUp ? "checkmark.square.fill" : "square")
                        .foregroundColor(hasBackedUp ? .green : .secondary)
                    Text("I have securely written down my recovery phrase")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
            }
            .padding(.horizontal)
            
            // Continue button
            Button(action: {
                withAnimation {
                    currentStep = .confirm
                }
            }) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .background(hasBackedUp ?
                LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing) :
                LinearGradient(colors: [.gray], startPoint: .leading, endPoint: .trailing)
            )
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .disabled(!hasBackedUp)
        }
    }
    
    // MARK: - Confirmation View
    
    private var confirmationView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Success icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)
            
            VStack(spacing: 12) {
                Text("Wallet Created!")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("Your wallet has been securely created")
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
        case .security: return 0.33
        case .mnemonic: return 0.66
        case .confirm: return 1.0
        }
    }
    
    private var navigationTitle: String {
        switch currentStep {
        case .security: return "Security Setup"
        case .mnemonic: return "Recovery Phrase"
        case .confirm: return "Complete"
        }
    }
    
    // MARK: - Actions
    
    private func createWallet() {
        isCreating = true
        
        Task {
            do {
                let mnemonic = try await authManager.createNewWallet(useBiometric: useBiometric)
                generatedMnemonic = mnemonic
                mnemonicWords = mnemonic.split(separator: " ").map(String.init)
                
                await MainActor.run {
                    isCreating = false
                    withAnimation {
                        currentStep = .mnemonic
                    }
                }
            } catch {
                await MainActor.run {
                    isCreating = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
    
    private func goBack() {
        switch currentStep {
        case .security:
            break
        case .mnemonic:
            currentStep = .security
        case .confirm:
            currentStep = .mnemonic
        }
    }
}

// MARK: - Security Option Row

struct SecurityOptionRow: View {
    let icon: String
    let title: String
    let description: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(isSelected ? .white : .orange)
                    .frame(width: 50, height: 50)
                    .background(isSelected ? Color.orange : Color(.systemGray5))
                    .clipShape(Circle())
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .orange : .secondary)
                    .font(.title2)
            }
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.orange : Color.clear, lineWidth: 2)
            )
        }
    }
}

#Preview {
    NavigationStack {
        CreateWalletView()
            .environmentObject(AuthenticationManager.shared)
    }
}
