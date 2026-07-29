//
//  CallsTabView.swift
//  Sur
//
//  Calls tab root — stub for now, fleshed out into Keypad/Contacts/Recents
//  with call-initiation attestation and Phone/FaceTime/WhatsApp handoff.
//

import SwiftUI

struct CallsTabView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 40))
                    .foregroundColor(Theme.brandOrange)
                Text("Calls")
                    .font(.headline)
            }
            .navigationTitle("Calls")
        }
    }
}
