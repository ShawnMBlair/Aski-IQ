# Test Checklist — Scheduling Phase 1

Phase 1 ships four upgrades to the existing scheduling module. None
of the original day/week/month views were rebuilt — additive only.
Verify Phase 1 in full before requesting Phase 2 (Dispatch Board).

---

## Pre-flight

- [ ] Build green in Xcode after rebuild
- [ ] Migration `schedule_entries_required_certifications` deployed (verified)
- [ ] No existing scheduling regression — open Schedule tab, all three view modes (Day / Week / Month) render
- [ ] Existing conflict banner still appears for current crew double-bookings

---

## 1.1 — Schedule filters

### Toolbar entry
- [ ] Schedule tab top-right shows a filter icon (`line.3.horizontal.decrease.circle`)
- [ ] When no filter active, icon has no badge
- [ ] When any dimension active, icon flips to filled-blue with a number badge showing dimension count

### Filter sheet — each dimension
- [ ] **Project** picker lists all non-deleted projects, "All projects" default
- [ ] **Crew** picker lists active crews
- [ ] **Foreman** picker lists employees who lead at least one active crew
- [ ] **Status** multi-select with all 5 cases — tap toggles checkmark
- [ ] **Date range** preset picker (Today / This Week / Next 7 / Next 30 / This Month / Custom) — picking a preset auto-fills custom start/end
- [ ] **Custom** preset shows DatePicker for start + end
- [ ] **Clear date range** button removes the constraint
- [ ] **"Clear all filters"** bottom button resets every dimension; greyed when no filter active

### Apply behavior
- [ ] Apply dismisses sheet; calendar immediately re-renders showing filtered entries only
- [ ] Cancel reverts to the snapshot taken on appear (no save)
- [ ] Filter persists across app suspends within the same scene (try home → reopen)
- [ ] Filter does NOT persist across full app kill (uses @SceneStorage, intentional)

### Filter math
- [ ] Filter by **Project A only** → calendar shows only Project A shifts on each day
- [ ] Filter by **Foreman X** → only shifts on crews led by X appear
- [ ] Filter by **Status: Cancelled** → only cancelled shifts show
- [ ] Combine 3+ dimensions — all must match for an entry to appear
- [ ] Date range "Next 7 days" — entries outside that window vanish even if you scroll the week view to a day inside the range (range overrides grain)

---

## 1.2 — Crew Calendar view

### Entry point
- [ ] Open any crew's detail view → see new **"View Full Schedule"** card under Upcoming Shifts
- [ ] Tap → CrewCalendarView opens with title `<Crew name> — Schedule`

### Layout
- [ ] Top: week navigation with prev / "Week of MMM d – MMM d" / next chevrons
- [ ] Summary card: "Scheduled this week: X.X hrs" + "Threshold: 40 hrs"
- [ ] If hours exceed threshold, summary number is orange
- [ ] Conflict banner appears only when this crew has at least one conflict in the visible week — first 3 listed, "and N more" if there are more
- [ ] Day rows: 7 cards, one per day of the week
- [ ] TODAY badge appears on today's row in blue
- [ ] Weekend rows show in grey "Weekend — no shifts scheduled" when empty
- [ ] Each shift cell shows: status-color stripe, project name, time range, task description (if set), required cert chips
- [ ] Tap any shift cell → opens that schedule entry's edit sheet

### Crew-scoped operations
- [ ] Toolbar `+` button creates a new shift pre-tied to this crew (verify crew picker is pre-selected)
- [ ] Prev/next chevrons step the week back/forward
- [ ] Conflict banner reflects the upgraded detector (shows employee-double-book / cert-missing / etc., not just crew double-book)

---

## 1.3 — Conflict detection upgrades

Each conflict type tested independently. Set up a clean state before each (revert sample data or use a throwaway day).

### 1.3a — Crew double-book (refined to time-overlap)
- [ ] Create two shifts: same crew, same day, different projects, **non-overlapping times** (8–12 + 13–17). Save → **NO conflict** (was incorrectly flagged pre-fix)
- [ ] Create two shifts: same crew, same day, different projects, **overlapping times** (8–12 + 11–15). Save → conflict surfaces
- [ ] Create two shifts: same crew, same day, **same project**, overlapping. Save → no conflict (intentional split work)
- [ ] One shift has no shift times set (all-day) + another with shift times same day, different project → conflict (all-day overlaps anything)

### 1.3b — Employee double-book (across crews)
- [ ] Crew A has Employee X. Crew B has Employee X. Schedule both on the same day with overlapping shifts → conflict appears with type `employeeDoubleBooked` (red)
- [ ] Same setup but non-overlapping shifts → no conflict
- [ ] Employee on only one crew → no employee conflict

### 1.3c — Travel buffer
- [ ] Settings: confirm `travelBufferMinutes = 30` (default)
- [ ] Create shift A: 8:00–12:00 on Project X. Create shift B: 12:15–16:00 on Project Y. Same crew. Same day → conflict (only 15 min gap, need 30)
- [ ] Same setup but B starts at 12:30 → no conflict (≥ 30 min gap)
- [ ] Same setup but A and B both on Project X → no conflict (no travel needed within same project)
- [ ] Set `travelBufferMinutes = 0` → all travel-buffer conflicts disappear

### 1.3d — Cert mismatch
- [ ] Create employee Jane with `certifications = ["WHMIS"]`. Add Jane to Crew Alpha. No other members
- [ ] Create shift on Crew Alpha with `requiredCertifications = ["WHMIS", "Confined Space"]` → conflict (no member has both)
- [ ] Add cert "Confined Space" to Jane → conflict disappears on next render
- [ ] Schedule shift with `requiredCertifications = ["WHMIS"]` but **no crew assigned** → conflict says "no crew assigned"

### 1.3e — Overtime threshold
- [ ] Confirm `overtimeWeeklyThresholdHours = 40` (default)
- [ ] Schedule 5 shifts × 9 hours = 45h for one crew in same week → conflict with description "X scheduled 45.0 h this week (over 40 h threshold)"
- [ ] Same but 4 shifts × 9 hours = 36h → no conflict
- [ ] Set threshold to 0 → all overtime conflicts disappear

### Conflict severity / colors
- [ ] Crew + employee double-book + cert-missing show as RED ("Conflict")
- [ ] Project overlap + travel buffer show as ORANGE ("Warning")
- [ ] Weekend + overtime risk show as YELLOW ("Notice")

### Conflict banner integration
- [ ] Main calendar's conflict banner counts include all 6 types (not just crew double-book)
- [ ] Toolbar critical-count badge counts the 3 red types
- [ ] Tapping the banner opens ScheduleConflictListView with all conflicts visible

---

## 1.4 — Schedule → Timesheet handoff

### CTA visibility
- [ ] User is the foreman of Crew Alpha. Today's schedule has a shift for Crew Alpha
- [ ] Open "Log Hours" (TimesheetDailyEntryView) → blue "Start from scheduled shift" section appears at the top with that shift listed
- [ ] User has no scheduled shift today → CTA section is hidden entirely
- [ ] User belongs to a crew but the day's shift is `cancelled` → CTA hides that shift

### Pre-fill behavior
- [ ] Tap a scheduled shift in the CTA → green check appears next to it
- [ ] Project field auto-populates from the shift's projectID
- [ ] Date jumps to the shift's date
- [ ] Start time fills from `shiftStart` (end time stays editable — set when work ends)
- [ ] Cost code auto-populates if one was on the shift
- [ ] Task description auto-populates if non-empty on the shift
- [ ] Re-tap a different shift → new shift's data overwrites; old picked badge moves
- [ ] User-typed cost code is NOT overwritten on re-tap (gentle fill)

### Save with back-link
- [ ] Submit the timesheet → in Supabase logs / Postgres, the new `timesheet_entries` row has `schedule_entry_id` set to the picked shift's UUID
- [ ] Submit without using the CTA → `schedule_entry_id` stays null
- [ ] Existing timesheet flows (manual entry, smart-flow) unaffected

---

## Cross-cutting verification

### Sync engine
- [ ] Edit a shift, add `requiredCertifications = ["Test"]`, Save
- [ ] Verify in Supabase: `SELECT id, required_certifications FROM schedule_entries WHERE id = '<…>'` returns `["Test"]`
- [ ] Pull on a second device: cert list arrives intact
- [ ] Legacy schedule_entries (rows that pre-date the migration) decode as empty array (no crash, no missing-column error)

### AppSettings tunables
- [ ] New settings appear with defaults `travelBufferMinutes = 30`, `overtimeWeeklyThresholdHours = 40` on first launch
- [ ] Setting either to 0 disables the corresponding conflict detector

### Permissions
- [ ] Field worker cannot open the create/edit shift sheet (existing role gate unchanged)
- [ ] Foreman / PM / office admin / manager / executive — full create/edit access including required-certs picker

### No regression
- [ ] Existing day/week/month modes render
- [ ] Material delivery + contract-milestone day overlay still appears
- [ ] "Schedule Anyway" override still works on save when the new conflict detectors fire
- [ ] Acknowledge / reassign / move-shift conflict resolution UI continues to work

---

## What this slice does NOT include (deferred to Phase 2+)

- **Dispatch board** with columns (Unscheduled / Today / Tomorrow / This Week / Conflicts / Completed) — Phase 2
- **Notifications** for shift assignment / change / cancellation / upcoming reminder / foreman daily summary — Phase 3
- **Drag-and-drop** dispatch reassignment — Phase 4
- **Recurring shifts** / "Copy week" — Phase 4
- **Equipment scheduling** integrated with shifts — Phase 4
- **Customer arrival notices** — Phase 4
- **Plan vs actual reporting** dashboard — Phase 4
- **iCal export** — Phase 4
- **Geofenced clock-in** — Phase 4

Per the master prompt: do NOT proceed to Phase 2 until Phase 1 is verified through this checklist.

---

## Files added/modified

### New files
- `ScheduleFilter.swift` — filter model + sheet + Codable bridge
- `CrewCalendarView.swift` — per-crew weekly schedule view
- `TestChecklist_Scheduling_Phase1.md` — this file

### Modified files
- `AppSettings.swift` — added `travelBufferMinutes` (Int = 30), `overtimeWeeklyThresholdHours` (Double = 40)
- `ScheduleEntry.swift` — added `requiredCertifications: [String]` (default empty)
- `ScheduleConflictService.swift` — refined crew-double-book to time-overlap, added 4 new conflict types (employeeDoubleBooked, travelBuffer, certificationMissing, overtimeRisk), upgraded entry-point signature, AppStore extension uses new detectors
- `ScheduleCalendarView.swift` — added filter state via @SceneStorage, filter button in toolbar, filter sheet wiring, `entriesFor(date:)` applies the filter
- `ScheduleEntryCreateEditView.swift` — accepts `preselectedCrewID`, edits required-certifications, normalizes cert list before save
- `CrewDetailView.swift` — "View Full Schedule" link to CrewCalendarView
- `TimesheetDailyEntryView.swift` — "Start from scheduled shift" CTA, applies pre-fill, passes scheduleEntryID through to save
- `TimesheetViewModel.swift` — `createEntry` accepts optional `scheduleEntryID` parameter
- `SyncEngine.swift` — schedule_entries pull/push round-trips `required_certifications` JSONB column

### Database
- Migration applied: `schedule_entries_required_certifications` adds `required_certifications jsonb NOT NULL DEFAULT '[]'::jsonb` + GIN index

### Untouched (no regression risk)
- Quote / Estimate / Material Sale workflows
- Existing day/week/month calendar UIs
- Existing conflict resolution UI (acknowledge/reassign/move/override)
- Existing role gating
- Existing crew/employee/project models — no breaking changes

---

## When Phase 1 verifies clean

Reply "Phase 1 verified" or paste any test that fails. I'll triage anything failing before Phase 2.
