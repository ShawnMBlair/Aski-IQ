// ImportValidationEngine.swift
// Aski IQ – Import Validation (v1.0 — Client focused, extensible)

import Foundation

final class ImportValidationEngine {

    private let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Validate Batch

    /// Validates all rows in place. Mutates state, issues, and existingMatchID on each row.
    func validate(
        rows: inout [ImportRow],
        recordType: ImportRecordType,
        mappings: [ColumnMapping]
    ) {
        // Apply mappings first
        applyMappings(rows: &rows, mappings: mappings)

        for i in rows.indices {
            rows[i].issues = []
            rows[i].existingMatchID = nil

            // Multi-tenant guard: mirrors MultiTabValidationEngine.checkCompanyID().
            // If the row carries a company_id cell, it MUST match the active session.
            // Blank is allowed — the app fills it on save.
            checkCompanyID(&rows[i])

            switch recordType {
            case .clients:
                validateClientRow(&rows[i])
            default:
                validateGenericRow(&rows[i], recordType: recordType)
            }

            // Set final row state
            if rows[i].isSkipped {
                rows[i].state = .skipped
            } else if rows[i].hasErrors {
                rows[i].state = .error
            } else if rows[i].hasWarnings {
                rows[i].state = .warning
            } else {
                rows[i].state = .clean
            }
        }
    }

    // MARK: - Column Mapping Application

    private func applyMappings(rows: inout [ImportRow], mappings: [ColumnMapping]) {
        for i in rows.indices {
            var mapped: [String: String] = [:]
            for mapping in mappings {
                guard let systemField = mapping.systemField else { continue }
                let value = rows[i].rawData[mapping.spreadsheetColumn] ?? ""
                mapped[systemField] = value.trimmingCharacters(in: .whitespaces)
            }
            rows[i].mappedData = mapped
        }
    }

    // MARK: - Client Validation

    private func validateClientRow(_ row: inout ImportRow) {
        // 1. Required: client_name
        let name = row.mappedData["client_name"] ?? ""
        if name.isEmpty {
            row.issues.append(error(row.rowIndex, field: "client_name", "Client Name is required."))
        }

        // 2. Email format
        if let email = nonEmpty(row.mappedData["contact_email"]) {
            if !isValidEmail(email) {
                row.issues.append(error(row.rowIndex, field: "contact_email",
                    "Invalid email: \(email)"))
            }
        }

        // 3. Phone format (lenient — warning only)
        if let phone = nonEmpty(row.mappedData["contact_phone"]) {
            let digits = phone.filter(\.isNumber)
            if digits.count < 7 || digits.count > 15 {
                row.issues.append(warning(row.rowIndex, field: "contact_phone",
                    "Phone number looks unusual: \(phone)"))
            }
        }

        // 4. Action type
        let action = resolvedAction(row.mappedData["action_type"])
        if let rawAction = nonEmpty(row.mappedData["action_type"]) {
            if !["create", "update", "archive"].contains(rawAction.lowercased()) {
                row.issues.append(error(row.rowIndex, field: "action_type",
                    "action_type must be create, update, or archive. Got: '\(rawAction)'"))
            }
        }

        // 5. Update requires app_record_id
        if action == "update" && nonEmpty(row.mappedData["app_record_id"]) == nil {
            row.issues.append(error(row.rowIndex, field: "app_record_id",
                "action_type 'update' requires an app_record_id."))
        }

        // 6. Duplicate detection
        if !name.isEmpty {
            detectClientDuplicate(&row, action: action)
        }
    }

    // MARK: - Generic Validation (other types — extensible)

    private func validateGenericRow(_ row: inout ImportRow, recordType: ImportRecordType) {
        for field in recordType.requiredFields {
            let value = row.mappedData[field] ?? ""
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                row.issues.append(error(row.rowIndex, field: field,
                    "'\(field)' is required."))
            }
        }
    }

    // MARK: - Duplicate Detection

    private func detectClientDuplicate(_ row: inout ImportRow, action: String) {
        let name  = (row.mappedData["client_name"]  ?? "").lowercased()
        let email = (row.mappedData["contact_email"] ?? "").lowercased()
        let phone = (row.mappedData["contact_phone"] ?? "").filter(\.isNumber)
        let code  = (row.mappedData["client_code"]  ?? "").lowercased()

        let match = store.clients.first { c in
            (!name.isEmpty  && c.name.lowercased() == name)     ||
            (!email.isEmpty && c.contactEmail?.lowercased() == email) ||
            (!phone.isEmpty && (c.contactPhone ?? "").filter(\.isNumber) == phone) ||
            (!code.isEmpty  && c.code?.lowercased() == code)
        }

        guard let match else { return }
        row.existingMatchID = match.id

        if action == "create" {
            row.issues.append(warning(row.rowIndex, field: "client_name",
                "Possible duplicate: '\(match.name)' already exists. " +
                "Set action_type to 'update' with app_record_id \(match.id) to update it, " +
                "or skip this row."))
        }
    }

    // MARK: - Helpers

    private func resolvedAction(_ raw: String?) -> String {
        (raw ?? "create").trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func isValidEmail(_ email: String) -> Bool {
        let regex = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return email.range(of: regex, options: .regularExpression) != nil
    }

    // MARK: - Multi-tenant Guard

    /// Blocks any row whose `company_id` cell does not match the active session's
    /// companyID. Blank cells are allowed — the app fills them at save time.
    /// Mirrors MultiTabValidationEngine.checkCompanyID() so CSV imports cannot
    /// bypass tenant isolation.
    private func checkCompanyID(_ row: inout ImportRow) {
        let cellValue = row.mappedData["company_id"] ?? row.rawData["company_id"] ?? ""
        if cellValue.isEmpty { return }
        guard let companyID = store.currentCompanyID else {
            row.issues.append(error(row.rowIndex, field: "company_id",
                "No active company session — sign in before importing."))
            return
        }
        if cellValue.lowercased() != companyID.uuidString.lowercased() {
            row.issues.append(error(row.rowIndex, field: "company_id",
                "company_id '\(cellValue)' does not match your account. This row will be blocked."))
        }
    }

    private func error(_ rowIndex: Int, field: String, _ msg: String) -> ImportValidationIssue {
        ImportValidationIssue(rowIndex: rowIndex, field: field, message: msg, isBlocking: true)
    }

    private func warning(_ rowIndex: Int, field: String, _ msg: String) -> ImportValidationIssue {
        ImportValidationIssue(rowIndex: rowIndex, field: field, message: msg, isBlocking: false)
    }
}

// MARK: - Import Processor

/// Executes validated rows against the live store.
final class ImportProcessor {

    private let store: AppStore

    init(store: AppStore) { self.store = store }

    // MARK: - Generic Dispatcher

    /// Process rows for any supported record type. Returns (created, updated, skipped, errors).
    @discardableResult
    func process(type: ImportRecordType, rows: [ImportRow], batchID: UUID)
    -> (created: Int, updated: Int, skipped: Int, errors: Int) {
        switch type {
        case .clients:       return processClients(rows: rows, batchID: batchID)
        case .contacts:      return processContacts(rows: rows, batchID: batchID)
        case .opportunities: return processOpportunities(rows: rows, batchID: batchID)
        case .projects:      return processProjects(rows: rows, batchID: batchID)
        case .employees:     return processEmployees(rows: rows, batchID: batchID)
        case .vendors:       return processVendors(rows: rows, batchID: batchID)
        case .equipment:     return processEquipment(rows: rows, batchID: batchID)
        case .products:      return processProducts(rows: rows, batchID: batchID)
        case .schedules:     return processSchedules(rows: rows, batchID: batchID)
        case .timesheets:    return processTimesheets(rows: rows, batchID: batchID)
        default:
            // Tabs not yet implemented (companies, estimateLines, safetyForms, etc.)
            let errs = rows.filter { $0.hasErrors && !$0.isSkipped }.count
            let skip = rows.filter { $0.isSkipped }.count
            return (0, 0, skip, errs)
        }
    }

    // MARK: - Shared Helpers

    private func action(for row: ImportRow) -> String {
        (row.mappedData["action_type"] ?? "create").trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    private func parseDecimal(_ s: String?) -> Decimal? {
        guard let s, !s.isEmpty, let d = Double(s) else { return nil }
        return Decimal(d)
    }

    private func parseInt(_ s: String?) -> Int? {
        guard let s, !s.isEmpty else { return nil }
        return Int(s)
    }

    // MARK: - Clients

    @discardableResult
    func processClients(rows: [ImportRow], batchID: UUID) -> (created: Int, updated: Int, skipped: Int, errors: Int) {
        var created = 0; var updated = 0; var skipped = 0; var errors = 0
        for row in rows {
            guard !row.isSkipped else { skipped += 1; continue }
            guard !row.hasErrors else { errors += 1; continue }
            switch action(for: row) {
            case "update":
                if let uuid = uuidFrom(row.mappedData["app_record_id"]),
                   var existing = store.clients.first(where: { $0.id == uuid }) {
                    applyClientMapping(row.mappedData, to: &existing)
                    existing.syncStatus = .pending
                    store.upsertClient(existing); updated += 1
                } else { errors += 1 }
            case "archive":
                if let uuid = uuidFrom(row.mappedData["app_record_id"]),
                   var existing = store.clients.first(where: { $0.id == uuid }) {
                    existing.isActive = false; existing.syncStatus = .pending
                    store.upsertClient(existing); updated += 1
                } else { errors += 1 }
            default:
                // IDEMPOTENT CREATE: before generating a fresh UUID, check if a
                // matching client already exists. Match by client_code (case-
                // insensitive) first, then by exact name. This makes repeated
                // runs of the same import template UPDATE the existing record
                // instead of creating duplicates with new UUIDs.
                let d = row.mappedData
                let importCode = (d["client_code"] ?? "").trimmingCharacters(in: .whitespaces)
                let importName = (d["client_name"] ?? "").trimmingCharacters(in: .whitespaces)
                let matched: Client? = {
                    if !importCode.isEmpty,
                       let m = store.clients.first(where: {
                           ($0.code ?? "").lowercased() == importCode.lowercased() && !$0.isDeleted
                       }) {
                        return m
                    }
                    if !importName.isEmpty,
                       let m = store.clients.first(where: {
                           $0.name.lowercased() == importName.lowercased() && !$0.isDeleted
                       }) {
                        return m
                    }
                    return nil
                }()
                if var existing = matched {
                    applyClientMapping(d, to: &existing)
                    existing.syncStatus = .pending
                    store.upsertClient(existing); updated += 1
                } else {
                    var client = Client(name: importName)
                    applyClientMapping(d, to: &client)
                    client.syncStatus = .pending
                    store.upsertClient(client); created += 1
                }
            }
        }
        return (created, updated, skipped, errors)
    }

    private func applyClientMapping(_ data: [String: String], to client: inout Client) {
        if let v = data["client_name"],      !v.isEmpty { client.name                   = v }
        if let v = data["client_code"],      !v.isEmpty { client.code                   = v }
        if let v = data["contact_name"],     !v.isEmpty { client.contactName            = v }
        if let v = data["contact_title"],    !v.isEmpty { client.contactTitle           = v }
        if let v = data["contact_email"],    !v.isEmpty { client.contactEmail           = v }
        if let v = data["contact_phone"],    !v.isEmpty { client.contactPhone           = v }
        if let v = data["billing_address"],  !v.isEmpty { client.billingAddress         = v }
        if let v = data["billing_city"],     !v.isEmpty { client.billingCity            = v }
        if let v = data["billing_province"], !v.isEmpty { client.billingProvince        = v }
        if let v = data["billing_postal"],   !v.isEmpty { client.billingPostal          = v }
        if let v = data["payment_terms"],    !v.isEmpty { client.defaultPaymentTerms    = v }
        if let v = data["notes"],            !v.isEmpty { client.notes                  = v }
        if let v = data["tax_exempt"] { client.taxExempt = v.lowercased() == "true" }
    }

    // MARK: - CRM Contacts

    @discardableResult
    func processContacts(rows: [ImportRow], batchID: UUID) -> (created: Int, updated: Int, skipped: Int, errors: Int) {
        var created = 0; var updated = 0; var skipped = 0; var errors = 0
        for row in rows {
            guard !row.isSkipped else { skipped += 1; continue }
            guard !row.hasErrors else { errors += 1; continue }
            let d = row.mappedData
            switch action(for: row) {
            case "update":
                if let uuid = uuidFrom(d["app_record_id"]),
                   var existing = store.crmContacts.first(where: { $0.id == uuid }) {
                    applyContactMapping(d, to: &existing)
                    existing.syncStatus = .pending
                    store.upsertCRMContact(existing); updated += 1
                } else { errors += 1 }
            case "archive":
                if let uuid = uuidFrom(d["app_record_id"]),
                   var existing = store.crmContacts.first(where: { $0.id == uuid }) {
                    existing.isDeleted = true; existing.deletedAt = Date()
                    existing.syncStatus = .pending
                    store.upsertCRMContact(existing); updated += 1
                } else { errors += 1 }
            default:
                // Resolve clientID by name or external_id
                let clientID = resolveClientID(name: d["company_name"], externalID: d["client_external_id"])
                    ?? store.clients.first?.id
                guard let clientID else { errors += 1; continue }
                // IDEMPOTENT CREATE: match by email (case-insensitive) within the
                // same client first, then by full name + clientID. Email is the
                // strongest natural key for a contact when present.
                let emailKey = (d["email"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                let firstName = (d["first_name"] ?? "").trimmingCharacters(in: .whitespaces)
                let lastName  = (d["last_name"] ?? "").trimmingCharacters(in: .whitespaces)
                let matched: CRMContact? = {
                    if !emailKey.isEmpty,
                       let m = store.crmContacts.first(where: {
                           $0.clientID == clientID && !$0.isDeleted &&
                           $0.email.lowercased() == emailKey
                       }) {
                        return m
                    }
                    if !firstName.isEmpty || !lastName.isEmpty,
                       let m = store.crmContacts.first(where: {
                           $0.clientID == clientID && !$0.isDeleted &&
                           $0.firstName.lowercased() == firstName.lowercased() &&
                           $0.lastName.lowercased()  == lastName.lowercased()
                       }) {
                        return m
                    }
                    return nil
                }()
                if var existing = matched {
                    applyContactMapping(d, to: &existing)
                    existing.syncStatus = .pending
                    store.upsertCRMContact(existing); updated += 1
                } else {
                    var contact = CRMContact(clientID: clientID)
                    applyContactMapping(d, to: &contact)
                    contact.syncStatus = .pending
                    store.upsertCRMContact(contact); created += 1
                }
            }
        }
        return (created, updated, skipped, errors)
    }

    private func applyContactMapping(_ d: [String: String], to c: inout CRMContact) {
        if let v = d["first_name"], !v.isEmpty { c.firstName = v }
        if let v = d["last_name"],  !v.isEmpty { c.lastName  = v }
        if let v = d["email"],      !v.isEmpty { c.email     = v }
        if let v = d["phone"],      !v.isEmpty { c.phone     = v }
        if let v = d["title"],      !v.isEmpty { c.title     = v }
        if let v = d["notes"],      !v.isEmpty { c.notes     = v }
    }

    // MARK: - CRM Opportunities

    @discardableResult
    func processOpportunities(rows: [ImportRow], batchID: UUID) -> (created: Int, updated: Int, skipped: Int, errors: Int) {
        var created = 0; var updated = 0; var skipped = 0; var errors = 0
        for row in rows {
            guard !row.isSkipped else { skipped += 1; continue }
            guard !row.hasErrors else { errors += 1; continue }
            let d = row.mappedData
            switch action(for: row) {
            case "update":
                if let uuid = uuidFrom(d["app_record_id"]),
                   var existing = store.crmOpportunities.first(where: { $0.id == uuid }) {
                    applyOpportunityMapping(d, to: &existing)
                    existing.syncStatus = .pending
                    store.upsertCRMOpportunity(existing); updated += 1
                } else { errors += 1 }
            case "archive":
                if let uuid = uuidFrom(d["app_record_id"]),
                   var existing = store.crmOpportunities.first(where: { $0.id == uuid }) {
                    existing.isDeleted = true; existing.deletedAt = Date()
                    existing.syncStatus = .pending
                    store.upsertCRMOpportunity(existing); updated += 1
                } else { errors += 1 }
            default:
                let clientID = resolveClientID(name: d["client_name"], externalID: d["client_external_id"])
                guard let clientID else { errors += 1; continue }
                // IDEMPOTENT CREATE: match by title within the same client. An
                // opportunity title is the natural key the user would re-enter.
                let importTitle = (d["opportunity_name"] ?? "").trimmingCharacters(in: .whitespaces)
                let matched: CRMOpportunity? = {
                    guard !importTitle.isEmpty else { return nil }
                    return store.crmOpportunities.first(where: {
                        $0.clientID == clientID && !$0.isDeleted &&
                        $0.title.lowercased() == importTitle.lowercased()
                    })
                }()
                if var existing = matched {
                    applyOpportunityMapping(d, to: &existing)
                    existing.syncStatus = .pending
                    store.upsertCRMOpportunity(existing); updated += 1
                } else {
                    var opp = CRMOpportunity(clientID: clientID)
                    applyOpportunityMapping(d, to: &opp)
                    opp.syncStatus = .pending
                    store.upsertCRMOpportunity(opp); created += 1
                }
            }
        }
        return (created, updated, skipped, errors)
    }

    private func applyOpportunityMapping(_ d: [String: String], to opp: inout CRMOpportunity) {
        if let v = d["opportunity_name"], !v.isEmpty { opp.title       = v }
        if let v = d["description"],      !v.isEmpty { opp.description = v }
        if let v = d["assigned_to"],      !v.isEmpty { opp.assignedToName = v }
        if let v = d["notes"],            !v.isEmpty { opp.notes       = v }
        if let dec = parseDecimal(d["value"])         { opp.value       = dec }
        if let pct = parseInt(d["probability_pct"])   { opp.probability = min(100, max(0, pct)) }
        if let stageStr = d["stage"], !stageStr.isEmpty {
            opp.stage = parseOpportunityStage(stageStr)
        }
        if let date = parseDate(d["expected_close_date"]) { opp.estimatedStart = date }
    }

    private func parseOpportunityStage(_ s: String) -> OpportunityStage {
        switch s.lowercased() {
        case "lead", "new lead":       return .newLead
        case "contacted":              return .contacted
        case "site visit":             return .siteVisit
        case "estimate", "estimating": return .estimateRequired
        case "quote sent", "quoted":   return .quoteSent
        case "follow-up", "followup":  return .followUp
        case "negotiation", "negotiating": return .followUp  // closest match
        case "proposal":               return .estimateRequired
        case "qualified":              return .contacted
        case "won":                    return .won
        case "lost":                   return .lost
        default:                       return .newLead
        }
    }

    // MARK: - Projects

    @discardableResult
    func processProjects(rows: [ImportRow], batchID: UUID) -> (created: Int, updated: Int, skipped: Int, errors: Int) {
        var created = 0; var updated = 0; var skipped = 0; var errors = 0
        for row in rows {
            guard !row.isSkipped else { skipped += 1; continue }
            guard !row.hasErrors else { errors += 1; continue }
            let d = row.mappedData
            switch action(for: row) {
            case "update":
                if let uuid = uuidFrom(d["app_record_id"]),
                   var existing = store.projects.first(where: { $0.id == uuid }) {
                    applyProjectMapping(d, to: &existing)
                    existing.syncStatus = .pending
                    store.upsertProject(existing); updated += 1
                } else { errors += 1 }
            case "archive":
                if let uuid = uuidFrom(d["app_record_id"]),
                   var existing = store.projects.first(where: { $0.id == uuid }) {
                    existing.status = .cancelled; existing.syncStatus = .pending
                    store.upsertProject(existing); updated += 1
                } else { errors += 1 }
            default:
                let clientID  = resolveClientID(name: d["client_name"], externalID: d["client_external_id"])
                let clientName = d["client_name"] ?? ""
                // IDEMPOTENT CREATE: match by externalID (project_number /
                // job number from the template) first, falling back to exact
                // project_name within the same client. Without this, every
                // re-import of the same template multiplies projects 1:N.
                let importNumber = (d["project_number"] ?? "").trimmingCharacters(in: .whitespaces)
                let importName   = (d["project_name"] ?? "").trimmingCharacters(in: .whitespaces)
                let matched: Project? = {
                    if !importNumber.isEmpty,
                       let m = store.projects.first(where: {
                           ($0.externalID ?? "").lowercased() == importNumber.lowercased() && !$0.isDeleted
                       }) {
                        return m
                    }
                    if !importName.isEmpty,
                       let m = store.projects.first(where: {
                           $0.name.lowercased() == importName.lowercased() &&
                           ($0.clientID == clientID || clientID == nil) &&
                           !$0.isDeleted
                       }) {
                        return m
                    }
                    return nil
                }()
                if var existing = matched {
                    if let cid = clientID { existing.clientID = cid }
                    if !clientName.isEmpty { existing.clientName = clientName }
                    if !importNumber.isEmpty { existing.externalID = importNumber }
                    applyProjectMapping(d, to: &existing)
                    existing.syncStatus = .pending
                    store.upsertProject(existing); updated += 1
                } else {
                    var project = Project(name: importName, clientName: clientName)
                    project.clientID = clientID
                    if !importNumber.isEmpty { project.externalID = importNumber }
                    applyProjectMapping(d, to: &project)
                    project.syncStatus = .pending
                    store.upsertProject(project); created += 1
                }
            }
        }
        return (created, updated, skipped, errors)
    }

    private func applyProjectMapping(_ d: [String: String], to p: inout Project) {
        if let v = d["project_name"],   !v.isEmpty { p.name        = v }
        if let v = d["client_name"],    !v.isEmpty { p.clientName  = v }
        if let v = d["site_address"],   !v.isEmpty { p.siteAddress = v }
        if let start = parseDate(d["start_date"]) { p.startDate    = start }
        if let end   = parseDate(d["end_date"])   { p.endDate      = end }
        if let val   = parseDecimal(d["contract_value"]) { p.contractValue = val }
        if let statusStr = d["project_status"], !statusStr.isEmpty {
            p.status = parseProjectStatus(statusStr)
        }
    }

    private func parseProjectStatus(_ s: String) -> ProjectStatus {
        switch s.lowercased() {
        case "active":                   return .active
        case "tender", "tendering":      return .tendering
        case "completed", "complete":    return .completed
        case "cancelled", "canceled":    return .cancelled
        default:                         return .active
        }
    }

    // MARK: - Employees

    @discardableResult
    func processEmployees(rows: [ImportRow], batchID: UUID) -> (created: Int, updated: Int, skipped: Int, errors: Int) {
        var created = 0; var updated = 0; var skipped = 0; var errors = 0
        for row in rows {
            guard !row.isSkipped else { skipped += 1; continue }
            guard !row.hasErrors else { errors += 1; continue }
            let d = row.mappedData
            switch action(for: row) {
            case "update":
                if let uuid = uuidFrom(d["app_record_id"]),
                   var existing = store.employees.first(where: { $0.id == uuid }) {
                    applyEmployeeMapping(d, to: &existing)
                    existing.syncStatus = .pending
                    store.upsertEmployee(existing); updated += 1
                } else { errors += 1 }
            case "archive":
                if let uuid = uuidFrom(d["app_record_id"]),
                   var existing = store.employees.first(where: { $0.id == uuid }) {
                    existing.isActive = false; existing.syncStatus = .pending
                    store.upsertEmployee(existing); updated += 1
                } else { errors += 1 }
            default:
                let firstName = d["first_name"] ?? ""
                let lastName  = d["last_name"]  ?? ""
                // Check for duplicate by email before creating
                let email = d["email"] ?? ""
                if !email.isEmpty, store.employees.contains(where: { $0.email?.lowercased() == email.lowercased() }) {
                    // Already exists — skip silently (was warned in validation)
                    skipped += 1; continue
                }
                var emp = Employee(firstName: firstName, lastName: lastName)
                applyEmployeeMapping(d, to: &emp)
                emp.syncStatus = .pending
                store.upsertEmployee(emp); created += 1
            }
        }
        return (created, updated, skipped, errors)
    }

    private func applyEmployeeMapping(_ d: [String: String], to e: inout Employee) {
        if let v = d["first_name"],      !v.isEmpty { e.firstName    = v }
        if let v = d["last_name"],       !v.isEmpty { e.lastName     = v }
        if let v = d["email"],           !v.isEmpty { e.email        = v }
        if let v = d["phone"],           !v.isEmpty { e.phone        = v }
        if let v = d["trade"],           !v.isEmpty { e.trade        = v }
        if let v = d["employee_number"], !v.isEmpty { e.externalID   = v }
        if let v = d["role"],            !v.isEmpty { e.role         = parseUserRole(v) }
        if let v = parseDecimal(d["regular_rate"])  { e.regularRate  = v }
        if let v = parseDecimal(d["overtime_rate"]) { e.overtimeRate = v }
    }

    private func parseUserRole(_ s: String) -> UserRole {
        switch s.lowercased().replacingOccurrences(of: " ", with: "_") {
        case "admin", "executive":        return .executive
        case "manager":                   return .manager
        case "project_manager":           return .projectManager
        case "foreman":                   return .foreman
        case "field_worker", "field":     return .fieldWorker
        case "office", "office_admin":    return .officeAdmin
        case "estimator":                 return .estimator
        case "safety_advisor", "safety":  return .safetyAdvisor
        default:                          return .fieldWorker
        }
    }

    // MARK: - Vendors / Suppliers

    @discardableResult
    func processVendors(rows: [ImportRow], batchID: UUID) -> (created: Int, updated: Int, skipped: Int, errors: Int) {
        var created = 0; var updated = 0; var skipped = 0; var errors = 0
        for row in rows {
            guard !row.isSkipped else { skipped += 1; continue }
            guard !row.hasErrors else { errors += 1; continue }
            let d = row.mappedData
            switch action(for: row) {
            case "update":
                if let uuid = uuidFrom(d["app_record_id"]),
                   var existing = store.suppliers.first(where: { $0.id == uuid }) {
                    applyVendorMapping(d, to: &existing)
                    store.updateSupplier(existing); updated += 1
                } else { errors += 1 }
            case "archive":
                if let uuid = uuidFrom(d["app_record_id"]),
                   var existing = store.suppliers.first(where: { $0.id == uuid }) {
                    existing.isDeleted = true; existing.deletedAt = Date()
                    store.updateSupplier(existing); updated += 1
                } else { errors += 1 }
            default:
                var supplier = Supplier(name: d["vendor_name"] ?? "")
                applyVendorMapping(d, to: &supplier)
                store.addSupplier(supplier); created += 1
            }
        }
        return (created, updated, skipped, errors)
    }

    private func applyVendorMapping(_ d: [String: String], to s: inout Supplier) {
        if let v = d["vendor_name"],    !v.isEmpty { s.name        = v }
        if let v = d["contact_name"],   !v.isEmpty { s.contactName = v }
        if let v = d["contact_email"],  !v.isEmpty { s.email       = v }
        if let v = d["contact_phone"],  !v.isEmpty { s.phone       = v }
        if let v = d["address"],        !v.isEmpty { s.address     = v }
        if let v = d["notes"],          !v.isEmpty { s.notes       = v }
        if let v = d["trade_type"],     !v.isEmpty {
            if !s.categories.contains(v) { s.categories.append(v) }
        }
        if let v = d["vendor_code"],    !v.isEmpty { s.accountNumber = v }
    }

    // MARK: - Equipment

    @discardableResult
    func processEquipment(rows: [ImportRow], batchID: UUID) -> (created: Int, updated: Int, skipped: Int, errors: Int) {
        var created = 0; var updated = 0; var skipped = 0; var errors = 0
        for row in rows {
            guard !row.isSkipped else { skipped += 1; continue }
            guard !row.hasErrors else { errors += 1; continue }
            let d = row.mappedData
            switch action(for: row) {
            case "update":
                if let uuid = uuidFrom(d["app_record_id"]),
                   var existing = store.equipment.first(where: { $0.id == uuid }) {
                    applyEquipmentMapping(d, to: &existing)
                    store.updateEquipment(existing); updated += 1
                } else { errors += 1 }
            case "archive":
                if let uuid = uuidFrom(d["app_record_id"]),
                   var existing = store.equipment.first(where: { $0.id == uuid }) {
                    existing.status = .retired
                    store.updateEquipment(existing); updated += 1
                } else { errors += 1 }
            default:
                var equip = Equipment(name: d["equipment_name"] ?? "", category: parseEquipmentCategory(d["category"]))
                applyEquipmentMapping(d, to: &equip)
                store.addEquipment(equip); created += 1
            }
        }
        return (created, updated, skipped, errors)
    }

    private func applyEquipmentMapping(_ d: [String: String], to e: inout Equipment) {
        if let v = d["equipment_name"],   !v.isEmpty { e.name         = v }
        if let v = d["make"],             !v.isEmpty { e.make         = v }
        if let v = d["model"],            !v.isEmpty { e.model        = v }
        if let v = d["serial_number"],    !v.isEmpty { e.serialNumber = v }
        if let v = d["equipment_number"], !v.isEmpty { e.externalID   = v }
        if let y = parseInt(d["year"])              { e.year          = y }
        if let v = d["category"],         !v.isEmpty { e.category     = parseEquipmentCategory(v) }
        if let v = d["equipment_status"], !v.isEmpty { e.status       = parseEquipmentStatus(v) }
    }

    private func parseEquipmentCategory(_ s: String?) -> EquipmentCategory {
        switch (s ?? "").lowercased() {
        case "vehicle", "fleet vehicle", "truck": return .vehicle
        case "tool", "tools":                      return .tool
        case "safety", "safety equipment":         return .safety
        case "heavy", "heavy equipment":           return .heavy
        case "light", "light equipment":           return .light
        default:                                   return .other
        }
    }

    private func parseEquipmentStatus(_ s: String) -> EquipmentStatus {
        switch s.lowercased() {
        case "maintenance":          return .maintenance
        case "retired", "inactive": return .retired
        default:                     return .available
        }
    }

    // MARK: - Products & Services

    @discardableResult
    func processProducts(rows: [ImportRow], batchID: UUID) -> (created: Int, updated: Int, skipped: Int, errors: Int) {
        var created = 0; var updated = 0; var skipped = 0; var errors = 0
        for row in rows {
            guard !row.isSkipped else { skipped += 1; continue }
            guard !row.hasErrors else { errors += 1; continue }
            let d = row.mappedData
            switch action(for: row) {
            case "update":
                if let uuid = uuidFrom(d["app_record_id"]),
                   var existing = store.productServices.first(where: { $0.id == uuid }) {
                    applyProductMapping(d, to: &existing)
                    existing.syncStatus = .pending
                    store.upsertProductService(existing); updated += 1
                } else { errors += 1 }
            case "archive":
                if let uuid = uuidFrom(d["app_record_id"]),
                   var existing = store.productServices.first(where: { $0.id == uuid }) {
                    existing.isActive = false; existing.syncStatus = .pending
                    store.upsertProductService(existing); updated += 1
                } else { errors += 1 }
            default:
                let psType: ProductServiceType = (d["category"] ?? "").lowercased().contains("material")
                    || (d["category"] ?? "").lowercased().contains("product")
                    ? .product : .service
                var ps = ProductService(
                    name: d["product_name"] ?? "",
                    type: psType,
                    costCode: d["cost_code"] ?? "",
                    description: d["description"] ?? "",
                    unit: d["unit"] ?? "hr",
                    defaultPrice: parseDecimal(d["unit_price"]) ?? 0,
                    category: .labour
                )
                applyProductMapping(d, to: &ps)
                store.upsertProductService(ps); created += 1
            }
        }
        return (created, updated, skipped, errors)
    }

    private func applyProductMapping(_ d: [String: String], to ps: inout ProductService) {
        if let v = d["product_name"],  !v.isEmpty { ps.name         = v }
        if let v = d["description"],   !v.isEmpty { ps.description  = v }
        if let v = d["unit"],          !v.isEmpty { ps.unit         = v }
        if let v = d["cost_code"],     !v.isEmpty { ps.costCode     = v }
        if let price = parseDecimal(d["unit_price"]) { ps.defaultPrice = price }
        // taxable field: map to isActive (false = non-taxable items are typically still active)
        // kept for future field extension
    }

    // MARK: - Schedule Items

    @discardableResult
    func processSchedules(rows: [ImportRow], batchID: UUID) -> (created: Int, updated: Int, skipped: Int, errors: Int) {
        var created = 0; var updated = 0; var skipped = 0; var errors = 0
        for row in rows {
            guard !row.isSkipped else { skipped += 1; continue }
            guard !row.hasErrors else { errors += 1; continue }
            let d = row.mappedData
            guard let startDate = parseDate(d["start_date"]) else { errors += 1; continue }
            // Resolve project (required for ScheduleEntry)
            let projName = d["project_name"] ?? ""
            let project  = store.projects.first { $0.name.lowercased() == projName.lowercased() }
            guard let projectID = project?.id ?? uuidFrom(d["project_external_id"])
            else { skipped += 1; continue }
            var entry = ScheduleEntry(projectID: projectID, date: startDate)
            entry.costCode       = d["cost_code"]
            entry.taskDescription = d["employee_name"].map { "Assigned: \($0)" }
            entry.syncStatus     = .pending
            store.upsertScheduleEntry(entry); created += 1
        }
        return (created, updated, skipped, errors)
    }

    // MARK: - Timesheets

    @discardableResult
    func processTimesheets(rows: [ImportRow], batchID: UUID) -> (created: Int, updated: Int, skipped: Int, errors: Int) {
        var created = 0; var updated = 0; var skipped = 0; var errors = 0
        for row in rows {
            guard !row.isSkipped else { skipped += 1; continue }
            guard !row.hasErrors else { errors += 1; continue }
            let d = row.mappedData
            guard let date = parseDate(d["date"]) else { errors += 1; continue }
            // Resolve employee
            let empName  = d["employee_name"] ?? ""
            let employee = store.employees.first { $0.fullName.lowercased() == empName.lowercased()
                || (!($0.externalID ?? "").isEmpty && $0.externalID == d["employee_external_id"]) }
            guard let employee else { skipped += 1; continue }
            // Resolve project
            let projName  = d["project_name"] ?? ""
            let project   = store.projects.first { $0.name.lowercased() == projName.lowercased() }
            guard let projectID = project?.id ?? uuidFrom(d["project_external_id"])
            else { skipped += 1; continue }
            var entry = TimesheetEntry(projectID: projectID, employeeID: employee.id, date: date)
            entry.regularHours   = parseDecimal(d["regular_hours"])  ?? 8
            entry.overtimeHours  = parseDecimal(d["overtime_hours"]) ?? 0
            if let brk = parseInt(d["break_minutes"]) { entry.breakMinutes = brk }
            entry.costCode       = d["cost_code"]
            entry.taskDescription = d["task_description"]
            entry.syncStatus     = .pending
            store.upsertTimesheetEntry(entry); created += 1
        }
        return (created, updated, skipped, errors)
    }

    // MARK: - Resolution Helpers

    private func resolveClientID(name: String?, externalID: String?) -> UUID? {
        if let extID = externalID, !extID.isEmpty {
            if let match = store.clients.first(where: { $0.code?.lowercased() == extID.lowercased() }) {
                return match.id
            }
        }
        if let name = name, !name.isEmpty {
            if let match = store.clients.first(where: { $0.name.lowercased() == name.lowercased() }) {
                return match.id
            }
        }
        return nil
    }

    private func uuidFrom(_ s: String?) -> UUID? {
        guard let s, !s.isEmpty else { return nil }
        return UUID(uuidString: s)
    }
}
