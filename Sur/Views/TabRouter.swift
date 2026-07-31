//
//  TabRouter.swift
//  Sur
//
//  Shared tab-selection state so a child view in one tab (e.g. the Attest
//  tab's compose menu choosing "Photo or Video") can switch MainTabView to
//  another tab (Sur Cam) without threading bindings through every screen.
//

import SwiftUI

@MainActor
final class TabRouter: ObservableObject {
    static let shared = TabRouter()
    @Published var selectedTab: MainTab = .surCam
    private init() {}
}
