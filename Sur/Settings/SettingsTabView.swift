//
//  SettingsTabView.swift
//  Sur
//
//  Settings tab root — stub for now, fleshed out as the trimmed remainder of
//  today's AccountView (keyboard settings + full-access directives, wallet
//  security, sharing prefs, about, replay onboarding, lock/delete).
//

import SwiftUI

struct SettingsTabView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 40))
                    .foregroundColor(Theme.brandOrange)
                Text("Settings")
                    .font(.headline)
            }
            .navigationTitle("Settings")
        }
    }
}
