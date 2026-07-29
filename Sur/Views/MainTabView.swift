//
//  MainTabView.swift
//  Sur
//
//  The authenticated app's root: a 5-tab bottom bar (Telegram-style — shallow,
//  independently-navigable tabs rather than one deep settings tree), with
//  Sur Cam as the default/home tab (Snapchat-style: camera is the app's
//  front door). Also owns first-launch presentation of GetStartedView.
//
//  Each tab body below is filled in incrementally as its feature lands
//  (Sur Chain, Settings, Attest, Sur Cam, Calls) — this file's job is just
//  the tab shell and the onboarding gate.
//

import SwiftUI

enum MainTab: Hashable {
    case surCam
    case attest
    case calls
    case surChain
    case settings
}

struct MainTabView: View {
    @StateObject private var router = TabRouter.shared
    @State private var showGetStarted = false

    private static let getStartedShownKey = "onboarding.getStarted.shown"

    var body: some View {
        TabView(selection: $router.selectedTab) {
            SurCamView()
                .tabItem { Label("Sur Cam", systemImage: "camera.fill") }
                .tag(MainTab.surCam)

            AttestFeedView()
                .tabItem { Label("Attest", systemImage: "checkmark.seal.fill") }
                .tag(MainTab.attest)

            CallsTabView()
                .tabItem { Label("Calls", systemImage: "phone.fill") }
                .tag(MainTab.calls)

            SurChainTabView()
                .tabItem { Label("Sur Chain", systemImage: "bitcoinsign.circle.fill") }
                .tag(MainTab.surChain)

            SettingsTabView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(MainTab.settings)
        }
        .tint(Theme.brandOrange)
        .onAppear {
            if !UserDefaults.standard.bool(forKey: Self.getStartedShownKey) {
                showGetStarted = true
            }
        }
        .fullScreenCover(isPresented: $showGetStarted) {
            GetStartedView {
                UserDefaults.standard.set(true, forKey: Self.getStartedShownKey)
                showGetStarted = false
            }
        }
    }
}
