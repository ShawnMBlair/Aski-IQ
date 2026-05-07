// MultiTabValidationEngine.swift
// Aski IQ – Multi-Tab Import Validation (v1.0)

import Foundation

// MARK: - Engine

final class MultiTabValidationEngine {

    private let store: AppStore

    init(store: AppStore) { self.store = store }

    // MARK: - Validate All Tabs

    /// Validates every tab's rows. Returns updated rows keyed by record type.
    func validateAll(
        tabs: inout [ImportRecordType: [ImportRow]],
        companyID: UUID
    ) {
        for type in tabs.keys.sorted(by: { $0.processingOrder < $1.processingOrder }) {
            guard var rows = tabs[type] else { continue }
            validate(rows: &rows, recordType: type, companyID: companyID)
            tabs[type] = rows
        }
    }

    // MARK: - Validate Single Tab

    func validate(
        rows: inout [ImportRow],
        recordType: ImportRecordType,
        companyID: UUID
    ) {
        for i in rows.indices {
            rows[i].issues = []
            rows[i].existingMatchID = nil

            // 1. Company ID guard
            checkCompanyID(&rows[i], companyID: companyID)

            // 2. Action type
            checkActionType(&rows[i])

            // 3. Required fields
            checkRequired(&rows[i], recordType: recordType)

            // 4. Format validation
            checkFormats(&rows[i], recordType: recordType)

            // 5. Duplicate detection
            detectDuplicate(&rows[i], recordType: recordType)

            // 6. Set final state
            rows[i].state = rows[i].effectiveState
        }
    }

    // MARK: - Company ID Guard

    private func checkCompanyID(_ row: inout ImportRow, companyID: UUID) {
        let cellValue = row.mappedData["company_id"] ?? row.rawData["company_id"] ?? ""
        if cellValue.isEmpty { return } // blank is allowed — app fills it
        if cellValue.lowercased() != companyID.uuidString.lowercased() {
            row.issues.append(err(row.rowIndex, field: "company_id",
                "company_id '\(cellValue)' does not match your account. This row will be blocked."))
        }
    }

    // MARK: - Action Type

    private func checkActionType(_ row: inout ImportRow) {
        let raw = (row.mappedData["action_type"] ?? row.rawData["action_type"] ?? "").lowercased()
        if raw.isEmpty || raw == "create" { return }
        let valid = ["create", "update", "archive", "skip"]
        if !valid.contains(raw) {
            row.issues.append(err(row.rowIndex, field: "action_type",
                "action_type must be create, update, archive, or skip. Got '\(raw)'."))
        }
        if (raw == "update" || raw == "archive") {
            let recID = row.mappedData["app_record_id"] ?? row.rawData["app_record_id"] ?? ""
            if recID.isEmpty {
                row.issues.append(err(row.rowIndex, field: "app_record_id",
                    "action_type '\(raw)' requires app_record_id."))
            }
        }
        if raw == "skip" { row.isSkipped = true }
    }

    // MARK: - Required Fields

    private func checkRequired(_ row: inout ImportRow, recordType: ImportRecordType) {
        for field in recordType.requiredFields {
            let val = (row.mappedData[field] ?? row.rawData[field] ?? "").trimmingCharacters(in: .whitespaces)
            if val.isEmpty {
                row.issues.append(err(row.rowIndex, field: field,
                    "'\(field)' is required and cannot be blank."))
            }
        }
    }

    // MARK: - Format Checks

    private func checkFormats(_ row: inout ImportRow, recordType: ImportRecordType) {
        let data = row.mappedData.merging(row.rawData) { mapped, _ in mapped }

        // Email fields
        for key in ["email", "contact_email"] {
            if let v = nonEmpty(data[key]), !isValidEmail(v) {
                row.issues.append(err(row.rowIndex, field: key, "Invalid email format: \(v)"))
            }
        }

        // Phone fields (warning only)
        for key in ["phone", "contact_phone"] {
            if let v = nonEmpty(data[key]) {
                let digits = v.filter(\.isNumber)
                if digits.count < 7 || digits.count > 15 {
                    row.issues.append(warn(row.rowIndex, field: key, "Phone looks unusual: \(v)"))
                }
            }
        }

        // Date fields (YYYY-MM-DD)
        for key in ["start_date", "end_date", "date", "hire_date",
                    "issue_date", "expiry_date", "expected_close_date", "submission_date"] {
            if let v = nonEmpty(data[key]), !isValidDate(v) {
                row.issues.append(warn(row.rowIndex, field: key,
                    "Date format should be YYYY-MM-DD. Got: \(v)"))
            }
        }

        // Numeric fields
        for key in ["quantity", "unit_price", "total_price", "value",
                    "regular_hours", "overtime_hours", "contract_value",
                    "subtotal", "total", "regular_rate", "overtime_rate"] {
            if let v = nonEmpty(data[key]), Double(v) == nil {
                row.issues.append(warn(row.rowIndex, field: key,
                    "'\(key)' should be a number. Got: \(v)"))
            }
        }

        // Boolean fields
        for key in ["tax_exempt", "taxable"] {
            if let v = nonEmpty(data[key]) {
                let lower = v.lowercased()
                if lower != "true" && lower != "false" {
                    row.issues.append(warn(row.rowIndex, field: key,
                        "'\(key)' should be true or false. Got: \(v)"))
                }
            }
        }

        // Probability
        if let v = nonEmpty(data["probability_pct"]), let d = Double(v), (d < 0 || d > 100) {
            row.issues.append(warn(row.rowIndex, field: "probability_pct",
                "Probability should be 0–100. Got: \(v)"))
        }
    }

    // MARK: - Duplicate Detection

    private func detectDuplicate(_ row: inout ImportRow, recordType: ImportRecordType) {
        let data = row.mappedData.merging(row.rawData) { m, _ in m }
        let action = (data["action_type"] ?? "create").lowercased()
        guard action == "create" else { return } // only flag duplicates on create

        switch recordType {
        case .clients:
            detectClientDuplicate(&row, data: data)
        case .employees:
            detectEmployeeDuplicate(&row, data: data)
        case .projects:
            detectProjectDuplicate(&row, data: data)
        case .vendors:
            detectVendorDuplicate(&row, data: data)
        default:
            break
        }
    }

    private func detectClientDuplicate(_ row: inout ImportRow, data: [String: String]) {
        let name  = (data["client_name"] ?? "").lowercased()
        let email = (data["contact_email"] ?? "").lowercased()
        let phone = (data["contact_phone"] ?? "").filter(\.isNumber)
        let code  = (data["client_code"] ?? "").lowercased()

        if let match = store.clients.first(where: {
            (!name.isEmpty  && $0.name.lowercased() == name)  ||
            (!email.isEmpty && $0.contactEmail?.lowercased() == email) ||
            (!phone.isEmpty && ($0.contactPhone ?? "").filter(\.isNumber) == phone) ||
            (!code.isEmpty  && $0.code?.lowercased() == code)
        }) {
            row.existingMatchID = match.id
            row.issues.append(warn(row.rowIndex, field: "client_name",
                "Possible duplicate: '\(match.name)' already exists. " +
                "Set action_type to 'update' with app_record_id \(match.id) to update it."))
        }
    }

    private func detectEmployeeDuplicate(_ row: inout ImportRow, data: [String: String]) {
        let email = (data["email"] ?? "").lowercased()
        let first = (data["first_name"] ?? "").lowercased()
        let last  = (data["last_name"]  ?? "").lowercased()

        if let match = store.employees.first(where: {
            (!email.isEmpty && $0.email?.lowercased() == email) ||
            (!first.isEmpty && !last.isEmpty &&
             $0.firstName.lowercased() == first && $0.lastName.lowercased() == last)
        }) {
            row.existingMatchID = match.id
            row.issues.append(warn(row.rowIndex, field: "email",
                "Possible duplicate: '\(match.fullName)' already exists."))
        }
    }

    private func detectProjectDuplicate(_ row: inout ImportRow, data: [String: String]) {
        let name = (data["project_name"] ?? "").lowercased()
        let num  = (data["project_number"] ?? "").lowercased()

        if let match = store.projects.first(where: {
            (!name.isEmpty && $0.name.lowercased() == name) ||
            (!num.isEmpty  && ($0.projectNumber ?? "").lowercased() == num)
        }) {
            row.existingMatchID = match.id
            row.issues.append(warn(row.rowIndex, field: "project_name",
                "Possible duplicate: '\(match.name)' already exists."))
        }
    }

    private func detectVendorDuplicate(_ row: inout ImportRow, data: [String: String]) {
        let name = (data["vendor_name"] ?? "").lowercased()
        if let match = store.suppliers.first(where: { $0.name.lowercased() == name }) {
            row.existingMatchID = match.id
            row.issues.append(warn(row.rowIndex, field: "vendor_name",
                "Possible duplicate: '\(match.name)' already exists."))
        }
    }

    // MARK: - Helpers

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func isValidEmail(_ email: String) -> Bool {
        let regex = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return email.range(of: regex, options: .regularExpression) != nil
    }

    private func isValidDate(_ s: String) -> Bool {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s) != nil
    }

    private func err(_ row: Int, field: String, _ msg: String) -> ImportValidationIssue {
        ImportValidationIssue(rowIndex: row, field: field, message: msg, isBlocking: true)
    }

    private func warn(_ row: Int, field: String, _ msg: String) -> ImportValidationIssue {
        ImportValidationIssue(rowIndex: row, field: field, message: msg, isBlocking: false)
    }
}

// MARK: - Project helper (projectNumber may not exist — safe access)

private extension Project {
    var projectNumber: String? { nil } // stubbed — wire to real field if available
}
