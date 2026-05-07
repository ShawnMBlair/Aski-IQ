// LaborPlanSection.swift
// Aski IQ — SR-1.4 take-off labor plan editor (used by QuoteCreateView).
//
// PURPOSE
// Lets the estimator declare WHAT the work needs in resource terms:
//   • how many people (count)
//   • what trade / class
//   • required certifications
//   • optional preferred / required individual workers
//   • optional preferred crew (back-compat with SR-1.3)
//
// The recommendation engine reads this on Generate Plan and assembles
// any valid combination — fixed crew, custom crew, or single worker —
// that satisfies the plan. This breaks the bottleneck of pinning a
// single crew when other qualified workers are available.
//
// SCOPE — SR-1.4
//   • Single labor plan per quote (per-line-item plans deferred to a
//     future SR-1.5 once the pattern is validated).
//   • Worker class is free-text; matched case-insensitively against
//     `Employee.trade`. The picker offers known trades from the
//     existing employee directory plus a "custom…" option.
//   • Required workers (hard pins) and preferred workers (soft pins)
//     surface as multi-select lists. Both are scoped to the
//     `workerClass` filter when set, so you can't accidentally pin a
//     non-matching trade.

import SwiftUI

struct LaborPlanSection: View {
    @Binding var plan: LaborRequirement
    @EnvironmentObject var store: AppStore

    /// Free-text input for the cert add-row.
    @State private var newCertText: String = ""

    /// Distinct list of trades observed across all active employees.
    /// Used to populate the worker-class Picker. Always includes a
    /// "Custom…" sentinel for free-text entry.
    private var knownTrades: [String] {
        let trades = store.employees
            .compactMap { $0.trade?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Set(trades)).sorted()
    }

    /// Active employees, optionally filtered by the chosen worker
    /// class so the preferred / required pickers can't accidentally
    /// land a worker outside the trade scope.
    private var eligibleWorkers: [Employee] {
        let pool = store.employees.filter { $0.isActive && !$0.isDeleted }
        guard let cls = plan.workerClass, !cls.isEmpty else { return pool.sorted { $0.fullName < $1.fullName } }
        return pool
            .filter { ($0.trade?.lowercased() ?? "") == cls.lowercased() }
            .sorted { $0.fullName < $1.fullName }
    }

    private var activeCrews: [Crew] {
        store.crews.filter { $0.isActive && !$0.isDeleted }.sorted { $0.name < $1.name }
    }

    var body: some View {
        Section {
            countRow
            classRow
            certificationsRow
        } header: {
            Text("Labor Plan")
        } footer: {
            Text("Tells the AI scheduling engine what the work needs. Engine then assembles any valid combination — a fixed crew, a custom crew, or one worker — and picks the earliest window where the people are actually free.")
                .font(.caption)
        }

        Section {
            preferredWorkersRow
            requiredWorkersRow
        } header: {
            Text("Specific people (optional)")
        } footer: {
            Text("Preferred workers boost scoring but the engine can substitute. Required workers are hard pins — the engine will push the start date forward to find a window where ALL of them are free.")
                .font(.caption)
        }

        Section {
            preferredCrewRow
        } header: {
            Text("Crew preference (optional)")
        } footer: {
            Text("If a standing crew has enough qualified members all free in the same window, the engine prefers them over assembling a custom crew. Leave blank to let the engine pick.")
                .font(.caption)
        }
    }

    // MARK: - Rows

    private var countRow: some View {
        Stepper(value: $plan.count, in: 1...20, step: 1) {
            HStack {
                Text("Workers needed")
                Spacer()
                Text("\(plan.count)")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var classRow: some View {
        // Worker class — Picker populated from observed trades, with
        // the canonical "any" option and a custom-entry path.
        Picker("Worker class", selection: workerClassBinding) {
            Text("Any trade").tag("")
            ForEach(knownTrades, id: \.self) { trade in
                Text(trade).tag(trade)
            }
        }
        .pickerStyle(.menu)
        // Custom-entry field shown when the user wants a class not in
        // the Picker. Useful for new trades the company is adding.
        TextField("Or type a trade (e.g. Insulator)", text: workerClassBinding)
            .textInputAutocapitalization(.words)
    }

    private var workerClassBinding: Binding<String> {
        Binding(
            get: { plan.workerClass ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                plan.workerClass = trimmed.isEmpty ? nil : trimmed
                // Removing the class loosens the eligibility filter
                // and may make previously-hidden workers visible
                // again. Wipe pinned workers that no longer match
                // the new filter so the engine doesn't get stale IDs.
                let eligibleIDs = Set(eligibleWorkers.map { $0.id })
                plan.preferredWorkerIDs = plan.preferredWorkerIDs.filter { eligibleIDs.contains($0) }
                plan.requiredWorkerIDs = plan.requiredWorkerIDs.filter { eligibleIDs.contains($0) }
            }
        )
    }

    private var certificationsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if plan.requiredCertifications.isEmpty {
                Text("No certifications required.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(plan.requiredCertifications, id: \.self) { cert in
                    HStack {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundColor(.indigo)
                        Text(cert)
                        Spacer()
                        Button(role: .destructive) {
                            plan.requiredCertifications.removeAll { $0 == cert }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                TextField("e.g. WHMIS, Confined Space", text: $newCertText)
                    .textInputAutocapitalization(.words)
                Button {
                    addCert()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .disabled(newCertText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var preferredWorkersRow: some View {
        // Multi-select inline list.
        VStack(alignment: .leading, spacing: 4) {
            Label("Preferred workers (\(plan.preferredWorkerIDs.count) selected)",
                  systemImage: "person.crop.circle")
                .font(.subheadline.bold())
                .foregroundColor(.secondary)
            ForEach(eligibleWorkers) { emp in
                workerToggleRow(emp,
                                isSelected: plan.preferredWorkerIDs.contains(emp.id),
                                toggle: { togglePreferred(emp.id) })
            }
        }
    }

    private var requiredWorkersRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Required workers (\(plan.requiredWorkerIDs.count) selected)",
                  systemImage: "lock.fill")
                .font(.subheadline.bold())
                .foregroundColor(.secondary)
            ForEach(eligibleWorkers) { emp in
                workerToggleRow(emp,
                                isSelected: plan.requiredWorkerIDs.contains(emp.id),
                                toggle: { toggleRequired(emp.id) })
            }
        }
    }

    private var preferredCrewRow: some View {
        Picker("Preferred crew", selection: preferredCrewBinding) {
            Text("No crew preference").tag(UUID?.none)
            ForEach(activeCrews) { crew in
                Text(crew.name).tag(Optional(crew.id))
            }
        }
        .pickerStyle(.menu)
    }

    private var preferredCrewBinding: Binding<UUID?> {
        Binding(
            get: { plan.preferredCrewID },
            set: { plan.preferredCrewID = $0 }
        )
    }

    @ViewBuilder
    private func workerToggleRow(_ emp: Employee,
                                 isSelected: Bool,
                                 toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(isSelected ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(emp.fullName)
                        .foregroundColor(.primary)
                    if let trade = emp.trade, !trade.isEmpty {
                        Text(trade)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if !emp.certifications.isEmpty {
                    Text(emp.certifications.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundColor(.indigo)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func addCert() {
        let trimmed = newCertText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let lower = trimmed.lowercased()
        if !plan.requiredCertifications.contains(where: { $0.lowercased() == lower }) {
            plan.requiredCertifications.append(trimmed)
        }
        newCertText = ""
    }

    private func togglePreferred(_ id: UUID) {
        if let idx = plan.preferredWorkerIDs.firstIndex(of: id) {
            plan.preferredWorkerIDs.remove(at: idx)
        } else {
            plan.preferredWorkerIDs.append(id)
        }
    }

    private func toggleRequired(_ id: UUID) {
        if let idx = plan.requiredWorkerIDs.firstIndex(of: id) {
            plan.requiredWorkerIDs.remove(at: idx)
        } else {
            plan.requiredWorkerIDs.append(id)
        }
    }
}
