//
//  Theme.swift
//  Sur
//
//  Shared visual constants for the redesigned tab UI (Sur Cam / Attest / Calls /
//  Sur Chain / Settings). Existing pre-redesign screens keep their inline
//  styling as-is; this file is what every new screen in the redesign builds on
//  so the five tabs read as one coherent app from day one.
//

import SwiftUI

enum Theme {
    /// Same RGB values as `BlockchainNetwork.sur.color` — kept as an
    /// independent literal here rather than importing that enum, since this
    /// is a UI constant, not a chain-selection concern.
    static let brandOrange = Color(red: 0.95, green: 0.55, blue: 0.15)

    static let primaryGradient = LinearGradient(
        colors: [.orange, .red],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let cardCornerRadius: CGFloat = 14
    static let secondaryBackground = Color(.systemGray6)

    // Status colors, matching the convention already used consistently across
    // AttestationsView / KeystrokeLogsView / SurChainSettingsView /
    // DeviceRegistrationView: green = success/on-chain, orange = pending,
    // red = failed, gray = neutral/not-yet.
    static let statusSuccess = Color.green
    static let statusPending = Color.orange
    static let statusFailed = Color.red
    static let statusNeutral = Color.secondary
}

/// Primary CTA: gradient background, white text, rounded-14 clip — the same
/// look repeated verbatim across WelcomeView/CreateWalletView/ImportWalletView/
/// LockScreenView/ReceiveSurView. New screens use this modifier instead of
/// re-copying that styling.
struct PrimaryCTAStyle: ViewModifier {
    var isEnabled: Bool = true

    func body(content: Content) -> some View {
        content
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Theme.primaryGradient)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }
}

extension View {
    func primaryCTA(isEnabled: Bool = true) -> some View {
        modifier(PrimaryCTAStyle(isEnabled: isEnabled))
    }

    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}
