# Test Checklist — Material Sale Digital Acceptance (Path-A clone)

This is a Path-A clone of the existing Quote acceptance pipeline. The
test plan mirrors what you already validated for Quotes.

---

## Pre-requisites
- [ ] iOS app rebuilt with the new files (MaterialSaleAcceptanceService, SignedMaterialSalePDFGenerator, MaterialSaleSendReviewSheet, updated MaterialSale model + sync engine + detail view + PDF renderer)
- [ ] Supabase migration `material_sale_acceptance` deployed (verified by RPC list query)
- [ ] **Cloudflare Pages `/ms` route deployed** (see CloudflareHandoff_MaterialSaleAcceptance.md)
- [ ] **Edge Function `material-sale-accept` deployed** (see same doc)

If the Cloudflare/Edge pieces aren't deployed yet, you can still test
everything iOS- and DB-side — magic links will be minted and tracked
correctly, the customer-facing page just won't load.

---

## Pattern parity with Quote acceptance
Everything below should feel identical to the equivalent Quote test.
If anything diverges except where explicitly called out, file it as a
clone-bug.

### Send-flow parity
- [ ] Material Sale detail view's "Send for Customer Acceptance" button is the entry point — same role as Quote's "Send Quote to Client"
- [ ] Tapping it opens **MaterialSaleSendReviewSheet** (NOT EmailComposeSheet directly)
- [ ] Review sheet mirrors QuoteSendReviewSheet exactly: recipient picker, CC list, sale summary, line items, T&C count, "Include digital acceptance link" toggle (admin-only)
- [ ] Sheet is non-dismissable while sending
- [ ] Cancel keeps sale in current state — no status change, no token minted
- [ ] Send tap shows ProgressView in the toolbar slot, then green checkmark on success, then auto-dismiss after ~500ms

### Status transition parity
- [ ] Sale at `.draft` + acceptance toggle ON → tap Send → on email-success the sale flips to `.quoted` (same as Quote `.draft → .sent`)
- [ ] Sale at `.draft` + acceptance toggle OFF → tap Send → on email-success the sale flips to `.quoted` (no token minted, no link in body)
- [ ] Sale at `.quoted` → tap Re-send → on email-success status STAYS `.quoted` (idempotent, never demotes)
- [ ] Sale at `.ordered` (already accepted) → tap Re-send → status STAYS `.ordered`
- [ ] Sale at `.paid` / `.cancelled` → no Send button visible

### Critical guardrails (must hold)
- [ ] **Opening the Review sheet alone never changes status** — open it then tap Cancel: sale still `.draft`, no token in DB, no CRM activity logged
- [ ] **Tapping Send + email failure** → sale STAYS at original status, token IS minted (server-side) but with no acceptance yet, error toast appears in the Review sheet
- [ ] **Opening Terms in the form never sends or submits** — verified by the previous T&C test plan; this slice doesn't change that contract
- [ ] **Material Sale is still linked to opportunityID** — verify on detail view's CRM card after send; the link is preserved across the send flow

---

## Email content
- [ ] Subject = `<saleNumber> — <ClientName>` (matches material_sale path that EmailComposeSheet was using)
- [ ] Body greeting includes client name; body verb adapts to saleType (rental → "rental agreement", direct invoice → "invoice", others → "quote")
- [ ] When acceptance toggle was ON: body has a line at the top reading "Click here to review and accept this <verb> digitally:" followed by the `https://accept.blairventures.ca/ms?token=…` URL
- [ ] PDF attachment named `Quote_<saleNumber>.pdf` (or `Rental_…` / `Invoice_…`)
- [ ] Reply-To header set to company email (when configured)

---

## Customer acceptance flow (requires Cloudflare/Edge deployed)
- [ ] Customer clicks the magic link → Cloudflare Pages page loads
- [ ] Page heading + badge adapt to saleType
- [ ] Page shows: sale number, client name, delivery address, total
- [ ] Customer types name + email → signature pad → tap Accept
- [ ] Page shows success message
- [ ] Refresh page → "This sale has already been accepted" (token is single-use)
- [ ] Try the link a second time from a different device → same already-accepted message

### Server-side after acceptance
- [ ] `material_sale_acceptance_tokens.accepted_at` is set
- [ ] `material_sales.status = 'ordered'`
- [ ] `material_sales.accepted_at` is set to the same timestamp
- [ ] Linked `crm_opportunities.stage = 'won'`, `won_at` set, `probability = 100`
- [ ] CRM activity row inserted with type `'salesAccepted'`, title `"Material sale <saleNumber> accepted via magic link"`

---

## iOS picks up acceptance + signed PDF generation
- [ ] iOS pull (force via app restart or sync timer) brings the sale's `acceptedAt` field across
- [ ] Detail view's acceptance pill switches from orange "Awaiting acceptance" to green "Accepted by <name> · <date>"
- [ ] Status badge on the header card shows "Ordered"
- [ ] Action buttons re-render: "Email Quote to Client" → "Re-Email", "Mark as Quoted (no email)" disappears, "Mark as Invoiced" appears

### Signed PDF auto-generation
- [ ] Within ~10 seconds of pull, a new document `Quote_<saleNumber>_signed.pdf` (or `Rental_…` / `Invoice_…`) appears in the sale's Documents grid
- [ ] Open the signed PDF — it's the original sale document plus a final "ACCEPTANCE CERTIFICATE" page showing:
  - Sale number
  - Accepted at (timestamp)
  - Accepted by (name)
  - Email
  - IP address
  - Token suffix (last 6 chars only — full token never embedded)
  - Signature image (drawn from base64 PNG)
- [ ] Customer's email inbox receives the signed PDF
- [ ] Company email inbox receives the signed PDF (if `companyEmail` is set in AppSettings)
- [ ] Console log: `✅ SignedMaterialSalePDFGenerator: signed PDF generated + sent for <saleNumber>`
- [ ] Subsequent pulls do NOT regenerate or re-email (idempotent ledger via `bv_signed_pdf_processed_sale_ids` UserDefaults key)

---

## Revoke flow
- [ ] Send a fresh sale with acceptance toggle ON
- [ ] DO NOT open the link as the customer
- [ ] On the iOS detail view, the orange "Awaiting acceptance" pill shows a small **Revoke** button (admin only)
- [ ] Tap Revoke → confirmation dialog → Revoke
- [ ] Pill switches to red "Acceptance link revoked"
- [ ] Customer clicks the original link in their email → page shows "This link has been revoked"
- [ ] Re-send the sale (a new token is minted server-side, the old one stays revoked)
- [ ] New magic link works; old one still doesn't

---

## Permission gating
- [ ] Logged in as Office Admin / Manager / Executive: "Include digital acceptance link" toggle is visible in the Review sheet; Revoke button visible on the pending-acceptance pill
- [ ] Logged in as a non-admin role (Estimator, Project Manager, Foreman, Field Worker): toggle is HIDDEN; Revoke button is HIDDEN
- [ ] Non-admin can still tap Send (sends without link); status still flips to `.quoted`

---

## What this slice does NOT do (deferred / acknowledged)

- **Status badge update for "accepted"** — `MaterialSaleStatus` doesn't have a dedicated `.accepted` case. Customer acceptance maps to `.ordered`, which is the closest existing semantic match. If you want a distinct "accepted-but-not-yet-ordered" state, that's an enum extension + Codable migration as a future slice.
- **Decline path** — the magic link only supports Accept. Customer-driven decline isn't yet wired (would need an additional RPC + UI button on the Cloudflare page). The lifecycle still has `.cancelled` for declines, but it's iOS-rep-driven only.
- **Acceptance PDF on Material Sale detail view** — the signed PDF lands in the Documents grid (already wired via `materialSaleDocs`), but the detail view doesn't yet have a prominent "View Signed PDF" link. Looking at the documents list works for now.
- **Slice C send-time warnings** — Quote has soft warnings for "no T&C attached" before sending. Not cloned here yet; the Review sheet just shows the count + an orange icon when zero.

---

## Files added/modified

### New
- `SupabaseMigration_MaterialSaleAcceptance.sql` — applied to prod
- `MaterialSaleAcceptanceService.swift` — mint / revoke / status / signed-details
- `SignedMaterialSalePDFGenerator.swift` — idempotent post-acceptance PDF generation + email
- `MaterialSaleSendReviewSheet.swift` — review-before-send UI
- `CloudflareHandoff_MaterialSaleAcceptance.md` — server-side handoff doc (you)
- `TestChecklist_MaterialSaleAcceptance.md` — this file

### Modified
- `MaterialSale.swift` — added `acceptedAt: Date?`
- `SyncEngine.swift` — pullMaterialSales decodes `accepted_at` + invokes signed-PDF generator for accepted sales
- `MaterialSaleViews.swift` — detail view: state for acceptance status + review sheet, refactored send button to open Review sheet, acceptance pill, revoke flow, runReviewedSend / handleReviewedSendSuccess / reloadAcceptanceStatus / revokeAcceptanceLink helpers
- `CommercialPDFRenderer.swift` — `MaterialSalePDFRenderer` gains `AcceptanceCertificate` struct + `drawAcceptanceCertificate` page (mirrors the Quote certificate page exactly)

### Deliberately NOT touched
- `QuoteAcceptanceService.swift` / `SignedQuotePDFGenerator.swift` / `QuoteSendReviewSheet.swift` — Path-A clone means existing Quote acceptance code is unchanged. Zero regression risk.
- `EmailComposeSheet.swift` — the existing `material_sale` branch (which advances `.draft → .quoted` on email-success) is now unused for the primary "Send for Customer Acceptance" flow (since that goes through the Review sheet directly via EmailService.sendPDF). It still works for any code path that uses EmailComposeSheet directly. Safe to leave.

---

## Architectural decision recorded

**Why `.draft → .quoted` on send-success but `.quoted → .ordered` on customer accept (not new statuses)?**

`MaterialSaleStatus` has 6 cases: `.draft / .quoted / .ordered / .invoiced / .paid / .cancelled`. The natural mapping to the Quote
acceptance lifecycle:

```
Quote:         draft → sent → accepted → (project)
Material Sale: draft → quoted → ordered (= customer accepted) → invoiced → paid
```

`.ordered` IS the customer-accepted state semantically — the customer
ordered the materials. Adding a redundant `.accepted` case would
require Codable migration, defensive decoders for in-flight rows,
and downstream logic updates everywhere `.ordered` is currently
treated as the accepted-deal pivot. Status mapping documented in
the migration SQL header for future readers.
