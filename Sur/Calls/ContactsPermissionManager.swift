//
//  ContactsPermissionManager.swift
//  Sur
//
//  Contacts permission + fetch, read-only (search + list, no create/edit —
//  the brief asked to "load contacts", not manage them).
//

import Contacts

@MainActor
final class ContactsPermissionManager: ObservableObject {
    @Published private(set) var authorizationStatus: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    @Published private(set) var contacts: [SurContact] = []
    @Published private(set) var isLoading = false

    private let store = CNContactStore()

    func requestAccessAndLoad() async {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            await load()
        case .notDetermined:
            _ = try? await store.requestAccess(for: .contacts)
            authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
            if authorizationStatus == .authorized || authorizationStatus == .limited { await load() }
        default:
            authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        }
    }

    private func load() async {
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        isLoading = true
        defer { isLoading = false }
        // Deliberately NOT using CNContactFormatter here: it requires every
        // name-part key (middleName, namePrefix, nickname, phonetic names,
        // …) to have been fetched, or it raises an uncatchable NSException
        // ("unfetched property") — a real crash hit during testing. A plain
        // given+family concatenation covers the vast majority of contacts
        // without needing to fetch/maintain that whole key list.
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var fetched: [SurContact] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !contact.phoneNumbers.isEmpty else { return }
                fetched.append(SurContact(
                    id: contact.identifier,
                    displayName: name,
                    phoneNumbers: contact.phoneNumbers.map { $0.value.stringValue },
                    thumbnail: contact.thumbnailImageData
                ))
            }
        } catch {
            fetched = []
        }
        contacts = fetched.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
