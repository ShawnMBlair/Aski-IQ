// WorkflowSettingsAdminView.swift
// Aski IQ — Admin UI for editing workflow_settings (approval limits +
// per-role MR permissions).
//
// AUDIENCE
//   Manager / executive / owner only. Wired into the admin panel; the view
//   itself enforces a role check at render time so a deep-link from a lower
//   role just shows an "Unauthorized" placeholder rather than crashing.
//
// SHAPE
//   One row per UserRole. Tap a row to expand the editor (approval limit +
//   five permission toggles). Saving an edit calls
//   AppStore.upsertWorkflowSetting which dispatches the push immediately —
//   no separate "Save All" button to lose state on dismiss.

import SwiftUI

struct WorkflowSettingsAdminView: View {
    @EnvironmentObject var store: AppStore

    private let editableRoles: [UserRole] = [
        .fieldWorker, .foreman, .safetyAdvisor, .projectManager,
        .estimator, .officeAdmin, .manager, .executive, .owner
        // .client intentionally excluded — clients shouldn't have MR
        // workflow permissions; the seeded row is deny-all.
    ]

    var body: some View {
        Group {
            if isAuthorized {
                authorizedView
            } else {
                ContentUnavailableView(
                    "Restricted",
                    systemImage: "lock.fill",
                    description: Text("Only managers, executives, or the owner can edit workflow settings.")
                )
            }
        }
        .navigationTitle("Approval Limits")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var isAuthorized: Bool {
        [.manager, .executive, .owner].contains(store.currentUserRole)
    }

    private var authorizedView: some View {
        List {
            Section {
                Text("These limits and permissions control who can submit, approve, send, and receive Material Requests. Changes apply company-wide and take effect immediately.")
                    .font(.caption).foregroundColor(.secondary)
            }
            ForEach(editableRoles, id: \.self) { role in
                NavigationLink {
                    WorkflowSettingEditor(role: role)
                } label: {
                    WorkflowSettingRow(role: role)
                }
            }
        }
    }
}

// MARK: - Row summary

private struct WorkflowSettingRow: View {
    @EnvironmentObject var store: AppStore
    let role: UserRole

    private var setting: WorkflowSetting { store.workflowSetting(for: role) }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(role.displayName).font(.subheadline).bold()
                HStack(spacing: 8) {
                    if setting.canApproveMaterialRequest {
                        permissionTag("Approve to \(setting.approvalLimitAmount.currencyString)",
                                      color: .green)
                    }
                    if setting.canSelfApprove {
                        permissionTag("Self-approve", color: .blue)
                    }
                    if setting.canSendToSupplier {
                        permissionTag("Send", color: .purple)
                    }
                    if setting.canReceiveMaterials {
                        permissionTag("Receive", color: .orange)
                    }
                }
                if !setting.canCreateMaterialRequest
                    && !setting.canApproveMaterialRequest
                    && !setting.canSendToSupplier
                    && !setting.canReceiveMaterials {
                    Text("No workflow permissions").font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func permissionTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}

// MARK: - Editor

private struct WorkflowSettingEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let role: UserRole

    @State private var approvalLimit: Decimal = 0
    @State private var canSelfApprove: Bool = false
    @State private var canCreateMR: Bool = true
    @State private var canApproveMR: Bool = false
    @State private var canSendToSupplier: Bool = false
    @State private var canReceiveMaterials: Bool = false
    @State private var isLoaded = false

    var body: some View {
        Form {
            Section("Approval Limit") {
                HStack {
                    Text("Up to")
                    Spacer()
                    TextField("0", value: $approvalLimit, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                    Text(currencySymbol).foregroundColor(.secondary)
                }
                Text("Material Requests at or below this amount can be approved by users with the \(role.displayName) role.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .disabled(!canApproveMR)

            Section("Permissions") {
                Toggle("Can create Material Requests",  isOn: $canCreateMR)
                Toggle("Can approve Material Requests", isOn: $canApproveMR)
                Toggle("Can self-approve own requests", isOn: $canSelfApprove)
                    .disabled(!canApproveMR)
                Toggle("Can send to supplier",          isOn: $canSendToSupplier)
                Toggle("Can receive materials",         isOn: $canReceiveMaterials)
            }

            Section {
                Button("Save Changes") { save() }
                    .frame(maxWidth: .infinity)
                    .disabled(!hasChanges)
            }
        }
        .navigationTitle(role.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadIfNeeded() }
    }

    private var currencySymbol: String {
        // Match the rest of the app — currencyString uses the locale formatter.
        Locale.current.currencySymbol ?? "$"
    }

    private var hasChanges: Bool {
        let s = store.workflowSetting(for: role)
        return s.approvalLimitAmount != approvalLimit
            || s.canSelfApprove != canSelfApprove
            || s.canCreateMaterialRequest != canCreateMR
            || s.canApproveMaterialRequest != canApproveMR
            || s.canSendToSupplier != canSendToSupplier
            || s.canReceiveMaterials != canReceiveMaterials
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        let s = store.workflowSetting(for: role)
        approvalLimit       = s.approvalLimitAmount
        canSelfApprove      = s.canSelfApprove
        canCreateMR         = s.canCreateMaterialRequest
        canApproveMR        = s.canApproveMaterialRequest
        canSendToSupplier   = s.canSendToSupplier
        canReceiveMaterials = s.canReceiveMaterials
        isLoaded = true
    }

    private func save() {
        guard let companyID = store.currentCompanyID else {
            ToastService.shared.error("No active company.")
            return
        }
        // Start from the existing row (preserves id) so the upsert hits
        // the right database row instead of inserting a duplicate.
        var existing = store.workflowSetting(for: role)
        existing.companyID                    = companyID
        existing.roleKey                      = role.rawValue
        existing.approvalLimitAmount          = approvalLimit
        existing.canSelfApprove               = canSelfApprove
        existing.canCreateMaterialRequest     = canCreateMR
        existing.canApproveMaterialRequest    = canApproveMR
        existing.canSendToSupplier            = canSendToSupplier
        existing.canReceiveMaterials          = canReceiveMaterials
        existing.isActive                     = true
        store.upsertWorkflowSetting(existing)
        ToastService.shared.success("Saved \(role.displayName) limits.")
        dismiss()
    }
}
