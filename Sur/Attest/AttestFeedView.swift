//
//  AttestFeedView.swift
//  Sur
//
//  Attest tab root — a single unified feed of every kind of proof: text
//  declarations, keystroke/keyboard sessions, file attestations (this step),
//  camera captures, voice memos, and call-initiation records (added in later
//  steps). Owns the list + compose flow that used to live in the standalone
//  AttestationsView.
//
//  AttestFeedItem wraps each source's own model rather than retrofitting a
//  shared protocol onto them — KeystrokeSession in particular is left
//  completely untouched, reusing its existing SessionRowView/SessionDetailView
//  as-is.
//

import SwiftUI

enum FeedFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case text = "Text"
    case keyboard = "Keyboard"
    case camera = "Camera"
    case file = "File"
    case voice = "Voice"
    var id: String { rawValue }
}

enum AttestFeedItem: Identifiable {
    case text(AttestationItem)
    case keystroke(KeystrokeSession)
    case media(CapturedMediaAttestation)
    case file(FileAttestation)
    case voice(VoiceAttestation)

    var id: String {
        switch self {
        case .text(let item): return item.id.uuidString
        case .keystroke(let session): return session.sessionId
        case .media(let item): return item.id.uuidString
        case .file(let item): return item.id.uuidString
        case .voice(let item): return item.id.uuidString
        }
    }

    var feedDate: Date {
        switch self {
        case .text(let item): return item.createdAt
        case .keystroke(let session): return Date(timeIntervalSince1970: Double(session.startTimestamp) / 1000)
        case .media(let item): return item.createdAt
        case .file(let item): return item.createdAt
        case .voice(let item): return item.createdAt
        }
    }

    var filter: FeedFilter {
        switch self {
        case .text: return .text
        case .keystroke: return .keyboard
        case .media: return .camera
        case .file: return .file
        case .voice: return .voice
        }
    }
}

struct AttestFeedView: View {
    @StateObject private var textStore = TextAttestationStore.shared
    @StateObject private var mediaStore = CapturedMediaAttestationStore.shared
    @StateObject private var fileStore = FileAttestationStore.shared
    @StateObject private var voiceStore = VoiceAttestationStore.shared
    @StateObject private var identity = SurChainIdentityManager.shared
    @ObservedObject private var tabRouter = TabRouter.shared

    @State private var showComposeMenu = false
    @State private var showTextCompose = false
    @State private var showFileCompose = false
    @State private var showVoiceRecorder = false
    @State private var keystrokeSessions: [KeystrokeSession] = []
    @State private var selectedSession: KeystrokeSession?
    @State private var selectedFilter: FeedFilter = .all

    private var feedItems: [AttestFeedItem] {
        let items: [AttestFeedItem] =
            textStore.items.map { .text($0) }
            + keystrokeSessions.map { .keystroke($0) }
            + mediaStore.items.map { .media($0) }
            + fileStore.items.map { .file($0) }
            + voiceStore.items.map { .voice($0) }
        return items
            .filter { selectedFilter == .all || $0.filter == selectedFilter }
            .sorted { $0.feedDate > $1.feedDate }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterChips

                List {
                    if identity.registeredUsername == nil {
                        Section {
                            Label("Register this device first (Sur Chain tab) to attest content.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    if feedItems.isEmpty {
                        Section {
                            Text("No attestations yet. Tap + to attest something.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    ForEach(feedItems) { item in
                        row(for: item)
                    }
                }
            }
            .navigationTitle("Attest")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showComposeMenu = true } label: { Image(systemName: "plus") }
                        .disabled(identity.registeredUsername == nil)
                }
            }
            .sheet(isPresented: $showComposeMenu) {
                ComposeMenuView { option in
                    showComposeMenu = false
                    switch option {
                    case .text: showTextCompose = true
                    case .file: showFileCompose = true
                    case .voice: showVoiceRecorder = true
                    case .photo: tabRouter.selectedTab = .surCam
                    }
                }
                .presentationDetents([.height(340)])
            }
            .sheet(isPresented: $showTextCompose) {
                ComposeAttestationView { text, origin, citation in
                    textStore.enqueue(text: text, ikiValues: [], humanScore: 0, keystrokeCount: 0,
                                       origin: origin, citation: citation)
                }
            }
            .sheet(isPresented: $showFileCompose) {
                FileAttestationView()
            }
            .sheet(isPresented: $showVoiceRecorder) {
                VoiceRecorderView()
            }
            .sheet(item: $selectedSession) { session in
                SessionDetailView(session: session)
            }
            .onAppear { loadKeystrokeSessions() }
            // Background pass: try to land anything still pending/failed.
            .task {
                await textStore.submitPending()
                await mediaStore.submitPending()
                await fileStore.submitPending()
                await voiceStore.submitPending()
                textStore.autoAttest(sessions: keystrokeSessions)
            }
        }
    }

    @ViewBuilder
    private func row(for item: AttestFeedItem) -> some View {
        switch item {
        case .text(let attestation):
            AttestationRow(item: attestation) {
                Task { await textStore.submit(id: attestation.id) }
            }
        case .keystroke(let session):
            SessionRowView(session: session, attestStore: textStore)
                .contentShape(Rectangle())
                .onTapGesture { selectedSession = session }
        case .media(let attestation):
            CapturedMediaAttestationRow(item: attestation) {
                Task { await mediaStore.submit(id: attestation.id) }
            }
        case .file(let attestation):
            FileAttestationRow(item: attestation) {
                Task { await fileStore.submit(id: attestation.id) }
            }
        case .voice(let attestation):
            VoiceAttestationRow(item: attestation) {
                Task { await voiceStore.submit(id: attestation.id) }
            }
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FeedFilter.allCases) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(.subheadline)
                            .fontWeight(selectedFilter == filter ? .semibold : .regular)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(selectedFilter == filter ? Theme.brandOrange.opacity(0.15) : Theme.secondaryBackground)
                            .foregroundColor(selectedFilter == filter ? Theme.brandOrange : .primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func loadKeystrokeSessions() {
        keystrokeSessions = KeystrokeLogManager.shared.loadAllSessions()
    }
}

extension KeystrokeSession: Identifiable {
    public var id: String { sessionId }
}
