# Deploying `/ms` to Cloudflare Pages

This is what you need to do to finish wiring up Material Sale digital
acceptance. Edge Function and database are already done — the only
remaining piece is the customer-facing HTML page at
`accept.blairventures.ca/ms`.

---

## Phase 1 — Deploy `/ms` (do now)

### What I've done
- ✅ Deployed Edge Function `material-sale-accept` (verify_jwt: false, public)
- ✅ Smoke-tested it: returns `{"status":"open", ...}` for a real token
- ✅ Wrote `index.html` in this folder — full standalone page, ready to deploy

### What you need to do

You have two reasonable options depending on how your existing
Cloudflare Pages project is structured.

#### Option A — Same Pages project, route `/ms` to a sub-path
*(Recommended if your existing site already has multi-page routing)*

1. In your Cloudflare Pages project (the one serving `accept.blairventures.ca`), create a folder named `ms` at the project root.
2. Drop `index.html` (from this `CloudflarePages_ms/` folder) into `/ms/index.html`.
3. Push the change. Cloudflare Pages will auto-deploy.
4. Verify by visiting `https://accept.blairventures.ca/ms?token=foo` in a browser — you should see "Link not found" (because `foo` isn't a real token), styled with the Aski IQ brand.

#### Option B — Separate Pages project for `/ms`
*(If your existing project uses single-page routing or you want strict isolation)*

1. Create a new Cloudflare Pages project (e.g. `aski-ms-accept`).
2. Add `index.html` to its root.
3. Configure a custom domain on Cloudflare to route `accept.blairventures.ca/ms*` to this new project. (In your DNS, you'd use Cloudflare's "Pages routes" or a Worker-as-router.)
4. Verify the same URL.

### Smoke test once deployed

A real token is already in the database from your earlier test (it expires June 4, 2026):

```
https://accept.blairventures.ca/ms?token=VaLSAzdXk6pR5hKhuZOG7T0LkmYpznLt
```

Open it in a browser. You should see:
- **MATERIAL SALE** badge
- **"Review & Accept MS-2026-0004"** heading
- Sale total: $330.75
- Bill to: Suncor Energy
- Name + email + signature fields
- **"Accept Material Sale"** button

**Don't actually accept it** during the smoke test unless you're ready
for the lifecycle to advance — accepting will:
- Flip `material_sales.status` from current to `'ordered'`
- Set `material_sales.accepted_at` to now
- Mark linked CRM opportunity as `won`
- Log a `salesAccepted` CRM activity
- Trigger signed-PDF email send to the signer + company inbox

If you want to test acceptance fully end-to-end, mint a fresh token
on a throwaway test sale instead.

---

## Phase 2 — Future unified `/accept` route (design only)

This is a design document. **Do NOT implement yet.** When the time
comes to consolidate, this is the roadmap.

### Target structure

```
accept.blairventures.ca/accept?kind=quote&token=...
accept.blairventures.ca/accept?kind=sale&token=...
accept.blairventures.ca/accept?kind=rental&token=...
accept.blairventures.ca/accept?kind=invoice&token=...
accept.blairventures.ca/accept?kind=contract&token=...
accept.blairventures.ca/accept?kind=lien_waiver&token=...
```

One page. One Edge Function. Multiple document types.

### Page architecture (`/accept`)

A single `index.html` that:
1. Reads `?kind=…&token=…` from the query string.
2. Calls a unified Edge Function endpoint:
   ```
   POST /functions/v1/accept-router
   { "action": "lookup", "kind": "<kind>", "token": "<token>" }
   ```
3. Renders the same UI shell — branded card, summary, signature pad, accept button — and adapts:
   - **Heading label** (`Quote` / `Material Sale` / `Rental Agreement` / etc.)
   - **Summary fields shown** (quotes show scope; sales show delivery; contracts show counterparty)
   - **Verb** in the accept button ("Accept Quote" vs "Sign Contract" vs "Sign Rental Agreement")
4. On Accept, POSTs back:
   ```
   POST /functions/v1/accept-router
   { "action": "accept", "kind": "<kind>", "token": "<token>",
     "name": "...", "email": "...", "signature": "<data-url>" }
   ```

### Edge Function architecture (`accept-router`)

A single function that dispatches by `kind`:

```ts
// pseudocode — DO NOT IMPLEMENT YET
const HANDLERS = {
  quote:        { lookup: "lookup_quote_by_token",         accept: "accept_quote_via_token" },
  sale:         { lookup: "lookup_material_sale_by_token", accept: "accept_material_sale_via_token" },
  rental:       { lookup: "lookup_material_sale_by_token", accept: "accept_material_sale_via_token" },
  invoice:      { lookup: "lookup_material_sale_by_token", accept: "accept_material_sale_via_token" },
  contract:     { lookup: "lookup_contract_by_token",      accept: "accept_contract_via_token" },
  lien_waiver:  { lookup: "lookup_lien_waiver_by_token",   accept: "accept_lien_waiver_via_token" },
};
```

The function would:
- Validate `kind` against the handler map (reject anything else with 400).
- Forward to the correct RPC pair based on the action.
- Normalize the response shape so the page renders the same way regardless of kind:
  - `{ status, label, number, party_name, summary_field, total, expires_at, accepted_at, revoked_at }`
- Run the same email-fanout block as today (admin notify + customer confirmation), with subjects parameterized by the resolved label.

### Backward compatibility

When the unified route ships:

1. **`/q` and `/ms` routes stay live** — they continue to point at their dedicated pages and Edge Functions.
2. **iOS apps stay on `/q` and `/ms` URLs for new mints.** No iOS changes required to keep working.
3. **Optional migration** — eventually update iOS to mint `/accept?kind=…` URLs for new tokens. Old `/q` and `/ms` URLs in already-sent emails still resolve because their dedicated pages are still up.
4. **Hard cutover** is never required. The old routes can run alongside the new one indefinitely. Retire them only when nothing uses them.

### Why bother with the unified route at all

- **One UI to maintain** instead of N — currently there's `/q`, `/ms`, and (latent) future routes for contracts, lien waivers, change orders, etc.
- **Single deploy surface** — bug fix to the page or function ships once.
- **Future-proof** — when you add `change_order_acceptance_tokens`, you just add one row to the handler map. No new page, no new function.
- **Cleaner URLs** for marketing copy / emails ("accept on aski.com/accept" vs "remember which letter, q or ms").

### When to do it

Don't do it now. Triggers for "now's the time":
1. You add a third document type that needs acceptance (change orders most likely).
2. You're paying CDN/Worker invocation costs for two functions and want to consolidate.
3. You hit a copy-paste bug where `/q` and `/ms` diverge in their CORS / rate-limiting / error handling, and the diff drift is a maintenance burden.

### Estimated effort when you do it

- Edge Function `accept-router`: ~200 lines (a fancy router around existing RPCs)
- Unified page: ~500 lines (extends current per-doctype page with conditional rendering)
- iOS update: 1 line per service to mint the new URL format
- Backwards-compat tests: handful of curl tests verifying old URLs still resolve

Total: half a day, when there's a real reason to do it.

---

## Files in this folder

| File | Purpose | Where it goes |
|---|---|---|
| `index.html` | Customer-facing acceptance page | Cloudflare Pages root → `/ms/index.html` |
| `DEPLOY.md` | This file | Reference only — not deployed |

## Post-deploy checklist

- [ ] `/ms` route returns the page (not a 404)
- [ ] Open the smoke-test URL above; see Material Sale summary card
- [ ] Open `/ms?token=invalid` in a browser; see "Link not found"
- [ ] On a personal sale: complete the full flow — sign, accept, see success page
- [ ] iOS pulls within ~1 minute and shows "Accepted by …" pill
- [ ] Customer + company inboxes receive the signed-PDF email
- [ ] `/q` quote acceptance still works (regression check)
