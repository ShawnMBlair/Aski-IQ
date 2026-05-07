# Cloudflare Pages + Edge Function Handoff — Material Sale Acceptance

The iOS + DB sides of Material Sale digital acceptance are deployed. To
finish the loop and let customers actually click an acceptance link,
two server-side changes are required. **Both are work you (the user)
need to do — I cannot deploy Cloudflare Pages or new Edge Functions on
your behalf.** Both follow the existing Quote-acceptance pattern.

---

## 1. Cloudflare Pages — add a `/ms` route

The iOS app builds magic-link URLs like:

```
https://accept.blairventures.ca/ms?token=<base64url-token>
```

The token format and length are identical to the existing `/q` (quote)
URLs. You need a new HTML page on Cloudflare Pages that:

1. Reads `?token=…` from the query string.
2. Calls the new Edge Function `material-sale-accept` with `{ "action": "lookup", "token": "…" }` to fetch the sale's display details (number, client, total, delivery address, expiry).
3. Renders a clean acceptance page that mirrors the existing `/q` page styling (logo, summary card, signature pad, Accept button).
4. On Accept, captures: signer name, signer email, signature PNG (data URL), then POSTs `{ "action": "accept", "token": "…", "name": …, "email": …, "signature": <data-url> }` to the same Edge Function.
5. Shows a success page on `ok: true` and an error message on `ok: false` (the RPC returns a human-readable `reason` string).

**Easiest implementation:** copy-paste the existing `q.html` file from
your Cloudflare Pages project, rename to `ms.html`, swap the API
endpoint URL to the new function, swap labels ("Quote" → "Material
Sale" / "Rental Agreement" / "Invoice" — adapt by the `sale_type`
field returned from `lookup_material_sale_by_token`).

The badge in the acceptance page should adapt to `sale_type`:
| sale_type      | Page heading      |
|---            |---                |
| project_work   | Project Quote     |
| service_work   | Service Quote     |
| material_sale  | Material Sale     |
| rental         | Rental Agreement  |
| direct_invoice | Invoice           |

---

## 2. Supabase Edge Function — `material-sale-accept`

The iOS app does NOT call this function directly. Cloudflare Pages
calls it. Two action codepaths:

### `lookup` (called when the customer first opens the link)

```ts
const { data, error } = await supabase.rpc("lookup_material_sale_by_token", {
  p_token: token,
});
// data[0] = { material_sale_id, company_id, company_name, sale_number,
//             sale_type, client_name, delivery_address, grand_total,
//             expires_at, accepted_at, revoked_at }
```

If `revoked_at` is set, render "This link has been revoked."
If `accepted_at` is set, render "This sale has already been accepted."
If `expires_at < now()`, render "This link has expired."
Otherwise render the acceptance UI.

### `accept` (called when the customer signs + clicks Accept)

```ts
const ip = req.headers.get("CF-Connecting-IP") ?? "0.0.0.0";
const ua = req.headers.get("User-Agent") ?? "";

const { data, error } = await supabase.rpc("accept_material_sale_via_token", {
  p_token: token,
  p_acceptor_name: name,
  p_acceptor_email: email,
  p_acceptor_ip: ip,
  p_acceptor_user_agent: ua,
  p_signature_data_url: signatureDataUrl,
});
// data[0] = { material_sale_id, company_id, sale_number, client_name,
//             grand_total, ok, reason }
```

Return the RPC row to the page so it can show success or the reason
string for failure.

### Function settings

- **Name:** `material-sale-accept`
- **Verify JWT:** `false` (must be public — customers don't have a Supabase auth session)
- **Service role:** Required (RPCs are SECURITY DEFINER but the function calls them via the service role anyway, just like `quote-accept`)
- **CORS:** Allow `https://accept.blairventures.ca` only (mirror the quote-accept config)

The simplest deployment is to clone your existing `quote-accept`
function source, rename to `material-sale-accept`, and replace the two
RPC names. Everything else (CORS, error handling, response shape) can
stay identical.

---

## 3. After deployment — verify with a smoke test

1. In the iOS app, send a test material sale to a personal email with "Include digital acceptance link" toggled ON.
2. Open the email on your phone. Tap the `accept.blairventures.ca/ms?token=…` link.
3. The Cloudflare Pages page should load with sale details.
4. Sign + Accept.
5. The page should show "Accepted — thank you" (or your equivalent).
6. Wait 30 seconds, then refresh the iOS detail view (or tap into a different sale and back). The acceptance pill should switch to "Accepted by …".
7. Within the same sync cycle, the iOS app generates the signed PDF + Acceptance Certificate page and emails it to the customer + company inbox. Both inboxes should receive it.
8. The sale status should now read `.ordered` in the iOS detail view.
9. The linked CRM opportunity (if any) should now read `won`.

If any step fails:
- **Page loads blank** → Cloudflare Pages routing is wrong; check `/ms` exists.
- **"Sale not found"** → token URL was malformed or the function is calling a wrong RPC name.
- **iOS pill never updates** → confirm the iOS app is calling pull (kill + reopen app to force refresh; or the realtime subscription if you have one).
- **Signed PDF never arrives** → check Xcode console for `⚠️ SignedMaterialSalePDFGenerator` lines.
