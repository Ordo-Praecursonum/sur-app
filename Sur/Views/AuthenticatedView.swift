//
//  AuthenticatedView.swift
//  Sur
//
//  Root view that handles authentication state routing
//

import SwiftUI

/// Root view that routes based on authentication state
struct AuthenticatedView: View {
    
    // MARK: - Properties
    
    @StateObject private var authManager = AuthenticationManager.shared
    
    // MARK: - Body
    
    var body: some View {
        Group {
            switch authManager.state {
            case .unknown:
                // Loading state
                loadingView
                
            case .unauthenticated:
                // No wallet - show welcome/onboarding
                WelcomeView()
                    .environmentObject(authManager)
                
            case .authenticating:
                // Currently authenticating
                loadingView
                
            case .locked:
                // Wallet exists but locked - show lock screen
                LockScreenView()
                    .environmentObject(authManager)
                
            case .authenticated:
                // Fully authenticated - show main app
                AccountView()
                    .environmentObject(authManager)
                
            case .error(let message):
                // Error state
                errorView(message: message)
            }
        }
        .animation(.easeInOut, value: authManager.state)
    }
    
    // MARK: - Loading View
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
    
    // MARK: - Error View
    
    private func errorView(message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            VStack(spacing: 8) {
                Text("Something went wrong")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            Button(action: { authManager.clearError() }) {
                Text("Try Again")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

#Preview {
    AuthenticatedView()
}
