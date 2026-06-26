//
//  ReceiveSurView.swift
//  Sur
//
//  Show the user's Sur Chain address as a QR code (for scanning) and as
//  copyable text, so others can send SUR to them.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

struct ReceiveSurView: View {
    @Environment(\.dismiss) private var dismiss

    let address: String

    @State private var copied = false

    private static let qrContext = CIContext()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Scan to send SUR to this address")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)

                if let qr = qrImage(from: address) {
                    Image(uiImage: qr)
                        .interpolation(.none)        // keep QR crisp
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                        .padding(16)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.systemGray5))
                        .frame(width: 240, height: 240)
                        .overlay(Text("QR unavailable").foregroundColor(.secondary))
                }

                VStack(spacing: 8) {
                    Text("Your Sur Address")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(address)
                        .font(.system(.footnote, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding(.horizontal)
                }

                Button {
                    Pasteboard.copy(address)
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied!" : "Copy Address",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            LinearGradient(colors: [.orange, .red],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 24)

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .navigationTitle("Receive SUR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func qrImage(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = Self.qrContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
