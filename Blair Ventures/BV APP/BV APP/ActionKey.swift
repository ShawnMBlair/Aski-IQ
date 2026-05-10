// ActionKey.swift
// Aski IQ — Phase 6 / Wave 2 of the stabilization plan.
//
// CONTRACT
//   ActionKey is the canonical Swift identifier for every gated action
//   in the app. The matching DB-side workflow_settings.action_key column
//   (Phase 6 / Wave 1 migration WS1) uses these same string values, so a
//   row in workflow_settings can be looked up by ActionKey.rawValue.
//
//   New gating call-sites should use:
//
//       guard store.canPerform(action: .quoteApprove, amount: total) else { return }
//
//   instead of hardcoded role lists like:
//
//       guard [.manager, .executive, .owner].contains(role) else { return }
//
//   The canPerform helper (in WorkflowSetting.swift) currently delegates
//   to the existing per-domain helpers (canApproveMaterialRequest,
//   canSendToSupplier, etc.) so behavior is identical to today. The
//   Wave 4 swap will replace that delegation with a workflow_settings
//   lookup keyed by (company_id, role_key, action_key) once WS1 lands
//   on prod.
//
//   Wave 3 (shipped): all major view-layer gating call-sites now route
//   through canPerform — Procurement (create / approve / send / receive),
//   the Approval Queue (quote / CO / timesheet / schedule), the More-tab
//   timesheet link, the DJR approve/reject button, and the Scheduling
//   Command Centre. Remaining direct uses of the underlying helpers are
//   intentional: the SyncEngine push/pull mappers (field IO) and the
//   WorkflowSettingsAdminView (the source-of-truth editor itself).
//
//   The two-step migration (shim now, engine later) lets call-sites
//   adopt the API immediately without waiting for WS1 to land on prod.

import Foundation

enum ActionKey: String, CaseIterable {

    // MARK: Material Requests
    case materialRequestCreate          = "material_request.create"
    case materialRequestApprove         = "material_request.approve"
    case materialRequestSendToSupplier  = "material_request.send_to_supplier"
    case materialRequestReceive         = "material_request.receive"

    // MARK: Purchase Orders
    case purchaseOrderCreate            = "purchase_order.create"
    case purchaseOrderSend              = "purchase_order.send"
    case purchaseOrderReceive           = "purchase_order.receive"
    case purchaseOrderMatchInvoice      = "purchase_order.match_invoice"

    // MARK: Quotes
    case quoteApprove                   = "quote.approve"
    case quoteSend                      = "quote.send"
    case quoteMarkAccepted              = "quote.mark_accepted"
    case quoteDecline                   = "quote.decline"

    // MARK: Estimates
    case estimateReview                 = "estimate.review"
    case estimateApprove                = "estimate.approve"

    // MARK: Invoices
    case invoiceSend                    = "invoice.send"
    case invoiceVoid                    = "invoice.void"
    case invoiceRecordPayment           = "invoice.record_payment"

    // MARK: Change Orders
    case changeOrderApprove             = "change_order.approve"
    case changeOrderReject              = "change_order.reject"

    // MARK: Schedule
    case scheduleEdit                   = "schedule.edit"
    case scheduleOverrideConflict       = "schedule.override_conflict"
    case scheduleApproveRecommendation  = "schedule.approve_recommendation"

    // MARK: Timesheets
    case timesheetApprove               = "timesheet.approve"
    case timesheetEditSubmitted         = "timesheet.edit_submitted"

    // MARK: RFIs
    case rfiAnswer                      = "rfi.answer"
    case rfiClose                       = "rfi.close"

    // MARK: Contracts / Sub-Contracts
    case contractApprove                = "contract.approve"
    case contractTerminate              = "contract.terminate"
    case subContractApprove             = "sub_contract.approve"

    // MARK: Material Sales
    case materialSaleApprove            = "material_sale.approve"
    case materialSaleVoid               = "material_sale.void"

    // MARK: Display

    /// Human-readable label for the action — shown in admin UIs (the
    /// Workflow Settings page) when an admin is configuring per-role
    /// limits per action. Keep concise; the module prefix is dropped
    /// because the admin UI groups by module.
    var displayName: String {
        switch self {
        case .materialRequestCreate:         return "Create Material Request"
        case .materialRequestApprove:        return "Approve Material Request"
        case .materialRequestSendToSupplier: return "Send to Supplier"
        case .materialRequestReceive:        return "Receive Materials"

        case .purchaseOrderCreate:           return "Create Purchase Order"
        case .purchaseOrderSend:             return "Send PO to Supplier"
        case .purchaseOrderReceive:          return "Receive PO"
        case .purchaseOrderMatchInvoice:     return "Match Supplier Invoice"

        case .quoteApprove:                  return "Approve Quote"
        case .quoteSend:                     return "Send Quote"
        case .quoteMarkAccepted:             return "Mark Quote Accepted"
        case .quoteDecline:                  return "Decline Quote"

        case .estimateReview:                return "Review Estimate"
        case .estimateApprove:               return "Approve Estimate"

        case .invoiceSend:                   return "Send Invoice"
        case .invoiceVoid:                   return "Void Invoice"
        case .invoiceRecordPayment:          return "Record Payment"

        case .changeOrderApprove:            return "Approve Change Order"
        case .changeOrderReject:             return "Reject Change Order"

        case .scheduleEdit:                  return "Edit Schedule"
        case .scheduleOverrideConflict:      return "Override Conflict"
        case .scheduleApproveRecommendation: return "Approve AI Schedule"

        case .timesheetApprove:              return "Approve Timesheet"
        case .timesheetEditSubmitted:        return "Edit Submitted Timesheet"

        case .rfiAnswer:                     return "Answer RFI"
        case .rfiClose:                      return "Close RFI"

        case .contractApprove:               return "Approve Contract"
        case .contractTerminate:             return "Terminate Contract"
        case .subContractApprove:            return "Approve Sub-Contract"

        case .materialSaleApprove:           return "Approve Material Sale"
        case .materialSaleVoid:              return "Void Material Sale"
        }
    }

    /// Module bucket for grouping in admin UIs. Derived from the part
    /// of the rawValue before the dot.
    var module: String {
        rawValue.split(separator: ".").first.map(String.init) ?? "other"
    }

    /// True for actions that take an amount (the per-role
    /// approval_limit_amount column gates them). False for binary
    /// allow/deny actions like "send" or "receive."
    var isAmountGated: Bool {
        switch self {
        case .materialRequestApprove,
             .quoteApprove,
             .changeOrderApprove,
             .estimateApprove,
             .subContractApprove,
             .materialSaleApprove:
            return true
        default:
            return false
        }
    }
}
