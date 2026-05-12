# Opportunity workType v1.1 — routing classification

Adds the `workType` classification dimension to `CRMOpportunity` and wires it through schema → sync → UI → routing → reports. **5 commits.** Implements the locked Path A spec (`project_opportunity_worktype_v1_1.md`).

## Summary

When creating a New Opportunity, users now pick **how this work monetizes**: Project Work / Service Work / Material Sale / Rental / Direct Invoice. This is distinct from `serviceType` (the trade — Scaffolding, Insulation, etc.) and from `OpportunityType` on Estimate (how the work came in — RFQ vs Negotiated).

The picker drives downstream routing: Material Sale opps surface a "Tap New Material Sale below" hint instead of the Create Estimate button; Direct Invoice opps surface a v1.2-deferral note; Project / Service / Rental opps continue through the estimate flow (Service + Rental fall back to project flow per spec until their dedicated modules ship in v1.2).

## Migrations applied to staging + prod (2026-05-12)

- **WT1** — adds `crm_opportunities.work_type text NOT NULL DEFAULT 'project_work'` + CHECK constraint + filter index. All 62 existing prod opportunities backfilled to `project_work` ✅.
- **WT1a** — aligned the CHECK constraint to use `'material_sale'` (singular, matching the existing `SaleType` enum) instead of `'material_sales'` (plural draft). Zero rows carried the plural value at switch time.

## What's in here

| Commit | Scope |
|---|---|
| `d6a2871` | WT1 migration draft + README (release-group v1.1 phase9_worktype) |
| `42a0869` | Swift OpportunityWorkType enum + CRMOpportunity.workType field + sync engine push/pull + New Opportunity picker + Detail-view badge + edit row + workTypeChanged audit log |
| `157371d` | Refactor: delete duplicate OpportunityWorkType, unify on existing `SaleType` (single source of truth shared with CommercialContext) + WT1a migration file documenting the constraint alignment |
| `97f4796` | Routing: gate Create Estimate / Quick Quote buttons by workType; conversion-hint rows for Material Sale + Direct Invoice; propagate opp.workType into CommercialContext.from(opportunity:) instead of hardcoding .projectWork |
| `89ce9b9` | Pipeline by Work Type report card in CRMReportsView — value + count per SaleType, sorted by value, color-coded per SaleType.color |

## v1.1 routing rules (locked spec)

| Work Type | Conversion path |
|---|---|
| Project Work | Opportunity → Estimate → Quote → Project → Progress Invoices |
| Service Work | falls back to project flow in v1.1; dedicated work-order module in v1.2 |
| Material Sale | Opportunity → MaterialSale (existing module) → Quote/Order/Invoice |
| Rental | falls back to project flow in v1.1; dedicated rental module in v1.2 |
| Direct Invoice | manual workaround in v1.1 (use Invoices tab); direct-invoice flow in v1.2 |

## Test plan

- [x] iOS simulator build green (iPhone 17 / iOS 26.4.1)
- [x] Mac Catalyst build green
- [x] 58 unit tests pass
- [x] Staging WT1 + WT1a applied + verified (column / check / index / distribution queries)
- [x] Prod WT1 + WT1a applied + verified (42 active + 20 deleted opps all backfilled to `project_work`)
- [ ] Manual smoke — iPhone: create one opp of each work type; verify picker writes correct enum string; verify routing buttons match the work type
- [ ] Manual smoke — iPad: same surface, verify picker + badge layout
- [ ] Manual smoke — pre-existing opportunities: open one created before WT1, verify it loads with workType = Project Work and behaves identically
- [ ] Manual smoke — switch an opp's workType from Project to Material Sale on the detail edit view; verify the workTypeChanged activity appears in history

## Deferred to v1.2

- Pipeline list filter chip (workType filter on `CRMPipelineView` summary bar — bigger surface area, deferred to keep v1.1 tight)
- Win-rate-by-workType report card (needs won/lost slicing logic)
- Dedicated Service Work module (work-order entity + recurring schedule)
- Dedicated Rental module (rental record + return tracking + daily/weekly billing)
- Direct-invoice creation flow from opportunity (Invoices tab + auto-link)

## Rollback

WT1 + WT1a are additive. Rollback SQL is in the file footers:
```sql
drop index public.crm_opportunities_company_work_type_idx;
alter table public.crm_opportunities drop constraint crm_opportunities_work_type_check;
alter table public.crm_opportunities drop column work_type;
```

Existing iOS clients without the workType field decode the column-default `project_work` value safely; pre-WT1 clients ignore it.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
