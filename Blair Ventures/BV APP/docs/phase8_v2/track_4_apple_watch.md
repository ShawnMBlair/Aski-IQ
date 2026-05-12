# Track 4 — Apple Watch companion app

**Status:** ⏳ BLOCKED on Xcode project edits + WatchOS target setup.
**Date:** 2026-05-10
**Phase:** 8 / v2+
**Effort estimate:** 8–12 hours once unblocked.

This doc captures the architecture for an Aski IQ Watch companion so the implementation can drop straight into the codebase once the target exists.

## Why blocked

Creating a WatchOS target requires:
1. Adding a new target to the Xcode project (`File → New → Target → Watch App`).
2. Choosing whether to embed the Watch app in the iPhone app (recommended) or ship as standalone.
3. Configuring the App Group / shared keychain entitlements so the Watch and iPhone apps share auth + cached data.
4. Adjusting code signing for the new target.

These are project-config changes that should be made deliberately in Xcode by a developer who can verify the resulting `.xcodeproj` builds end-to-end on a Watch simulator before any code lands. Doing this from an automation pass risks producing a corrupted `.xcodeproj` that's painful to debug after the fact.

## Scope — v1 Watch features

Keep v1 narrow. The Watch should be a **read-only field companion** with one write path: shift start/stop. Everything else routes back to the iPhone.

| Feature | v1 | v2 |
|---|---|---|
| Today's projects (assigned to current user) | ✅ | |
| Today's schedule entries (start/end time, project name) | ✅ | |
| Active timesheet shift — start/stop with location stamp | ✅ | |
| Safety incident quick-log (severity + 1-line description) | ✅ | |
| Open RFIs assigned to current user | | ✅ |
| Material request quick-create from a saved template | | ✅ |
| Equipment scan (via Watch camera? — no Watch has a camera; defer) | ❌ | ❌ |
| Voice memo → Claude transcription for DJR | | ✅ |

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  iPhone App (existing)                                           │
│                                                                  │
│  AppStore  ── publishes @Published arrays                        │
│  SyncEngine ── push/pull via Supabase                            │
│  WCSession.shared.activate()                                     │
│              │                                                   │
│              ▼ updateApplicationContext()                        │
│  Sends a compact "WatchSnapshot" struct any time the relevant    │
│  data changes (debounced).                                       │
└──────────────────────────────────────────────────────────────────┘
                              │
                  WatchConnectivity framework
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Watch App (new target)                                          │
│                                                                  │
│  WatchAppStore  ── observes the WatchSnapshot                    │
│  WCSession delegate receives updates                             │
│  Local UI reads from WatchAppStore                               │
│                                                                  │
│  Writes (start shift, log incident) → WCSession.sendMessage      │
│  to iPhone → iPhone's AppStore mutates + SyncEngine pushes       │
└──────────────────────────────────────────────────────────────────┘
```

Why iPhone-mediated writes instead of direct Supabase calls from the Watch:
- The Watch's network stack is unreliable (relies on iPhone or LTE depending on model).
- Auth tokens, RLS state, and conflict-detection logic all live on the iPhone today. Re-implementing them on the Watch doubles the surface area.
- WatchConnectivity's `sendMessage` is fire-and-forget with reply — the Watch UI can show optimistic state, the iPhone does the actual sync, and the Watch sees the canonical truth via the next snapshot.

## Data contract — WatchSnapshot

```swift
struct WatchSnapshot: Codable {
    let userName: String
    let companyName: String
    let todayProjects: [WatchProjectSummary]
    let todayShifts:   [WatchShiftSummary]
    let activeShift:   WatchActiveShift?      // nil if not clocked in
    let openRFICount:  Int
    let openIncidentCount: Int
}

struct WatchProjectSummary: Codable, Identifiable {
    let id: UUID
    let name: String
    let clientName: String
    let address: String?
}

struct WatchShiftSummary: Codable, Identifiable {
    let id: UUID
    let projectName: String
    let startTime: Date
    let endTime: Date
    let crewName: String?
}

struct WatchActiveShift: Codable {
    let timesheetEntryID: UUID
    let projectID: UUID
    let projectName: String
    let startedAt: Date
    let locationOK: Bool   // for the geofence indicator
}
```

Snapshot size budget: ~5KB. WCSession.updateApplicationContext has a soft cap around 65KB but lower payloads sync faster.

## Implementation outline

### Phase A — project setup (manual, ~1 hour)

1. Add WatchOS target to `BV APP.xcodeproj`.
2. Embed in iPhone app.
3. Configure App Group `group.com.askisearch.bvapp` (or existing — check `entitlements`).
4. Verify builds + runs on Watch sim.

### Phase B — WCSession plumbing (~2 hours)

`Blair Ventures/BV APP/BV APP/WatchBridge.swift`:
- `WatchBridgeService` singleton, `@MainActor`.
- `activate()` called from `BV_APPApp.init`.
- Observes the relevant AppStore Combine publishers (projects, scheduleEntries, timesheets, incidents, rfis), debounces to 1Hz, builds a `WatchSnapshot`, sends via `updateApplicationContext`.
- `session(_:didReceiveMessage:replyHandler:)` handles incoming Watch writes:
  - `startShift(projectID:)` → calls `store.startTimesheet(projectID:)` then replies with the new shift ID.
  - `endShift(entryID:)` → calls `store.endTimesheet(id:)` and replies success.
  - `logIncident(severity:summary:projectID:)` → calls `store.upsertIncident(...)`.

### Phase C — Watch app (~5 hours)

`BV APP Watch/` target:
- `WatchRootView` with TabView: Today / Shift / Log.
- `TodayTab` — list of today's projects + shifts.
- `ShiftTab` — big "Start Shift" / "Stop Shift" button, shows running time.
- `LogTab` — incident quick-log form (severity picker + text field).
- `WatchAppStore` observable — owns the latest `WatchSnapshot` + handles WCSession delegate callbacks for write replies.

### Phase D — Complications (~2 hours)

- Modular complication showing today's project count + open incident count.
- Update via WidgetKit + `CLKComplicationServer.sharedInstance().reloadTimeline(for:)` on snapshot change.

## Open questions for product

1. **Authentication on the Watch** — does the user need to sign in separately on the Watch, or is the iPhone session enough? (Recommendation: iPhone session via App Group keychain; Watch refuses to function if the iPhone isn't signed in.)
2. **Offline shifts** — if the Watch has no LTE and the iPhone is far away, can the user still start a shift? (Recommendation: yes; queue locally, sync when reconnected.)
3. **Watch-only workflow features** — anything the field crew specifically wants on-wrist that isn't in the v1 list above?

## Files to create when unblocked

```
BV APP Watch/                    — new target
├── BV APP WatchApp.swift        — @main entry
├── WatchAppStore.swift          — Observable, owns WatchSnapshot
├── WatchBridgeService.swift     — WCSession delegate (Watch side)
├── Views/
│   ├── WatchRootView.swift
│   ├── TodayTab.swift
│   ├── ShiftTab.swift
│   └── LogTab.swift
└── Complications/
    └── WatchComplication.swift

Blair Ventures/BV APP/BV APP/
└── WatchBridge.swift            — iPhone-side WCSession delegate
```

## When this unblocks

Tell me: *"Watch target is set up — proceed with Phase B"* and I'll wire the bridge service + write the Watch app source files. The architecture above is the contract.
