//
//  AccountView.swift
//  Sur
//
//  Formerly the single settings-list root screen. Superseded by MainTabView's
//  5-tab layout (Sur Cam / Attest / Calls / Sur Chain / Settings) — its
//  content now lives in SurChainTabView and SettingsTabView. What's left
//  here is RecoveryPhraseSheet, still used by SettingsTabView.
//

import SwiftUI

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
                        Pasteboard.copy(phrase)
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
