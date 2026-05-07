// DataExportService.swift
// Aski IQ — Per-tenant data export.
//
// WHY THIS EXISTS
// PIPEDA (Canada) and similar privacy regimes give the user a right of access
// to their own data. The strategy report (§10, P1) flagged this as a missing
// flow before launch. This service produces a single JSON document containing
// every record currently in the local store for the signed-in tenant — no
// network call required, so it works offline too.
//
// SHAPE
//   {
//     "exportedAt": "2026-04-28T18:42:00Z",
//     "schemaVersion": 1,
//     "company": { id, name },
//     "user": { id, fullName, email, role },
//     "data": {
//       "clients": [...],
//       "projects": [...],
//       "employees": [...],
//       ...
//     }
//   }
//
// USAGE
//   let url = try DataExportService.shared.exportAll(from: store)
//   // Pass `url` to UIActivityViewController to share / save to Files

import Foundation

@MainActor
final class DataExportService {

    static let shared = DataExportService()
    private init() {}

    enum ExportError: Error, LocalizedError {
        case notSignedIn
        case encodingFailed(Error)
        case writeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:           return "Sign in before exporting your data."
            case .encodingFailed(let e): return "Couldn't serialize your data: \(e.localizedDescription)"
            case .writeFailed(let e):    return "Couldn't save the export file: \(e.localizedDescription)"
            }
        }
    }

    /// Generates a JSON file containing every record currently in the local
    /// store for the active tenant and returns its temp-file URL. Caller is
    /// responsible for sharing / saving via `UIActivityViewController`.
    func exportAll(from store: AppStore) throws -> URL {
        guard let user = store.currentUser else { throw ExportError.notSignedIn }

        let payload = ExportPayload(
            exportedAt:    Date(),
            schemaVersion: 1,
            company: ExportPayload.Company(
                id:   store.currentCompanyID?.uuidString ?? "",
                name: AppSettings.shared.companyName
            ),
            user: ExportPayload.User(
                id:        user.id.uuidString,
                fullName:  user.fullName,
                email:     user.email ?? "",
                role:      store.currentUserRole.rawValue
            ),
            data: ExportPayload.Data(
                clients:           store.clients,
                projects:          store.projects,
                employees:         store.employees,
                crews:             store.crews,
                scheduleEntries:   store.scheduleEntries,
                timesheetEntries:  store.timesheetEntries,
                formTemplates:     store.formTemplates,
                formSubmissions:   store.formSubmissions,
                incidents:         store.incidents,
                certificates:      store.certificates,
                equipment:         store.equipment,
                changeOrders:      store.changeOrders,
                rfis:              store.rfis,
                projectBudgets:    store.projectBudgets,
                subcontractors:    store.subcontractors,
                subContracts:      store.subContracts,
                invoices:          store.invoices,
                quotes:            store.quotes,
                estimates:         store.estimates,
                materialSales:     store.materialSales,
                materialRequests:  store.materialRequests,
                purchaseOrders:    store.purchaseOrders,
                suppliers:         store.suppliers,
                productServices:   store.productServices,
                clientPricings:    store.clientPricings,
                companyCostCodes:  store.companyCostCodes,
                crmContacts:       store.crmContacts,
                crmOpportunities:  store.crmOpportunities,
                crmTasks:          store.crmTasks,
                crmActivities:     store.crmActivities,
                handoffChecklists: store.handoffChecklists,
                auditSnapshots:    store.auditSnapshots
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting    = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data: Foundation.Data
        do {
            data = try encoder.encode(payload)
        } catch {
            throw ExportError.encodingFailed(error)
        }

        let dateString = DateFormatter.exportTimestamp.string(from: Date())
        let companySlug = AppSettings.shared.companyName
            .components(separatedBy: .whitespacesAndNewlines)
            .joined(separator: "_")
            .replacingOccurrences(of: "/", with: "-")
        let safeSlug = companySlug.isEmpty ? "AskiIQ" : companySlug
        let filename = "\(safeSlug)_data_export_\(dateString).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ExportError.writeFailed(error)
        }
        return url
    }
}

// MARK: - Payload schema

private struct ExportPayload: Encodable {
    let exportedAt: Date
    let schemaVersion: Int
    let company: Company
    let user: User
    let data: Data

    struct Company: Encodable {
        let id: String
        let name: String
    }

    struct User: Encodable {
        let id: String
        let fullName: String
        let email: String
        let role: String
    }

    struct Data: Encodable {
        let clients:           [Client]
        let projects:          [Project]
        let employees:         [Employee]
        let crews:             [Crew]
        let scheduleEntries:   [ScheduleEntry]
        let timesheetEntries:  [TimesheetEntry]
        let formTemplates:     [FormTemplate]
        let formSubmissions:   [FormSubmission]
        let incidents:         [Incident]
        let certificates:      [Certificate]
        let equipment:         [Equipment]
        let changeOrders:      [ChangeOrder]
        let rfis:              [RFI]
        let projectBudgets:    [ProjectBudget]
        let subcontractors:    [Subcontractor]
        let subContracts:      [SubContract]
        let invoices:          [Invoice]
        let quotes:            [Quote]
        let estimates:         [Estimate]
        let materialSales:     [MaterialSale]
        let materialRequests:  [MaterialRequest]
        let purchaseOrders:    [PurchaseOrder]
        let suppliers:         [Supplier]
        let productServices:   [ProductService]
        let clientPricings:    [ClientPricing]
        let companyCostCodes:  [CompanyCostCode]
        let crmContacts:       [CRMContact]
        let crmOpportunities:  [CRMOpportunity]
        let crmTasks:          [CRMTask]
        let crmActivities:     [CRMActivity]
        let handoffChecklists: [HandoffChecklistItem]
        let auditSnapshots:    [AuditSnapshot]
    }
}

private extension DateFormatter {
    static let exportTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        f.timeZone   = TimeZone(secondsFromGMT: 0)
        return f
    }()
}
