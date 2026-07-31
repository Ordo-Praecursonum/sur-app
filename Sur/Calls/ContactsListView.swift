//
//  ContactsListView.swift
//  Sur
//
//  Searchable, read-only contacts list. Tapping a contact hands off to
//  CallMethodPicker (wired in the calls-handoff step).
//

import SwiftUI
import Contacts

struct ContactsListView: View {
    @StateObject private var manager = ContactsPermissionManager()
    @State private var searchText = ""
    var onSelect: (SurContact) -> Void

    private var filteredContacts: [SurContact] {
        guard !searchText.isEmpty else { return manager.contacts }
        return manager.contacts.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Group {
            switch manager.authorizationStatus {
            case .authorized, .limited:
                if manager.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if manager.contacts.isEmpty {
                    emptyState(
                        icon: "person.crop.circle",
                        title: "No contacts found",
                        subtitle: "Contacts with a phone number will show up here."
                    )
                } else {
                    List(filteredContacts) { contact in
                        Button {
                            onSelect(contact)
                        } label: {
                            contactRow(contact)
                        }
                        .buttonStyle(.plain)
                    }
                    .searchable(text: $searchText)
                }
            case .denied, .restricted:
                emptyState(
                    icon: "person.crop.circle.badge.exclamationmark",
                    title: "Contacts access is off",
                    subtitle: "Enable contacts access in Settings to call people from Sur.",
                    showSettingsButton: true
                )
            case .notDetermined:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            @unknown default:
                EmptyView()
            }
        }
        .task { await manager.requestAccessAndLoad() }
    }

    private func contactRow(_ contact: SurContact) -> some View {
        HStack(spacing: 12) {
            if let thumbnail = contact.thumbnail, let uiImage = UIImage(data: thumbnail) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Theme.brandOrange.opacity(0.2))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Text(String(contact.displayName.prefix(1)))
                            .font(.headline)
                            .foregroundColor(Theme.brandOrange)
                    )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName).foregroundColor(.primary)
                if let firstNumber = contact.phoneNumbers.first {
                    Text(firstNumber).font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private func emptyState(icon: String, title: String, subtitle: String, showSettingsButton: Bool = false) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(title).font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if showSettingsButton {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .tint(Theme.brandOrange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
