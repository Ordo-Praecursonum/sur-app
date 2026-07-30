//
//  PhoneNumberFormatting.swift
//  Sur
//
//  Minimal E.164 normalizer — NOT a full libphonenumber equivalent. Only
//  affects the call-initiation attestation's canonical hash input (so the
//  same callee normalizes the same way regardless of how the number was
//  typed/formatted), never the raw string actually dialed via tel:/facetime:.
//  Naive US-default heuristic: non-US numbers typed without a country code
//  may normalize incorrectly — documented limitation, not a dialing bug.
//

import Foundation

enum PhoneNumberFormatting {
    static func e164(from raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        if raw.trimmingCharacters(in: .whitespaces).hasPrefix("+") {
            return "+\(digits)"
        }
        if digits.count == 10 {
            return "+1\(digits)"
        }
        if digits.count == 11 && digits.hasPrefix("1") {
            return "+\(digits)"
        }
        return "+\(digits)"
    }
}
