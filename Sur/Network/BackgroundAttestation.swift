//
//  BackgroundAttestation.swift
//  Sur
//
//  Lets pending attestations finish without the app being actively used:
//    • a short UIKit background-task window when the app is backgrounded
//      (flushes the handful of pending proofs immediately), and
//    • a low-priority BGProcessingTask iOS runs opportunistically later
//      (the fallback for anything that didn't finish, e.g. no network then).
//
//  Proving itself runs off the main thread at .utility QoS (see
//  SurChainIdentityManager.proveAndSubmitText), so this stays light.
//

import Foundation
import BackgroundTasks
import UIKit
import os

enum BackgroundAttestation {

    /// Must match the Info.plist BGTaskSchedulerPermittedIdentifiers entry.
    static let taskID = "com.ordo.sur.attest.flush"

    private static let log = Logger(subsystem: "com.ordo.sur.chain", category: "background")

    /// Register the BGProcessingTask handler. Call once during app launch (before
    /// launch finishes), i.e. from the App initializer.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            handle(task as! BGProcessingTask)
        }
    }

    /// Ask iOS to run a low-priority processing task later. Opportunistic — the
    /// system decides when (typically while idle / charging), and won't require
    /// external power so it can still run on battery.
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            log.notice("scheduled background attestation flush")
        } catch {
            // Common in the Simulator / when the entitlement isn't present — harmless.
            log.error("could not schedule BG task: \(String(describing: error), privacy: .public)")
        }
    }

    private static func handle(_ task: BGProcessingTask) {
        schedule() // keep the chain going for next time
        let work = Task(priority: .utility) {
            await TextAttestationStore.shared.submitPending()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Flush pending attestations now, holding a short background-task window so
    /// the work can finish after the app is backgrounded. Light and bounded.
    @MainActor
    static func flushOnBackground() {
        var bgID: UIBackgroundTaskIdentifier = .invalid
        bgID = UIApplication.shared.beginBackgroundTask(withName: "sur.attest.flush") {
            if bgID != .invalid { UIApplication.shared.endBackgroundTask(bgID); bgID = .invalid }
        }
        guard bgID != .invalid else { return }
        Task(priority: .utility) {
            await TextAttestationStore.shared.submitPending()
            await MainActor.run {
                if bgID != .invalid { UIApplication.shared.endBackgroundTask(bgID); bgID = .invalid }
            }
        }
    }
}
