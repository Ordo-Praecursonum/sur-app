//
//  SurChainTabView.swift
//  Sur
//
//  Sur Chain tab root — thin composition wrapping the existing
//  SurChainSettingsView (identity/registration, sharing, balance,
//  network) in its own NavigationStack. SurChainSettingsView already
//  presents DeviceRegistrationView/SendSurView/ReceiveSurView as sheets,
//  so no further re-parenting is needed; this file's only job is to give
//  that content its own tab-root navigation stack instead of being reached
//  through the old AccountView list.
//

import SwiftUI

struct SurChainTabView: View {
    var body: some View {
        NavigationStack {
            SurChainSettingsView()
        }
    }
}
