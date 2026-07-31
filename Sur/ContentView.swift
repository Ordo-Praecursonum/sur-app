//
//  ContentView.swift
//  Sur
//
//  Created by Mathe Eliel on 04/10/2025.
//

import SwiftUI

// MARK: - Settings Manager (Shared with Keyboard Extension)
class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let hapticFeedbackKey = "hapticFeedbackEnabled"
    /// Mirrors SurKeyboard/KeyboardTutorialOverlay's "Don't show this again"
    /// checkbox. The overlay can only set this to true (it disappears once
    /// dismissed, so it can't offer an "uncheck" control itself) — unchecking
    /// happens here, via the "Show keyboard tutorial again" toggle in Settings.
    private let keyboardTutorialDismissedKey = "keyboard.tutorial.dismissed"
    private let surCamLogoWatermarkKey = "surcam.logoWatermarkEnabled"

    @Published var isHapticFeedbackEnabled: Bool {
        didSet {
            if let sharedDefaults = UserDefaults(suiteName: "group.com.ordo.sure.Sur") {
                sharedDefaults.set(isHapticFeedbackEnabled, forKey: hapticFeedbackKey)
            }
        }
    }

    /// The QR-code proof sticker is always applied to Sur Cam photos — it's
    /// how a photo's on-chain proof travels with the image itself, so it
    /// isn't user-toggleable. The Sur logo watermark is purely cosmetic
    /// branding, so unlike the QR sticker it CAN be turned off here.
    @Published var surCamLogoWatermarkEnabled: Bool {
        didSet {
            if let sharedDefaults = UserDefaults(suiteName: "group.com.ordo.sure.Sur") {
                sharedDefaults.set(surCamLogoWatermarkEnabled, forKey: surCamLogoWatermarkKey)
            }
        }
    }

    @Published var keyboardTutorialDismissed: Bool {
        didSet {
            if let sharedDefaults = UserDefaults(suiteName: "group.com.ordo.sure.Sur") {
                sharedDefaults.set(keyboardTutorialDismissed, forKey: keyboardTutorialDismissedKey)
            }
        }
    }

    /// Whether the keyboard extension has ever confirmed it has "Allow Full
    /// Access" — set by SurKeyboard/KeyboardViewController.swift on launch
    /// (see its `fullAccessKey`). Without it, keystroke sessions/proof links
    /// can't be written to/read from the shared container. Best-effort,
    /// write-once-true flag: it can confirm access was granted, but can't
    /// detect it being revoked later (the keyboard only observes its own
    /// `hasFullAccess` while it's running).
    var hasConfirmedFullAccess: Bool {
        UserDefaults(suiteName: "group.com.ordo.sure.Sur")?.bool(forKey: "keyboard.hasFullAccess") ?? false
    }

    init() {
        let sharedDefaults = UserDefaults(suiteName: "group.com.ordo.sure.Sur")
        self.isHapticFeedbackEnabled = sharedDefaults?.object(forKey: hapticFeedbackKey) as? Bool ?? true
        self.keyboardTutorialDismissed = sharedDefaults?.object(forKey: keyboardTutorialDismissedKey) as? Bool ?? false
        self.surCamLogoWatermarkEnabled = sharedDefaults?.object(forKey: surCamLogoWatermarkKey) as? Bool ?? true
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var settings = AppSettings.shared
    @State private var testText = ""
    
    var body: some View {
        NavigationStack {
            List {
                // MARK: - Setup Section
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
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Getting Started")
                }
                
                // MARK: - Settings Section
                Section {
                    Toggle(isOn: $settings.isHapticFeedbackEnabled) {
                        Label("Haptic Feedback", systemImage: "hand.tap")
                    }
                } header: {
                    Text("Keyboard Settings")
                } footer: {
                    Text("When enabled, you'll feel a gentle vibration when pressing keys.")
                }
                
                // MARK: - Test Keyboard Section
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Test your keyboard here:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        TextField("Type something...", text: $testText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...6)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Test Keyboard")
                }
                
                // MARK: - Keystroke Logs Section
                Section {
                    NavigationLink(destination: KeystrokeLogsView()) {
                        Label("Keystroke Logs", systemImage: "list.bullet.rectangle")
                    }
                } header: {
                    Text("Data Provenance")
                } footer: {
                    Text("View your keystroke logs with cryptographic proofs that verify human-generated content.")
                }
                
                // MARK: - About Section
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
            }
            .navigationTitle("Sur Keyboard")
        }
    }
    
    private func openKeyboardSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Setup Step View
struct SetupStepView: View {
    let number: Int
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            
            Text(text)
                .font(.subheadline)
        }
    }
}

#Preview {
    ContentView()
}
