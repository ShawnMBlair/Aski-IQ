// MultiTabImportModels.swift
// Aski IQ – Multi-Tab Import System Models (v1.0)

import Foundation
import SwiftUI

// MARK: - Tab Definition

struct ImportTab: Identifiable {
    let id:            ImportRecordType
    let sheetName:     String          // Exact Excel tab name
    let processingOrder: Int
    let requiredFields:  [String]
    let allFields:       [ImportTabField]
    let description:     String

    var specificFields: [ImportTabField] { allFields.filter { !$0.isGlobal } }
    var globalFields:   [ImportTabField] { allFields.filter(\.isGlobal) }
}

struct ImportTabField: Identifiable {
    let key:      String
    let label:    String
    let required: Bool
    let isGlobal: Bool
    let hint:     String
    var id: String { key }
}

// MARK: - Global Fields (appended to every tab)

let importGlobalFields: [ImportTabField] = [
    .init(key: "action_type",       label: "Action Type",       required: false, isGlobal: true, hint: "create / update / archive / skip"),
    .init(key: "app_record_id",     label: "App Record ID",     required: false, isGlobal: true, hint: "UUID — required for update/archive"),
    .init(key: "external_id",       label: "External ID",       required: false, isGlobal: true, hint: "Your own reference ID"),
    .init(key: "status",            label: "Status",            required: false, isGlobal: true, hint: "active / inactive / archived"),
    .init(key: "notes",             label: "Notes",             required: false, isGlobal: true, hint: "Internal notes"),
    .init(key: "template_version",  label: "Template Version",  required: false, isGlobal: true, hint: "e.g. v1.0"),
    .init(key: "import_batch_id",   label: "Import Batch ID",   required: false, isGlobal: true, hint: "Filled automatically by app"),
    .init(key: "company_id",        label: "Company ID",        required: false, isGlobal: true, hint: "Auto-filled by app — or enter your UUID to validate the row"),
    .init(key: "company_name",      label: "Company Name",      required: false, isGlobal: true, hint: "Must match your company"),
    .init(key: "record_type",       label: "Record Type",       required: false, isGlobal: true, hint: "Filled automatically by app"),
]

// MARK: - Tab Registry

enum ImportTabRegistry {

    static let all: [ImportTab] = [
        companies, crmClients, crmContacts, crmOpportunities,
        productsServices, vendorsSuppliers, employeesCrew, equipment,
        projects, estimates, estimateLineItems,
        scheduleItems, timesheets, safetyForms, customForms, documentsAttachments,
    ]

    static func tab(for type: ImportRecordType) -> ImportTab? {
        all.first { $0.id == type }
    }

    // MARK: Companies
    static let companies = ImportTab(
        id: .companies, sheetName: "Companies", processingOrder: 1,
        requiredFields: ["company_name"],
        allFields: [
            .init(key: "company_name",     label: "Company Name *",    required: true,  isGlobal: false, hint: "Legal company name"),
            .init(key: "company_code",     label: "Company Code",      required: false, isGlobal: false, hint: "Short code e.g. APEX"),
            .init(key: "industry",         label: "Industry",          required: false, isGlobal: false, hint: "e.g. Construction"),
            .init(key: "phone",            label: "Phone",             required: false, isGlobal: false, hint: ""),
            .init(key: "email",            label: "Email",             required: false, isGlobal: false, hint: ""),
            .init(key: "website",          label: "Website",           required: false, isGlobal: false, hint: ""),
            .init(key: "billing_address",  label: "Billing Address",   required: false, isGlobal: false, hint: ""),
            .init(key: "billing_city",     label: "City",              required: false, isGlobal: false, hint: ""),
            .init(key: "billing_province", label: "Province",          required: false, isGlobal: false, hint: ""),
            .init(key: "billing_postal",   label: "Postal / ZIP",      required: false, isGlobal: false, hint: ""),
            .init(key: "billing_country",  label: "Country",           required: false, isGlobal: false, hint: "Default: Canada"),
        ] + importGlobalFields,
        description: "Top-level company accounts. Required only for multi-company setups."
    )

    // MARK: CRM Clients
    static let crmClients = ImportTab(
        id: .clients, sheetName: "CRM Clients", processingOrder: 2,
        requiredFields: ["client_name"],
        allFields: [
            .init(key: "client_name",       label: "Client Name *",      required: true,  isGlobal: false, hint: "Company / org name"),
            .init(key: "client_code",       label: "Client Code",        required: false, isGlobal: false, hint: "Short code e.g. SYN"),
            .init(key: "contact_name",      label: "Contact Name",       required: false, isGlobal: false, hint: "Primary contact"),
            .init(key: "contact_title",     label: "Contact Title",      required: false, isGlobal: false, hint: ""),
            .init(key: "contact_email",     label: "Contact Email",      required: false, isGlobal: false, hint: ""),
            .init(key: "contact_phone",     label: "Contact Phone",      required: false, isGlobal: false, hint: ""),
            .init(key: "billing_address",   label: "Billing Address",    required: false, isGlobal: false, hint: ""),
            .init(key: "billing_city",      label: "City",               required: false, isGlobal: false, hint: ""),
            .init(key: "billing_province",  label: "Province",           required: false, isGlobal: false, hint: ""),
            .init(key: "billing_postal",    label: "Postal / ZIP",       required: false, isGlobal: false, hint: ""),
            .init(key: "payment_terms",     label: "Payment Terms",      required: false, isGlobal: false, hint: "Net 30 / Net 45"),
            .init(key: "tax_exempt",        label: "Tax Exempt",         required: false, isGlobal: false, hint: "true / false"),
        ] + importGlobalFields,
        description: "CRM client accounts. Matched on name, email, phone, or client code."
    )

    // MARK: CRM Contacts
    static let crmContacts = ImportTab(
        id: .contacts, sheetName: "CRM Contacts", processingOrder: 3,
        requiredFields: ["first_name", "last_name"],
        allFields: [
            .init(key: "first_name",       label: "First Name *",   required: true,  isGlobal: false, hint: ""),
            .init(key: "last_name",        label: "Last Name *",    required: true,  isGlobal: false, hint: ""),
            .init(key: "email",            label: "Email",          required: false, isGlobal: false, hint: ""),
            .init(key: "phone",            label: "Phone",          required: false, isGlobal: false, hint: ""),
            .init(key: "title",            label: "Job Title",      required: false, isGlobal: false, hint: ""),
            .init(key: "company_name",     label: "Company Name",   required: false, isGlobal: false, hint: "Links to CRM Client"),
            .init(key: "client_external_id",label: "Client Ext. ID",required: false, isGlobal: false, hint: "Links to CRM Client"),
            .init(key: "linkedin",         label: "LinkedIn",       required: false, isGlobal: false, hint: "Profile URL"),
        ] + importGlobalFields,
        description: "Individual contacts linked to CRM clients."
    )

    // MARK: CRM Opportunities
    static let crmOpportunities = ImportTab(
        id: .opportunities, sheetName: "CRM Opportunities", processingOrder: 4,
        requiredFields: ["opportunity_name", "client_name"],
        allFields: [
            .init(key: "opportunity_name",   label: "Opportunity Name *", required: true,  isGlobal: false, hint: ""),
            .init(key: "client_name",        label: "Client Name *",      required: true,  isGlobal: false, hint: ""),
            .init(key: "client_external_id", label: "Client Ext. ID",     required: false, isGlobal: false, hint: ""),
            .init(key: "stage",              label: "Stage",               required: false, isGlobal: false, hint: "Lead/Qualified/Proposal/Negotiation/Won/Lost"),
            .init(key: "value",              label: "Value ($)",           required: false, isGlobal: false, hint: "Deal value"),
            .init(key: "probability_pct",    label: "Probability (%)",     required: false, isGlobal: false, hint: "0–100"),
            .init(key: "expected_close_date",label: "Expected Close Date", required: false, isGlobal: false, hint: "YYYY-MM-DD"),
            .init(key: "assigned_to",        label: "Assigned To",         required: false, isGlobal: false, hint: "Employee name"),
            .init(key: "description",        label: "Description",         required: false, isGlobal: false, hint: ""),
        ] + importGlobalFields,
        description: "CRM pipeline opportunities."
    )

    // MARK: Projects
    static let projects = ImportTab(
        id: .projects, sheetName: "Projects", processingOrder: 9,
        requiredFields: ["project_name"],
        allFields: [
            .init(key: "project_name",     label: "Project Name *",   required: true,  isGlobal: false, hint: ""),
            .init(key: "project_number",   label: "Project Number",   required: false, isGlobal: false, hint: "e.g. PRJ-2024-001"),
            .init(key: "client_name",      label: "Client Name",      required: false, isGlobal: false, hint: ""),
            .init(key: "client_external_id",label: "Client Ext. ID",  required: false, isGlobal: false, hint: ""),
            .init(key: "start_date",       label: "Start Date",       required: false, isGlobal: false, hint: "YYYY-MM-DD"),
            .init(key: "end_date",         label: "End Date",         required: false, isGlobal: false, hint: "YYYY-MM-DD"),
            .init(key: "contract_value",   label: "Contract Value ($)",required: false, isGlobal: false, hint: ""),
            .init(key: "project_type",     label: "Project Type",     required: false, isGlobal: false, hint: "e.g. Industrial, Commercial"),
            .init(key: "project_status",   label: "Project Status",   required: false, isGlobal: false, hint: "active/tender/completed/cancelled"),
            .init(key: "site_address",     label: "Site Address",     required: false, isGlobal: false, hint: ""),
            .init(key: "site_city",        label: "Site City",        required: false, isGlobal: false, hint: ""),
            .init(key: "site_province",    label: "Site Province",    required: false, isGlobal: false, hint: ""),
            .init(key: "project_manager",  label: "Project Manager",  required: false, isGlobal: false, hint: "Employee name"),
        ] + importGlobalFields,
        description: "Active and historical projects."
    )

    // MARK: Estimates
    static let estimates = ImportTab(
        id: .estimates, sheetName: "Estimates", processingOrder: 10,
        requiredFields: ["estimate_name"],
        allFields: [
            .init(key: "estimate_name",     label: "Estimate Name *",   required: true,  isGlobal: false, hint: ""),
            .init(key: "estimate_number",   label: "Estimate Number",   required: false, isGlobal: false, hint: "e.g. EST-2024-001"),
            .init(key: "client_name",       label: "Client Name",       required: false, isGlobal: false, hint: ""),
            .init(key: "client_external_id",label: "Client Ext. ID",    required: false, isGlobal: false, hint: ""),
            .init(key: "project_name",      label: "Project Name",      required: false, isGlobal: false, hint: ""),
            .init(key: "issue_date",        label: "Issue Date",        required: false, isGlobal: false, hint: "YYYY-MM-DD"),
            .init(key: "expiry_date",       label: "Expiry Date",       required: false, isGlobal: false, hint: "YYYY-MM-DD"),
            .init(key: "subtotal",          label: "Subtotal ($)",      required: false, isGlobal: false, hint: "Before tax"),
            .init(key: "tax_rate",          label: "Tax Rate (%)",      required: false, isGlobal: false, hint: "e.g. 5 for GST"),
            .init(key: "total",             label: "Total ($)",         required: false, isGlobal: false, hint: "Including tax"),
        ] + importGlobalFields,
        description: "Estimates / quotes linked to clients and projects."
    )

    // MARK: Estimate Line Items
    static let estimateLineItems = ImportTab(
        id: .estimateLines, sheetName: "Estimate Line Items", processingOrder: 11,
        requiredFields: ["estimate_name", "line_number", "description"],
        allFields: [
            .init(key: "estimate_name",      label: "Estimate Name *",    required: true,  isGlobal: false, hint: "Match exactly to Estimates tab"),
            .init(key: "estimate_external_id",label: "Estimate Ext. ID",  required: false, isGlobal: false, hint: ""),
            .init(key: "line_number",        label: "Line # *",           required: true,  isGlobal: false, hint: "1, 2, 3…"),
            .init(key: "description",        label: "Description *",      required: true,  isGlobal: false, hint: "Line item description"),
            .init(key: "quantity",           label: "Quantity",           required: false, isGlobal: false, hint: ""),
            .init(key: "unit",               label: "Unit",               required: false, isGlobal: false, hint: "hr / m / ft / each"),
            .init(key: "unit_price",         label: "Unit Price ($)",     required: false, isGlobal: false, hint: ""),
            .init(key: "total_price",        label: "Total Price ($)",    required: false, isGlobal: false, hint: "qty × unit_price"),
            .init(key: "cost_code",          label: "Cost Code",          required: false, isGlobal: false, hint: "e.g. LAB-001"),
            .init(key: "category",           label: "Category",           required: false, isGlobal: false, hint: "e.g. Labour, Materials"),
        ] + importGlobalFields,
        description: "Individual line items for estimates."
    )

    // MARK: Products & Services
    static let productsServices = ImportTab(
        id: .products, sheetName: "Products & Services", processingOrder: 5,
        requiredFields: ["product_name"],
        allFields: [
            .init(key: "product_name",  label: "Product / Service Name *", required: true,  isGlobal: false, hint: ""),
            .init(key: "product_code",  label: "Product Code",             required: false, isGlobal: false, hint: "SKU or code"),
            .init(key: "category",      label: "Category",                 required: false, isGlobal: false, hint: "Labour / Material / Equipment"),
            .init(key: "description",   label: "Description",              required: false, isGlobal: false, hint: ""),
            .init(key: "unit_price",    label: "Unit Price ($)",           required: false, isGlobal: false, hint: ""),
            .init(key: "unit",          label: "Unit",                     required: false, isGlobal: false, hint: "hr / m / ft / each"),
            .init(key: "cost_code",     label: "Cost Code",                required: false, isGlobal: false, hint: "e.g. INS-001"),
            .init(key: "taxable",       label: "Taxable",                  required: false, isGlobal: false, hint: "true / false"),
        ] + importGlobalFields,
        description: "Product and service catalogue."
    )

    // MARK: Vendors & Suppliers
    static let vendorsSuppliers = ImportTab(
        id: .vendors, sheetName: "Vendors & Suppliers", processingOrder: 6,
        requiredFields: ["vendor_name"],
        allFields: [
            .init(key: "vendor_name",     label: "Vendor Name *",    required: true,  isGlobal: false, hint: ""),
            .init(key: "vendor_code",     label: "Vendor Code",      required: false, isGlobal: false, hint: ""),
            .init(key: "contact_name",    label: "Contact Name",     required: false, isGlobal: false, hint: ""),
            .init(key: "contact_email",   label: "Contact Email",    required: false, isGlobal: false, hint: ""),
            .init(key: "contact_phone",   label: "Contact Phone",    required: false, isGlobal: false, hint: ""),
            .init(key: "address",         label: "Address",          required: false, isGlobal: false, hint: ""),
            .init(key: "city",            label: "City",             required: false, isGlobal: false, hint: ""),
            .init(key: "province",        label: "Province",         required: false, isGlobal: false, hint: ""),
            .init(key: "postal",          label: "Postal / ZIP",     required: false, isGlobal: false, hint: ""),
            .init(key: "payment_terms",   label: "Payment Terms",    required: false, isGlobal: false, hint: "Net 30 / Net 45"),
            .init(key: "trade_type",      label: "Trade / Category", required: false, isGlobal: false, hint: "e.g. Insulation, Scaffolding"),
        ] + importGlobalFields,
        description: "External vendors and suppliers."
    )

    // MARK: Employees & Crew
    static let employeesCrew = ImportTab(
        id: .employees, sheetName: "Employees & Crew", processingOrder: 7,
        requiredFields: ["first_name", "last_name", "email"],
        allFields: [
            .init(key: "first_name",      label: "First Name *",    required: true,  isGlobal: false, hint: ""),
            .init(key: "last_name",       label: "Last Name *",     required: true,  isGlobal: false, hint: ""),
            .init(key: "employee_number", label: "Employee #",      required: false, isGlobal: false, hint: "Payroll ID"),
            .init(key: "email",           label: "Email *",         required: true,  isGlobal: false, hint: "Used for login"),
            .init(key: "phone",           label: "Phone",           required: false, isGlobal: false, hint: ""),
            .init(key: "role",            label: "Role",            required: false, isGlobal: false, hint: "admin/manager/foreman/field_worker/office"),
            .init(key: "trade",           label: "Trade",           required: false, isGlobal: false, hint: "e.g. Insulation, Scaffolding"),
            .init(key: "hire_date",       label: "Hire Date",       required: false, isGlobal: false, hint: "YYYY-MM-DD"),
            .init(key: "regular_rate",    label: "Regular Rate ($/hr)", required: false, isGlobal: false, hint: ""),
            .init(key: "overtime_rate",   label: "Overtime Rate ($/hr)",required: false, isGlobal: false, hint: ""),
        ] + importGlobalFields,
        description: "Field crew and office staff. Email is used as the unique login identifier."
    )

    // MARK: Equipment
    static let equipment = ImportTab(
        id: .equipment, sheetName: "Equipment", processingOrder: 8,
        requiredFields: ["equipment_name"],
        allFields: [
            .init(key: "equipment_name",   label: "Equipment Name *",  required: true,  isGlobal: false, hint: ""),
            .init(key: "equipment_number", label: "Equipment #",       required: false, isGlobal: false, hint: "Asset number"),
            .init(key: "make",             label: "Make",              required: false, isGlobal: false, hint: "e.g. Cat, JLG"),
            .init(key: "model",            label: "Model",             required: false, isGlobal: false, hint: ""),
            .init(key: "year",             label: "Year",              required: false, isGlobal: false, hint: ""),
            .init(key: "serial_number",    label: "Serial Number",     required: false, isGlobal: false, hint: ""),
            .init(key: "category",         label: "Category",          required: false, isGlobal: false, hint: "e.g. Lift, Compressor, Vehicle"),
            .init(key: "equipment_status", label: "Status",            required: false, isGlobal: false, hint: "active / maintenance / retired"),
            .init(key: "assigned_project", label: "Assigned Project",  required: false, isGlobal: false, hint: "Project name"),
        ] + importGlobalFields,
        description: "Company-owned and rented equipment."
    )

    // MARK: Schedule Items
    static let scheduleItems = ImportTab(
        id: .schedules, sheetName: "Schedule Items", processingOrder: 12,
        requiredFields: ["employee_name", "project_name", "start_date"],
        allFields: [
            .init(key: "employee_name",      label: "Employee Name *",    required: true,  isGlobal: false, hint: ""),
            .init(key: "employee_external_id",label: "Employee Ext. ID",  required: false, isGlobal: false, hint: ""),
            .init(key: "project_name",       label: "Project Name *",     required: true,  isGlobal: false, hint: ""),
            .init(key: "project_external_id",label: "Project Ext. ID",    required: false, isGlobal: false, hint: ""),
            .init(key: "start_date",         label: "Start Date *",       required: true,  isGlobal: false, hint: "YYYY-MM-DD"),
            .init(key: "end_date",           label: "End Date",           required: false, isGlobal: false, hint: "YYYY-MM-DD"),
            .init(key: "start_time",         label: "Start Time",         required: false, isGlobal: false, hint: "HH:MM"),
            .init(key: "end_time",           label: "End Time",           required: false, isGlobal: false, hint: "HH:MM"),
            .init(key: "cost_code",          label: "Cost Code",          required: false, isGlobal: false, hint: "e.g. LAB-001"),
        ] + importGlobalFields,
        description: "Employee schedule assignments."
    )

    // MARK: Timesheets
    static let timesheets = ImportTab(
        id: .timesheets, sheetName: "Timesheets", processingOrder: 13,
        requiredFields: ["employee_name", "project_name", "date"],
        allFields: [
            .init(key: "employee_name",      label: "Employee Name *",    required: true,  isGlobal: false, hint: ""),
            .init(key: "employee_external_id",label: "Employee Ext. ID",  required: false, isGlobal: false, hint: ""),
            .init(key: "project_name",       label: "Project Name *",     required: true,  isGlobal: false, hint: ""),
            .init(key: "project_external_id",label: "Project Ext. ID",    required: false, isGlobal: false, hint: ""),
            .init(key: "date",               label: "Date *",             required: true,  isGlobal: false, hint: "YYYY-MM-DD"),
            .init(key: "start_time",         label: "Start Time",         required: false, isGlobal: false, hint: "HH:MM"),
            .init(key: "end_time",           label: "End Time",           required: false, isGlobal: false, hint: "HH:MM"),
            .init(key: "break_minutes",      label: "Break (min)",        required: false, isGlobal: false, hint: "e.g. 30"),
            .init(key: "regular_hours",      label: "Regular Hours",      required: false, isGlobal: false, hint: "Calculated from times"),
            .init(key: "overtime_hours",     label: "Overtime Hours",     required: false, isGlobal: false, hint: "Calculated from times"),
            .init(key: "cost_code",          label: "Cost Code",          required: false, isGlobal: false, hint: "e.g. LAB-001"),
            .init(key: "task_description",   label: "Task Description",   required: false, isGlobal: false, hint: ""),
        ] + importGlobalFields,
        description: "Historical timesheet entries."
    )

    // MARK: Safety Forms
    static let safetyForms = ImportTab(
        id: .safetyForms, sheetName: "Safety Forms", processingOrder: 14,
        requiredFields: ["form_type", "date"],
        allFields: [
            .init(key: "form_type",          label: "Form Type *",        required: true,  isGlobal: false, hint: "Toolbox Talk / JHA / Incident Report / Site Inspection / FLHA"),
            .init(key: "project_name",       label: "Project Name",       required: false, isGlobal: false, hint: ""),
            .init(key: "project_external_id",label: "Project Ext. ID",    required: false, isGlobal: false, hint: ""),
            .init(key: "submitted_by",       label: "Submitted By",       required: false, isGlobal: false, hint: "Employee name"),
            .init(key: "date",               label: "Date *",             required: true,  isGlobal: false, hint: "YYYY-MM-DD"),
            .init(key: "site_location",      label: "Site Location",      required: false, isGlobal: false, hint: ""),
            .init(key: "hazards_identified", label: "Hazards Identified", required: false, isGlobal: false, hint: ""),
            .init(key: "controls_in_place",  label: "Controls In Place",  required: false, isGlobal: false, hint: ""),
            .init(key: "workers_present",    label: "Workers Present",    required: false, isGlobal: false, hint: "Count or names"),
            .init(key: "sign_off_name",      label: "Sign-Off Name",      required: false, isGlobal: false, hint: ""),
        ] + importGlobalFields,
        description: "Safety forms: toolbox talks, JHAs, incident reports."
    )

    // MARK: Custom Forms
    static let customForms = ImportTab(
        id: .customForms, sheetName: "Custom Forms", processingOrder: 15,
        requiredFields: ["form_template_name", "submission_date"],
        allFields: [
            .init(key: "form_template_name", label: "Form Template Name *", required: true,  isGlobal: false, hint: "Must match existing template"),
            .init(key: "project_name",       label: "Project Name",         required: false, isGlobal: false, hint: ""),
            .init(key: "submitted_by",       label: "Submitted By",         required: false, isGlobal: false, hint: "Employee name"),
            .init(key: "submission_date",    label: "Submission Date *",    required: true,  isGlobal: false, hint: "YYYY-MM-DD"),
            .init(key: "field_1_label",      label: "Field 1 Label",        required: false, isGlobal: false, hint: ""),
            .init(key: "field_1_value",      label: "Field 1 Value",        required: false, isGlobal: false, hint: ""),
            .init(key: "field_2_label",      label: "Field 2 Label",        required: false, isGlobal: false, hint: ""),
            .init(key: "field_2_value",      label: "Field 2 Value",        required: false, isGlobal: false, hint: ""),
            .init(key: "field_3_label",      label: "Field 3 Label",        required: false, isGlobal: false, hint: ""),
            .init(key: "field_3_value",      label: "Field 3 Value",        required: false, isGlobal: false, hint: ""),
            .init(key: "field_4_label",      label: "Field 4 Label",        required: false, isGlobal: false, hint: ""),
            .init(key: "field_4_value",      label: "Field 4 Value",        required: false, isGlobal: false, hint: ""),
            .init(key: "field_5_label",      label: "Field 5 Label",        required: false, isGlobal: false, hint: ""),
            .init(key: "field_5_value",      label: "Field 5 Value",        required: false, isGlobal: false, hint: ""),
        ] + importGlobalFields,
        description: "Submissions for custom form templates."
    )

    // MARK: Documents & Attachments
    static let documentsAttachments = ImportTab(
        id: .documents, sheetName: "Documents & Attachments", processingOrder: 16,
        requiredFields: ["document_name"],
        allFields: [
            .init(key: "document_name",     label: "Document Name *",    required: true,  isGlobal: false, hint: ""),
            .init(key: "document_type",     label: "Document Type",      required: false, isGlobal: false, hint: "Contract / Invoice / Drawing / Photo / Certificate / Other"),
            .init(key: "linked_record_type",label: "Linked Record Type", required: false, isGlobal: false, hint: "Project / Client / Estimate / Employee / Equipment"),
            .init(key: "linked_record_name",label: "Linked Record Name", required: false, isGlobal: false, hint: ""),
            .init(key: "linked_external_id",label: "Linked Ext. ID",     required: false, isGlobal: false, hint: ""),
            .init(key: "file_url",          label: "File URL",           required: false, isGlobal: false, hint: "External link or Supabase path"),
            .init(key: "description",       label: "Description",        required: false, isGlobal: false, hint: ""),
        ] + importGlobalFields,
        description: "Document and attachment records (metadata only — files upload separately)."
    )
}

// MARK: - Multi-Tab Batch Result

struct MultiTabBatchResult {
    var batchID:    UUID = UUID()
    var tabResults: [ImportRecordType: TabResult] = [:]

    var totalCreated: Int { tabResults.values.map(\.created).reduce(0, +) }
    var totalUpdated: Int { tabResults.values.map(\.updated).reduce(0, +) }
    var totalSkipped: Int { tabResults.values.map(\.skipped).reduce(0, +) }
    var totalErrors:  Int { tabResults.values.map(\.errors).reduce(0, +) }
    var totalRows:    Int { tabResults.values.map(\.total).reduce(0, +) }

    var hasAnyErrors: Bool { totalErrors > 0 }
}

struct TabResult {
    var recordType: ImportRecordType
    var total:   Int
    var created: Int
    var updated: Int
    var skipped: Int
    var errors:  Int
    var rows:    [ImportRow] = []
}

// MARK: - Import Row (extended with tab info)

extension ImportRow {
    var actionType: String {
        (mappedData["action_type"] ?? "create").lowercased().trimmingCharacters(in: .whitespaces)
    }
    var companyIDValue: String {
        mappedData["company_id"] ?? ""
    }
}
