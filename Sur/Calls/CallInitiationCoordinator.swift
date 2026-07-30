//
//  CallInitiationCoordinator.swift
//  Sur
//
//  Handoff only — no CallKit, no in-app VoIP. Submits the call-initiation
//  attestation (via CallAttestationStore, fire-and-forget) then opens the
//  chosen method's URL scheme. WhatsApp has no public call-intent scheme:
//  wa.me opens the chat, and the user taps the call icon themselves — this
//  must be surfaced honestly in the UI (see CallMethodPicker), not implied
//  as a direct call.
//

import UIKit

@MainActor
enum CallInitiationCoordinator {
    static func initiateCall(displayName: String, rawNumber: String, method: CallMethod) {
        let e164 = PhoneNumberFormatting.e164(from: rawNumber)
        CallAttestationStore.shared.enqueue(calleeDisplayName: displayName, calleeNumberE164: e164, method: method)
        if let url = handoffURL(rawNumber: rawNumber, method: method) {
            UIApplication.shared.open(url)
        }
    }

    static func canOpen(method: CallMethod, rawNumber: String) -> Bool {
        // wa.me is a universal web link — it degrades gracefully to Safari
        // even without WhatsApp installed, so it's always offered.
        if method == .whatsapp { return true }
        guard let url = handoffURL(rawNumber: rawNumber, method: method) else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    private static func handoffURL(rawNumber: String, method: CallMethod) -> URL? {
        let digits = rawNumber.filter { $0.isNumber || $0 == "+" }
        switch method {
        case .phone:
            return URL(string: "tel://\(digits)")
        case .facetimeVideo:
            return URL(string: "facetime://\(digits)")
        case .facetimeAudio:
            return URL(string: "facetime-audio://\(digits)")
        case .whatsapp:
            let waNumber = digits.hasPrefix("+") ? String(digits.dropFirst()) : digits
            return URL(string: "https://wa.me/\(waNumber)")
        }
    }
}
