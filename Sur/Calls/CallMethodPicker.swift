//
//  CallMethodPicker.swift
//  Sur
//
//  Action sheet for choosing how to place a call. All four methods are
//  always shown — see CallInitiationCoordinator's header comment for why
//  this isn't filtered by canOpenURL anymore (it was unreliably hiding
//  Phone/FaceTime on real devices).
//

import SwiftUI

struct CallMethodPicker: View {
    let displayName: String
    let rawNumber: String
    var onSelect: (CallMethod, String) -> Void

    @State private var citation = ""

    private let allMethods: [CallMethod] = [.phone, .facetimeVideo, .facetimeAudio, .whatsapp]

    private var resolvedCitation: String {
        let trimmed = citation.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? EventDescription.call : trimmed
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(.systemGray4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 8)

            Text(displayName)
                .font(.headline)
            Text(rawNumber)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.bottom, 12)

            TextField(EventDescription.call, text: $citation)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .padding(.horizontal)
                .padding(.bottom, 8)

            ForEach(allMethods, id: \.self) { method in
                Button {
                    onSelect(method, resolvedCitation)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: icon(for: method))
                            .font(.title2)
                            .foregroundColor(Theme.brandOrange)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(method.displayName).foregroundColor(.primary)
                            if method == .whatsapp {
                                Text("Opens chat — tap the call icon in WhatsApp")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if method != allMethods.last {
                    Divider().padding(.leading, 60)
                }
            }

            Spacer(minLength: 12)
        }
    }

    private func icon(for method: CallMethod) -> String {
        switch method {
        case .phone: return "phone.fill"
        case .facetimeVideo: return "video.fill"
        case .facetimeAudio: return "phone.arrow.up.right.fill"
        case .whatsapp: return "message.fill"
        }
    }
}
