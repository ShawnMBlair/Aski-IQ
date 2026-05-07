// EmptyStatePlaceholder.swift
// Aski IQ — shared empty-state component
//
// Used across list views (Clients, Estimates, Quotes, Opportunities,
// Employees, Project sub-views) to give users a clear "what is this
// section / what should I do next" cue when no records exist yet.
// Replaces ad-hoc "No X yet" Text labels that left users with no
// guidance.
//
// USAGE
//   EmptyStatePlaceholder(
//       icon: "doc.text.magnifyingglass",
//       title: "No estimates yet",
//       subtitle: "Estimates capture scope, line items, and pricing before sending a formal quote.",
//       actionTitle: "Create Estimate",
//       action: { showCreate = true }
//   )
//
// The action button is optional — pass nil for actionTitle/action when
// the host view already exposes a "+" toolbar button (the placeholder
// then just communicates emptiness without duplicating the affordance).

import SwiftUI

struct EmptyStatePlaceholder: View {
    let icon:        String
    let title:       String
    let subtitle:    String
    var actionTitle: String? = nil
    var action:      (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.6))
                .frame(width: 72, height: 72)
                .background(Color.accentColor.opacity(0.10))
                .clipShape(Circle())

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview("With action") {
    EmptyStatePlaceholder(
        icon: "person.2.fill",
        title: "No clients yet",
        subtitle: "Clients are the companies you work for. Add one to start tracking opportunities, estimates, and projects against them.",
        actionTitle: "Add Client",
        action: { }
    )
}

#Preview("Without action") {
    EmptyStatePlaceholder(
        icon: "calendar",
        title: "No schedule entries",
        subtitle: "Use the + button to add crew assignments for this project."
    )
}
#endif
