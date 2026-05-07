// PermissionMatrixView.swift
// Aski IQ — Read-only admin view of role → capability mapping.
//
// WHY THIS EXISTS
// The 2026-04-28 strategy report (§10, P1) flagged "Permission matrix admin UI"
// as a P1 gap before paying customer. The data already exists — every role's
// capabilities are typed booleans on the UserRole enum (BaseModel.swift:76+).
// This view surfaces them so an admin can answer "what can a foreman do?" or
// "should an estimator be able to approve quotes?" without reading source.
//
// READ-ONLY for v1. Editing role permissions would require server-side
// configuration (custom roles in Supabase + dynamic checks) — that's a Phase 2
// build. For now this is observability.

import SwiftUI

/// One row in the capabilities table — a single permission flag we surface.
fileprivate struct Capability: Identifiable {
    let id: String
    let label: String
    let icon: String
    let group: String
    let test: (UserRole) -> Bool
}

struct PermissionMatrixView: View {

    fileprivate let capabilities: [Capability] = [
        // CRM
        Capability(id: "viewCRM", label: "View CRM",
                   icon: "person.crop.rectangle.stack", group: "CRM",
                   test: { $0.canViewCRM }),
        Capability(id: "editCRM", label: "Create + edit CRM records",
                   icon: "square.and.pencil", group: "CRM",
                   test: { $0.canEditCRM }),
        Capability(id: "markWonLost", label: "Mark opportunity won / lost",
                   icon: "trophy", group: "CRM",
                   test: { $0.canMarkWonLost }),
        Capability(id: "deleteCRM", label: "Delete CRM records",
                   icon: "trash", group: "CRM",
                   test: { $0.canDeleteCRM }),
        Capability(id: "deleteCRMTasks", label: "Delete CRM tasks",
                   icon: "checkmark.rectangle", group: "CRM",
                   test: { $0.canDeleteCRMTasks }),
        Capability(id: "editOppFinancials", label: "See opportunity dollar values",
                   icon: "dollarsign.circle", group: "CRM",
                   test: { $0.canEditOpportunityFinancials }),

        // Commercial
        Capability(id: "commercial", label: "Access commercial module",
                   icon: "doc.text.below.ecg", group: "Commercial",
                   test: { $0.canAccessCommercial }),
        Capability(id: "estimate", label: "Create + edit estimates",
                   icon: "list.bullet.clipboard", group: "Commercial",
                   test: { $0.canEstimate }),
        Capability(id: "approveQuotes", label: "Approve quotes",
                   icon: "checkmark.seal", group: "Commercial",
                   test: { $0.canApproveQuotes }),

        // Field operations
        Capability(id: "approveTS", label: "Approve timesheets",
                   icon: "clock.badge.checkmark", group: "Field Operations",
                   test: { $0.canApproveTimesheets }),
        Capability(id: "seeAllProjects", label: "See all projects",
                   icon: "folder", group: "Field Operations",
                   test: { $0.canSeeAllProjects }),
        Capability(id: "viewSafety", label: "View safety records",
                   icon: "shield", group: "Field Operations",
                   test: { $0.canViewSafetyData }),

        // People & money
        Capability(id: "seePay", label: "See pay rates / cost data",
                   icon: "banknote", group: "Sensitive Data",
                   test: { $0.canSeePay }),
        Capability(id: "manageUsers", label: "Manage users & invitations",
                   icon: "person.2.gobackward", group: "Sensitive Data",
                   test: { $0.canManageUsers }),
    ]

    /// Order roles from most permissive to most restricted for legibility.
    fileprivate let roleOrder: [UserRole] = [
        .executive, .manager, .officeAdmin, .projectManager,
        .estimator, .safetyAdvisor, .foreman, .fieldWorker, .client
    ]

    @State private var selectedRole: UserRole = .foreman

    var body: some View {
        Form {
            Section {
                Picker("Role", selection: $selectedRole) {
                    ForEach(roleOrder, id: \.rawValue) { role in
                        Text(role.displayName).tag(role)
                    }
                }
                .pickerStyle(.menu)
                metaRow(for: selectedRole)
            } header: {
                Text("Choose a role")
            } footer: {
                Text("Read-only. Permissions are defined by the UserRole enum and enforced at every CRUD call site via store.requireRole(...). Editing permissions requires a server change.")
            }

            ForEach(grouped(capabilities), id: \.0) { group, items in
                Section(group) {
                    ForEach(items) { cap in
                        capabilityRow(cap, role: selectedRole)
                    }
                }
            }

            Section {
                NavigationLink("Side-by-side compare all roles…") {
                    PermissionCompareView(capabilities: capabilities, roleOrder: roleOrder)
                }
            }
        }
        .navigationTitle("Permissions")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Rows

    @ViewBuilder
    private func metaRow(for role: UserRole) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if role.isAdmin     { tag("Admin",     color: .purple) }
                if role.isFieldRole { tag("Field",     color: .blue) }
                if role.isExternal  { tag("External",  color: .orange) }
            }
            Text(roleDescription(role))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func capabilityRow(_ cap: Capability, role: UserRole) -> some View {
        HStack {
            Image(systemName: cap.icon)
                .frame(width: 22)
                .foregroundColor(.secondary)
            Text(cap.label)
            Spacer()
            if cap.test(role) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Image(systemName: "minus.circle")
                    .foregroundColor(Color.secondary.opacity(0.4))
            }
        }
    }

    // MARK: - Helpers

    private func grouped(_ items: [Capability]) -> [(String, [Capability])] {
        let dict = Dictionary(grouping: items, by: { $0.group })
        // Stable order based on first appearance in `capabilities`
        let order: [String] = items.reduce(into: [String]()) { acc, c in
            if !acc.contains(c.group) { acc.append(c.group) }
        }
        return order.map { ($0, dict[$0] ?? []) }
    }

    private func roleDescription(_ role: UserRole) -> String {
        switch role {
        case .executive:      return "Full operational access. Senior leadership."
        case .owner:          return "Account owner. Billing, tenant management, and all approvals."
        case .manager:        return "Operational leader. Can manage projects, financials, and team."
        case .officeAdmin:    return "Office staff. CRM, scheduling, payroll, document management."
        case .projectManager: return "Owns projects. Schedules crews, approves field paperwork, manages COs."
        case .estimator:      return "Builds estimates and quotes. Limited project visibility."
        case .safetyAdvisor:  return "Reviews safety forms, incidents, certifications."
        case .foreman:        return "Field supervisor. Logs hours for crew, files daily reports + safety."
        case .fieldWorker:    return "Front-line worker. Sees only assigned jobs and own timesheet."
        case .client:         return "External client portal user. Read-only on their own project."
        }
    }
}

// MARK: - Side-by-side compare

private struct PermissionCompareView: View {
    let capabilities: [Capability]
    let roleOrder: [UserRole]

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 0) {
                    Text("Capability")
                        .font(.caption.bold())
                        .frame(width: 220, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color(.systemBackground))
                    ForEach(roleOrder, id: \.rawValue) { role in
                        Text(role.displayName)
                            .font(.caption2.bold())
                            .multilineTextAlignment(.center)
                            .frame(width: 78, height: 44)
                            .background(Color(.secondarySystemBackground))
                            .border(Color(.separator), width: 0.5)
                    }
                }
                Divider()
                ForEach(capabilities) { cap in
                    HStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: cap.icon)
                                .foregroundColor(.secondary)
                                .frame(width: 18)
                            Text(cap.label).font(.caption)
                        }
                        .frame(width: 220, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        ForEach(roleOrder, id: \.rawValue) { role in
                            ZStack {
                                if cap.test(role) {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                } else {
                                    Image(systemName: "minus")
                                        .foregroundColor(Color.secondary.opacity(0.4))
                                }
                            }
                            .frame(width: 78, height: 32)
                            .border(Color(.separator).opacity(0.5), width: 0.5)
                        }
                    }
                }
            }
        }
        .navigationTitle("Compare roles")
        .navigationBarTitleDisplayMode(.inline)
    }
}
