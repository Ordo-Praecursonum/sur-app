//
//  SurChainTabView.swift
//  Sur
//
//  Sur Chain tab root — stub for now, fleshed out to compose identity/
//  registration, balance, and Send/Receive (fusing SurChainSettingsView +
//  DeviceRegistrationView) into the wallet/identity operational home.
//

import SwiftUI

struct SurChainTabView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "bitcoinsign.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(Theme.brandOrange)
                Text("Sur Chain")
                    .font(.headline)
            }
            .navigationTitle("Sur Chain")
        }
    }
}
