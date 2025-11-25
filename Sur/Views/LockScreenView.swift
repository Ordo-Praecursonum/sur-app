//
//  LockScreenView.swift
//  Sur
//
//  Lock screen view for biometric authentication
//

import SwiftUI

/// Lock screen that appears when wallet needs to be unlocked
struct LockScreenView: View {
    
    // MARK: - Properties
    
    @EnvironmentObject private var authManager: AuthenticationManager
    @State private var isAuthenticating = false
    @State private var showError = false
    @State private var errorMessage: String?
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Lock icon
            Image(systemName: "lock.fill")
                .font(.system(size: 60))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange, .red],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            // Title
            VStack(spacing: 8) {
                Text("Wallet Locked")
                    .font(.title)
                    .fontWeight(.bold)
                
                if let shortAddress = authManager.shortAddress {
                    Text(shortAddress)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Unlock button
            VStack(spacing: 16) {
                Button(action: { authenticate() }) {
                    HStack(spacing: 12) {
                        if isAuthenticating {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Image(systemName: authManager.biometricType.iconName)
                            Text("Unlock with \(authManager.biometricType.displayName)")
                        }
                    }
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
                .disabled(isAuthenticating)
                
                // If biometric fails, show option to use passcode
                if authManager.isBiometricEnabled == false || !authManager.isBiometricAvailable {
                    Button(action: { authenticate() }) {
                        Text("Tap to Unlock")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground))
        .alert("Authentication Failed", isPresented: $showError) {
            Button("Try Again") {
                authenticate()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Please try again")
        }
        .onAppear {
            // Auto-trigger authentication when view appears
            authenticate()
        }
    }
    
    // MARK: - Actions
    
    private func authenticate() {
        guard !isAuthenticating else { return }
        
        isAuthenticating = true
        
        Task {
            do {
                try await authManager.authenticate()
                await MainActor.run {
                    isAuthenticating = false
                }
            } catch {
                await MainActor.run {
                    isAuthenticating = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
}

#Preview {
    LockScreenView()
        .environmentObject(AuthenticationManager.shared)
}
