//
//  AttestationActivityManager.swift
//  Sur
//
//  Starts a Live Activity when an attestation submission begins and
//  updates/ends it as the result comes in. Best-effort only — Live
//  Activities can be unavailable (Low Power Mode, user disabled them in
//  Settings, pre-16.1) and that must never block or fail the actual
//  attestation submission, which is why every entry point here is silent
//  on failure.
//

import ActivityKit
import Foundation

@MainActor
final class AttestationActivityManager {
    static let shared = AttestationActivityManager()
    private init() {}

    private var activities: [String: Activity<AttestationActivityAttributes>] = [:]

    func start(id: String, kindLabel: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activities[id] == nil else { return }
        let attributes = AttestationActivityAttributes(kindLabel: kindLabel)
        let state = AttestationActivityAttributes.ContentState(status: .submitting, detail: "Signing and broadcasting…")
        do {
            let activity = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
            activities[id] = activity
        } catch {
            // Live Activities are a nice-to-have progress indicator, not a
            // dependency of the attestation flow — swallow and move on.
        }
    }

    func end(id: String, status: AttestationLiveStatus, detail: String) async {
        guard let activity = activities[id] else { return }
        let state = AttestationActivityAttributes.ContentState(status: status, detail: detail)
        let dismissAfter: TimeInterval = status == .failed ? 5 : 3
        await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(dismissAfter)))
        activities[id] = nil
    }
}
