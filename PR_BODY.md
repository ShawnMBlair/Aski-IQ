# Expenses v1.1 — capture, approval queue, PDF report

Implements the locked Expenses v1 spec (`project_expenses_v1_spec.md`, Path-confirmed 2026-05-11). **4 commits** on top of post-workType main. Adds full schema, sync engine, capture UI, approval queue, approval state machine, audit log integration, and an audit-binder-style PDF report.

## Summary

Field workers, Office Staff, and managers now have a complete expense workflow:

- **Capture** — vendor + date + amount + category + paid-by + cost destination (Company / Project / Material Request) + photo receipt — all in a single sheet. Auto-approval path for company-card spends ≤ $250 with no flags; everything else lands in Pending Approval.
- **Approve** — shared first-to-approve-wins queue. Inline flag chips (Missing Receipt / Over $250 / Over $5K / Reimbursement / On-Behalf-Of) make decisions fast. Self-approval blocked at the DB and the service layer.
- **Report** — generate a PDF with the charge table up front and receipt images appended as separate pages (audit-binder style). Share via UIActivityViewController — Files, Mail, AirDrop, Print.

## Migrations applied to staging + prod (2026-05-12)

- **EXP1** — `expenses` table: 43 columns, 8 CHECK constraints (single-destination, reimbursement-consistency, no-self-approval, plus column-level enums), 7 indexes (PK + per-company unique on expense_number + 5 partial filter indexes for approval / reimbursement / project / MR / owner queues), 4 RLS policies, `updated_at` trigger.
- **EXP2** — `expense_attachments` table: 20 columns, `expense_id` FK with `ON DELETE CASCADE`, bytea inline binary, 4 RLS policies.
- Zero advisor diff after apply (no new RLS-no-policy, no new function-search-path-mutable).

## Commits

| SHA | Scope |
|---|---|
| `0321f1c` | `AppStore.expenses` + `AppStore.expenseAttachments` published properties, `SupabaseTable.expenses` + `SupabaseTable.expenseAttachments` constants, `MultiCompany.resetTenantCaches()` clears them on swap, `SyncEngineExpenses.swift` pull + push for both tables with `recordSyncError` / `clearSyncError` on each catch, slotted into `pullAll()` and `pushPending()` |
| `5f3d013` | `ExpenseViews.swift` — `ExpenseListView` (filter chips, search, summary bar, +button), `ExpenseCreateEditView` (single-form capture with photos-picker), `ExpenseDetailView`, `ApprovalStateBadge` + `ExpenseRow` helpers, `AppStore.upsertExpense` / `upsertExpenseAttachment` helpers, EXP1/EXP2 SQL files marked APPLIED |
| `0d8c9af` | `ExpenseApprovalService.swift` (typed errors, eligibility checks gating role + self-approval + tier ladder), `ExpenseApprovalQueueView.swift` (shared queue, "All / I Can Approve" filter, inline flag chips, rejection-reason alert, big approve/reject buttons), RootView More-tab gains "Expenses" + "Expense Approvals" entries with pending-count badges |
| `5f3548e` | `ExpensePDFRenderer.swift` — cover page + charge table with header redraw on page break + totals row + receipt appendix (PDFKit for native PDFs, UIImage.draw for images), Share PDF action wired into Detail view ⋯ menu |

## v1.1 locked rules (from spec)

| Rule | Enforced where |
|---|---|
| Self-approval blocked regardless of role | DB CHECK `expenses_no_self_approval_check` + `ExpenseApprovalService.canApprove` |
| Single cost destination per expense | DB CHECK `expenses_single_destination_check` |
| Reimbursable iff personal-paid | DB CHECK `expenses_reimbursement_consistency_check` |
| < $250 company-card auto-approves if no flags | `Expense.qualifiesForAutoApproval(attachments:)` |
| Reimbursements always require approval | `ExpenseCreateEditView.save` forces `.pendingApproval` when reimbursable |
| > $5K needs Admin/Executive | `ExpenseApprovalService.canApprove` role gate |
| Rejection requires a reason | UI alert + service `ExpenseApprovalError.missingRejectionReason` |
| Submitted-on-behalf-of tracked across 4 fields | `Expense.createdBy`, `submittedBy`, `expenseOwnerEmployeeID`, `submittedOnBehalfOf` (DB + Swift) |

## Test plan

- [x] iOS simulator build green (iPhone 17 / iOS 26.4.1)
- [x] Mac Catalyst build green
- [x] 58 unit tests pass (no regressions)
- [x] EXP1 + EXP2 verified on staging + prod (43 + 20 columns, 4 + 4 RLS policies, RLS enabled both)
- [ ] Manual smoke — iPad: capture a receipt with company card under $250 → expect `.autoApproved` on save
- [ ] Manual smoke — iPad: capture a personal-paid receipt for any amount → expect `.pendingApproval`
- [ ] Manual smoke — iPhone: switch user to non-approver role → submit → second device approver-role taps Approve → first device sees `.approved`
- [ ] Manual smoke — Mac Catalyst: open ⋯ → Share PDF Report → save to Files → verify charge table + receipt appendix
- [ ] Manual smoke — switch companies on Multi-Company switcher → Expenses tab is empty (no cross-tenant leak)

## Deferred to v1.2 / external dependencies

- **CSV export** — schema depends on Helen's answer (Sage / QuickBooks / Xero / other). Code path is a follow-up commit.
- **Batched-per-employee PDF** — current PDF is on-demand single-expense. Multi-expense bulk action on the list view ships as a v1.2 follow-up.
- **Direct camera attach** — current capture uses PhotosPicker (library) only. Mirroring the DJR / Cert camera pattern is a v1.2 add.
- **Monotonic `BV-EXP-2026-####` numbering** — v1.1 uses a placeholder format; proper `NumberGenerationService` extension with the EXP prefix is a small follow-up.

## Rollback

Both EXP1 + EXP2 are isolated additive tables — `drop table public.expense_attachments` then `drop table public.expenses cascade` removes everything cleanly.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
