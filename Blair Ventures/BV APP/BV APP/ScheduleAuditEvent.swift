// ScheduleAuditEvent.swift
// Aski IQ — Phase 2 hardening: append-only audit log for every
// schedule mutation. Captures who/when/what so any later "what changed
// here?" question can be answered from the data, not from memory.
//
// Design:
//   • Append-only — once written, an event is immutable. The DB has no
//     UPDATE/DELETE policy on the table.
//   • Push-only — iOS produces these events and pushes them to Supabase.
//     No pull — reading audit history is a one-off query (a future
//     "Schedule History" view can use a paged select).
//   • Captured at the chokepoint (`AppStore.upsertScheduleEntry`) so
//     every save path — manual edit, force-save, reassign, move,
//     quick-assign, import — produces a row.
//
// Out of scope (deferred):
//   • Pull / display of historical audit entries in the UI
//   • Notifications on suspicious-looking diffs
//   • Geo / IP capture (would require server-side enrichment)

import Foundation

/// Discrete category for a single audit row. Keep these strings stable
/// — they're persisted to Postgres and any analytics layer downstream
/// will hard-code them.
enum ScheduleAuditAction: String, Codable {
    case created       // first time the entry was upserted
    case edited        // any mutation that didn't fall into the categories below
    case reassigned    // crewID changed
    case dateMoved     = "date_moved"
    case cancelled
    case completed
    case deleted       // soft-delete (isDeleted = true)
    case quickAssigned = "quick_assigned"   // assigned via Dispatch board Quick Assign
    case overrideUsed  = "override"         // "Schedule Anyway" / force=true
}

/// Single immutable audit row. Stored locally in `AppStore.scheduleAuditEvents`
/// until pushed; then `syncStatus = .synced` and stays in memory only as
/// long as the device cares. (No pull, so the local array is a write-ahead
/// queue, not a mirror of the server's full history.)
struct ScheduleAuditEvent: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var companyID: UUID
    var scheduleEntryID: UUID
    var projectID: UUID?
    var userID: UUID?
    var userName: String?
    var action: ScheduleAuditAction
    var oldCrewID: UUID?
    var newCrewID: UUID?
    var oldDate: Date?
    var newDate: Date?
    /// True when the save fired with at least one live conflict in the
    /// current detector pass (see `ScheduleConflictService`).
    var conflictDetected: Bool = false
    /// rawValues of the conflict types observed at write time, if any.
    /// Stored as text[] in Postgres — no need for structured access.
    var conflictTypes: [String] = []
    /// True when the user explicitly chose "Schedule Anyway" / force=true
    /// to bypass a detected conflict. Pairs with `conflictDetected`.
    var overrideUsed: Bool = false
    /// Optional human-readable note (e.g. "Schedule Anyway from
    /// QuickAssignSheet" or "Reassigned from ConflictResolutionSheet").
    var notes: String? = nil
    var createdAt: Date = Date()
    var syncStatus: SyncStatus = .pending
}
