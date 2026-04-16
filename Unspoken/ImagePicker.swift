//
//  ImagePicker.swift
//  Unspoken
//

import SwiftUI
import UIKit
import ImageIO

// MARK: - ImagePicker

struct ImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImage: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        if sourceType == .camera && UIImagePickerController.isCameraDeviceAvailable(.front) {
            picker.cameraDevice = .front
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        init(onImage: @escaping (UIImage) -> Void) { self.onImage = onImage }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.editedImage] as? UIImage ?? info[.originalImage] as? UIImage {
                onImage(img)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - Image Processing

/// Resize to max 1200px, encode as HEIC at 0.75 quality. Must be called off the main thread.
func processImageForSending(_ image: UIImage) -> Data? {
    let maxDimension: CGFloat = 1200
    let pixelW = image.size.width  * image.scale
    let pixelH = image.size.height * image.scale
    let ratio  = min(maxDimension / pixelW, maxDimension / pixelH, 1.0)
    let newSize = CGSize(width: (pixelW * ratio).rounded(), height: (pixelH * ratio).rounded())

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
    let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }

    guard let cgImage = resized.cgImage else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

/// Generate a 60×60px center-crop JPEG thumbnail for use as a quote preview.
func makeQuoteThumbnail(_ data: Data) -> Data? {
    guard let image = UIImage(data: data) else { return nil }
    let side: CGFloat = 60
    let scale = max(side / image.size.width, side / image.size.height)
    let scaledSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let origin = CGPoint(x: (side - scaledSize.width) / 2, y: (side - scaledSize.height) / 2)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
    let thumb = renderer.image { _ in image.draw(in: CGRect(origin: origin, size: scaledSize)) }
    return thumb.jpegData(compressionQuality: 0.6)
}
