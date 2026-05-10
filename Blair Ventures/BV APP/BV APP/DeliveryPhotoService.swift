// DeliveryPhotoService.swift
// Aski IQ — Upload delivery-proof photos to Supabase Storage.
//
// PURPOSE
//   The receiving workflow requires at least one photo of the packing
//   slip / delivered material before a Material Request can be flipped
//   to .delivered. This service handles the upload + path generation;
//   callers stamp the returned path on MaterialRequest.deliveryPhotoURL
//   and push through the standard sync layer.
//
// STORAGE LAYOUT
//   Bucket: `contracts` — already provisioned with company-scoped RLS
//   (path-leading-folder = company_id). Re-using it avoids spinning up
//   a new bucket for one feature.
//   Path:   <companyId>/material-requests/<requestId>/delivery_<UUID>.jpg
//
//   The UUID suffix lets a single MR accumulate multiple photo uploads
//   over time (e.g. partial → full delivery photo replacement) without
//   collisions, even though we only store a pointer to the most recent
//   one on the MR row today.
//
// COMPRESSION
//   Routes through SharedComponents.compressPhoto, which (a) downsizes
//   to 2048 px on the longest edge and (b) iterates JPEG quality down
//   from 0.8 until the encoded payload fits ~500 KB. Same helper used
//   by DJR / Forms / Incidents — receivers on cellular at job sites
//   get tolerable upload sizes regardless of the source camera's
//   megapixel count.
//
// EXIF
//   The UIImage → jpegData round-trip strips EXIF metadata (GPS
//   coordinates, device serial, capture timestamps) — iOS does not
//   preserve EXIF when re-encoding via UIImage. Project site
//   coordinates therefore never reach Supabase Storage.

#if canImport(UIKit)
import Foundation
import UIKit
import Supabase

@MainActor
final class DeliveryPhotoService {

    static let shared = DeliveryPhotoService()
    private init() {}

    enum DeliveryPhotoError: LocalizedError {
        case missingCompany
        case encodeFailed
        case uploadFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingCompany:        return "No active company — can't determine storage path."
            case .encodeFailed:          return "Couldn't encode the photo. Try a different image."
            case .uploadFailed(let msg): return "Photo upload failed: \(msg)"
            }
        }
    }

    /// Uploads `image` to Supabase Storage and returns the storage path.
    /// The upload is routed through SharedComponents.compressPhoto which
    /// caps the longest edge at 2048 px and iterates JPEG quality down
    /// to keep the payload near 500 KB — see file header.
    /// Caller stamps the path on MaterialRequest.deliveryPhotoURL and
    /// pushes through SyncEngine.
    func upload(image: UIImage,
                requestID: UUID,
                companyID: UUID?) async throws -> String {
        guard let companyID = companyID else {
            throw DeliveryPhotoError.missingCompany
        }
        // Encode at high quality first so compressPhoto has full fidelity
        // to step down from. The helper takes Data and returns Data.
        guard let raw = image.jpegData(compressionQuality: 0.95) else {
            throw DeliveryPhotoError.encodeFailed
        }
        let data = compressPhoto(raw)
        let filename = "delivery_\(UUID().uuidString).jpg"
        let path = "\(companyID.uuidString)/material-requests/\(requestID.uuidString)/\(filename)"
        do {
            _ = try await supabase.storage
                .from("contracts")
                .upload(
                    path,
                    data: data,
                    options: FileOptions(
                        contentType: "image/jpeg",
                        upsert: false   // unique UUID-suffixed name → no collision
                    )
                )
            return path
        } catch {
            throw DeliveryPhotoError.uploadFailed(error.localizedDescription)
        }
    }

    /// Resolves a Supabase Storage path to a short-lived signed URL so
    /// the photo can be displayed in the MR Detail view. Returns nil on
    /// failure (UI shows a placeholder rather than crashing).
    func signedURL(for path: String, ttlSeconds: Int = 3600) async -> URL? {
        do {
            return try await supabase.storage
                .from("contracts")
                .createSignedURL(path: path, expiresIn: ttlSeconds)
        } catch {
            print("⚠️ DeliveryPhotoService: signedURL failed for \(path): \(error)")
            return nil
        }
    }
}
#endif
