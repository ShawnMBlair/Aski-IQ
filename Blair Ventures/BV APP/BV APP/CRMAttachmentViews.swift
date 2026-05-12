// CRMAttachmentViews.swift
// BV APP – CRM File & Photo Attachments

import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers

// MARK: - Attachment Section (reusable)

struct CRMAttachmentSection: View {
    @EnvironmentObject var store: AppStore

    let entityID: UUID
    let entityType: CRMEntityType

    @State private var showPhotoPicker   = false
    @State private var showFilePicker    = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var previewURL: URL?  = nil
    @State private var fullScreenImage: UIImage? = nil
    @State private var isUploading       = false
    @State private var uploadError: String? = nil
    /// FIX (debug audit): live camera for CRM attachments (meeting
    /// notes, business card shots, contact records). Same pattern as
    /// the other photo flows.
    @State private var showCamera       = false
    @State private var capturedPhoto: UIImage? = nil

    private static let maxFileSizeBytes: Int = 25 * 1024 * 1024  // 25 MB

    private var attachments: [CRMAttachment] {
        store.attachments(for: entityID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Label("Files & Photos", systemImage: "paperclip")
                    .font(.headline)
                Spacer()
                if store.currentUserRole.canEditCRM {
                    Menu {
                        // FIX (debug audit): live camera shortcut.
                        // Hidden on devices without a camera.
                        if CameraPicker.isAvailable {
                            Button {
                                showCamera = true
                            } label: {
                                Label("Take Photo", systemImage: "camera.fill")
                            }
                        }
                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label("Photo Library", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showFilePicker = true
                        } label: {
                            Label("Browse Files", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                    }
                }
            }
            .padding(.horizontal, 16)

            if isUploading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Saving…").font(.caption).foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
            }

            if let err = uploadError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(err).font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button { uploadError = nil } label: {
                        Image(systemName: "xmark").font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
            }

            if attachments.isEmpty && !isUploading {
                Text("No files attached yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
            } else {
                // Thumbnail grid
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 10)], spacing: 10) {
                    ForEach(attachments) { attachment in
                        AttachmentTile(attachment: attachment) {
                            openAttachment(attachment)
                        } onDelete: {
                            store.deleteCRMAttachment(attachment)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        // Photo picker
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItem,
            matching: .images
        )
        .onChange(of: selectedPhotoItem) { item in
            guard let item else { return }
            isUploading = true
            Task {
                await handlePhotoSelection(item)
                selectedPhotoItem = nil
                isUploading = false
            }
        }
        // File picker
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf, .plainText, .data, .image,
                                   UTType(filenameExtension: "doc") ?? .data,
                                   UTType(filenameExtension: "docx") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        // QuickLook preview
        .quickLookPreview($previewURL)
        // Full-screen image viewer
        .fullScreenCover(item: $fullScreenImage) { img in
            FullScreenImageViewer(image: img)
        }
        // FIX (debug audit): live camera capture.
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(image: $capturedPhoto)
                .ignoresSafeArea()
        }
        .onChange(of: capturedPhoto) { img in
            guard let img = img,
                  let data = img.jpegData(compressionQuality: 0.9) else { return }
            capturedPhoto = nil
            isUploading = true
            Task {
                await handleCapturedPhoto(data: data)
                isUploading = false
            }
        }
    }

    /// Camera-captured photo path. Mirrors handlePhotoSelection but
    /// starts from raw Data already JPEG-encoded by UIImage.
    private func handleCapturedPhoto(data: Data) async {
        if data.count > Self.maxFileSizeBytes {
            await MainActor.run { uploadError = "Photo exceeds 25 MB limit." }
            return
        }
        let fileName = "photo_\(Date().timeIntervalSince1970).jpg"
        let thumbnail = makeThumbnail(from: data, maxDimension: 200)
        await MainActor.run {
            store.addCRMAttachment(
                entityID:      entityID,
                entityType:    entityType,
                fileName:      fileName,
                fileType:      .image,
                data:          data,
                thumbnailData: thumbnail
            )
        }
    }

    // MARK: - Handlers

    private func handlePhotoSelection(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            await MainActor.run { uploadError = "Could not load photo. Try again." }
            return
        }
        if data.count > Self.maxFileSizeBytes {
            await MainActor.run { uploadError = "Photo exceeds 25 MB limit." }
            return
        }
        let fileName = "photo_\(Date().timeIntervalSince1970).jpg"
        let thumbnail = makeThumbnail(from: data, maxDimension: 200)
        await MainActor.run {
            store.addCRMAttachment(
                entityID: entityID,
                entityType: entityType,
                fileName: fileName,
                fileType: .image,
                data: data,
                thumbnailData: thumbnail
            )
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else {
            uploadError = "Could not access file."; return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: url) else {
            uploadError = "Could not read file."; return
        }
        if data.count > Self.maxFileSizeBytes {
            uploadError = "File exceeds 25 MB limit."; return
        }
        let ext = url.pathExtension
        let fileType = CRMAttachmentFileType.from(extension: ext)
        var thumbnail: Data? = nil
        if fileType == .image { thumbnail = makeThumbnail(from: data, maxDimension: 200) }

        store.addCRMAttachment(
            entityID: entityID,
            entityType: entityType,
            fileName: url.lastPathComponent,
            fileType: fileType,
            data: data,
            thumbnailData: thumbnail
        )
    }

    private func openAttachment(_ attachment: CRMAttachment) {
        let fileURL = store.attachmentFileURL(attachment)
        if attachment.fileType == .image, let data = try? Data(contentsOf: fileURL),
           let img = UIImage(data: data) {
            fullScreenImage = img
        } else {
            previewURL = fileURL
        }
    }

    private func makeThumbnail(from data: Data, maxDimension: CGFloat) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let size = img.size
        let scale = min(maxDimension / size.width, maxDimension / size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let thumb = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: newSize)) }
        return thumb.jpegData(compressionQuality: 0.7)
    }
}

// MARK: - Attachment Tile

private struct AttachmentTile: View {
    @EnvironmentObject var store: AppStore
    let attachment: CRMAttachment
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirm = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onTap) {
                VStack(spacing: 6) {
                    thumbnailView
                        .frame(height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text(attachment.fileName)
                        .font(.caption2)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    Text(attachment.displaySize)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .confirmationDialog("Delete \"\(attachment.fileName)\"?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { onDelete() }
                Button("Cancel", role: .cancel) {}
            }

            if store.currentUserRole.canDeleteCRM {
                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .background(Color.red.clipShape(Circle()))
                }
                .offset(x: 4, y: -4)
            }
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbData = attachment.thumbnailData, let img = UIImage(data: thumbData) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(attachment.fileType.color.opacity(0.12))
                Image(systemName: attachment.fileType.icon)
                    .font(.system(size: 28))
                    .foregroundColor(attachment.fileType.color)
            }
        }
    }
}

// MARK: - Full Screen Image Viewer

struct FullScreenImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in scale = lastScale * value }
                        .onEnded { _ in lastScale = scale }
                )
                .onTapGesture(count: 2) {
                    withAnimation { scale = scale > 1 ? 1 : 2; lastScale = scale }
                }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.8))
                    .padding(16)
            }
        }
    }
}

// MARK: - UIImage Identifiable

extension UIImage: @retroactive Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}
