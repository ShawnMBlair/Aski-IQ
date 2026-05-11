# Aski IQ v1.0 — Stabilization + Phase 8 v2+

Ships the full 8-phase stabilization plan plus all autonomously-completable Phase 8 v2+ tracks. 25 commits.

## Summary

This PR closes the multi-month stabilization plan agreed 2026-05-09 and lands every Phase 8 v2+ feature that didn't require external prerequisites (Watch target, vendor OAuth). Build green on iOS device target, 58 unit tests green on iPhone 17 / iOS 26.4.1 sim.

## What's in here

### Stabilization (Phases 2 → 7)

| Phase | Commits | Outcome |
|---|---|---|
| 2 — DB foundation | `5aad052`, `855dae8`, `238d002`, `ffac107`, `76b5bce` | Foundational baseline migration registered on prod at version `00000000000000`. Fresh branches now replay all 104 historical migrations cleanly to `FUNCTIONS_DEPLOYED`. |
| 6 (Wave 4) | `5ad9bcd` | `canPerform(action:amount:)` engine-driven via `workflow_settings`. 16 action keys × 7 roles seeded. |
| 7 (audit) | `76676d2`, `ee827cc`, `41def3a` | Orphan-record prevention catalog + Decisions 2+3 re-graded as already-wired. |
| 7 (Decision 1) | `73d5554`, `13c862a` | Auto-route the 8 top-level commercial creates through parent pickers via new `ParentPickerSheet` helper. Fixes 2 real `UUID()` orphan bugs (CO + RFI). Also fixes adjacent Sub-Contract project-scope bug. |
| 4 (cleanup) | `79ae0d0`, `5c4d24a` | WS1 INSERT fix + SEC3 anon-revoke migration. |

### Phase 8 — New features

| Track | Commits | Outcome |
|---|---|---|
| Inventory v1 | `ad9fa6b`, `a5626af`, `2d28a73` | Schema on prod, 4 models + sync, 7 views, MR hook, 10 unit tests, navigation. |
| AI Assistant v1 | `dec606d` | Procurement + Inventory + Contracts context, adaptive suggestion chips, UserDefaults conversation persistence. |
| Polish | `2b0399a` | Auto-Opp toast in `finalizeEstimateSave`, 5 new Inventory pull-side tests (53→58). |
| AI v2 — Threads | `ea849e3` | Per-conversation threads, sidebar sheet, v1→v2 migration, auto-title. |
| Inventory v2 — Reorder | `95f66b5` | `reorderPoint`/`reorderQuantity` fields, low-stock detection, editor UI, AI context update, INV2 migration draft. |
| Multi-Company v1 | `5a1fd19` | `CompanyMembership` model, safe `switchToCompany` orchestration, `CompanySwitcherSheet`. |
| Gantt v1 | `d471df9` | Read-only project timeline, 3 zoom scales, status-colored bars, today-line. |
| Watch + Integrations | `a53ce1f` | Architecture docs (blocked on Xcode target / vendor credentials respectively). |
| Supabase | `af8a23b` | INV2 + MULTI1 + anon-revoke applied to prod via `phase8-v2-supabase` branch. iOS `switchToCompany` now calls `set_active_company` RPC before local cache wipe. |

### Migrations applied to prod (2026-05-10)

- `INV2_reorder_thresholds` — adds nullable reorder columns + non-negative CHECKs + partial index.
- `MULTI1_company_memberships` — new join table + 3 helper functions + relaxed `companies` RLS + 3-row backfill.
- `MULTI1b_anon_revoke` — SEC3-style cleanup. 5 new advisor warnings → 2 (both intentional).

## Test plan

- [x] iOS device build green (`xcodebuild build` on `generic/platform=iOS`)
- [x] iOS simulator build green (iPhone 17 / iOS 26.4.1)
- [x] 58 unit tests green on iPhone 17 sim — no regressions across sync engine, MR push, DJR push, MR + Inventory push/pull, number generation, error mapper, permissions
- [x] Supabase advisors: 5 new warnings introduced by MULTI1 → 2 remaining (both intentional: `authenticated` must call `current_user_company_ids` for RLS evaluation + `set_active_company` for swap)
- [ ] Manual smoke: iPhone — every tab, parent-picker auto-routes, AI threads, multi-company swap, Inventory reorder threshold
- [ ] Manual smoke: iPad — same, verify sidebar layout
- [ ] Manual smoke: AI chat hydrates from disk on cold launch
- [ ] Manual smoke: Material Request creation surfaces inventory availability toast
- [ ] Manual smoke: Gantt scales (Week/Month/Quarter) render with current projects

## Deferred / not in this PR

| Item | Reason |
|---|---|
| Apple Watch companion | Needs Xcode WatchOS target setup; architecture in `docs/phase8_v2/track_4_apple_watch.md` |
| QBO / Sage / Procore integrations | Needs vendor OAuth credentials; architecture in `docs/phase8_v2/track_5_integrations.md` |
| AI v3 (RAG, function-calling, threads multi-window) | Next phase scope |
| Inventory v2.1 (multi-UOM, barcode scan, suggested PO) | Next phase scope |
| Gantt v2 (drag-to-edit, dependency arrows, milestones) | Next phase scope |
| Mac Catalyst | Will land in follow-up PR after this merges |
| Web app | Separate workstream after Mac Catalyst |

## Rollback

Migrations on prod are additive and backward-compatible:
- `INV2`: both new columns are nullable; iOS Optional decode handles missing columns gracefully.
- `MULTI1`: `get_my_company_id()` unchanged, so every existing tenant-scoped RLS policy keeps working. Rollback SQL is documented in `migrations/phase8_multi_company/README.md`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
