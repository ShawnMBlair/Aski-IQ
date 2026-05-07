// LaborRequirement.swift
// Aski IQ — SR-1.4 labor pre-plan / take-off labor requirements.
//
// PURPOSE
// Captures what the WORK needs (how many people, what trade, what
// certs, optional preferences) so the scheduling engine can satisfy
// it with any valid combination of resources — a fixed crew, a
// custom crew assembled from qualified workers, or a single
// individual worker.
//
// Pre-SR-1.4 the take-off layer could only pin a single crew. That
// pinned the project's start date to that crew's availability,
// which delayed kickoff when other qualified workers were idle.
// LaborRequirement replaces the single-crew pin with a declarative
// "this is what we need" payload that the engine can satisfy
// flexibly.
//
// PERSISTENCE
// Stored as JSONB on `quotes.labor_plan` and `projects.labor_plan`.
// All fields optional — an empty struct means "no plan; engine
// picks best fit."
//
// LIFECYCLE
//   1. Estimator builds the take-off → fills in the labor plan on
//      the Quote.
//   2. Quote is accepted → `convertQuoteToProject` copies the plan
//      onto the Project.
//   3. Command Centre's Section 1 surfaces the project; the engine
//      reads `project.laborPlan` to pick resources.
//
// FUTURE (deferred)
//   • Per-line-item plans (e.g. "Cost code INS-001 needs 2 insulators
//     with WHMIS, INS-002 needs 1 lead").
//   • Required equipment alongside required workers.
//   • Auto-derive requiredCertifications from the cost-code library.

import Foundation

struct LaborRequirement: Codable, Equatable {

    // MARK: - Codable
    //
    // Explicit init(from:) and encode(to:) instead of the auto-
    // synthesized versions. The synthesized Decodable can fail when
    // a struct's only properties have default values and the JSON
    // input is `{}` (server-side default for new rows). Hand-written
    // Codable using `decodeIfPresent` everywhere makes decoding from
    // `{}` produce a fully-defaulted struct on every Swift version.
    //
    // BUG THIS FIXES (2026-05): every Project row from Supabase carries
    // `labor_plan: {}` after the SR-1.4 migration. The pull's auto-
    // synthesized decoder threw on the empty object, the throw bubbled
    // up to the array-level decode, and the entire `store.projects`
    // assignment was skipped — leaving the Projects tab empty. Custom
    // Codable here makes empty payloads decode reliably.

    private enum CodingKeys: String, CodingKey {
        case count
        case workerClass
        case requiredCertifications
        case preferredWorkerIDs
        case requiredWorkerIDs
        case preferredCrewID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.count                  = try c.decodeIfPresent(Int.self,        forKey: .count) ?? 1
        self.workerClass            = try c.decodeIfPresent(String.self,     forKey: .workerClass)
        self.requiredCertifications = try c.decodeIfPresent([String].self,   forKey: .requiredCertifications) ?? []
        self.preferredWorkerIDs     = try c.decodeIfPresent([UUID].self,     forKey: .preferredWorkerIDs)     ?? []
        self.requiredWorkerIDs      = try c.decodeIfPresent([UUID].self,     forKey: .requiredWorkerIDs)      ?? []
        self.preferredCrewID        = try c.decodeIfPresent(UUID.self,       forKey: .preferredCrewID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(count, forKey: .count)
        try c.encodeIfPresent(workerClass, forKey: .workerClass)
        try c.encode(requiredCertifications, forKey: .requiredCertifications)
        try c.encode(preferredWorkerIDs,     forKey: .preferredWorkerIDs)
        try c.encode(requiredWorkerIDs,      forKey: .requiredWorkerIDs)
        try c.encodeIfPresent(preferredCrewID, forKey: .preferredCrewID)
    }

    /// How many workers the work needs. Default 1 = single-person
    /// task. Higher counts let the engine assemble crews or custom
    /// crews instead of a single individual.
    var count: Int = 1

    /// Worker trade / class. Matches `Employee.trade` case-
    /// insensitively. nil or empty = any trade qualifies.
    /// e.g. "Insulator", "Scaffolder", "Welder", "Electrician".
    var workerClass: String? = nil

    /// Cert names every assigned worker must carry. Empty = no
    /// certification requirement.
    /// Free-text matching against `Employee.certifications`,
    /// case-insensitive (matches the existing schedule-entry
    /// requiredCertifications behavior).
    var requiredCertifications: [String] = []

    /// Soft preference — engine boosts these workers in scoring but
    /// will substitute equivalents if any preferred worker is
    /// unavailable. Empty = no preference.
    var preferredWorkerIDs: [UUID] = []

    /// Hard pin — engine MUST use exactly these workers (subject to
    /// `count`). When set, the engine searches for the earliest
    /// window where ALL pinned workers are simultaneously free.
    /// Use sparingly — pinning specific workers narrows
    /// scheduling flexibility the same way pinning a crew did.
    var requiredWorkerIDs: [UUID] = []

    /// Soft crew preference — if a fixed crew has enough qualified
    /// members all simultaneously free, the engine prefers that
    /// crew over assembling a custom crew of equivalents.
    /// nil = no crew preference.
    var preferredCrewID: UUID? = nil

    // MARK: - Convenience init for legacy preferred_crew_id migration

    /// Builds a plan from the legacy single-crew preference column.
    /// Used by `QuoteCreateView.populate()` when an older quote has
    /// `preferredCrewID` set but an empty `laborPlan` payload.
    init(preferredCrewID: UUID) {
        self.preferredCrewID = preferredCrewID
    }

    init() {}

    // MARK: - Convenience

    /// True when the user supplied any meaningful field. Drives
    /// engine pathway selection — empty plans fall through to the
    /// legacy "find best resource" logic; populated plans constrain
    /// the candidate pool by class + certs.
    var isEmpty: Bool {
        count == 1
            && (workerClass == nil || workerClass?.isEmpty == true)
            && requiredCertifications.isEmpty
            && preferredWorkerIDs.isEmpty
            && requiredWorkerIDs.isEmpty
            && preferredCrewID == nil
    }

    /// Normalize for storage — trims whitespace, drops empties,
    /// dedupes case-insensitively. Match how ScheduleEntry
    /// requiredCertifications gets cleaned.
    func normalized() -> LaborRequirement {
        var copy = self
        copy.workerClass = workerClass?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        var seenCerts = Set<String>()
        copy.requiredCertifications = requiredCertifications
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seenCerts.insert($0.lowercased()).inserted }
        copy.preferredWorkerIDs = Array(Set(preferredWorkerIDs))
        copy.requiredWorkerIDs = Array(Set(requiredWorkerIDs))
        copy.count = max(1, count)
        return copy
    }
}

// MARK: - Small helper

private extension String {
    /// Returns nil if the string is empty after trimming.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
