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
///
/// Rendering mode is `.alwaysTemplate` (not `.alwaysOriginal`) so this icon
/// participates in the same selected/unselected tinting as the other four
/// SF Symbol tabs, via `configureTabBarAppearance()` below — with
/// `.alwaysOriginal` it stayed full-color at all times, which read fine
/// selected but meant it never dimmed to the muted unselected state either.
private let surChainTabIcon: UIImage = {
    let size = CGSize(width: 24, height: 24)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { _ in
        UIImage(named: "AppLogo")?.draw(in: CGRect(origin: .zero, size: size))
    }.withRenderingMode(.alwaysTemplate)
}()

/// The system default unselected tab tint reads as barely visible in dark
/// mode against this app's mostly-black/blurred tab bar backgrounds (Sur Cam
/// in particular is a full-bleed black camera view behind the bar). Setting
/// an explicit, sufficiently light unselected color — plus the matching
/// brand-orange selected color — fixes contrast in both appearances instead
/// of relying on the system's low-contrast default gray.
private func configureTabBarAppearance() {
    let unselectedColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.75, alpha: 1.0)
            : UIColor(white: 0.44, alpha: 1.0)
    }
    let selectedColor = UIColor(Theme.brandOrange)

    let appearance = UITabBarAppearance()
    appearance.configureWithDefaultBackground()
    for itemAppearance in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
        itemAppearance.normal.iconColor = unselectedColor
        itemAppearance.normal.titleTextAttributes = [.foregroundColor: unselectedColor]
        itemAppearance.selected.iconColor = selectedColor
        itemAppearance.selected.titleTextAttributes = [.foregroundColor: selectedColor]
    }

    UITabBar.appearance().standardAppearance = appearance
    UITabBar.appearance().scrollEdgeAppearance = appearance
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
            configureTabBarAppearance()
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
