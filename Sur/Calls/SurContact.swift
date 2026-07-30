//
//  SurContact.swift
//  Sur
//
//  Small value type decoupled from CNContact so the rest of the Calls UI
//  doesn't depend on the Contacts framework directly.
//

import Foundation

struct SurContact: Identifiable, Equatable {
    let id: String
    let displayName: String
    let phoneNumbers: [String]
    let thumbnail: Data?
}
