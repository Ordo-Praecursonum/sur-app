//
//  CallMethodPicker.swift
//  Sur
//
//  Action sheet for choosing how to place a call — filtered by
//  CallInitiationCoordinator.canOpen so a method with no handler (e.g. no
//  FaceTime on this Apple ID) never shows a dead button.
//

import SwiftUI

struct CallMethodPicker: View {
    let displayName: String
    let rawNumber: String
    var onSelect: (CallMethod) -> Void

    private let allMethods: [CallMethod] = [.phone, .facetimeVideo, .facetimeAudio, .whatsapp]

    private var availableMethods: [CallMethod] {
        allMethods.filter { CallInitiationCoordinator.canOpen(method: $0, rawNumber: rawNumber) }
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

            if availableMethods.isEmpty {
                Text("No call method is available for this number.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding()
            }

            ForEach(availableMethods, id: \.self) { method in
                Button {
                    onSelect(method)
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
                if method != availableMethods.last {
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
