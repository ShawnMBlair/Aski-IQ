// SharedComponents.swift
// FieldOS – Reusable UI Components

import SwiftUI

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(title).font(.headline)
            if let count {
                Text("(\(count))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: "plus")
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }
                .accessibilityLabel("\(actionTitle) to \(title)")
            }
        }
        .padding(.horizontal)
        // Treat title + count as a single accessibility heading
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Empty State Card

struct EmptyCard: View {
    let message: String
    /// Optional system icon. Defaults to no icon for backward-compat callers.
    var icon: String? = nil

    var body: some View {
        VStack(spacing: AskiSpacing.sm) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(AskiSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: AskiRadius.card, style: .continuous)
                .fill(AskiColor.surfaceElevated)
        )
        .padding(.horizontal, AskiSpacing.lg)
    }
}

// MARK: - Schedule Entry Row

struct ScheduleEntryRow: View {
    let entry: ScheduleEntry
    @EnvironmentObject var store: AppStore

    private var projectName: String {
        store.project(id: entry.projectID)?.name ?? "Unknown Project"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AskiSpacing.xs) {
            Text(projectName).font(.headline)
            if let task = entry.taskDescription {
                Text(task).font(.subheadline).foregroundColor(.secondary)
            }
            if let location = entry.location {
                Label(location, systemImage: "mappin").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(AskiSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AskiRadius.card, style: .continuous)
                .fill(AskiColor.surfaceElevated)
        )
        .padding(.horizontal, AskiSpacing.lg)
    }
}

// MARK: - Project Summary Row

struct ProjectSummaryRow: View {
    let project: Project

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: AskiSpacing.xs) {
                Text(project.name).font(.headline)
                Text(project.clientName).font(.subheadline).foregroundColor(.secondary)
            }
            Spacer()
            StatusBadge(status: project.status)
        }
        .padding(AskiSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: AskiRadius.card, style: .continuous)
                .fill(AskiColor.surfaceElevated)
        )
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: ProjectStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption2.weight(.bold))
            .tracking(0.3)
            .textCase(.uppercase)
            .padding(.horizontal, AskiSpacing.sm)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(backgroundColor.opacity(0.16))
            )
            .overlay(
                Capsule()
                    .stroke(backgroundColor.opacity(0.35), lineWidth: 0.5)
            )
            .foregroundColor(backgroundColor)
            .accessibilityLabel("Status: \(status.rawValue)")
            .accessibilityAddTraits(.isStaticText)
    }

    private var backgroundColor: Color {
        // Token-backed; falls back to system colors for variants
        // not in AskiColor.status*.
        switch status {
        case .active:    return AskiColor.statusActive
        case .awarded:   return AskiColor.statusPending
        case .tendering: return AskiColor.statusWarning
        case .completed: return AskiColor.statusInactive
        case .onHold:    return Color.yellow
        case .cancelled: return AskiColor.statusError
        }
    }
}

// MARK: - Offline Banner

/// Shown at the top of the screen (via safeAreaInset) when the device has no network connection.
/// Call site should wrap with `.animation(.easeInOut, value: isOnline)` for slide-in effect.
struct OfflineBanner: View {
    let isVisible: Bool
    @EnvironmentObject private var store: AppStore

    private var pendingCount: Int {
        store.formSubmissions.filter { $0.syncStatus == .pending || $0.syncStatus == .failed }.count
    }

    var body: some View {
        if isVisible {
            HStack(spacing: 10) {
                Image(systemName: "wifi.slash")
                    .font(.subheadline).bold()
                VStack(alignment: .leading, spacing: 2) {
                    Text("No internet connection")
                        .font(.caption).bold()
                    Text(pendingCount > 0
                         ? "\(pendingCount) item\(pendingCount == 1 ? "" : "s") queued — will sync when back online"
                         : "Changes will sync when you're back online")
                        .font(.caption2)
                        .opacity(0.9)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.orange)
            .foregroundColor(.white)
            .transition(.move(edge: .top).combined(with: .opacity))
            // VoiceOver: announce when banner appears; treat as a single status region
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(pendingCount > 0
                ? "No internet connection. \(pendingCount) item\(pendingCount == 1 ? "" : "s") queued and will sync when back online."
                : "No internet connection. Changes will sync when you're back online.")
            .accessibilityAddTraits(.isStaticText)
        }
    }
}

// MARK: - Failed Sync Banner

/// Shown when one or more local records failed to push to Supabase. Offers
/// "Retry" (re-run pushPending) and "Discard" (hard-delete the failed local
/// records). Independent of the offline banner — failed-sync can happen even
/// with full connectivity (RLS denial, FK violation, transient 5xx, etc).
struct FailedSyncBanner: View {
    @EnvironmentObject var store: AppStore
    @State private var isRetrying = false
    @State private var showDiscardConfirm = false
    /// 2026-04 audit fix (Phase 9): drill-in detail sheet.
    @State private var showDetailSheet = false

    private var failedCount: Int {
        store.totalFailedSyncCount
    }

    var body: some View {
        if failedCount > 0 {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline).bold()
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(failedCount) item\(failedCount == 1 ? "" : "s") failed to sync")
                        .font(.caption).bold()
                    // Updated copy: tap the banner area itself to
                    // see per-record drill-in. Pre-fix the only
                    // way to act was Retry-All / Discard-All.
                    Text("Tap to inspect, or hit Retry to send them all.")
                        .font(.caption2)
                        .opacity(0.9)
                }
                .contentShape(Rectangle())
                .onTapGesture { showDetailSheet = true }
                Spacer()
                Button {
                    isRetrying = true
                    Task {
                        await store.retryFailedSyncs()
                        await MainActor.run { isRetrying = false }
                    }
                } label: {
                    if isRetrying {
                        ProgressView().tint(.white)
                    } else {
                        Text("Retry").font(.caption).bold()
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.white.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                .disabled(isRetrying)

                // Overflow menu — adds a Discard action so users can clear
                // permanently-stuck records (e.g. orphan FK violations).
                Menu {
                    Button {
                        showDetailSheet = true
                    } label: {
                        Label("Inspect failed records…", systemImage: "list.bullet.rectangle")
                    }
                    Button(role: .destructive) {
                        showDiscardConfirm = true
                    } label: {
                        Label("Discard failed items", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title3)
                }
                .accessibilityLabel("More sync options")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.red)
            .foregroundColor(.white)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(failedCount) item\(failedCount == 1 ? "" : "s") failed to sync. Retry available.")
            .alert("Discard \(failedCount) failed item\(failedCount == 1 ? "" : "s")?",
                   isPresented: $showDiscardConfirm) {
                Button("Discard", role: .destructive) {
                    let count = store.totalFailedSyncCount
                    store.discardFailedSyncs()
                    Haptics.heavy()
                    ToastService.shared.success("Discarded \(count) stuck item\(count == 1 ? "" : "s")")
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("These records can't reach the server (usually because a parent record is missing or the data is invalid). Discarding removes them from this device. They are NOT on Supabase, so this is permanent.")
            }
            .sheet(isPresented: $showDetailSheet) {
                FailedSyncDetailView()
                    .environmentObject(store)
            }
        }
    }
}

// MARK: - Photo Compression

/// Compresses image data to stay under `maxBytes` (default 500 KB).
/// Downsizes the image first if it's very large, then applies JPEG compression.
func compressPhoto(_ data: Data, maxBytes: Int = 500_000) -> Data {
    guard let img = UIImage(data: data) else { return data }

    // Downscale if image is very large (> 2048 on longest side)
    let maxDimension: CGFloat = 2048
    let size = img.size
    let scaled: UIImage
    if max(size.width, size.height) > maxDimension {
        let scale = maxDimension / max(size.width, size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        scaled = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: newSize)) }
    } else {
        scaled = img
    }

    var quality: CGFloat = 0.8
    var compressed = scaled.jpegData(compressionQuality: quality) ?? data
    while compressed.count > maxBytes && quality > 0.1 {
        quality -= 0.1
        compressed = scaled.jpegData(compressionQuality: quality) ?? data
    }
    return compressed
}

// MARK: - Stub Views (Placeholders for Sprint 1-2)
// These prevent compile errors while screens are built sprint by sprint.


