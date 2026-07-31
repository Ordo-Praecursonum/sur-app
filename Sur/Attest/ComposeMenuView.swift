//
//  ComposeMenuView.swift
//  Sur
//
//  The Attest tab's "+" menu: what kind of proof to create. Photo/Video
//  switches to the Sur Cam tab rather than composing inline — the camera is
//  a place in the app (like Snapchat), not a sheet stacked on top of Attest.
//

import SwiftUI

enum ComposeOption {
    case text
    case file
    case voice
    case photo
}

struct ComposeMenuView: View {
    var onSelect: (ComposeOption) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(.systemGray4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 4)

            option(.text, icon: "text.alignleft", title: "Text",
                   subtitle: "Type or paste text to declare or prove")
            Divider().padding(.leading, 60)
            option(.file, icon: "doc.fill", title: "File",
                   subtitle: "Attest a file's fingerprint")
            Divider().padding(.leading, 60)
            option(.voice, icon: "waveform", title: "Voice memo",
                   subtitle: "Record and attest a voice memo")
            Divider().padding(.leading, 60)
            option(.photo, icon: "camera.fill", title: "Photo or video",
                   subtitle: "Open Sur Cam")

            Spacer(minLength: 12)
        }
    }

    private func option(_ opt: ComposeOption, icon: String, title: String, subtitle: String) -> some View {
        Button {
            onSelect(opt)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(Theme.brandOrange)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundColor(.primary)
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
