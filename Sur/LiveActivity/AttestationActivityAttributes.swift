//
//  AttestationActivityAttributes.swift
//  Sur
//
//  Shared between the app (starts/updates/ends the activity from
//  AttestationActivityManager) and the SurLiveActivity widget extension
//  (renders it in the Dynamic Island / Lock Screen). Kept intentionally
//  minimal — just enough to show submission progress.
//

import ActivityKit
import Foundation

struct AttestationActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var status: AttestationLiveStatus
        var detail: String
    }

    /// e.g. "Sur Cam photo", "Text attestation", "Call to Jane" — fixed for
    /// the activity's lifetime, unlike ContentState which changes as the
    /// submission progresses.
    var kindLabel: String
}

enum AttestationLiveStatus: String, Codable, Hashable {
    case submitting
    case submitted
    case failed
}
