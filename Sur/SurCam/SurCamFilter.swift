//
//  SurCamFilter.swift
//  Sur
//
//  A small curated filter list — no intensity sliders, no filter chains.
//  Chosen and applied post-capture, against the actual photo, in
//  PhotoReviewView — never against the (unfiltered) live camera preview.
//

import CoreImage
import SwiftUI

enum SurCamFilter: String, CaseIterable, Identifiable {
    case none
    case mono
    case noir
    case sepia
    case vivid
    case cool
    case warm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:  return "Normal"
        case .mono:  return "Mono"
        case .noir:  return "Noir"
        case .sepia: return "Sepia"
        case .vivid: return "Vivid"
        case .cool:  return "Cool"
        case .warm:  return "Warm"
        }
    }

    /// Applies this filter to `image`, returning `image` unchanged for
    /// `.none` or if the filter fails to produce output.
    func apply(to image: CIImage) -> CIImage {
        switch self {
        case .none:
            return image
        case .mono:
            return filtered(image, name: "CIPhotoEffectMono")
        case .noir:
            return filtered(image, name: "CIPhotoEffectNoir")
        case .sepia:
            let filter = CIFilter(name: "CISepiaTone")
            filter?.setValue(image, forKey: kCIInputImageKey)
            filter?.setValue(0.85, forKey: kCIInputIntensityKey)
            return filter?.outputImage ?? image
        case .vivid:
            return filtered(image, name: "CIPhotoEffectChrome")
        case .cool:
            let filter = CIFilter(name: "CITemperatureAndTint")
            filter?.setValue(image, forKey: kCIInputImageKey)
            filter?.setValue(CIVector(x: 5500, y: 0), forKey: "inputNeutral")
            filter?.setValue(CIVector(x: 9000, y: 0), forKey: "inputTargetNeutral")
            return filter?.outputImage ?? image
        case .warm:
            let filter = CIFilter(name: "CITemperatureAndTint")
            filter?.setValue(image, forKey: kCIInputImageKey)
            filter?.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            filter?.setValue(CIVector(x: 4000, y: 0), forKey: "inputTargetNeutral")
            return filter?.outputImage ?? image
        }
    }

    private func filtered(_ image: CIImage, name: String) -> CIImage {
        let filter = CIFilter(name: name)
        filter?.setValue(image, forKey: kCIInputImageKey)
        return filter?.outputImage ?? image
    }
}
