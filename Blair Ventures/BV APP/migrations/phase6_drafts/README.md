# Phase 6 — Approval and Audit Standardization (drafts)

Per the [Aski IQ Major Issue Repair Plan](../../BV%20APP/DEVELOPER_ROADMAP.md), Phase 6 generalizes the procurement-only `workflow_settings` model into a project-wide approval engine and standardizes audit-trail behavior across commercial modules.

## State of the world entering Phase 6

**Already done (mostly):**
- `ApprovalQueueView` aggregates 6 approval sources (estimates, quotes, change orders, material requests, AI schedule recommendations, timesheets) into a unified inbox.
- `AppStore.approvalQueueCount` matches the queue view's filter set, so the dashboard badge stays consistent.
- Per-source role-gating helpers exist: `role.canApproveDomain(.materialRequest)`, `role.canApproveChangeOrder`, etc.
- Procurement uses the dynamic `workflow_settings` table (per-role amount tier) — admins can rebalance approval limits without code.
- `MaterialRequestAudit` table + trigger captures every MR status change automatically.

**Open gaps:**
- **Engine generalization.** Only procurement reads `workflow_settings`. Other modules use hardcoded role lists scattered across the codebase. Adding a new gated action means hunting for the right `if [.manager, .executive].contains(role)` to update.
- **Audit-log extension.** `MaterialRequestAudit` is the procurement-shaped pattern. Quotes have `quote_approvals`, estimates have `audit_snapshots`, but invoices / change orders / RFIs / contracts have ad-hoc or missing audit. No project-wide standard.
- **Override reasons.** Procurement captures reject + request-changes notes via `approvalNote`. Quote approvals capture `decision_note`. Other modules don't consistently capture *why* a decision was made — important for compliance / dispute resolution.

## Wave 1 — Engine generalization (this directory)

Migration draft: `WS1_workflow_settings_action_key.sql`.

### Schema change

```sql
alter table public.workflow_settings
add column if not exists action_key text not null default 'material_request.approve';

-- New unique scope: (company, role, action) instead of (company, role).
-- Allows the same role to have different limits for different actions
-- (e.g. project_manager can approve $10k MR but only $5k change orders).
alter table public.workflow_settings drop constraint if exists workflow_settings_company_role_unique;
alter table public.workflow_settings add constraint workflow_settings_company_role_action_unique
    unique (company_id, role_key, action_key);
```

### Action-key namespace

Module-prefixed, dot-separated, lowercase. The contract: any place in code that gates a user action checks `AppStore.canPerform(action: <key>, amount: <optional>)`. The engine reads the matching `workflow_settings` row for the user's role + that action_key.

| Action key | Replaces |
|---|---|
| `material_request.create` | `canCreateMaterialRequest` |
| `material_request.approve` | `canApproveMaterialRequest(amount:)` |
| `material_request.send_to_supplier` | `canSendToSupplier` |
| `material_request.receive` | `canReceiveMaterials` |
| `purchase_order.create` | (currently the same role list as MR) |
| `purchase_order.send` | `canSendToSupplier` |
| `purchase_order.receive` | `canReceiveMaterials` |
| `purchase_order.match_invoice` | (currently `[.officeAdmin,.manager,.executive]`) |
| `quote.approve` | `ApprovalAuthority.canApproveQuoteApproval` (multiple call-sites) |
| `quote.send` | `canSendQuote` |
| `quote.mark_accepted` | (currently hardcoded) |
| `estimate.review` | `internalReview` flow |
| `estimate.approve` | hardcoded |
| `invoice.send` | hardcoded |
| `invoice.void` | hardcoded |
| `change_order.approve` | `canApproveChangeOrder` |
| `schedule.edit` | hardcoded |
| `schedule.override_conflict` | `canOverrideConflict` |
| `schedule.approve_recommendation` | `canApproveScheduleRecommendation` |
| `timesheet.approve` | `canApproveTimesheets` |

### Wave-1 scope (this directory)

- ✅ Schema migration (`WS1`) — adds `action_key` column + new unique scope. Idempotent. Backfills existing rows to `'material_request.approve'`.
- ✅ Re-seed defaults to populate every (company, role, action_key) combo per the matrix above.
- ⏳ Swift `WorkflowSetting.actionKey: ActionKey` field + new `canPerform(action:amount:)` helper — **NOT** in this commit. Next wave.
- ⏳ Migration of existing helpers (`canApproveMaterialRequest`, etc.) to delegate to the generalized engine — **NOT** in this commit. Wave 3.
- ⏳ Audit-log extension to all commercial modules — **NOT** in this commit. Wave 4.
- ⏳ Override-reason capture audit + standardization — **NOT** in this commit. Wave 5.

The migration in this folder is **not yet applied to prod**. Apply only after the Swift `actionKey` field is added (otherwise the existing pull would fail with a missing field if the column is non-nullable). The default value on the column allows backwards compatibility — existing rows get `'material_request.approve'` automatically; client pulls deserialize cleanly.

## Apply order — Wave 1 → Wave 2 → Wave 3

1. Add Swift `actionKey` field with default value (no schema dependency).
2. Apply `WS1` migration to staging branch; verify pull works with new column.
3. Apply `WS1` to prod.
4. Add `canPerform(action:amount:)` helper.
5. Migrate procurement helpers to delegate (Wave 3).
6. Migrate other modules (Wave 3 cont.).

## What this doesn't change

- **Existing approval flows continue working** while migration is in progress. Default action_key on the column means pre-Wave-2 code paths keep reading the procurement-only rows.
- **Audit triggers stay per-table** for now. The standardization (Wave 4) generalizes `MaterialRequestAudit` into a per-module pattern.
- **The `ApprovalQueueView` UI doesn't change** in Wave 1. Wave 4+ may add per-module override-reason rendering, but the queue layout is fine.

## Why we're stopping at the migration draft for this commit

The full Phase 6 build is multi-day work (engine refactor + per-module migration + audit-log extension + override-reason capture). Shipping a draft migration + design doc lets you review the action_key namespace before any code commits to it. Adjustments to the namespace are cheap now; expensive once helpers across N modules call `canPerform("material_request.approve")` literally.
