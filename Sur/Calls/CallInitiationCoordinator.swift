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
//  All four methods are always offered (no canOpenURL pre-filtering): that
//  gating was hiding Phone/FaceTime entirely on real devices — `tel://`
//  (double-slash "authority" form) is not the canonical scheme Apple
//  documents (`tel:1-408-555-5555`, single colon) and `canOpenURL` doesn't
//  reliably parse it as a valid tel handler on-device, even though it
//  happens to construct a non-nil URL. Fixed to the documented `tel:` form
//  and dropped the gate entirely — exactly like WhatsApp already was, we
//  let iOS itself no-op or show its own error if a method genuinely isn't
//  available, rather than risk hiding options a user expects to see.
//

import UIKit

@MainActor
enum CallInitiationCoordinator {
    static func initiateCall(displayName: String, rawNumber: String, method: CallMethod,
                              citation: String = EventDescription.call) {
        let e164 = PhoneNumberFormatting.e164(from: rawNumber)
        CallAttestationStore.shared.enqueue(calleeDisplayName: displayName, calleeNumberE164: e164,
                                             method: method, citation: citation)
        if let url = handoffURL(rawNumber: rawNumber, method: method) {
            UIApplication.shared.open(url)
        }
    }

    private static func handoffURL(rawNumber: String, method: CallMethod) -> URL? {
        let digits = rawNumber.filter { $0.isNumber || $0 == "+" }
        switch method {
        case .phone:
            // Apple's documented tel: format is single-colon, no slashes —
            // `tel://` is the authority form and isn't reliably recognized.
            return URL(string: "tel:\(digits)")
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
