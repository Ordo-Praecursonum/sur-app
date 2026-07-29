//
//  SettingsTabView.swift
//  Sur
//
//  Settings tab root — the trimmed remainder of the old AccountView after
//  identity/balance/network (now the Sur Chain tab) and attestations/
//  keystroke logs (now the Attest tab) moved out. What's left is genuine
//  device/app configuration: keyboard setup + full-access directives,
//  wallet security, sharing/tutorial toggles, about, replay onboarding,
//  lock/delete.
//

import SwiftUI

struct SettingsTabView: View {
    @EnvironmentObject private var authManager: AuthenticationManager
    @ObservedObject private var settings = AppSettings.shared

    @State private var showRecoveryPhrase = false
    @State private var showDeleteConfirmation = false
    @State private var showGetStartedReplay = false
    @State private var recoveryPhrase: String?
    @State private var isLoadingPhrase = false
    @State private var showError = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if !settings.hasConfirmedFullAccess {
                    Section {
                        NavigationLink {
                            KeyboardDirectivesView()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .font(.title3)
                                    .foregroundColor(Theme.statusPending)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Keyboard: Full Access not enabled")
                                        .font(.subheadline).fontWeight(.semibold)
                                    Text("Tap for setup steps")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section {
                    NavigationLink {
                        KeyboardDirectivesView()
                    } label: {
                        Label("Keyboard Setup", systemImage: "keyboard")
                    }
                    Toggle(isOn: $settings.isHapticFeedbackEnabled) {
                        Label("Haptic Feedback", systemImage: "hand.tap")
                    }
                    .tint(Theme.brandOrange)
                    Toggle(isOn: Binding(
                        get: { !settings.keyboardTutorialDismissed },
                        set: { settings.keyboardTutorialDismissed = !$0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show keyboard tutorial again")
                            Text("The explainer the keyboard shows the first time you open it.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tint(Theme.brandOrange)
                } header: {
                    Text("Keyboard")
                }

                Section {
                    HStack {
                        Label("Security", systemImage: "lock.shield")
                        Spacer()
                        Text(authManager.isBiometricEnabled ? authManager.biometricType.displayName : "None")
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

                Section {
                    Button {
                        showGetStartedReplay = true
                    } label: {
                        Label("Replay Get Started", systemImage: "sparkles")
                    }
                } header: {
                    Text("Tour")
                }

                Section {
                    HStack {
                        Label("Version", systemImage: "info.circle")
                        Spacer()
                        Text("1.0.0").foregroundColor(.secondary)
                    }
                } header: {
                    Text("About")
                }

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
            .navigationTitle("Settings")
            .tint(Theme.brandOrange)
            .sheet(isPresented: $showRecoveryPhrase) {
                RecoveryPhraseSheet(
                    isPresented: $showRecoveryPhrase,
                    recoveryPhrase: $recoveryPhrase,
                    isLoading: $isLoadingPhrase,
                    loadPhrase: loadRecoveryPhrase
                )
            }
            .fullScreenCover(isPresented: $showGetStartedReplay) {
                GetStartedView { showGetStartedReplay = false }
            }
            .alert("Delete Wallet", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    authManager.signOut(deleteWallet: true)
                }
            } message: {
                Text("Are you sure you want to delete your wallet? This action cannot be undone. Make sure you have backed up your recovery phrase.")
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "An error occurred")
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
}
