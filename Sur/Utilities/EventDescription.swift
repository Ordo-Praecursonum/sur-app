//
//  EventDescription.swift
//  Sur
//
//  Default, human-readable descriptions submitted as each attestation's
//  on-chain `citation` field (see SurChainIdentityManager.submitDeclaration —
//  citation is signed and broadcast, not just local UI copy). Every compose/
//  capture flow shows its default as a TextField placeholder rather than a
//  fixed label, so the user can always type their own description instead —
//  these are just what gets submitted if they don't.
//

enum EventDescription {
    static func placeholder(for origin: AttestationOrigin) -> String {
        switch origin {
        case .humanKeyboard:  return "Text typing"
        case .deviceAuthored: return "Text"
        case .aiGenerated, .externalSource, .imported:
            return "An interaction"
        }
    }

    static let photo = "A photo"
    static let video = "A video"
    static let audio = "An audio"
    static let file = "A file"
    static let call = "A call"
}
