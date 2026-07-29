//
//  KeyboardDirectivesView.swift
//  Sur
//
//  The "menu with directives" shown when Sur Keyboard's Full Access isn't
//  enabled yet. Reuses the existing SetupStepView row (ContentView.swift)
//  rather than rewriting it, and adds a direct deep link into Settings.
//

import SwiftUI

struct KeyboardDirectivesView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: settings.hasConfirmedFullAccess ? "checkmark.seal.fill" : "exclamationmark.shield.fill")
                            .foregroundColor(settings.hasConfirmedFullAccess ? Theme.statusSuccess : Theme.statusPending)
                        Text(settings.hasConfirmedFullAccess ? "Full Access is enabled" : "Full Access isn't enabled")
                            .font(.headline)
                    }
                    Text("Sur Keyboard needs Full Access to save keystroke proofs and share proof links. Without it, typing still works, but nothing gets attested.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    SetupStepView(number: 1, text: "Open Settings")
                    SetupStepView(number: 2, text: "Go to General → Keyboard → Keyboards")
                    SetupStepView(number: 3, text: "Make sure \"Sur\" is added, then tap it")
                    SetupStepView(number: 4, text: "Turn on \"Allow Full Access\"")
                }
                .padding(.vertical, 4)

                Button(action: openSettings) {
                    Label("Open Keyboard Settings", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brandOrange)
            } header: {
                Text("Steps")
            }
        }
        .navigationTitle("Keyboard Setup")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
