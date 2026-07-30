//
//  CallsTabView.swift
//  Sur
//
//  Calls tab root — Telegram-style top segmented control: Keypad / Contacts
//  / Recents. Selecting a contact or dialing a number presents
//  CallMethodPicker; picking a method submits the call-initiation
//  attestation (fire-and-forget, doesn't block the handoff) and hands off
//  to Phone/FaceTime/WhatsApp via CallInitiationCoordinator.
//

import SwiftUI

private enum CallsSegment: String, CaseIterable {
    case keypad = "Keypad"
    case contacts = "Contacts"
    case recents = "Recents"
}

private struct PendingCall: Identifiable {
    let id = UUID()
    let displayName: String
    let number: String
}

struct CallsTabView: View {
    @StateObject private var callStore = CallAttestationStore.shared
    @State private var segment: CallsSegment = .contacts
    @State private var pendingCall: PendingCall?

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
                    KeypadView { number in pendingCall = PendingCall(displayName: number, number: number) }
                case .contacts:
                    ContactsListView { contact in
                        guard let number = contact.phoneNumbers.first else { return }
                        pendingCall = PendingCall(displayName: contact.displayName, number: number)
                    }
                case .recents:
                    recentsList
                }
            }
            .navigationTitle("Calls")
            .sheet(item: $pendingCall) { call in
                CallMethodPicker(displayName: call.displayName, rawNumber: call.number) { method in
                    CallInitiationCoordinator.initiateCall(displayName: call.displayName, rawNumber: call.number, method: method)
                    pendingCall = nil
                }
                .presentationDetents([.height(360)])
            }
            .task { await callStore.submitPending() }
        }
    }

    private var recentsList: some View {
        Group {
            if callStore.items.isEmpty {
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
            } else {
                List(callStore.items) { item in
                    CallAttestationRow(item: item) {
                        Task { await callStore.submit(id: item.id) }
                    }
                }
            }
        }
    }
}
