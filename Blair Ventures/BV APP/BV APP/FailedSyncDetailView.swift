// FailedSyncDetailView.swift
// Aski IQ — Per-record drill-down for sync failures (Phase 9 audit fix).
//
// PRE-FIX
// `FailedSyncBanner` showed "N items failed to sync" with two
// blunt-instrument buttons: Retry All / Discard All. The 2026-04
// audit flagged this as the only "offline conflict resolution" UI
// in the entire app — operators had no visibility into WHICH
// records failed or WHY.
//
// THIS VIEW
//   * Lists every failed record across all collections, grouped by
//     entity type with a count badge.
//   * Each row shows the record's display name + identifier.
//   * Per-row actions: Retry (flip to .pending and push) or Discard.
//   * "Retry All" and "Discard All" preserved at the section level.
//
// WHAT IT DOESN'T DO
// True 3-way merge (local vs. server vs. ancestor) is the next
// step but requires the server to expose a concurrent-edit detector.
// For now the failure surface is the conflict surface — most failed
// pushes are RLS / FK violations, not conflicting edits.

import SwiftUI

struct FailedSyncDetailView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var isRetrying = false
    @State private var showDiscardAllConfirm = false

    /// Snapshot of failed items grouped for display. Computed once on
    /// each render so we don't have to mutate state to filter.
    private var groups: [FailedGroup] {
        var out: [FailedGroup] = []

        // Generic over any element type. We don't require BaseModel
        // because Client doesn't conform — instead the caller supplies
        // a `syncStatus` accessor closure so we can filter for .failed
        // rows. Same closure approach for `id` + `label`.
        func add<T>(_ collection: [T],
                    typeName: String,
                    label: (T) -> String,
                    id: (T) -> UUID,
                    syncStatus: (T) -> SyncStatus,
                    onRetry: @escaping (UUID) -> Void,
                    onDiscard: @escaping (UUID) -> Void)
        {
            let rows = collection
                .filter { syncStatus($0) == .failed }
                .map { item in
                    FailedRow(
                        id:      id(item),
                        label:   label(item),
                        retry:   onRetry,
                        discard: onDiscard
                    )
                }
            if !rows.isEmpty {
                out.append(FailedGroup(typeName: typeName, rows: rows))
            }
        }

        add(store.projects, typeName: "Projects",
            label: { $0.name }, id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.projects),
            onDiscard: discard(\.projects))
        add(store.employees, typeName: "Employees",
            label: { $0.fullName }, id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.employees),
            onDiscard: discard(\.employees))
        add(store.crews, typeName: "Crews",
            label: { $0.name }, id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.crews),
            onDiscard: discard(\.crews))
        add(store.scheduleEntries, typeName: "Schedule Entries",
            label: { entry in
                let proj = store.projects.first(where: { $0.id == entry.projectID })?.name ?? "Unknown"
                return "\(proj) · \(entry.date.shortDate)"
            },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.scheduleEntries),
            onDiscard: discard(\.scheduleEntries))
        add(store.timesheetEntries, typeName: "Timesheets",
            label: { ts in
                let emp = store.employees.first(where: { $0.id == ts.employeeID })?.fullName ?? "Unknown"
                return "\(emp) · \(ts.date.shortDate) · \(ts.totalHours)h"
            },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.timesheetEntries),
            onDiscard: discard(\.timesheetEntries))
        add(store.invoices, typeName: "Invoices",
            label: { inv in "\(inv.invoiceNumber) · \(inv.total.currencyString)" },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.invoices),
            onDiscard: discard(\.invoices))
        add(store.estimates, typeName: "Estimates",
            label: { "\($0.jobNumber) · \($0.name)" },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.estimates),
            onDiscard: discard(\.estimates))
        add(store.materialSales, typeName: "Material Sales",
            label: { "\($0.saleNumber) · \($0.grandTotal.currencyString)" },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.materialSales),
            onDiscard: discard(\.materialSales))
        // Client doesn't conform to BaseModel but exposes the same
        // syncStatus shape — reaching it through the closure keeps
        // the helper generic without dragging in protocol gymnastics.
        add(store.clients, typeName: "Clients",
            label: { $0.name },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retryClient,
            onDiscard: discardClient)
        add(store.contracts, typeName: "Contracts",
            label: { c in c.contractNumber.map { "\($0) · \(c.title)" } ?? c.title },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.contracts),
            onDiscard: discard(\.contracts))
        add(store.changeOrders, typeName: "Change Orders",
            label: { co in
                let proj = store.projects.first(where: { $0.id == co.projectID })?.name ?? "Project"
                return "\(co.number) · \(proj)"
            },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.changeOrders),
            onDiscard: discard(\.changeOrders))

        // 2026-04 re-audit fix #7: extend the drill-in to the 16
        // collection types that were previously invisible. Operators
        // can now see failed pushes on quotes, RFIs, sub-contractors,
        // procurement, contract clauses/milestones/compliance/waivers,
        // workflow, and all CRM entities.

        add(store.quotes, typeName: "Quotes",
            label: { q in "\(q.jobNumber) · \(q.clientName)" },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.quotes),
            onDiscard: discard(\.quotes))

        add(store.rfis, typeName: "RFIs",
            label: { r in "\(r.number) · \(r.title)" },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.rfis),
            onDiscard: discard(\.rfis))

        add(store.subcontractors, typeName: "Subcontractors",
            label: { s in s.companyName },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.subcontractors),
            onDiscard: discard(\.subcontractors))

        add(store.subContracts, typeName: "Sub-Contracts",
            label: { sc in
                let sub = store.subcontractors.first(where: { $0.id == sc.subcontractorID })?.companyName ?? "Subcontractor"
                return "\(sc.contractNumber) · \(sub)"
            },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.subContracts),
            onDiscard: discard(\.subContracts))

        add(store.projectBudgets, typeName: "Project Budgets",
            label: { pb in
                let proj = store.projects.first(where: { $0.id == pb.projectID })?.name ?? "Project"
                return "\(proj) · \(pb.lines.count) lines"
            },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.projectBudgets),
            onDiscard: discard(\.projectBudgets))

        add(store.incidents, typeName: "Incidents",
            label: { inc in
                let proj = store.projects.first(where: { $0.id == inc.projectID })?.name ?? "Project"
                return "\(inc.severity.rawValue.capitalized) · \(proj)"
            },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.incidents),
            onDiscard: discard(\.incidents))

        add(store.equipment, typeName: "Equipment",
            label: { e in e.name },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.equipment),
            onDiscard: discard(\.equipment))

        // Procurement
        add(store.suppliers, typeName: "Suppliers",
            label: { s in s.name },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.suppliers),
            onDiscard: discard(\.suppliers))

        add(store.purchaseOrders, typeName: "Purchase Orders",
            label: { po in
                let supp = store.suppliers.first(where: { $0.id == po.supplierID })?.name ?? "Supplier"
                return "\(po.poNumber) · \(supp)"
            },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.purchaseOrders),
            onDiscard: discard(\.purchaseOrders))

        add(store.materialRequests, typeName: "Material Requests",
            label: { mr in
                let proj = store.projects.first(where: { $0.id == mr.projectID })?.name ?? "Project"
                return "\(mr.requestNumber) · \(proj)"
            },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.materialRequests),
            onDiscard: discard(\.materialRequests))

        // Contracts module (parent already covered above; cover children)
        add(store.contractClauses, typeName: "Contract Clauses",
            label: { cc in
                let title = cc.title?.isEmpty == false ? cc.title! : cc.clauseKind.rawValue
                return title
            },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.contractClauses),
            onDiscard: discard(\.contractClauses))

        add(store.contractMilestones, typeName: "Contract Milestones",
            label: { cm in
                "\(cm.title) · \(cm.milestoneDate.shortDate)"
            },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.contractMilestones),
            onDiscard: discard(\.contractMilestones))

        add(store.complianceDocuments, typeName: "Compliance Documents",
            label: { cd in cd.title },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.complianceDocuments),
            onDiscard: discard(\.complianceDocuments))

        add(store.lienWaivers, typeName: "Lien Waivers",
            label: { lw in
                "\(lw.waiverType.displayName) · \(lw.waiverFromName)"
            },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.lienWaivers),
            onDiscard: discard(\.lienWaivers))

        // Workflow automation (synced 2026-04 audit)
        add(store.workflowRules, typeName: "Workflow Rules",
            label: { r in r.name },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.workflowRules),
            onDiscard: discard(\.workflowRules))

        add(store.workflowLog, typeName: "Workflow Log",
            label: { e in "\(e.ruleName) · \(e.title)" },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.workflowLog),
            onDiscard: discard(\.workflowLog))

        // CRM (gated by canViewCRM at sync time, but admins should
        // still see the failure surface even if their role can't
        // CREATE — the failed row may be from a different user).
        add(store.crmContacts, typeName: "CRM Contacts",
            label: { c in c.fullName.isEmpty ? "Contact" : c.fullName },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.crmContacts),
            onDiscard: discard(\.crmContacts))

        add(store.crmOpportunities, typeName: "CRM Opportunities",
            label: { o in o.title },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.crmOpportunities),
            onDiscard: discard(\.crmOpportunities))

        add(store.crmTasks, typeName: "CRM Tasks",
            label: { t in t.title },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.crmTasks),
            onDiscard: discard(\.crmTasks))

        add(store.crmActivities, typeName: "CRM Activities",
            label: { a in a.title },
            id: { $0.id }, syncStatus: { $0.syncStatus },
            onRetry: retry(\.crmActivities),
            onDiscard: discard(\.crmActivities))

        return out
    }

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
                    ContentUnavailableView(
                        "All synced",
                        systemImage: "checkmark.seal.fill",
                        description: Text("No records are stuck. Pull-to-refresh on any list to confirm.")
                    )
                } else {
                    List {
                        Section {
                            Text("These records couldn't push to the server. Most failures are RLS rejections (wrong role) or foreign-key violations (parent record missing). Retry to try again, or discard to remove from this device — discarded records are NOT on the server and can't be recovered.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        ForEach(groups) { group in
                            Section {
                                ForEach(group.rows) { row in
                                    rowView(row)
                                }
                            } header: {
                                HStack {
                                    Text(group.typeName)
                                    Spacer()
                                    Text("\(group.rows.count)")
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Color.red.opacity(0.15))
                                        .foregroundColor(.red)
                                        .clipShape(Capsule())
                                        .font(.caption.weight(.semibold))
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Failed Syncs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !groups.isEmpty {
                        Menu {
                            Button {
                                Task { @MainActor in
                                    isRetrying = true
                                    await store.retryFailedSyncs()
                                    isRetrying = false
                                }
                            } label: {
                                Label(isRetrying ? "Retrying…" : "Retry all", systemImage: "arrow.clockwise")
                            }
                            Button(role: .destructive) {
                                showDiscardAllConfirm = true
                            } label: {
                                Label("Discard all", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .alert("Discard all failed records?",
                   isPresented: $showDiscardAllConfirm) {
                Button("Discard", role: .destructive) {
                    store.discardFailedSyncs()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("These records aren't on the server. Discarding deletes them from this device permanently.")
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: FailedRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.label).font(.subheadline)
            Text("ID \(row.id.uuidString.prefix(8))…")
                .font(.caption2)
                .fontDesign(.monospaced)
                .foregroundColor(.secondary)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                row.discard(row.id)
            } label: {
                Label("Discard", systemImage: "trash")
            }
            Button {
                row.retry(row.id)
                Task { await store.retryFailedSyncs() }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .tint(.blue)
        }
    }

    // MARK: - Per-collection retry/discard helpers

    /// Returns a closure that flips one record's syncStatus from
    /// `.failed` back to `.pending`. Constrained to `Syncable` so we
    /// don't have to require the heavier BaseModel — many of our
    /// models (Client, RFI, Supplier, contract clauses, CRM
    /// entities, etc.) carry `id` + `syncStatus` without conforming
    /// to BaseModel. The retroactive `Syncable` conformances are at
    /// the bottom of this file.
    private func retry<T: Syncable>(
        _ kp: ReferenceWritableKeyPath<AppStore, [T]>
    ) -> (UUID) -> Void {
        { id in
            if let i = store[keyPath: kp].firstIndex(where: { $0.id == id }) {
                store[keyPath: kp][i].syncStatus = .pending
            }
        }
    }

    /// Returns a closure that hard-removes one failed record from
    /// the local collection. Same protocol constraint as `retry`.
    private func discard<T: Syncable>(
        _ kp: ReferenceWritableKeyPath<AppStore, [T]>
    ) -> (UUID) -> Void {
        { id in
            store[keyPath: kp].removeAll { $0.id == id && $0.syncStatus == .failed }
        }
    }

    // MARK: Client-specific helpers
    //
    // Client carries a syncStatus field but doesn't conform to
    // BaseModel, so the generic helpers above don't accept its
    // keypath. These are the explicit per-collection equivalents.
    private func retryClient(_ id: UUID) {
        if let i = store.clients.firstIndex(where: { $0.id == id }) {
            store.clients[i].syncStatus = .pending
        }
    }

    private func discardClient(_ id: UUID) {
        store.clients.removeAll { $0.id == id && $0.syncStatus == .failed }
    }
}

// MARK: - Display models

private struct FailedGroup: Identifiable {
    var id: String { typeName }
    let typeName: String
    let rows:     [FailedRow]
}

private struct FailedRow: Identifiable {
    let id:      UUID
    let label:   String
    let retry:   (UUID) -> Void
    let discard: (UUID) -> Void
}

// MARK: - Syncable protocol
//
// Lighter than `BaseModel`. Just `Identifiable<UUID>` + a mutable `syncStatus`.
// Used by the generic `retry` / `discard` keypath helpers above so we
// can extend the failed-sync drill-in across collections whose models
// don't formally adopt `BaseModel` (Client, RFI, Supplier, contract
// children, CRM entities, etc.). All retroactive conformances live
// here so adding a new type to the drill-in requires changing exactly
// one file.

protocol Syncable: Identifiable where ID == UUID {
    var syncStatus: SyncStatus { get set }
}

// BaseModel-conforming types get Syncable for free.
extension Project:           Syncable {}
extension Employee:          Syncable {}
extension Crew:              Syncable {}
extension ScheduleEntry:     Syncable {}
extension TimesheetEntry:    Syncable {}
extension Invoice:           Syncable {}
extension Estimate:          Syncable {}
extension MaterialSale:      Syncable {}
extension Contract:          Syncable {}
extension ChangeOrder:       Syncable {}
extension Quote:             Syncable {}

// Non-BaseModel types — these structs carry id + syncStatus but
// don't formally conform to BaseModel. Conforming them to Syncable
// here in one file keeps the conformance footprint narrow.
extension Client:            Syncable {}
extension RFI:               Syncable {}
extension Subcontractor:     Syncable {}
extension SubContract:       Syncable {}
extension ProjectBudget:     Syncable {}
extension Incident:          Syncable {}
extension Equipment:         Syncable {}
extension Supplier:          Syncable {}
extension PurchaseOrder:     Syncable {}
extension MaterialRequest:   Syncable {}
extension ContractClause:    Syncable {}
extension ContractMilestone: Syncable {}
extension ComplianceDocument: Syncable {}
extension LienWaiver:        Syncable {}
extension WorkflowRule:      Syncable {}
extension WorkflowLogEntry:  Syncable {}
extension CRMContact:        Syncable {}
extension CRMOpportunity:    Syncable {}
extension CRMTask:           Syncable {}
extension CRMActivity:       Syncable {}
