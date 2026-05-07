# Blair Ventures App — Developer Roadmap
**Shawn Blair / Blair Ventures & Integral Containment Systems**
**Last updated: April 2026**

---

## Build Status

All Phase 1–5 sprints are complete. The app has expanded significantly beyond the original 12-sprint plan. The roadmap below reflects what has been built and what remains.

---

## COMPLETED

### Phase 1 — Foundation
- [x] Sprint 1: Core models (Project, Employee, Crew, ScheduleEntry, TimesheetEntry, Form, Estimate, AppStore)
- [x] Sprint 2: Navigation shell, RootView, role-based routing, LoginView

### Phase 2 — Core Operations
- [x] Sprint 3: Projects module (list, detail, create/edit, status tabs, search)
- [x] Sprint 4: Crew + Employee module (list, detail, create/edit, crew builder)
- [x] Sprint 5: Scheduling module (calendar, day view, create/edit, conflict detection)

### Phase 3 — Timesheets
- [x] Sprint 6: Daily entry, crew bulk entry, Field Quick Mode (Start/End Shift)
- [x] Sprint 7: Approval queue, timesheet detail, exception logging, audit snapshots

### Phase 4 — Forms
- [x] Sprint 8: Form template builder, submission view (photo, signature, conditional logic)
- [x] Sprint 9: Form PDF export, offline queue, audit hash signing

### Phase 5 — Reporting
- [x] Sprint 10: Project report (labor vs estimate, variance), daily summary report
- [x] Sprint 11: Payroll export (CSV, approved timesheets only)

### Phase 6 — Commercial & Financial Modules
- [x] Sprint 12: Widget dashboard (modular, drag/drop/resize, role-aware defaults, AI button)
- [x] Estimating module (line items, cost codes, contingency/overhead/profit, status workflow)
- [x] Quote module (from estimate, PDF renderer, revision tracking, status: draft→approved→sent→accepted)
- [x] Invoice module (line items, payments, status workflow, overdue detection)
- [x] Change Orders (scope changes, cost/schedule impact, linked to project)
- [x] RFIs (question/answer workflow, priority, cost/schedule flags)
- [x] Project Budgets (cost-code level budget vs actual tracking)
- [x] Procurement (Material Requests, Purchase Orders, Supplier master)
- [x] Subcontractors + Sub-Contracts (insurance/WCB/COR compliance, contract value, retention)

### Phase 7 — Safety & Field Operations
- [x] Incident reporting (type, severity, WCB/OHS flags, witness log, audit hash)
- [x] Daily Job Reports (crew, weather, work performed, delays, equipment, visitors)
- [x] Certificate/compliance tracking (expiry alerts, per-employee)
- [x] Equipment registry (asset tracking, service due dates, assignment)

### Phase 8 — CRM
- [x] Client database (multi-site, billing, contacts)
- [x] CRM Contacts (linked to clients, primary contact flag)
- [x] CRM Opportunities (full pipeline: New Lead → Quote Sent → Won/Lost, value, probability)
- [x] CRM Tasks (priority, due date, assigned to, linked to opportunity/project)
- [x] CRM Activities (call/email/meeting/note log, append-only)
- [x] Handoff Checklists (auto-generated on won opportunity)
- [x] CRM Attachments (file storage in Documents/)
- [x] CRM AI Service (AI-powered insights and drafting)
- [x] Lead Intake form (external-facing quick capture)
- [x] Pipeline reports + revenue forecasting (ForecastSnapshotWidget)
- [x] Quote from Opportunity flow (one-tap quote creation from won opportunity)

### Phase 9 — Sync & Infrastructure
- [x] Supabase auth (sign in, sign out, session restore, profile auto-create)
- [x] SyncEngine: full pull on launch for all modules
- [x] SyncEngine: push pending for all modules (offline-first with syncStatus)
- [x] SyncEngineCRM: CRM pull/push + realtime opportunity changes
- [x] SyncEngineCommercial: Change Orders, RFIs, Budgets, Subcontractors, Invoices, Procurement, Clients, Quotes
- [x] Realtime timesheet updates (Supabase Realtime channel)
- [x] Workflow automation engine (rules, triggers, in-app alerts, push notifications)
- [x] Weather service (auto-populates form fields, DJR weather block)
- [x] Network monitor (offline mode detection)
- [x] Notification manager (compliance sweep, cert expiry, task assignment)
- [x] Admin panel (reset data, role switching, sync controls)
- [x] AI Chat (AIChatView, AskiCommand integration)

---

## IN PROGRESS / NEXT

### ✅ Sprint 13 — Quote PDF Export
- [x] `QuotePDFRenderer` — company header, To block, scope/inclusions/exclusions, line items, totals, validity note, footer
- [x] "Export PDF" toolbar button on `QuoteDetailView`
- [x] Share sheet via `UIActivityViewController`
- [x] Auto-named file: `Quote_{jobNumber}_{client}.pdf`

---

### ✅ Sprint 14 — CRM Role-Gating + UX Polish
- [x] Opportunity financials (value, probability) gated to estimator/PM/admin/manager/executive via `canEditOpportunityFinancials`
- [x] Won/Lost gated to PM/admin/manager/executive via `canMarkWonLost`
- [x] Swipe-to-complete (green, leading) on CRM task rows
- [x] Swipe-to-delete (red, trailing) on CRM task rows — gated to `canDeleteCRMTasks`
- [x] Create/edit/delete permission checks on all CRM views

---

### ✅ Sprint 15 — CRM Search
- [x] `CRMSearchView` — grouped results: Companies / Contacts / Opportunities
- [x] 300ms debounced live search
- [x] Tap navigates to correct detail view
- [x] Search button wired into `CRMHubView` toolbar

---

### ✅ Sprint 16 — Supabase Schema Hardening
- [x] `SupabaseMigration_Commercial.sql` — clients, quotes, change_orders, rfis, project_budgets, subcontractors, sub_contracts, invoices, suppliers, material_requests, purchase_orders (CREATE + ALTER + RLS)
- [x] `SupabaseMigration_CRM.sql` — crm_contacts, crm_opportunities, crm_tasks, crm_activities, crm_checklists (CREATE + ALTER + Realtime + RLS)
- [x] `syncStatus` added to `Client` and `Quote` models
- [x] `pushPendingClients()` and `pushPendingQuotes()` + `pullQuotes()` wired into SyncEngine

---

### ✅ Sprint 17 — Invoice PDF + Email + Aging Report
- [x] `InvoicePDFRenderer` — company header, Bill To block, line items, totals with GST, balance due, notes, footer
- [x] Export PDF toolbar button + iOS share sheet on `InvoiceDetailView`
- [x] "Mark Sent" status + `sentAt` timestamp on invoice action buttons
- [x] Invoice aging report — 30/60/90+ day buckets with bar chart, per-bucket drill-down, days-overdue per invoice

---

### ✅ Sprint 18 — Performance + Polish
- [x] Pagination on all large lists (25 items, `PaginationState` + `LoadMoreFooter`) — 16 views
- [x] Photo compression `compressPhoto()` — max 2048px, target <500KB, JPEG quality step-down
- [x] Zero Swift compiler warnings *(see Sprint 19 for remaining deprecation-only warnings)*
- [ ] App icon + launch screen final assets *(requires design assets)*
- [ ] Accessibility audit (VoiceOver labels on interactive elements)
- [x] iPad split-view layout pass — `.tabViewStyle(.sidebarAdaptable)` on all three TabViews; `UISupportedInterfaceOrientations~ipad` (all 4 orientations)
- [ ] Instruments profile on real device

---

### ✅ Sprint 19A — Enterprise Data Hardening
- [x] Global soft-delete — `isDeleted/deletedAt/deletedBy` on all 23 entity structs; all delete functions mark `.pending` and push; all pull functions filter `is_deleted = false`
- [x] `@Published var quotes: [Quote]` — migrated from UserDefaults computed property to true @Published array; `pullQuotes()` writes to array; `deleteQuote()` uses soft-delete
- [x] Decimal precision — `Decimal(string: String(value)) ?? 0` across all three sync engines (SyncEngine, SyncEngineCRM, SyncEngineCommercial); eliminates IEEE 754 binary float artifacts in all financial calculations
- [x] Tenant isolation — `companyID: UUID?` added to `Supplier`, `MaterialRequest`, `PurchaseOrder`; stamped on create; all pull functions guard on `currentCompanyID` and filter by it; all push Row structs include `company_id`
- [x] Complete sample data — `SampleDataManager` v4 adds `seedSuppliers`, `seedMaterialRequests`, `seedPurchaseOrders`, `seedRFIs`, `seedIncidents`, `seedCertificates` (7 new seed functions, 6 new SID UUID blocks aaaa0016–aaaa0021, 25 realistic records cross-linked to existing proj1/employees)
- [x] Enterprise Diagnostic Suite — `EnterpriseValidationView.swift`: 25-point in-app validation engine covering Auth & Identity, Sync Health, Tenant Isolation, Data Integrity, Compliance & Safety, Commercial accuracy, and Connectivity; wired into Admin Panel → Sync & Storage section

---

### Sprint 19B — TestFlight + App Store Prep

- [x] Resolve high-value Xcode warnings — 19 deprecated `onChange(of:) { _ in }` closures → new zero-parameter form; 7 deprecated `.foregroundColor(.accentColor)` → `.foregroundStyle(.tint)` *(396 `.cornerRadius()` + ~1,350 `.foregroundColor(Color.X)` deprecations intentionally deferred — cosmetic only, no submission impact)*
- [x] Privacy manifest — `PrivacyInfo.xcprivacy` updated: added `NSPrivacyCollectedDataTypePreciseLocation` (weather), `NSPrivacyCollectedDataTypePhotosOrVideos` (form attachments), `NSPrivacyCollectedDataTypeOtherUserContent` (field text entries); existing UserDefaults (CA92.1) and FileTimestamp (C617.1) required-reason entries verified correct
- [x] App Store metadata — `APP_STORE_METADATA.md`: full description (4,000 chars), subtitle, keyword string (100 chars), What's New copy, screenshot caption guide, reviewer notes template, age rating questionnaire, pricing
- [x] Crash reporting — `CrashReporter.swift`: Sentry abstraction layer (compiles without package via `#if canImport(Sentry)`); `configure()` called in `AskiIQApp.init()`; user context set on sign-in (company ID + role, no PII); cleared on sign-out; `capture(error:)`, `capture(message:)`, `breadcrumb()`, `startTransaction()` API; `SENTRY_DSN` injected via build setting; setup instructions in file header
- [x] Accessibility audit — 31 VoiceOver annotations added across 7 files: `StatTile` (`.accessibilityElement + .accessibilityLabel`), `MoreBadgeRow`, `adminNavRow` + hint, `SectionHeader` (`.isHeader` trait), `StatusBadge`, `OfflineBanner` (queue count in label), `ComplianceAlertBanner`, `StartShiftFlowView` navigation buttons, `FieldQuickModeView` clock-in/clock-out/submit buttons
- [ ] App icon + launch screen final assets *(requires design assets)*
- [ ] TestFlight build — upload to App Store Connect, invite internal testers
- [ ] App Store submission

---

## Backlog (Future Consideration)

- Push notifications via APNs (server-triggered, e.g. "Your timesheet was approved")
- Client portal (read-only role for clients to view their project status and DJRs)
- Gantt chart view for project scheduling
- Material delivery tracking with QR scan
- Integration: QuickBooks export for invoices
- Integration: Procore / Autodesk field sync
- Multi-company support (Blair Ventures + Integral Containment as separate orgs)
- Watch app (clock-in/out from wrist)

---

*Sprint = ~1 week. Estimates assume 1 developer full-time.*
