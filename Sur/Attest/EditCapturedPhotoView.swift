//
//  EditCapturedPhotoView.swift
//  Sur
//
//  Post-capture re-edit, reached from an already-attested Sur Cam photo in
//  the Attest feed. This is the ONLY thing that creates a provenance
//  (lineage) edge — picking a filter before the shutter is just part of the
//  original capture. Re-fetches the original bytes from Photos (via the
//  saved PHAsset localIdentifier), applies a new filter, submits a fresh
//  attestation for the edited image, and links old→new via ProvenanceManager.
//

import SwiftUI
import Photos
import CoreImage
import CryptoKit

struct EditCapturedPhotoView: View {
    let original: CapturedMediaAttestation

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
                        Text("Couldn't load the original photo from your library.")
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
        guard let assetId = original.localAssetIdentifier else {
            loadFailed = true
            return
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = assets.firstObject else {
            loadFailed = true
            return
        }
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(
            for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: options
        ) { image, _ in
            Task { @MainActor in
                if let image {
                    self.sourceImage = image
                } else {
                    self.loadFailed = true
                }
            }
        }
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
            _ = await CaptureAttestationCoordinator.attestPhoto(capture, finalImage: finalImage, qrApplied: false)
            try await ProvenanceManager.shared.submitProvenanceNode(
                hashIn: original.contentHash, hashOut: newHash, transformationType: "filter:\(selectedFilter.rawValue)"
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
