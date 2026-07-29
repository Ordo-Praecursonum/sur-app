//
//  ProofLink.swift
//  Sur
//
//  App-side mirror of SurKeyboard/KeyboardViewController.proofLink(forContentHash:).
//  Duplicated rather than shared: the app and keyboard-extension targets share
//  no Swift module (only the prebuilt surcorelibs.xcframework binary), so
//  this ~15-line helper is small enough to keep in sync by hand rather than
//  introduce a new shared framework for one function.
//

import Foundation

enum ProofLink {
    private static let appGroupID = "group.com.ordo.sure.Sur"
    private static let verifierBaseURLWithoutDevice = "https://surprotocol.org/v"
    private static let verifierBaseURLWithDevice = "https://surprotocol.org/vd"
    private static let includeDeviceIDKey = "sur.share.includeDeviceIDInLinks"
    private static let deviceIDKey = "sur.identity.username.v1"

    /// Builds the shareable proof link for a content hash, honoring the
    /// "include device id" setting from SurChainSettingsView's sharing toggle.
    static func build(contentHash: Data) -> URL {
        let hex = contentHash.map { String(format: "%02x", $0) }.joined()
        if let defaults = UserDefaults(suiteName: appGroupID),
           defaults.bool(forKey: includeDeviceIDKey),
           let deviceID = defaults.string(forKey: deviceIDKey), !deviceID.isEmpty {
            return URL(string: "\(verifierBaseURLWithDevice)?p=\(hex)&d=\(deviceID)")!
        }
        return URL(string: "\(verifierBaseURLWithoutDevice)?p=\(hex)")!
    }
}
