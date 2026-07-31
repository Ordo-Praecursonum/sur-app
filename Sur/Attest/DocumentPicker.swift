//
//  DocumentPicker.swift
//  Sur
//
//  UIViewControllerRepresentable wrapping UIDocumentPickerViewController for
//  a single-file pick, used by FileAttestationView.
//

import SwiftUI
import UniformTypeIdentifiers

struct DocumentPicker: UIViewControllerRepresentable {
    /// Called with (fileName, data) on a successful pick, or nil if cancelled.
    var onPick: ((String, Data)?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ((String, Data)?) -> Void

        init(onPick: @escaping ((String, Data)?) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onPick(nil); return }
            guard let data = try? Data(contentsOf: url) else { onPick(nil); return }
            onPick((url.lastPathComponent, data))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}
