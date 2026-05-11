# Aski IQ v1.0 — Stabilization + Phase 8 v2+ + Mac Catalyst

Ships the full 8-phase stabilization plan, all autonomously-completable Phase 8 v2+ tracks, Mac Catalyst readiness, a deep procurement-workflow defect sweep, and the post-audit polish round. **42 commits.**

## Summary

Closes the multi-month stabilization plan agreed 2026-05-09 plus every Phase 8 v2+ feature that didn't require external prerequisites (Watch target, vendor OAuth). Adds Mac Catalyst as a shipped platform — Aski IQ now runs on iPhone, iPad, and macOS from the same codebase. iOS device + Mac Catalyst builds green; 58+ unit tests green on iPhone 17 / iOS 26.4.1 sim.

## What's in here

### 1. Stabilization (Phases 2 → 7)

| Phase | Commits | Outcome |
|---|---|---|
| 2 — DB foundation | `5aad052`, `855dae8`, `238d002`, `ffac107`, `76b5bce` | Foundational baseline migration registered on prod at version `00000000000000`. Fresh branches now replay all 104 historical migrations cleanly to `FUNCTIONS_DEPLOYED`. |
| 6 (Wave 4) | `5ad9bcd` | `canPerform(action:amount:)` engine-driven via `workflow_settings`. 16 action keys × 7 roles seeded. |
| 7 (audit) | `76676d2`, `ee827cc`, `41def3a` | Orphan-record prevention catalog + Decisions 2+3 re-graded as already-wired. |
| 7 (Decision 1) | `73d5554`, `13c862a` | Auto-route the 8 top-level commercial creates through parent pickers via new `ParentPickerSheet` helper. Fixes 2 real `UUID()` orphan bugs (CO + RFI). Also fixes adjacent Sub-Contract project-scope bug. |
| 4 (cleanup) | `79ae0d0`, `5c4d24a` | WS1 INSERT fix + SEC3 anon-revoke migration. |

### 2. Phase 8 — New features

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

### 3. Mac Catalyst readiness — new platform

| Commit | Outcome |
|---|---|
| `d5f6022` | Enable Mac Catalyst target. Aski IQ now ships on iPhone, iPad, **and macOS** from the same codebase. |
| `6d716dc` | Add network + photos + camera + location entitlements so sign-in + capture flows work in the sandboxed Catalyst container. |
| `dcc341d` | Disable App Sandbox so users can sign in with their existing Apple ID without re-pairing on Mac. |
| `414e4b1` | Fix Settings sheet not dismissing after save on Mac Catalyst. |

### 4. Procurement workflow defect sweep

Triggered by real-world repro of BV-MR-2026-0001 (couldn't convert MR → PO). Cascaded into a full re-audit of the procurement flow.

| Commit | Defect → fix |
|---|---|
| `5d0de49` | PO create-edit sheet wouldn't scroll when keyboard up |
| `b9d84c4` | MR-approved-no-supplier flow: collapsed scattered warning + action into one card |
| `39243fd` | **Root-cause fix for BV-MR-2026-0001**: PO creation + PDF share for supplier-less MRs |
| `a6ff1a3` | Supplier picker bypass, PO edit-lock, approval-PDF generation |
| `3d1815f` | Manual "Mark as Ordered" button for approved MRs (was implicit-only) |
| `1d9a6e3` | Direct camera capture for delivery photos (was photo-library only) |
| `51766d0` | Close + Cancel terminal actions on Material Requests and Purchase Orders |
| `7136299` | Monotonic request/PO number generation across soft-deletes (was reusing freed numbers, e.g. every new request started at BV-MR-2026-0001) |

### 5. Debug audit + Failed Syncs polish

Final post-stabilization sweep — silent-failure surface area + the only "offline conflict resolution" UI in the app.

| Commit | Outcome |
|---|---|
| `7ea9d67` | Fix 3 silent-push-fail bugs (Invoice / CO / Contract missing `opportunityID` on push) + gate VisionKit doc scanner on iPhone-only (Catalyst regression) |
| `678b0fa` | MEDIUM batch: `.scrollDismissesKeyboard(.interactively)` on 12 forms + live camera (`Take Photo` next to `Photo Library`) on 5 photo flows |
| `f0215d6` | Surface per-row error reason for CRM pushes — Failed Syncs screen was designed to show diagnoses but CRM sync was dropping the error |
| `91864c0` | Failed Syncs redesign per `/design-critique`: inline Retry chip, "Waiting on _Parent_" dependency badges, plain-language banner, polished auto-dismissing empty state, cross-platform toolbar placements |
| `b9193b0` | Failed Syncs completeness: extend `recordSyncError` + `clearSyncError` to 22 remaining entity types (projects, employees, crews, schedule, timesheets, form templates/submissions, audit, exceptions, budgets, subs, products, pricings, clients, estimates, clauses, milestones, compliance, waivers, cost codes). Every push catch block in the app now surfaces its server-side rejection reason on the Failed Syncs screen. |

### Migrations applied to prod (2026-05-10)

- `INV2_reorder_thresholds` — adds nullable reorder columns + non-negative CHECKs + partial index.
- `MULTI1_company_memberships` — new join table + 3 helper functions + relaxed `companies` RLS + 3-row backfill.
- `MULTI1b_anon_revoke` — SEC3-style cleanup. 5 new advisor warnings → 2 (both intentional).

## Test plan

- [x] iOS device build green (`xcodebuild build` on `generic/platform=iOS`)
- [x] iOS simulator build green (iPhone 17 / iOS 26.4.1)
- [x] **Mac Catalyst build green** (`platform=macOS,variant=Mac Catalyst`)
- [x] 58 unit tests green on iPhone 17 sim — no regressions across sync engine, MR push, DJR push, MR + Inventory push/pull, number generation, error mapper, permissions
- [x] Supabase advisors: 5 new warnings introduced by MULTI1 → 2 remaining (both intentional: `authenticated` must call `current_user_company_ids` for RLS evaluation + `set_active_company` for swap)
- [ ] **Manual smoke — iPhone**: every tab, parent-picker auto-routes, AI threads, multi-company swap, Inventory reorder threshold, MR→PO→Receive flow, camera capture in DJR / Incident / Certificate / CRM attachment
- [ ] **Manual smoke — iPad**: same surface as iPhone + verify sidebar layout, photo+camera split, Settings dismiss
- [ ] **Manual smoke — Mac Catalyst**: sign-in with existing Apple ID, Settings dismiss after save, Failed Syncs sheet, doc scanner correctly hidden, file picker
- [ ] Manual smoke: AI chat hydrates from disk on cold launch
- [ ] Manual smoke: Material Request creation surfaces inventory availability toast
- [ ] Manual smoke: Gantt scales (Week / Month / Quarter) render with current projects
- [ ] Manual smoke: Failed Syncs row shows actual error reason + "Waiting on Parent" badge when applicable; auto-dismisses after clearing the queue
- [ ] **Push notification provisioning** — verify entitlements file references resolve in Xcode auto-signing (CLI was using `CODE_SIGNING_ALLOWED=NO` as workaround during development)

## Deferred / not in this PR

| Item | Reason |
|---|---|
| Apple Watch companion | Needs Xcode WatchOS target setup; architecture in `docs/phase8_v2/track_4_apple_watch.md` |
| QBO / Sage / Procore integrations | Needs vendor OAuth credentials; architecture in `docs/phase8_v2/track_5_integrations.md` |
| AI v3 (RAG, function-calling, threads multi-window) | Next phase scope |
| Inventory v2.1 (multi-UOM, barcode scan, suggested PO) | Next phase scope |
| Gantt v2 (drag-to-edit, dependency arrows, milestones) | Next phase scope |
| Remove `canPerformLegacy` fallback | Once WS1 seed is proven in admin practice |
| Pull-side test coverage beyond DJR + Inventory | Mechanical follow-up; `FakeSyncClient` pattern documented |
| Web app | Separate workstream — 3-4 months after v1.0 ships |

## Rollback

Migrations on prod are additive and backward-compatible:
- `INV2`: both new columns are nullable; iOS Optional decode handles missing columns gracefully.
- `MULTI1`: `get_my_company_id()` unchanged, so every existing tenant-scoped RLS policy keeps working. Rollback SQL is documented in `migrations/phase8_multi_company/README.md`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
