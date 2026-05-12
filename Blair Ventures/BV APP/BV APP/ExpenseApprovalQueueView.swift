// ExpenseApprovalQueueView.swift
// Phase 9 / Expenses v1.1 — shared approval queue
//
// One queue per company, visible to every eligible approver. First
// to approve/reject wins; the row's state flips to terminal and
// all other approvers see the locked decision via the standard
// expenses sync cycle.
//
// Flags surface inline (Missing Receipt / Over $250 / Over $5K /
// Possible Duplicate / Reimbursement / On-Behalf-Of) so the
// approver doesn't have to drill in to decide.

import SwiftUI
import Combine

struct ExpenseApprovalQueueView: View {
    @EnvironmentObject var store: AppStore

    @State private var rejectingExpense: Expense? = nil
    @State private var rejectionReason: String = ""
    @State private var errorMessage: String? = nil
    @State private var filterMineOnly: Bool = false

    private var pending: [Expense] {
        store.expenses
            .filter { $0.approvalState == .pendingApproval && !$0.isDeleted }
            .filter { e in
                if !filterMineOnly { return true }
                // "Mine" = expenses I CAN approve (not just any pending)
                return ExpenseApprovalService.canApprove(
                    expense: e,
                    approverRole: store.currentUserRole,
                    approverID: store.currentUser?.id
                )
            }
            .sorted { $0.amount > $1.amount }
    }

    private var totalPending: Decimal {
        pending.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pending Approval").font(.caption).foregroundColor(.secondary)
                    Text(totalPending.currencyString)
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                Picker("Filter", selection: $filterMineOnly) {
                    Text("All").tag(false)
                    Text("I Can Approve").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))

            if pending.isEmpty {
                ContentUnavailableView(
                    "Nothing waiting",
                    systemImage: "checkmark.seal.fill",
                    description: Text(filterMineOnly
                        ? "No expenses currently need your approval."
                        : "No expenses are pending approval.")
                )
            } else {
                List {
                    ForEach(pending) { expense in
                        ExpenseApprovalRow(
                            expense: expense,
                            canAct: ExpenseApprovalService.canApprove(
                                expense: expense,
                                approverRole: store.currentUserRole,
                                approverID: store.currentUser?.id
                            ),
                            onApprove: { approve(expense) },
                            onReject:  { rejectingExpense = expense; rejectionReason = "" }
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Approvals")
        .alert("Rejection reason required", isPresented: Binding(
            get: { rejectingExpense != nil },
            set: { if !$0 { rejectingExpense = nil } }
        )) {
            TextField("Why is this being rejected?", text: $rejectionReason)
                .textInputAutocapitalization(.sentences)
            Button("Cancel", role: .cancel) { rejectingExpense = nil }
            Button("Reject", role: .destructive) {
                if let exp = rejectingExpense { reject(exp, reason: rejectionReason) }
                rejectingExpense = nil
            }
            .disabled(rejectionReason.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("This message goes back to the submitter and is recorded on the expense audit log.")
        }
        .alert(
            "Action failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            actions: { Button("OK") { errorMessage = nil } },
            message: { Text(errorMessage ?? "") }
        )
    }

    // MARK: Actions

    private func currentApprover() -> Employee? {
        guard let uid = store.currentUser?.id else { return nil }
        return store.employees.first(where: { $0.id == uid })
    }

    private func approve(_ expense: Expense) {
        guard let approver = currentApprover() else {
            errorMessage = "Could not identify the current user."
            return
        }
        do {
            let updated = try ExpenseApprovalService.approve(
                expense, by: approver, approverRole: store.currentUserRole
            )
            store.upsertExpense(updated)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func reject(_ expense: Expense, reason: String) {
        guard let approver = currentApprover() else {
            errorMessage = "Could not identify the current user."
            return
        }
        do {
            let updated = try ExpenseApprovalService.reject(
                expense, by: approver, approverRole: store.currentUserRole, reason: reason
            )
            store.upsertExpense(updated)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Approval Row

private struct ExpenseApprovalRow: View {
    @EnvironmentObject var store: AppStore
    let expense: Expense
    let canAct: Bool
    let onApprove: () -> Void
    let onReject:  () -> Void

    private var attachments: [ExpenseAttachment] {
        store.expenseAttachments.filter { $0.expenseID == expense.id && !$0.isDeleted }
    }

    private var flags: Set<ExpenseFlag> {
        expense.flags(attachments: attachments)
    }

    private var ownerName: String {
        guard let id = expense.expenseOwnerEmployeeID,
              let emp = store.employees.first(where: { $0.id == id }) else {
            return "Unknown"
        }
        return emp.fullName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(expense.vendor.isEmpty ? "(no vendor)" : expense.vendor)
                        .font(.subheadline.weight(.semibold))
                    Text("\(ownerName) · \(expense.expenseDate.shortDate)")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Text(expense.amount.currencyString)
                    .font(.subheadline.weight(.semibold))
            }

            if !flags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(flags), id: \.self) { f in
                            Label(f.displayName, systemImage: f.icon)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(flagColor(f).opacity(0.15))
                                .foregroundColor(flagColor(f))
                                .cornerRadius(5)
                        }
                    }
                }
            }

            if !canAct {
                Text("You can't approve this one (self-approval or insufficient role).")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 10) {
                    Button(role: .destructive, action: onReject) {
                        Label("Reject", systemImage: "xmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button(action: onApprove) {
                        Label("Approve", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func flagColor(_ f: ExpenseFlag) -> Color {
        switch f {
        case .overUpperThreshold:    return .red
        case .missingReceipt,
             .possibleDuplicate:     return .orange
        case .overLowerThreshold:    return .blue
        case .employeeReimbursement: return .purple
        case .submittedOnBehalfOf:   return .gray
        }
    }
}
