//
//  EditCapturedPhotoView.swift
//  Sur
//
//  Post-capture re-edit, reached from an already-attested Sur Cam photo in
//  the Attest feed. This is the ONLY thing that creates a provenance
//  (lineage) edge — picking a filter in PhotoReviewView right after the
//  shutter is just part of the original capture. Re-fetches the original
//  bytes from CapturedImageCache (this app's own sandboxed copy, NOT the
//  Photos library — PHAsset/PHImageManager reads require
//  NSPhotoLibraryUsageDescription, which this app deliberately doesn't
//  declare since it only ever does add-only Photos saves; calling those
//  APIs without it is an instant crash, which is exactly what used to
//  happen when this screen opened), applies a new filter, submits a fresh
//  attestation for the edited image, and links old→new via ProvenanceManager.
//

import SwiftUI
import CoreImage
import CryptoKit

struct EditCapturedPhotoView: View {
    let original: CapturedMediaAttestation
    /// Called with the newly-created attestation's id right before dismiss,
    /// so a caller showing `original` (e.g. the gallery detail view) can
    /// switch to displaying the edited result in place instead of the user
    /// having to go find it themselves.
    var onSaved: ((UUID) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var sourceImage: UIImage?
    @State private var selectedFilter: SurCamFilter = .none
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Group {
                    if let sourceImage {
                        Image(uiImage: filteredPreview(sourceImage))
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                    } else if loadFailed {
                        Text("Couldn't load the original photo. It may have been captured before this update and can't be re-edited.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ProgressView("Loading photo…")
                    }
                }
                .frame(maxHeight: .infinity)

                filterCarousel

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }

                Button {
                    Task { await submitEdit() }
                } label: {
                    if isSubmitting {
                        ProgressView().tint(.white)
                    } else {
                        Text("Save edit & record lineage")
                    }
                }
                .primaryCTA(isEnabled: canSubmit)
                .disabled(!canSubmit)
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("Edit Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: loadSourceImage)
        }
    }

    private var canSubmit: Bool {
        sourceImage != nil && selectedFilter != .none && !isSubmitting
    }

    private func filteredPreview(_ image: UIImage) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }
        let filtered = selectedFilter.apply(to: ciImage)
        let context = CIContext()
        guard let cg = context.createCGImage(filtered, from: filtered.extent) else { return image }
        return UIImage(cgImage: cg)
    }

    private var filterCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(SurCamFilter.allCases) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text(filter.displayName)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedFilter == filter ? Theme.brandOrange : Theme.secondaryBackground)
                            .foregroundColor(selectedFilter == filter ? .white : .primary)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func loadSourceImage() {
        guard let image = CapturedImageCache.load(id: original.id) else {
            loadFailed = true
            return
        }
        sourceImage = image
    }

    private func submitEdit() async {
        guard let sourceImage, selectedFilter != .none else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let finalImage = filteredPreview(sourceImage)
            guard let pngData = finalImage.pngData() else {
                throw MediaCaptureProcessor.ProcessingError.renderFailed
            }
            let newHash = Data(SHA256.hash(data: pngData))
            let capture = ProcessedCapture(finalImageForSaving: finalImage, contentHash: newHash, filterApplied: selectedFilter)
            let watermarked = PhotoWatermarkPipeline.apply(
                to: finalImage, contentHash: newHash,
                includeLogoWatermark: AppSettings.shared.surCamLogoWatermarkEnabled
            )
            let newId = await CaptureAttestationCoordinator.attestPhoto(
                capture, finalImage: watermarked, qrApplied: true, citation: "\(original.citation) — edited"
            )
            try await ProvenanceManager.shared.submitProvenanceNode(
                hashIn: original.contentHash, hashOut: newHash, transformationType: "filter:\(selectedFilter.rawValue)"
            )
            onSaved?(newId)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
