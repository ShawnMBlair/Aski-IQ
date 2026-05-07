// ToastService.swift
// Aski IQ — Lightweight system-wide toast / banner notifications.
//
// WHY THIS EXISTS
// Audit §29 (UX/UI gaps) flagged: "No success/error toast pattern (alerts only).
// 3 days for a ToastService." This is that file. Every save/delete/import flow
// can now post a transient banner instead of stealing focus with a modal alert.
//
// USAGE
//   ToastService.shared.success("Quote sent to client")
//   ToastService.shared.warning("3 line items missing cost code")
//   ToastService.shared.error("Couldn't reach Supabase. Retry?", action: .init(label: "Retry") { … })
//
// MOUNTING
// Mount the host once at the app root (BV_APPApp.swift) — it observes the
// service and renders the toast over any active scene. No need to touch
// individual views.

import SwiftUI
import UIKit
import Combine

// MARK: - Toast model

struct Toast: Identifiable, Equatable {
    enum Kind {
        case success, info, warning, error
    }

    struct Action: Equatable {
        let label: String
        let handler: () -> Void

        // Equatable needs a stable comparison; we never mutate handlers, so id-by-label is fine.
        static func == (lhs: Action, rhs: Action) -> Bool { lhs.label == rhs.label }
    }

    let id: UUID = UUID()
    let kind: Kind
    let title: String
    let body: String?
    let action: Action?
    let duration: TimeInterval

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

// MARK: - Service

@MainActor
final class ToastService: ObservableObject {

    static let shared = ToastService()
    private init() {}

    @Published var current: Toast? = nil
    private var dismissTask: Task<Void, Never>? = nil

    // MARK: - Public API

    func success(_ title: String, body: String? = nil, duration: TimeInterval = 2.5) {
        post(Toast(kind: .success, title: title, body: body, action: nil, duration: duration))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func info(_ title: String, body: String? = nil, duration: TimeInterval = 2.5) {
        post(Toast(kind: .info, title: title, body: body, action: nil, duration: duration))
    }

    func warning(_ title: String, body: String? = nil, duration: TimeInterval = 3.5) {
        post(Toast(kind: .warning, title: title, body: body, action: nil, duration: duration))
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func error(_ title: String, body: String? = nil, action: Toast.Action? = nil, duration: TimeInterval = 4.5) {
        post(Toast(kind: .error, title: title, body: body, action: action, duration: duration))
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { current = nil }
    }

    // MARK: - Internal

    private func post(_ toast: Toast) {
        dismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            current = toast
        }
        let duration = toast.duration
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if !Task.isCancelled {
                await MainActor.run { self?.dismiss() }
            }
        }
    }
}

// MARK: - Host view

/// Mount this once near the root of the app (under `RootView()` in
/// `BV_APPApp.swift`) so toasts appear above whatever the active scene is.
struct ToastHost: View {
    @ObservedObject private var service = ToastService.shared

    var body: some View {
        VStack {
            Spacer()
            if let toast = service.current {
                ToastView(toast: toast)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(service.current != nil)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: service.current?.id)
    }
}

// MARK: - Toast view

private struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(iconBackground)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                if let body = toast.body, !body.isEmpty {
                    Text(body)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)

            if let action = toast.action {
                Button {
                    action.handler()
                    ToastService.shared.dismiss()
                } label: {
                    Text(action.label)
                        .font(.caption.weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.white.opacity(0.2))
                        .clipShape(Capsule())
                }
            } else {
                Button {
                    ToastService.shared.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 26, height: 26)
                }
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AskiRadius.card)
                .fill(background)
                .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) — \(toast.title)")
    }

    private var iconName: String {
        switch toast.kind {
        case .success: return "checkmark"
        case .info:    return "info"
        case .warning: return "exclamationmark"
        case .error:   return "xmark"
        }
    }

    private var iconBackground: Color {
        switch toast.kind {
        case .success: return .green
        case .info:    return .blue
        case .warning: return .orange
        case .error:   return .red
        }
    }

    private var background: Color {
        switch toast.kind {
        case .success: return Color(red: 0.10, green: 0.22, blue: 0.16)   // deep green
        case .info:    return Color(red: 0.10, green: 0.18, blue: 0.30)   // deep blue
        case .warning: return Color(red: 0.30, green: 0.20, blue: 0.05)   // amber
        case .error:   return Color(red: 0.30, green: 0.08, blue: 0.10)   // deep red
        }
    }

    private var label: String {
        switch toast.kind {
        case .success: return "Success"
        case .info:    return "Info"
        case .warning: return "Warning"
        case .error:   return "Error"
        }
    }
}
