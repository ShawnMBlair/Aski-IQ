# Phase 7 — Orphan-Record Prevention Audit

**Date:** 2026-05-10
**Scope:** Every commercial / operational entity creation entry point in the iOS app
**Goal:** Catalog where users can create records *without* their required parent context, recommend gating

## Summary

The Aski IQ data layer is robust against orphan records:
- **DB-level:** FK constraints + NOT NULL on `company_id` / `opportunity_id` (per Phase 4) reject any push that lacks parent context
- **Sync-level:** First-launch sync gate (Phase 2) prevents create-before-pull across 9 commercial views
- **DB-level CHECK constraints** (per `commercial_integrity_check_constraints` migration): material_requests must have either `project_id` OR `material_sales_id` per `destination_type`

But the **UX layer can still ALLOW the user to start a creation flow before they have the parent context.** Each entry point's gating posture is documented below. "Free-floating" creates are the targets for design intervention — should the entry point be hidden, disabled, or pre-filled?

## Audit table — commercial documents

| Entity | Entry point | Current gating | Required parents (per FK / CHECK) | Recommendation |
|---|---|---|---|---|
| **Quote** | `QuoteListView` (`QuoteViews.swift:523`) | First-sync gate ✅ • role check ✅ • **does NOT pre-require client/opportunity** | `company_id` (NOT NULL FK), `opportunity_id` (NOT NULL FK on prod) | Empty-state copy says "Create a quote from an existing estimate" but the toolbar `+` opens `QuoteCreateView` with no estimate/client picker prerequisite. Recommend: hide top-level `+` and require entry from Estimate or Opportunity. |
| **Quote** | `QuoteCreateView` (`QuoteViews.swift:2060`) | Has `selectedEstimateID` state; user picks inside form | (same) | If we keep top-level entry, force estimate selection FIRST, then derive client/opportunity. |
| **Estimate** | `EstimateListView` (`EstimateViews.swift:12`) | First-sync gate ✅ • role check ✅ • **does NOT pre-require opportunity** | `company_id`, `opportunity_id` (NOT NULL on prod) | Same as Quote — top-level `+` lets user start an Estimate that has no parent Opportunity. Recommend: require Opportunity selection or hide entry. |
| **Estimate** | `CRMOpportunityDetailView.showCreateEstimate` (`CRMOpportunityViews.swift:958`) | Started from an Opportunity | (same) | ✅ Already gated correctly — Opportunity is the parent. |
| **Estimate** | `ClientDetailView.showNewEstimate` (`ClientViews.swift:457`) | Started from a Client | (same) | ⚠️ Client is the parent, but Opportunity is required by the FK. Need to either auto-create an Opportunity or surface picker. |
| **Estimate** | `SiteDetailView.showNewEstimate` (`SiteDetailView.swift:15`) | Started from a Site | (same) | ⚠️ Same issue — Site doesn't satisfy `opportunity_id` FK. |
| **Invoice** | `InvoiceListView` (`InvoiceViews.swift:12`) | First-sync gate ✅ • role check ✅ • **does NOT pre-require quote/project/client** | `company_id`, `opportunity_id` (NOT NULL on prod) | Top-level `+` allows free-floating invoice. Recommend: route through Quote → "Create Invoice" or Project → "Bill Now". |
| **Invoice** | `InvoiceListView` (`InvoiceViews.swift:1421`) | (second list view, likely Project-scoped) | (same) | ✅ Project-scoped path is correctly gated. |
| **Change Order** | `ChangeOrderListView` (`ChangeOrderViews.swift:15`) | First-sync gate ✅ • role check ✅ • **does NOT pre-require project** | `company_id`, `project_id` (NOT NULL FK), `opportunity_id` (NOT NULL on prod) | Top-level `+` allows free-floating CO. Recommend: require Project selection or surface from Project Detail. |
| **RFI** | `RFIListView` (`RFIViews.swift:13`) | First-sync gate ✅ • role check ✅ • **does NOT pre-require project** | `company_id`, `project_id` (NOT NULL FK) | Same as CO. |
| **Material Request** | `ProcurementHubView` (`ProcurementViews.swift:497`) | First-sync gate ✅ + canPerform engine ✅ | `company_id`, `opportunity_id` (NOT NULL on prod), CHECK constraint enforces destination_type/project_id/material_sales_id valid combos | ⚠️ Top-level `+` opens MaterialRequestEditorView. The view likely lets user pick destination_type but doesn't gate on having a project OR material_sale selected. Worth checking that the Save button is disabled until the constraint is satisfied. |
| **Purchase Order** | `ProcurementHubView` "Create PO" (`ProcurementViews.swift:654`) | (Inside MR detail view, after MR is approved) | `company_id`, `project_id`, `material_request_id` (FK target), `opportunity_id` | ✅ Already gated correctly — PO originates from approved MR. |
| **Contract** | `ContractListView` (`ContractViews.swift:31`) | First-sync gate ✅ • role check ✅ • **does NOT pre-require client/project** | `company_id`, `client_id` (NOT NULL FK), optionally `project_id` | Top-level `+` allows free-floating contract. Recommend: require Client selection. |
| **Sub-Contract** | `SubcontractorListView` (`ProcurementViews.swift:2841`) | First-sync gate ✅ • role check ✅ • **does NOT pre-require parent contract** | `company_id`, `subcontractor_id`, `project_id` (NOT NULL FK), optionally `linked_contract_id` | Top-level `+` allows free-floating sub-contract. Recommend: surface from Subcontractor Detail or Project. |
| **Material Sale** | `MaterialSaleListView` (`MaterialSaleViews.swift:13`) | First-sync gate ✅ • role check ✅ • **does NOT pre-require client/opportunity** | `company_id`, `client_id` (NOT NULL FK), `opportunity_id` (NOT NULL on prod) | Top-level `+` allows free-floating material sale. Recommend: require Opportunity selection. |
| **Daily Job Report** | `DailyJobReportListView` (`DailyJobReportViews.swift:13`) | (inside ProjectDetail; project context is implicit) | `company_id`, `project_id` | ✅ Project-embedded — already gated. |

## Audit table — operational entities

| Entity | Entry point | Current gating | Recommendation |
|---|---|---|---|
| **Schedule Entry** | `ScheduleCalendarView` (`ScheduleCalendarView.swift:25`) | First-sync gate ✅ • role check ✅ | Allows free-floating schedule entry. Schedule entries reference projects + employees + crews; the form should require at minimum a project/crew before save. |
| **Exception Log** | `ExceptionLogListView` (`ExceptionLogViews.swift:134`) | (inside Project context) | ✅ Already project-scoped. |
| **Project** | `ProjectListView` (`ProjectListView.swift:10`) | First-sync gate ✅ | Allows free-floating project create. Per the Phase 7 plan, projects should originate from Opportunities (which is the entity-first pattern). Currently the procurement auto-link trigger fills `opportunity_id` via fallback, but a UX-level gate would make the intent explicit. |
| **Crew** | `CrewListView` (`CrewListView.swift:9`) | First-sync gate ✅ | ✅ Crew is a top-level company resource — free-floating create is correct. |
| **Equipment** | `EquipmentListView` (`EquipmentViews.swift:14`) | First-sync gate ✅ | ✅ Top-level company resource — free-floating create is correct. |
| **Form Template** | `FormTemplateListView` (`FormTemplateViews.swift:15`) | First-sync gate ✅ | ✅ Admin resource — free-floating create is correct. |
| **Form Submission** | `FormsHubView` (`FormsHubView.swift:476`) | (template + project context required by the form itself) | ✅ Form fields enforce target context. |
| **Certificate** | `CertificateListView` (`CertificateViews.swift:14`) | First-sync gate ✅ | Allows free-floating certificate. Certificates should attach to Employees — currently `employee_id` is nullable in the baseline. Worth requiring employee selection. |
| **Client** | `ClientListView` (`ClientViews.swift:334`) | First-sync gate ✅ | ✅ Top-level CRM resource — free-floating create is correct. |
| **CRM Opportunity** | `CRMHubView` "New Lead" (`CRMOpportunityViews.swift:43`) | First-sync gate ✅ | ✅ Top-level CRM resource — free-floating create is correct. |
| **CRM Contact** | (inside CRMCompany / Client context) | ✅ Already client-scoped |  |

## Categorization

### ✅ Already correctly gated (10)
- Quote-from-Opportunity
- Estimate-from-Opportunity
- Invoice-from-Project (line 1421 path)
- Purchase Order from approved MR
- Daily Job Report from Project
- Exception Log from Project
- Form Submission with template+project
- Crew / Equipment / Form Template (intentionally top-level)
- Client / Opportunity (top-level CRM)
- CRM Contact from Client

### ⚠️ Free-floating top-level create — recommended for design review (10)
- Quote (`QuoteListView`)
- Estimate (`EstimateListView`)
- Invoice (`InvoiceListView`)
- Change Order (`ChangeOrderListView`)
- RFI (`RFIListView`)
- Material Request (`ProcurementHubView`)
- Contract (`ContractListView`)
- Sub-Contract (`SubcontractorListView`)
- Material Sale (`MaterialSaleListView`)
- Project (`ProjectListView`) — should originate from Opportunity per entity-first pattern

### ⚠️ Started from non-FK parent (2)
- Estimate from Client (Client doesn't satisfy opportunity_id FK)
- Estimate from Site (Site doesn't satisfy opportunity_id FK)

## Recommended interventions (in design-decision order)

**Decision 1: Free-floating top-level commercial creates — block, warn, or auto-route?**

Three patterns exist in the app today:
- **Block:** Hide the `+` button entirely; users must navigate from the parent (Opportunity / Project / Client). Highest enforcement, lowest UX flexibility.
- **Warn:** Show a "Where does this belong?" prompt that forces the user to pick a parent. Same destination, gentler UX.
- **Auto-route:** The `+` button always opens a "Pick parent" flow first. The auto-link trigger then fills FKs. Same as the procurement pattern that just shipped.

Recommendation: **Auto-route** for Quote/Estimate/Invoice/CO/RFI/MR/MS (always require Opportunity or Project), **block** for Sub-Contract (always require parent Contract or Project), **leave free-floating** for Client/Crew/Equipment/Project (top-level resources).

**Decision 2: Estimate-from-Client/Site flows**

These currently start from a non-Opportunity parent. Two options:
- Auto-create an "Untitled Opportunity" placeholder when the user starts an estimate from a Client/Site
- Force the user to either pick an existing Opportunity or create one first

Recommendation: **Auto-create placeholder** with a banner "This created Opportunity '<client> — <date>'. You can rename later." Lowest friction, preserves data integrity.

**Decision 3: Material Request constraint enforcement at UI layer**

The DB CHECK constraint enforces `(destination_type, project_id, material_sales_id)` validity. The Swift form should disable the Save button until the constraint is satisfied (currently it errors on push and shows the SyncErrorMapper message). Worth fixing for UX even if not strictly required.

## Implementation effort estimate

- **Decision 1 / Auto-route:** 7 view files. Each needs a "select parent" sheet before the create form. ~4 hours.
- **Decision 2 / Auto-create placeholder Opportunity:** Modify EstimateCreateView to inject Opportunity creation when called from non-Opp parent. ~1 hour.
- **Decision 3 / MR Save-button disable:** Add a computed `isValidDestination` to MaterialRequestEditorView. ~30 minutes.

Total: ~5-6 hours of focused work once the design decisions are made.

## What this audit does NOT cover

- Mobile vs iPad-specific entry points (assumes iPhone+iPad share the same view hierarchy, which they do for Aski IQ)
- Deep-link / URL-scheme creates (none currently exist)
- AI-driven creates (the AI Assistant module is Phase 8; no creates today)
- Offline-first race conditions (out of scope; covered by sync engine)

## Next session

When you're ready to act on this:
1. Review the three design decisions above.
2. Pick a pattern (block / warn / auto-route) for each free-floating entry.
3. Tell me which subset to implement first.
4. I'll wire it across the relevant views in 1-2 hours per entity-class group.
