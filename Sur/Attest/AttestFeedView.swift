//
//  AttestFeedView.swift
//  Sur
//
//  Attest tab root — a single unified feed of every kind of proof: text
//  declarations (this step), keystroke/keyboard sessions, camera captures,
//  file attestations, voice memos, and call-initiation records (added in
//  later steps). Owns the list + compose flow that used to live in the
//  standalone AttestationsView.
//

import SwiftUI

struct AttestFeedView: View {
    @StateObject private var textStore = TextAttestationStore.shared
    @StateObject private var identity = SurChainIdentityManager.shared
    @State private var showCompose = false

    var body: some View {
        NavigationStack {
            List {
                if identity.registeredUsername == nil {
                    Section {
                        Label("Register this device first (Sur Chain tab) to attest content.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                if textStore.items.isEmpty {
                    Section {
                        Text("No attestations yet. Tap + to attest something.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                ForEach(textStore.items) { item in
                    AttestationRow(item: item) {
                        Task { await textStore.submit(id: item.id) }
                    }
                }
                .onDelete { idx in
                    idx.map { textStore.items[$0].id }.forEach { textStore.remove(id: $0) }
                }
            }
            .navigationTitle("Attest")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCompose = true } label: { Image(systemName: "plus") }
                        .disabled(identity.registeredUsername == nil)
                }
            }
            .sheet(isPresented: $showCompose) {
                ComposeAttestationView { text, origin, citation in
                    textStore.enqueue(text: text, ikiValues: [], humanScore: 0, keystrokeCount: 0,
                                       origin: origin, citation: citation)
                }
            }
            // Background pass: try to land anything still pending/failed.
            .task { await textStore.submitPending() }
        }
    }
}
