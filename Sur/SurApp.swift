//
//  SurApp.swift
//  Sur
//
//  Created by Mathe Eliel on 04/10/2025.
//

import SwiftUI

@main
struct SurApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Register the background-processing handler before launch finishes.
        BackgroundAttestation.register()
    }

    var body: some Scene {
        WindowGroup {
            AuthenticatedView()
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        // Finish pending attestations in a short background window,
                        // and schedule a low-priority task for anything left over.
                        BackgroundAttestation.flushOnBackground()
                        BackgroundAttestation.schedule()
                    }
                }
        }
    }
}
