//
//  GetStartedView.swift
//  Sur
//
//  First-launch tour — stub for now (single screen + dismiss), fleshed out
//  into the full TabView(.page) carousel (Welcome/Sur Cam/Attest/Calls/Sur
//  Chain) in the onboarding step. Also reachable anytime via "Replay Get
//  Started" in Settings.
//

import SwiftUI

struct GetStartedView: View {
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "shield.checkerboard")
                .font(.system(size: 56))
                .foregroundColor(.white)
            Text("Welcome to Sur")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)
            Text("Sur Cam, Attest, Calls, and Sur Chain — a quick tour is coming here.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button("Get Started", action: onFinish)
                .primaryCTA()
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
}
