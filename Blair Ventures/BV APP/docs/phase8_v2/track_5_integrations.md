# Track 5 — External Integrations (QuickBooks / Sage / Procore)

**Status:** ⏳ BLOCKED on vendor OAuth credentials + product priority.
**Date:** 2026-05-10
**Phase:** 8 / v2+
**Effort estimate:** 12–20 hours per vendor (OAuth + 1 entity round-trip + reconciliation UI).

This doc captures the architecture for syncing Aski IQ data with external accounting / project-management systems so the implementation can start once a vendor is picked and credentials are issued.

## Why blocked

Each integration requires:
1. **Developer account** with the vendor (free for QuickBooks Online + Procore, paid for some Sage tiers).
2. **OAuth client ID + secret** registered against an Aski IQ-controlled redirect URL.
3. **Sandbox account** to test against without polluting a customer's books.
4. A **product decision** on which entities round-trip (just Invoices? + Clients? + Estimates?).
5. A **conflict-resolution policy** when Aski IQ and the external system disagree on a record's state.

Without 1–3 we can't run the OAuth flow end-to-end; without 4–5 we'd be building scope blind.

## Vendor priority

Recommended order, by what Aski IQ customers ask about most:

| Vendor | API quality | Effort | Use case |
|---|---|---|---|
| **QuickBooks Online** | ✅ Modern REST, sandbox sane | Medium | Invoice → AR, Estimate → Estimate, Client → Customer |
| **Procore** | ⚠️ Procore Connect API; complex auth | Higher | Project → Project, RFI ⇆ RFI, DJR → Daily Log |
| **Sage 100 Contractor** | ⚠️ ODBC-only on older versions; REST on Sage Intacct | Higher | Job costing, AP/AR (Sage Intacct only) |
| **Xero** | ✅ Clean REST | Medium | Same as QBO but for non-US customers |

**Recommendation: start with QuickBooks Online.** Largest US construction customer base, cleanest API, sandbox tier covers all the entities Aski IQ surfaces.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Aski IQ iOS                                                     │
│                                                                  │
│  IntegrationsService                                             │
│   ├── connect(vendor: .quickbooks) — opens OAuth WebView         │
│   ├── refreshToken(_:)                                           │
│   ├── pushInvoice(_:) → POST to ai-proxy / vendor edge fn        │
│   └── pullVendorChanges() → optional delta poll                  │
└────────────────────────┬─────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│  Supabase Edge Functions (server-side; vendor secrets live here) │
│                                                                  │
│  /qbo-oauth-callback   — exchanges code → access+refresh tokens │
│  /qbo-push-invoice     — server-side push so the access token   │
│                          never touches the iOS client            │
│  /qbo-webhook-sink     — receives QBO change events             │
│                          (entity.deleted, entity.updated)        │
└────────────────────────┬─────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│  Supabase tables                                                 │
│                                                                  │
│  integration_connections                                         │
│   (id, company_id, vendor, status, access_token_enc,            │
│    refresh_token_enc, expires_at, scope, last_sync_at)          │
│                                                                  │
│  integration_mappings                                            │
│   (id, company_id, aski_entity_type, aski_entity_id,            │
│    vendor, vendor_entity_id, last_synced_at, sync_state)        │
│                                                                  │
│  integration_event_log                                           │
│   (id, company_id, vendor, direction, entity_type,              │
│    aski_id, vendor_id, payload, status, error, created_at)      │
└──────────────────────────────────────────────────────────────────┘
```

**Why server-side OAuth + push:**
- Vendor secrets (`QBO_CLIENT_SECRET`) must never reach the iOS client; an Edge Function holds them.
- Token refresh runs on a Supabase cron job, decoupled from iOS sync state.
- Webhook receivers need a stable HTTPS endpoint — Edge Functions provide one.

## OAuth flow

1. User taps "Connect QuickBooks" in Aski IQ Settings.
2. iOS opens `https://appcenter.intuit.com/connect/oauth2?client_id=...&redirect_uri=aski-iq://qbo-oauth&...` in `ASWebAuthenticationSession`.
3. User authenticates in Intuit's flow, approves scopes.
4. Intuit redirects back to `aski-iq://qbo-oauth?code=...&realmId=...`.
5. iOS forwards the `code` + `realmId` to `/qbo-oauth-callback` Edge Function via authenticated POST.
6. Edge function exchanges code → tokens, stores encrypted in `integration_connections`, returns `{status: "connected", realmId}`.
7. iOS Settings now shows "Connected to QuickBooks (Realm: 4620816365...)" and exposes a "Disconnect" button.

## Conflict-resolution policy

For v1 keep it strict and surface conflicts to the user:

| Scenario | Policy |
|---|---|
| Aski IQ creates → QBO push succeeds | ✅ Happy path. Stamp `vendor_id` in `integration_mappings`. |
| Aski IQ updates → QBO push fails (entity not found / 404) | ⚠️ Mark mapping as `orphaned`. Surface in Settings → Integrations as "X invoices no longer exist in QuickBooks". |
| QBO webhook fires `invoice.updated` | 🔄 Pull the diff. If Aski IQ's `updated_at > vendor's last push`, surface a conflict modal: *"Invoice INV-2026-0042 was updated in both systems. Pick one."* |
| QBO webhook fires `invoice.deleted` | ⚠️ Don't auto-delete in Aski IQ. Mark mapping as `vendor_deleted` and surface in Settings. |

Auto-merge is out of scope for v1. Always require human confirmation when both sides moved.

## Per-vendor scope — QBO v1

Entities to round-trip in QBO v1:

| Aski IQ entity | QBO entity | Direction | Notes |
|---|---|---|---|
| `Invoice` | Invoice | Aski → QBO | Push on `.sent` status transition. |
| `Client` | Customer | Aski → QBO | Auto-create on first invoice push; reuse existing match by name. |
| `Estimate` | Estimate | Aski → QBO | Push on `.sent` status transition. |
| `MaterialSale` | Invoice (TYPE=Cash) | Aski → QBO | Treat as one-line invoice. |
| `PurchaseOrder` | Bill | (deferred) | Requires vendor mapping; complex tax rules. |

Read-only pulls (QBO → Aski):
- Customer (sync customer changes back to Aski's `clients`).
- Item (so Aski's `productServices` mirror QBO's inventory catalog).

## Implementation outline

### Phase A — Edge Functions (~6 hours)

`supabase/functions/`:
- `qbo-oauth-callback/index.ts` — token exchange.
- `qbo-push-invoice/index.ts` — server-side invoice POST.
- `qbo-push-customer/index.ts` — server-side customer POST.
- `qbo-webhook-sink/index.ts` — receive Intuit webhook signals; write to `integration_event_log`.
- `qbo-token-refresh/index.ts` — scheduled cron job, refreshes expiring tokens.

Each function:
- Reads access token from `integration_connections` (decrypt via `pgp_sym_decrypt`).
- Calls Intuit API.
- Writes result to `integration_event_log`.

### Phase B — Schema migration (~2 hours)

`migrations/phase8_integrations/INT1_quickbooks_v1.sql`:
- Create `integration_connections`, `integration_mappings`, `integration_event_log`.
- Index on `(company_id, vendor)` for fast connection lookup.
- RLS: company-scoped per `get_my_company_id()`.
- Encryption: use `pgp_sym_encrypt(token, key)` with a server-side key in `vault.secrets`.

### Phase C — iOS surface (~6 hours)

`Blair Ventures/BV APP/BV APP/IntegrationsService.swift`:
- `connect(vendor:)` → launches `ASWebAuthenticationSession`.
- `disconnect(vendor:)` → POSTs to `/qbo-disconnect`; clears local mapping cache.
- `pushInvoice(_:)` → POSTs to `/qbo-push-invoice` with the Aski invoice ID; Edge Function does the heavy lifting.
- `integrationStatus(vendor:)` → reads `integration_connections` for the current tenant.

`Blair Ventures/BV APP/BV APP/IntegrationsSettingsView.swift`:
- Lists connected + disconnected vendors.
- Per-vendor: "Connect" / "Disconnect" / "View Recent Sync Activity" buttons.
- "Recent Activity" sheet shows the last 50 `integration_event_log` rows.

Integration into existing flows:
- `Invoice.markSent()` triggers `IntegrationsService.shared.pushInvoice(invoice)` if a connection exists for this tenant.
- `Estimate.markSent()` triggers `pushEstimate(estimate)` similarly.
- ToastService surfaces success / failure of the push.

### Phase D — Reconciliation UI (~4 hours)

`IntegrationConflictResolverView`:
- Loads conflicts from `integration_event_log` where `status = 'conflict'`.
- Side-by-side diff of Aski IQ vs vendor.
- Resolve buttons: "Keep Aski IQ version" / "Keep QuickBooks version" / "Cancel".
- Stamps the chosen resolution back via Edge Function.

## Open questions for product

1. **Pricing tier gating** — should QBO sync be a paid-tier-only feature? (Recommendation: yes, professional+ tier.)
2. **Multi-company QBO** — can one Aski IQ tenant connect to multiple QBO Realms? (Recommendation: no for v1; 1:1.)
3. **Push triggers** — auto-push on every save, or only on `.sent` / `.approved` status transitions? (Recommendation: status-transition-based to avoid spamming QBO with drafts.)
4. **Estimate vs Quote** — Aski IQ separates these; QBO only has Estimate. Which one syncs? (Recommendation: Aski's `Quote` since it's the customer-facing artifact; Estimate stays internal.)

## When this unblocks

Tell me one of:

- *"QBO sandbox + OAuth credentials are configured — proceed with Phase A"* → I write the Edge Functions.
- *"Procore-first instead"* → I rewrite this doc for Procore's Connect API and start there.
- *"Defer integrations entirely; pick a different track"* → I park this and move to AI v2 / RAG (deepest remaining track) or whatever you pick.
