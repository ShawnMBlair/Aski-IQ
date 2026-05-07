# Test Checklist — T&C Path-A Clone for Estimates & Material Sales

## Migration verification (done)
- [x] `estimate_terms` table created with `estimate_id` FK + indexes + RLS policies
- [x] `material_sale_terms` table created with `material_sale_id` FK + indexes + RLS policies
- [x] `estimates.terms_default_applied` column added (default false)
- [x] `material_sales.terms_default_applied` column added (default false)

---

## Build verification
- [ ] **Build green in Xcode** — no compile errors after rebuilding the project
- [ ] No new warnings introduced beyond what was there before
- [ ] No crash on app launch (rebuild + reinstall on device)

---

## Estimates — T&C functionality

### Add terms to a draft estimate
- [ ] Open New Commercial Work → pick work type → pick client → land in EstimateCreateView
- [ ] Scroll to "Terms & Conditions" section (between Pricing Adjustments and Internal Notes)
- [ ] Empty-state copy reads: "No Terms & Conditions attached. Tap Add Terms..."
- [ ] Tap **"Add Terms from Library"** — picker sheet opens (not auto-dismissed!)
- [ ] If you have default templates configured in Settings → Terms & Conditions, they auto-attach on first open and appear in the list
- [ ] Pick one or more templates → tap Add (N) → sheet dismisses → terms appear in the section
- [ ] Tap **"Add Custom Term"** — custom sheet opens
- [ ] Type a title + body → tap Save → custom term appears in the section with CUSTOM badge
- [ ] Drag rows to reorder — order persists
- [ ] Swipe left to remove a term — it disappears
- [ ] Tap **"Preview Terms"** — read-only sheet shows all attached terms, swipe down to dismiss

### Save persistence
- [ ] Save the estimate (toolbar Save)
- [ ] Reopen the same estimate from the estimate list
- [ ] Verify all attached terms still appear in the same order
- [ ] Open Xcode console and verify there's a `POST /rest/v1/estimate_terms` request in the network log (no silent client-side push failure)

### Cross-device sync
- [ ] On second device (or same device after force-quit + relaunch), open the same estimate
- [ ] Verify terms appear

### Read-only state
- [ ] Mark the estimate as `.submitted`, `.awarded`, `.converted`, `.lost`, or `.cancelled`
- [ ] Reopen the estimate
- [ ] Terms section header shows "🔒 Locked"
- [ ] No "Add Terms from Library" / "Add Custom Term" buttons visible
- [ ] Existing terms cannot be reordered (no drag handles) or swipe-deleted
- [ ] Preview Terms still works
- [ ] Footer reads: "This estimate has been submitted or completed — attached terms are now locked..."

### PDF rendering
- [ ] Export Estimate PDF (Internal or Client variant)
- [ ] Confirm a "TERMS & CONDITIONS" section appears at the bottom of the PDF (between Notes and the bottom rule)
- [ ] Each term shows: bold title (left), version badge or CUSTOM tag (right), body text below
- [ ] Long bodies wrap correctly and pages break cleanly (no orphaned titles)
- [ ] When no terms attached: T&C section is omitted entirely (no empty heading)

---

## Material Sales — T&C functionality

### Add terms to a draft sale
- [ ] Open New Commercial Work → pick a non-estimate work type (e.g. Material Sale, Rental, Direct Invoice) → pick client → land in MaterialSaleCreateEditView
- [ ] Scroll to "Terms & Conditions" section (between Line Items / Pricing and Notes)
- [ ] All same picker / custom / preview behaviours as estimates (test each)

### Save persistence
- [ ] Save the sale
- [ ] Reopen and verify terms persist
- [ ] Network log shows `POST /rest/v1/material_sale_terms`

### Read-only state
- [ ] Mark the sale `.paid` or `.cancelled`
- [ ] Reopen — terms section is locked, banner reads correctly

---

## Estimate → Quote conversion: carry-forward

### Happy path
- [ ] Create an Estimate. Attach 2-3 terms (mix of library + custom).
- [ ] Promote the Estimate to a Quote (via the Approve & Send / Convert flow)
- [ ] Open the new Quote
- [ ] Verify the Estimate's terms have been snapshotted onto the Quote
- [ ] Order matches the Estimate's order
- [ ] Custom terms come across as custom, library terms come across linked to the same template ID
- [ ] Editing the Estimate's terms after conversion does NOT affect the Quote's snapshotted terms (snapshot rule)
- [ ] Editing the Quote's terms after conversion does NOT affect the Estimate's terms

### Idempotency / dedup
- [ ] Default templates configured: e.g., "Payment Terms" marked as default
- [ ] Create Estimate → defaults auto-attach → confirm "Payment Terms" appears
- [ ] Convert to Quote → defaults also auto-attach to the new Quote → carry-forward should NOT duplicate "Payment Terms"
- [ ] Quote shows ONE "Payment Terms" row, not two

### Empty source
- [ ] Estimate with zero terms → convert to Quote
- [ ] Quote shows whatever its own defaults are (or empty if none configured), no errors logged

---

## Quote T&C regression check (must still work)

The clone is additive — quote terms code was untouched. Verify nothing broke:

- [ ] Open an existing Quote
- [ ] Add a term from library → saves
- [ ] Add a custom term → saves
- [ ] Reorder, delete, preview → all work
- [ ] PDF export shows terms section
- [ ] Send-time warnings (no terms attached / unmatched service types) still surface

---

## Critical guardrail: Terms must NEVER trigger workflow

**This is the most important set of tests.** Opening, selecting, saving, or previewing terms must NOT submit, send, or change the parent record's status.

- [ ] Open an Estimate at `.estimating` → tap Add Terms from Library → pick one → status STAYS `.estimating`
- [ ] Open a Quote at `.draft` → tap Add Terms from Library → pick one → status STAYS `.draft` (no email sent, no `.sent`)
- [ ] Open a Material Sale at `.draft` → tap Add Custom Term → save → status STAYS `.draft`
- [ ] Open Preview Terms on any of the three → close → status unchanged on parent record
- [ ] Reorder terms via drag → parent status unchanged
- [ ] Delete a term via swipe → parent status unchanged
- [ ] Cancel out of Add Custom Term sheet without saving → no terms added, parent status unchanged
- [ ] Cancel out of the Picker sheet without selecting any → no terms added, parent status unchanged

If any of these tests fail, **stop immediately** and report which path triggered the workflow change.

---

## Sync robustness

- [ ] Offline: add terms while airplane mode is on → terms appear locally with sync indicator
- [ ] Re-enable network → terms push successfully (verify with `SELECT * FROM estimate_terms` in Supabase)
- [ ] Network interruption mid-push: terms revert to `.failed` syncStatus, retry on next sync
- [ ] Force-quit mid-edit: reopen → unsynced terms still in the list (UserDefaults survives)

---

## Defensive checks

- [ ] No nested-sheet binding flap (the issue that bit Quote T&C earlier this session). If a sheet auto-dismisses immediately after opening, it's the multi-sheet issue resurfacing.
- [ ] No "Resume Previous Work?" prompt firing unexpectedly when opening Estimate or Material Sale create flows
- [ ] No console errors / RLS denials in Xcode logs while editing terms
- [ ] Terms sheets dismiss cleanly with Cancel button — no stale draft, no auto-save artifacts

---

## Files touched / created

### New
- `SupabaseMigration_EstimateTerms_MaterialSaleTerms.sql` — applied
- `EstimateTerm.swift` — model + AppStore extensions + SyncEngine push/pull + Estimate→Quote carry-forward
- `EstimateTermsViews.swift` — section + picker + custom + preview
- `MaterialSaleTerm.swift` — model + AppStore + SyncEngine
- `MaterialSaleTermsViews.swift` — section + picker + custom + preview

### Modified
- `Estimate.swift` — added `termsDefaultApplied: Bool` field
- `MaterialSale.swift` — added `termsDefaultApplied: Bool` field
- `SupabaseService.swift` — added `estimateTerms` + `materialSaleTerms` table constants
- `SyncEngineCommercial.swift` — pullEstimates / pushPendingEstimates round-trip `terms_default_applied`
- `SyncEngine.swift` — pullMaterialSales / pushPendingMaterialSales round-trip `terms_default_applied`
- `EstimateViews.swift` — EstimateCreateView wires section + sheet + applyDefaults; PDF call site passes `estimateTerms`
- `MaterialSaleViews.swift` — MaterialSaleCreateEditView wires section + sheet + applyDefaults
- `QuoteViews.swift` — `finalizeQuoteSave` calls `carryEstimateTermsForwardToQuote` on conversion
- `CommercialPDFRenderer.swift` — `EstimatePDFRenderer` accepts `estimateTerms` param and draws T&C section

### Deliberately NOT touched
- `QuoteTerm.swift` / `QuoteTermsViews.swift` / `quote_terms` table — Path-A clone means existing quote T&C code path is unchanged, zero regression risk

---

---

## Material Sale — Email-to-Client Send Flow

A second slice landed alongside T&C: Material Sales can now generate
a PDF and email it to the client (same UX as Quotes).

### Send to client
- [ ] Open a Material Sale at `.draft` → tap **"Email Quote to Client"** (blue, primary)
- [ ] Spinner appears with "Generating PDF…" while the renderer runs (off main)
- [ ] EmailComposeSheet opens with:
  - Recipients pre-filled from the linked CRMContact's email + the client's `contactEmail` (deduplicated)
  - Subject: `<saleNumber> — <ClientName>`
  - Body: branded greeting + "Please find attached your quote/rental/invoice" (verb adapts to saleType)
  - PDF attached, named `Quote_<saleNumber>.pdf` (or `Rental_…` / `Invoice_…` based on saleType)
- [ ] Edit any field if desired → tap Send
- [ ] Green "Email sent" toast appears
- [ ] Sheet dismisses; sale's status auto-advances `.draft` → `.quoted`
- [ ] Detail view re-renders showing the new status badge
- [ ] Back on the action card, the button is now labeled **"Re-Email to Client"** (allows resending)
- [ ] In Supabase API logs you should see `POST /functions/v1/send-email` returning 200
- [ ] In CRM activity timeline, an `emailSent` event appears for this sale
- [ ] Re-email a sale already in `.quoted` — works, status stays `.quoted` (idempotent — does NOT demote)

### Share PDF (without email)
- [ ] On the same sale, tap **"Share PDF"** (secondary, grey)
- [ ] System share sheet opens with the PDF — AirDrop / Files / Mail / etc. all work
- [ ] Sale status does NOT change (share is read-only — no email logged)

### PDF content
- [ ] Open the generated PDF and verify:
  - Header: company logo + name + sale number
  - Badge in top-right reflects saleType ("MATERIAL SALE" / "RENTAL AGREEMENT" / "PROJECT QUOTE" / "SERVICE QUOTE" / "INVOICE")
  - Issued date + Requested date (if set)
  - "DELIVER TO" block: client name + delivery address (resolved from sale.deliveryAddress, then linked site, then client billing as fallback)
  - Line items table: description, qty + unit, unit price, line total
  - Subtotal / Tax (when > 0) / TOTAL
  - Notes section (if sale.notes is set)
  - Terms & Conditions (if attached) — same shape as Quote/Estimate PDFs
  - Footer: "Generated: ... · Aski IQ"

### Lifecycle gating
- [ ] Sale at `.paid` → "Email Quote to Client" button is hidden (it's no longer in the eligible status range)
- [ ] Sale at `.cancelled` → button hidden
- [ ] Sale at `.invoiced` → button visible (you can still re-email)

### Critical guardrail (mirrors the T&C guardrails)
- [ ] Tapping **"Email Quote to Client"** but cancelling out of EmailComposeSheet without sending → sale status STAYS `.draft`, no CRM activity logged, no PDF saved permanently
- [ ] Tapping **"Share PDF"** then dismissing the share sheet without picking a target → sale status STAYS `.draft`, no CRM activity logged
- [ ] Email send fails (e.g. invalid recipient, network error) → sale status STAYS at original (no premature advance), error toast surfaces

---

## What's deferred (acknowledged scope cuts)

- **Detail-view terms display:** EstimateDetailView and MaterialSaleDetailView do not show a dedicated T&C card on the read-only summary. Users see/edit terms via the create/edit sheet (Edit button) or in the rendered PDF. Add a card later if needed — low priority.
- **Slice C suggestions:** The Slice C "Suggested for this quote" pinned section (which uses cost-code service-type tags to suggest matching templates) is implemented for Quotes but not cloned to Estimates / Material Sales. Add later if usage warrants — keeps the picker simpler in the meantime.
- **Send-time warnings:** Quotes show warnings before sending (no terms attached / unmatched service types). Material Sales send flow does NOT yet show these warnings — keeps the path simple. Add later if needed (mirror the Quote pattern).
- **Acceptance link / signed PDF:** Quotes support customer acceptance via magic link → signed PDF. Material Sales do not — sales are typically internal/back-office documents that don't need a customer signature flow. If customer signature on rental agreements is needed later, mirror the Quote acceptance pipeline.
- **Polymorphic refactor:** Per master prompt — explicitly deferred. Path-A clone shipped; future refactor is a separate slice.

---

## Files added/modified for the Material Sale send flow

### Modified
- `CommercialPDFRenderer.swift` — new `MaterialSalePDFRenderer` class inserted between Estimate and Invoice renderers. Header / Deliver-To block / Line Items / Totals / Notes / T&C / Footer. Badge text adapts to saleType.
- `MaterialSaleViews.swift` — `MaterialSaleDetailView` gains: PDF generation state, "Email Quote to Client" + "Share PDF" buttons, EmailComposeSheet wiring, ShareSheet wiring, helper functions for filename / recipient suggestions / email body. The legacy "Mark as Quoted" button is now labeled "(no email)" and styled secondary — keeps it as a manual fallback for in-person quotes.
- `EmailComposeSheet.swift` — added a `material_sale` branch alongside the existing `quote` branch. On confirmed email-success, advances `.draft` → `.quoted` for material sales (idempotent — never demotes from later states).
