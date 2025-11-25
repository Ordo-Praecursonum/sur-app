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
    
    @Published var isHapticFeedbackEnabled: Bool {
        didSet {
            if let sharedDefaults = UserDefaults(suiteName: "group.com.ordo.sure.Sur") {
                sharedDefaults.set(isHapticFeedbackEnabled, forKey: hapticFeedbackKey)
            }
        }
    }
    
    init() {
        if let sharedDefaults = UserDefaults(suiteName: "group.com.ordo.sure.Sur") {
            self.isHapticFeedbackEnabled = sharedDefaults.object(forKey: hapticFeedbackKey) as? Bool ?? true
        } else {
            self.isHapticFeedbackEnabled = true
        }
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
