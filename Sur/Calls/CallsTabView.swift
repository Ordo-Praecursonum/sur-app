//
//  CallsTabView.swift
//  Sur
//
//  Calls tab root — Telegram-style top segmented control: Keypad / Contacts
//  / Recents. Selecting a contact or dialing a number currently shows a
//  placeholder; the call-method picker + attestation + handoff land in the
//  next step (CallMethodPicker/CallInitiationCoordinator), and Recents
//  becomes a real list once CallAttestationStore exists.
//

import SwiftUI

private enum CallsSegment: String, CaseIterable {
    case keypad = "Keypad"
    case contacts = "Contacts"
    case recents = "Recents"
}

struct CallsTabView: View {
    @State private var segment: CallsSegment = .contacts
    @State private var pendingCallTarget: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    ForEach(CallsSegment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                switch segment {
                case .keypad:
                    KeypadView { number in pendingCallTarget = number }
                case .contacts:
                    ContactsListView { contact in pendingCallTarget = contact.phoneNumbers.first }
                case .recents:
                    recentsPlaceholder
                }
            }
            .navigationTitle("Calls")
            .alert("Calling", isPresented: Binding(
                get: { pendingCallTarget != nil },
                set: { if !$0 { pendingCallTarget = nil } }
            )) {
                Button("OK") { pendingCallTarget = nil }
            } message: {
                Text("Call handoff + on-chain attestation lands in the next step.")
            }
        }
    }

    private var recentsPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No recent calls yet")
                .font(.headline)
            Text("Calls you initiate from Sur will show up here with their on-chain proof.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
