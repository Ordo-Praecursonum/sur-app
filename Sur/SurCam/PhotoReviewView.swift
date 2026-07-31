//
//  PhotoReviewView.swift
//  Sur
//
//  Pre-attestation review shown right after a Sur Cam photo is captured.
//  The raw, orientation-corrected capture is shown here — filters are
//  applied live against this static image so the user can actually see the
//  result before committing (the live camera preview itself stays
//  unfiltered — see SurCamFilter's header comment).
//
//  "Use Photo" hands the chosen filter straight back to SurCamView and
//  dismisses immediately — the actual full-res render, hashing, Photos
//  save, and chain submission all happen afterwards in the background, so
//  the user is back at a live camera instantly and can keep shooting.
//

import CoreImage
import SwiftUI

struct PhotoReviewView: View {
    let orientedImage: CIImage
    var onRetake: () -> Void
    var onUsePhoto: (SurCamFilter, String) -> Void

    @State private var selectedFilter: SurCamFilter = .none
    @State private var citation = ""
    @State private var previewImage: UIImage?
    @State private var previewSourceImage: CIImage?

    private var resolvedCitation: String {
        let trimmed = citation.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? EventDescription.photo : trimmed
    }

    private static let context = CIContext()
    /// Filter switching re-renders on every tap — capping the working size
    /// keeps that snappy even on a 48MP capture. The final "Use Photo"
    /// render always uses the full-resolution `orientedImage`.
    private static let previewMaxDimension: CGFloat = 1200

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                Spacer()
                descriptionField
                filterCarousel
                actionButtons
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onRetake) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundColor(.white)
                    .shadow(radius: 4)
            }
            .padding()
        }
        .onAppear {
            previewSourceImage = Self.downscaled(orientedImage, maxDimension: Self.previewMaxDimension)
            renderPreview()
        }
        .onChange(of: selectedFilter) { _, _ in renderPreview() }
    }

    private var descriptionField: some View {
        TextField("", text: $citation, prompt: Text(EventDescription.photo).foregroundColor(.white.opacity(0.5)))
            .foregroundColor(.white)
            .tint(.white)
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.black.opacity(0.45))
            .clipShape(Capsule())
            .padding(.horizontal)
            .padding(.bottom, 10)
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
                            .fontWeight(selectedFilter == filter ? .semibold : .regular)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedFilter == filter ? Theme.brandOrange : .black.opacity(0.35))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 12)
    }

    private var actionButtons: some View {
        HStack(spacing: 32) {
            Button(action: onRetake) {
                Label("Retake", systemImage: "arrow.counterclockwise")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.black.opacity(0.45))
                    .clipShape(Capsule())
            }

            Button {
                onUsePhoto(selectedFilter, resolvedCitation)
            } label: {
                Label("Use Photo", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.white)
                    .clipShape(Capsule())
            }
            .disabled(previewImage == nil)
        }
        .padding(.bottom, 28)
    }

    private func renderPreview() {
        guard let previewSourceImage else { return }
        let filtered = selectedFilter.apply(to: previewSourceImage)
        guard let cgImage = Self.context.createCGImage(filtered, from: previewSourceImage.extent) else { return }
        previewImage = UIImage(cgImage: cgImage)
    }

    private static func downscaled(_ image: CIImage, maxDimension: CGFloat) -> CIImage {
        let extent = image.extent
        let scale = min(1, maxDimension / max(extent.width, extent.height))
        guard scale < 1 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}
