// CameraPicker.swift
// Aski IQ — direct camera capture for delivery proof, incident
// photos, DJR photos, and form attachments.
//
// SwiftUI's `PhotosPicker` only surfaces the photo LIBRARY — it
// doesn't offer live camera capture. For field workflows
// (receiving deliveries, logging incidents on a job site) the
// natural action is "open camera, take photo, attach" — not
// "switch to Camera app, take photo, switch back, pick from
// library." This bridge wraps `UIImagePickerController` with
// sourceType = `.camera` so SwiftUI can present it as a sheet
// alongside the existing PhotosPicker.
//
// USAGE
//   @State private var showCamera = false
//   @State private var capturedImage: UIImage? = nil
//
//   Button("Take Photo") { showCamera = true }
//     .disabled(!CameraPicker.isAvailable)
//   .sheet(isPresented: $showCamera) {
//       CameraPicker(image: $capturedImage)
//   }
//
// AVAILABILITY
//   `CameraPicker.isAvailable` is true when:
//     • Compiled under canImport(UIKit) (iOS + iPad + Mac Catalyst)
//     • UIImagePickerController reports `.camera` is supported
//   On Mac Catalyst without an attached camera (most desktops), and
//   on iPad without a camera, isAvailable returns false. Callers
//   should hide / disable their "Take Photo" button when false and
//   leave PhotosPicker as the only path.

#if canImport(UIKit)
import SwiftUI
import UIKit

struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    /// Convenience for callers to gate the "Take Photo" button when
    /// the device has no camera. Cheap to call repeatedly — the
    /// underlying `isSourceTypeAvailable` is a static lookup.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // Prefer .originalImage — `.editedImage` is only present
            // when allowsEditing = true (which we set false above).
            if let image = info[.originalImage] as? UIImage {
                parent.image = image
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

#endif
