// ReceiptScanService.swift
// Aski IQ — Scan supplier receipts / quotes / hand-written lists into a
// Material Request via VisionKit's document camera.
//
// PURPOSE
//   Field workers and PMs frequently get a paper receipt or quote with
//   a delivery and want to attach it to the request without retyping.
//   VisionKit handles edge detection, perspective correction, and
//   multi-page capture — far better quality than a raw photo.
//
// STORAGE LAYOUT
//   Bucket:  `contracts` (re-used; company-scoped RLS already in place)
//   Path:    <companyId>/material-requests/<requestId>/receipt_<UUID>.pdf
//
//   Same naming convention as DeliveryPhotoService so all attachments
//   for a single MR sit in one folder. The "receipt_" prefix lets
//   downstream queries / UIs distinguish receipt scans from delivery
//   photos by filename without an extra metadata table.
//
// FILE FORMAT
//   Multi-page PDF (one page per scanned page). PDF rather than per-page
//   JPEGs because supplier receipts are often multiple pages and a single
//   file is easier to share, attach to emails, and review in QuickLook.

#if canImport(UIKit)
import Foundation
import UIKit
import VisionKit
import SwiftUI
import Supabase

// MARK: - Service

@MainActor
final class ReceiptScanService {

    static let shared = ReceiptScanService()
    private init() {}

    enum ReceiptScanError: LocalizedError {
        case missingCompany
        case noPages
        case renderFailed
        case uploadFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingCompany:        return "No active company — can't determine storage path."
            case .noPages:               return "No pages were captured."
            case .renderFailed:          return "Couldn't render the scan to PDF."
            case .uploadFailed(let msg): return "Receipt upload failed: \(msg)"
            }
        }
    }

    /// Render the scanned pages to a single PDF and upload it. Caller
    /// stamps the returned path on MaterialRequest.receiptScanPath and
    /// pushes through SyncEngine.
    func upload(scan: VNDocumentCameraScan,
                requestID: UUID,
                companyID: UUID?) async throws -> String {
        guard let companyID = companyID else {
            throw ReceiptScanError.missingCompany
        }
        guard scan.pageCount > 0 else {
            throw ReceiptScanError.noPages
        }
        guard let pdfData = render(scan: scan) else {
            throw ReceiptScanError.renderFailed
        }
        let filename = "receipt_\(UUID().uuidString).pdf"
        let path = "\(companyID.uuidString)/material-requests/\(requestID.uuidString)/\(filename)"
        do {
            _ = try await supabase.storage
                .from("contracts")
                .upload(
                    path,
                    data: pdfData,
                    options: FileOptions(
                        contentType: "application/pdf",
                        upsert: false
                    )
                )
            return path
        } catch {
            throw ReceiptScanError.uploadFailed(error.localizedDescription)
        }
    }

    /// Resolve a storage path to a short-lived signed URL for inline
    /// display / QuickLook. Returns nil on failure.
    func signedURL(for path: String, ttlSeconds: Int = 3600) async -> URL? {
        do {
            return try await supabase.storage
                .from("contracts")
                .createSignedURL(path: path, expiresIn: ttlSeconds)
        } catch {
            print("⚠️ ReceiptScanService: signedURL failed for \(path): \(error)")
            return nil
        }
    }

    /// Convert a VNDocumentCameraScan to a single multi-page PDF Data
    /// blob. Each scan page becomes one PDF page sized to the image.
    private func render(scan: VNDocumentCameraScan) -> Data? {
        guard scan.pageCount > 0 else { return nil }
        // Use the first page's bounds as the canvas; subsequent pages
        // get scaled to fit. Receipts are usually portrait + similar
        // aspect ratios so this rarely needs a true per-page bounds.
        let firstPage = scan.imageOfPage(at: 0)
        let bounds = CGRect(origin: .zero, size: firstPage.size)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            for i in 0..<scan.pageCount {
                let page = scan.imageOfPage(at: i)
                ctx.beginPage()
                // Draw centered + scaled to fit while preserving aspect.
                let pageRect = CGRect(origin: .zero, size: bounds.size)
                let scale = min(
                    pageRect.width  / page.size.width,
                    pageRect.height / page.size.height
                )
                let drawW = page.size.width  * scale
                let drawH = page.size.height * scale
                let drawX = pageRect.midX - drawW / 2
                let drawY = pageRect.midY - drawH / 2
                page.draw(in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
            }
        }
    }
}

// MARK: - SwiftUI wrapper

/// Wraps VNDocumentCameraViewController for SwiftUI. The system camera
/// handles edge detection, multi-page capture, and the Save / Retake UI;
/// this is just the bridge that hands the resulting scan back via the
/// `onScan` closure. Cancellation calls `onScan(nil)`.
struct DocumentScannerView: UIViewControllerRepresentable {
    let onScan: (VNDocumentCameraScan?) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: (VNDocumentCameraScan?) -> Void

        init(onScan: @escaping (VNDocumentCameraScan?) -> Void) {
            self.onScan = onScan
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            onScan(scan)
            controller.dismiss(animated: true)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onScan(nil)
            controller.dismiss(animated: true)
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            print("⚠️ DocumentScanner failed: \(error)")
            onScan(nil)
            controller.dismiss(animated: true)
        }
    }
}
#endif
