# Phase 9 — Opportunity workType v1.1 migrations

**Status:** DRAFT — NOT APPLIED. Review before staging.

Locked spec: `~/.claude/.../memory/project_opportunity_worktype_v1_1.md` (Path A, 2026-05-12).
Build branch: `claude/opportunity-worktype-v1` (off v1.0.0 head `9a86696`).

## Release group

Single migration. No upstream / downstream dependencies for v1.1 — service-work and rental schemas are deferred to v1.2.

| File | Purpose | Depends on | Rollback |
|---|---|---|---|
| `WT1_crm_opportunities_work_type_column.sql` | Adds `work_type text NOT NULL DEFAULT 'project_work'` + CHECK constraint with 5 allowed values + filter index `crm_opportunities_company_work_type_idx`. Defensive backfill. No RLS changes. | `crm_opportunities` table | `alter table … drop column work_type` (script in file footer) |

## Deploy sequence

1. **Staging branch** — apply WT1; run the four verification queries listed at the bottom of the SQL file. Confirm:
   - column exists with `text NOT NULL` and default `'project_work'`
   - CHECK constraint count = 1
   - index count = 1
   - all existing live opps grouped by work_type return exactly one row: `project_work | <total>`
2. **Staging iOS build** — pull staging schema; verify the new field decodes correctly on existing opps + sets to `project_work` on push if not provided.
3. **Prod** — apply WT1 to prod. No downtime: the column is additive with a default, so existing queries are unaffected.

## What ships in the same branch (Swift side, no DB impact)

Once WT1 is approved, the following land as separate commits on `claude/opportunity-worktype-v1`:

1. `OpportunityWorkType` Swift enum (Codable, CaseIterable, displayName, icon, downstream-flow description string).
2. `CRMOpportunity.workType: OpportunityWorkType` field (default `.projectWork`).
3. `SyncEngineCRM` push/pull wiring (decode `work_type` from server, send on every upsert).
4. New Opportunity sheet picker (required, defaults to `.projectWork`).
5. Detail view: colored pill badge alongside Stage.
6. `CRMActivity.workTypeChanged` activity type + log emission on workType edits.
7. **Routing** — `CommercialContext.createFromOpportunity` branches on workType (separate commit, behavior change, smoke before merge).
8. Filter / report support — pipeline list filter + win-rate analytics segmented by workType.

Step 7 is the largest behavior change; the picker + pill + audit log can be reviewed and merged before routing if needed.

## Out of scope for WT1 (v1.2 candidates)

- **Service Work module** — proper work-order / recurring service entity with its own schema and lifecycle. v1.1 routes to project flow with `Project.serviceFlag` if that flag is added, otherwise to vanilla project flow.
- **Rental module** — equipment+customer rental records, return tracking, daily/weekly billing. v1.1 routes to project flow as fallback.
- **Backfill heuristics** — smart backfill that looks at downstream entities (e.g. MR/PO/Invoice patterns) to guess the correct workType for closed-out historical opps. v1.1 backfills all to `project_work` — manual cleanup post-deploy.

## Risks

- **Downstream routing edge cases.** Existing opportunities with linked estimates that get edited post-WT1 already follow the project flow; their `work_type = 'project_work'` will route them correctly. The risk is users picking `material_sales` on a new opp and the routing not finding the MaterialSale creation entry-point.
- **Reporting changes.** Pipeline filter by workType is a new dimension. Existing saved filters / dashboards aren't affected since they don't filter by workType.
- **Sync engine forward-compat.** Server might one day add a 6th workType value; the iOS enum decodes strictly. Mitigate by falling back to `.projectWork` on unknown values with a CrashReporter breadcrumb (same pattern as `UserRole` decode fallback in `BaseModel.swift`).
