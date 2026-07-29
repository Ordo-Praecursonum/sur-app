//
//  GetStartedView.swift
//  Sur
//
//  First-launch tour: a swipeable TabView(.page) carousel introducing the
//  5 tabs, shown once via MainTabView's fullScreenCover (gated by
//  UserDefaults.standard key "onboarding.getStarted.shown") and replayable
//  anytime from Settings ("Replay Get Started").
//

import SwiftUI

private struct OnboardingPage: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let body: String
}

private let onboardingPages: [OnboardingPage] = [
    OnboardingPage(
        icon: "shield.checkerboard",
        title: "Welcome to Sur",
        body: "Sur proves what's real — content, calls, and messages — with a record on chain that anyone can check."
    ),
    OnboardingPage(
        icon: "camera.fill",
        title: "Sur Cam",
        body: "Take a photo or video and Sur automatically attests it on chain. Turn on QR to stamp the proof link right onto the photo."
    ),
    OnboardingPage(
        icon: "checkmark.seal.fill",
        title: "Attest",
        body: "Every proof lives here — text, keyboard sessions, camera captures, files, voice memos, and calls, all in one feed."
    ),
    OnboardingPage(
        icon: "phone.fill",
        title: "Calls",
        body: "Call contacts through Phone, FaceTime, or WhatsApp. Sur records an on-chain proof that the call was initiated."
    ),
    OnboardingPage(
        icon: "bitcoinsign.circle.fill",
        title: "Sur Chain",
        body: "Your identity, balance, and network — everything about your presence on the Sur Chain lives here."
    ),
]

struct GetStartedView: View {
    var onFinish: () -> Void

    @State private var pageIndex = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Button("Skip") { onFinish() }
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding()

                TabView(selection: $pageIndex) {
                    ForEach(Array(onboardingPages.enumerated()), id: \.element.id) { index, page in
                        pageView(page)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button(pageIndex == onboardingPages.count - 1 ? "Get Started" : "Next") {
                    if pageIndex == onboardingPages.count - 1 {
                        onFinish()
                    } else {
                        withAnimation { pageIndex += 1 }
                    }
                }
                .primaryCTA()
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
    }

    private func pageView(_ page: OnboardingPage) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: page.icon)
                .font(.system(size: 56))
                .foregroundColor(Theme.brandOrange)
            Text(page.title)
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)
            Text(page.body)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Spacer()
        }
    }
}
