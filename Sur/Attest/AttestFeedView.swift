//
//  AttestFeedView.swift
//  Sur
//
//  Attest tab root — stub for now, fleshed out to fuse TextAttestationStore,
//  KeystrokeLogManager sessions, and the new file/voice/camera/call
//  attestation stores into one chronological feed with filter chips.
//

import SwiftUI

struct AttestFeedView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 40))
                    .foregroundColor(Theme.brandOrange)
                Text("Attest")
                    .font(.headline)
            }
            .navigationTitle("Attest")
        }
    }
}
