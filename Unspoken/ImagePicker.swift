//
//  ImagePicker.swift
//  Unspoken
//

import SwiftUI
import UIKit
import ImageIO
import PhotosUI

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

// MARK: - MultiImagePicker
// PHPicker-based library picker with ordered multi-select (numbered 1, 2, 3… badges).
// Calls onImages with the picked images in selection order; empty array on cancel.

struct MultiImagePicker: UIViewControllerRepresentable {
    let onImages: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onImages: onImages) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 0
        config.selection = .ordered
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onImages: ([UIImage]) -> Void
        init(onImages: @escaping ([UIImage]) -> Void) { self.onImages = onImages }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                onImages([])
                return
            }
            // Item providers load asynchronously on arbitrary threads; collect into
            // fixed slots under a lock so selection order is preserved.
            var loaded = [UIImage?](repeating: nil, count: results.count)
            let lock = NSLock()
            let group = DispatchGroup()
            for (index, result) in results.enumerated()
            where result.itemProvider.canLoadObject(ofClass: UIImage.self) {
                group.enter()
                result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                    lock.lock()
                    loaded[index] = object as? UIImage
                    lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                self.onImages(loaded.compactMap { $0 })
            }
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
