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
import UIKit

enum MainTab: Hashable {
    case surCam
    case attest
    case calls
    case surChain
    case settings
}

/// SwiftUI's `.resizable().frame()` on a custom asset `Image` isn't reliably
/// honored once bridged into `UITabBarItem.image` — the AppLogo asset only
/// has its 1x slot filled (2x/3x are declared but unassigned in
/// Contents.json), and the tab bar item rendered that source at native
/// (huge) size instead of the requested frame, blowing out the whole tab
/// bar's layout. Pre-rendering a fixed-size bitmap once, up front, sidesteps
/// that asset-scale/SwiftUI-tabItem-bridging quirk entirely.
private let surChainTabIcon: UIImage = {
    let size = CGSize(width: 24, height: 24)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { _ in
        UIImage(named: "AppLogo")?.draw(in: CGRect(origin: .zero, size: size))
    }.withRenderingMode(.alwaysOriginal)
}()

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
                .tabItem {
                    Label {
                        Text("Sur Chain")
                    } icon: {
                        Image(uiImage: surChainTabIcon)
                    }
                }
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
