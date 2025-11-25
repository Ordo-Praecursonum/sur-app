//
//  WelcomeView.swift
//  Sur
//
//  Initial welcome screen for wallet setup
//

import SwiftUI

/// Welcome view for new users to create or import a wallet
struct WelcomeView: View {
    
    // MARK: - Properties
    
    @EnvironmentObject private var authManager: AuthenticationManager
    @State private var showCreateWallet = false
    @State private var showImportWallet = false
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                
                // Logo and title
                VStack(spacing: 24) {
                    Image(systemName: "wallet.pass")
                        .font(.system(size: 80))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.orange, .red],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    VStack(spacing: 8) {
                        Text("Sur Wallet")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text("Secure Ethereum wallet")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.bottom, 60)
                
                Spacer()
                
                // Action buttons
                VStack(spacing: 16) {
                    Button(action: { showCreateWallet = true }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Create New Wallet")
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
                    
                    Button(action: { showImportWallet = true }) {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Import Existing Wallet")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray6))
                        .foregroundColor(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
                
                // Security note
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundColor(.green)
                    Text("Your keys are stored securely on this device")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 24)
            }
            .background(Color(.systemBackground))
            .navigationDestination(isPresented: $showCreateWallet) {
                CreateWalletView()
                    .environmentObject(authManager)
            }
            .navigationDestination(isPresented: $showImportWallet) {
                ImportWalletView()
                    .environmentObject(authManager)
            }
        }
    }
}

#Preview {
    WelcomeView()
        .environmentObject(AuthenticationManager.shared)
}
