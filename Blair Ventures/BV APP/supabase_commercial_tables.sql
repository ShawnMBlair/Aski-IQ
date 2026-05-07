-- ============================================================
-- Blair Ventures Field OS  –  Commercial Modules Schema
-- Run this in: Supabase Dashboard → SQL Editor → New query
--
-- Creates 9 new tables for the commercial modules:
--   change_orders, rfis, project_budgets, subcontractors,
--   sub_contracts, invoices, purchase_orders,
--   material_requests, suppliers
--
-- Safe to run multiple times (IF NOT EXISTS / OR REPLACE).
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. CHANGE ORDERS
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS change_orders (
    id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id             text,
    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now(),
    sync_status             text        NOT NULL DEFAULT 'synced',
    last_modified_by        text        NOT NULL DEFAULT '',
    last_modified_at        timestamptz NOT NULL DEFAULT now(),

    -- Identity
    number                  text        NOT NULL,
    title                   text        NOT NULL,
    project_id              uuid        NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    -- Classification
    type                    text        NOT NULL DEFAULT 'owner_initiated',
    status                  text        NOT NULL DEFAULT 'draft',

    -- Financial / schedule impact
    cost_impact             numeric(14,2) NOT NULL DEFAULT 0,
    schedule_impact_days    integer     NOT NULL DEFAULT 0,

    -- Detail
    description             text        NOT NULL DEFAULT '',
    reason                  text,
    notes                   text,
    line_items_json         text        NOT NULL DEFAULT '[]',  -- JSON array of ChangeOrderLineItem

    -- Dates
    submitted_date          timestamptz,
    approved_date           timestamptz,
    rejected_date           timestamptz,

    -- People
    created_by_id           uuid,
    approved_by_name        text,
    client_reference_number text
);

CREATE INDEX IF NOT EXISTS idx_change_orders_project_id ON change_orders(project_id);
CREATE INDEX IF NOT EXISTS idx_change_orders_status     ON change_orders(status);

ALTER TABLE change_orders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "change_orders_auth" ON change_orders;
CREATE POLICY "change_orders_auth" ON change_orders
    FOR ALL TO authenticated USING (true) WITH CHECK (true);


-- ────────────────────────────────────────────────────────────
-- 2. RFIs
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rfis (
    id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id             text,
    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now(),
    sync_status             text        NOT NULL DEFAULT 'synced',
    last_modified_by        text        NOT NULL DEFAULT '',
    last_modified_at        timestamptz NOT NULL DEFAULT now(),

    -- Identity
    number                  text        NOT NULL,
    title                   text        NOT NULL,
    project_id              uuid        NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    -- Classification
    status                  text        NOT NULL DEFAULT 'draft',
    priority                text        NOT NULL DEFAULT 'normal',
    category                text        NOT NULL DEFAULT 'other',

    -- Question
    question                text        NOT NULL DEFAULT '',
    reference               text,
    submitted_by_id         uuid,
    submitted_by_name       text,
    submitted_date          timestamptz,
    required_by_date        timestamptz,

    -- Response
    answer                  text,
    answered_by_name        text,
    answered_date           timestamptz,

    -- Impact
    has_cost_impact         boolean     NOT NULL DEFAULT false,
    has_schedule_impact     boolean     NOT NULL DEFAULT false,
    linked_change_order_id  uuid,

    -- Internal
    internal_notes          text,
    closed_date             timestamptz
);

CREATE INDEX IF NOT EXISTS idx_rfis_project_id ON rfis(project_id);
CREATE INDEX IF NOT EXISTS idx_rfis_status     ON rfis(status);

ALTER TABLE rfis ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "rfis_auth" ON rfis;
CREATE POLICY "rfis_auth" ON rfis
    FOR ALL TO authenticated USING (true) WITH CHECK (true);


-- ────────────────────────────────────────────────────────────
-- 3. PROJECT BUDGETS
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS project_budgets (
    id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id             text,
    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now(),
    sync_status             text        NOT NULL DEFAULT 'synced',
    last_modified_by        text        NOT NULL DEFAULT '',
    last_modified_at        timestamptz NOT NULL DEFAULT now(),

    project_id              uuid        NOT NULL UNIQUE REFERENCES projects(id) ON DELETE CASCADE,

    original_contract_value numeric(14,2) NOT NULL DEFAULT 0,
    contingency_amount      numeric(14,2) NOT NULL DEFAULT 0,

    -- JSON array of ProjectBudgetLine (cost-code breakdown)
    lines_json              text        NOT NULL DEFAULT '[]'
);

CREATE INDEX IF NOT EXISTS idx_project_budgets_project_id ON project_budgets(project_id);

ALTER TABLE project_budgets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "project_budgets_auth" ON project_budgets;
CREATE POLICY "project_budgets_auth" ON project_budgets
    FOR ALL TO authenticated USING (true) WITH CHECK (true);


-- ────────────────────────────────────────────────────────────
-- 4. SUBCONTRACTORS
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS subcontractors (
    id                              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id                     text,
    created_at                      timestamptz NOT NULL DEFAULT now(),
    updated_at                      timestamptz NOT NULL DEFAULT now(),
    sync_status                     text        NOT NULL DEFAULT 'synced',
    last_modified_by                text        NOT NULL DEFAULT '',
    last_modified_at                timestamptz NOT NULL DEFAULT now(),

    -- Identity
    company_name                    text        NOT NULL,
    trade                           text,
    status                          text        NOT NULL DEFAULT 'active',

    -- Contact
    contact_name                    text,
    contact_title                   text,
    email                           text,
    phone                           text,
    address                         text,

    -- Insurance
    insurance_policy_number         text,
    insurance_expiry                timestamptz,
    insurance_amount                numeric(14,2),

    -- WCB
    wcb_account                     text,
    wcb_expiry                      timestamptz,
    wcb_clearance_letter_received   boolean     NOT NULL DEFAULT false,

    -- COR
    has_cor                         boolean     NOT NULL DEFAULT false,
    cor_expiry                      timestamptz,

    -- Internal
    notes                           text,
    rating                          integer     CHECK (rating IS NULL OR rating BETWEEN 1 AND 5)
);

CREATE INDEX IF NOT EXISTS idx_subcontractors_status ON subcontractors(status);

ALTER TABLE subcontractors ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "subcontractors_auth" ON subcontractors;
CREATE POLICY "subcontractors_auth" ON subcontractors
    FOR ALL TO authenticated USING (true) WITH CHECK (true);


-- ────────────────────────────────────────────────────────────
-- 5. SUB-CONTRACTS
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sub_contracts (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id         text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    sync_status         text        NOT NULL DEFAULT 'synced',
    last_modified_by    text        NOT NULL DEFAULT '',
    last_modified_at    timestamptz NOT NULL DEFAULT now(),

    -- Identity
    contract_number     text        NOT NULL,
    subcontractor_id    uuid        NOT NULL REFERENCES subcontractors(id) ON DELETE CASCADE,
    project_id          uuid        NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    -- Classification
    status              text        NOT NULL DEFAULT 'draft',
    scope               text        NOT NULL DEFAULT '',

    -- Financial
    contract_value      numeric(14,2) NOT NULL DEFAULT 0,
    retention_percent   numeric(5,2)  NOT NULL DEFAULT 10,
    invoiced_to_date    numeric(14,2) NOT NULL DEFAULT 0,
    paid_to_date        numeric(14,2) NOT NULL DEFAULT 0,

    -- Schedule
    start_date          timestamptz,
    end_date            timestamptz,

    -- Terms
    payment_terms       text,
    notes               text,
    executed_date       timestamptz
);

CREATE INDEX IF NOT EXISTS idx_sub_contracts_project_id       ON sub_contracts(project_id);
CREATE INDEX IF NOT EXISTS idx_sub_contracts_subcontractor_id ON sub_contracts(subcontractor_id);
CREATE INDEX IF NOT EXISTS idx_sub_contracts_status           ON sub_contracts(status);

ALTER TABLE sub_contracts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "sub_contracts_auth" ON sub_contracts;
CREATE POLICY "sub_contracts_auth" ON sub_contracts
    FOR ALL TO authenticated USING (true) WITH CHECK (true);


-- ────────────────────────────────────────────────────────────
-- 6. INVOICES
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS invoices (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id      text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    sync_status      text        NOT NULL DEFAULT 'synced',
    last_modified_by text        NOT NULL DEFAULT '',
    last_modified_at timestamptz NOT NULL DEFAULT now(),

    -- Identity
    invoice_number   text        NOT NULL,
    project_id       uuid        REFERENCES projects(id) ON DELETE SET NULL,
    client_id        uuid,

    -- Dates
    invoice_date     timestamptz NOT NULL DEFAULT now(),
    due_date         timestamptz NOT NULL,
    sent_at          timestamptz,
    paid_at          timestamptz,

    -- Status
    status           text        NOT NULL DEFAULT 'draft',

    -- Header
    bill_to_name     text        NOT NULL DEFAULT '',
    bill_to_address  text        NOT NULL DEFAULT '',
    po_number        text        NOT NULL DEFAULT '',
    terms            text        NOT NULL DEFAULT 'Net 30',
    notes            text        NOT NULL DEFAULT '',
    internal_notes   text        NOT NULL DEFAULT '',

    -- Line items & payments (JSON arrays)
    line_items_json  text        NOT NULL DEFAULT '[]',
    payments_json    text        NOT NULL DEFAULT '[]',

    -- Tax
    tax_rate         numeric(6,4) NOT NULL DEFAULT 0.05
);

CREATE INDEX IF NOT EXISTS idx_invoices_project_id ON invoices(project_id);
CREATE INDEX IF NOT EXISTS idx_invoices_status     ON invoices(status);
CREATE INDEX IF NOT EXISTS idx_invoices_due_date   ON invoices(due_date);

ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "invoices_auth" ON invoices;
CREATE POLICY "invoices_auth" ON invoices
    FOR ALL TO authenticated USING (true) WITH CHECK (true);


-- ────────────────────────────────────────────────────────────
-- 7. SUPPLIERS
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS suppliers (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at     timestamptz NOT NULL DEFAULT now(),
    name           text        NOT NULL,
    contact_name   text        NOT NULL DEFAULT '',
    phone          text        NOT NULL DEFAULT '',
    email          text        NOT NULL DEFAULT '',
    address        text        NOT NULL DEFAULT '',
    account_number text        NOT NULL DEFAULT '',
    notes          text        NOT NULL DEFAULT '',
    is_preferred   boolean     NOT NULL DEFAULT false,
    categories_json text       NOT NULL DEFAULT '[]'   -- JSON array of category strings
);

ALTER TABLE suppliers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "suppliers_auth" ON suppliers;
CREATE POLICY "suppliers_auth" ON suppliers
    FOR ALL TO authenticated USING (true) WITH CHECK (true);


-- ────────────────────────────────────────────────────────────
-- 8. MATERIAL REQUESTS
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS material_requests (
    id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    sync_status       text        NOT NULL DEFAULT 'synced',

    -- Identity
    request_number    text        NOT NULL,
    project_id        uuid        REFERENCES projects(id) ON DELETE SET NULL,
    requested_by_id   uuid,
    requested_by_name text        NOT NULL DEFAULT '',

    -- Dates
    request_date      timestamptz NOT NULL DEFAULT now(),
    required_by_date  timestamptz,

    -- Status
    status            text        NOT NULL DEFAULT 'draft',

    -- Content
    line_items_json   text        NOT NULL DEFAULT '[]',
    notes             text        NOT NULL DEFAULT '',
    site_location     text        NOT NULL DEFAULT '',

    -- Approval
    approved_by_name  text        NOT NULL DEFAULT '',
    approved_at       timestamptz,

    -- Linked PO
    purchase_order_id uuid
);

CREATE INDEX IF NOT EXISTS idx_material_requests_project_id ON material_requests(project_id);
CREATE INDEX IF NOT EXISTS idx_material_requests_status     ON material_requests(status);

ALTER TABLE material_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "material_requests_auth" ON material_requests;
CREATE POLICY "material_requests_auth" ON material_requests
    FOR ALL TO authenticated USING (true) WITH CHECK (true);


-- ────────────────────────────────────────────────────────────
-- 9. PURCHASE ORDERS
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS purchase_orders (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    sync_status         text        NOT NULL DEFAULT 'synced',

    -- Identity
    po_number           text        NOT NULL,
    project_id          uuid        REFERENCES projects(id) ON DELETE SET NULL,
    supplier_id         uuid        REFERENCES suppliers(id) ON DELETE SET NULL,
    supplier_name       text        NOT NULL DEFAULT '',

    -- Dates
    issue_date          timestamptz NOT NULL DEFAULT now(),
    required_date       timestamptz,
    received_date       timestamptz,

    -- Status
    status              text        NOT NULL DEFAULT 'draft',

    -- Linked request
    material_request_id uuid        REFERENCES material_requests(id) ON DELETE SET NULL,

    -- Content
    line_items_json     text        NOT NULL DEFAULT '[]',
    delivery_address    text        NOT NULL DEFAULT '',
    terms               text        NOT NULL DEFAULT '',
    notes               text        NOT NULL DEFAULT '',
    internal_notes      text        NOT NULL DEFAULT '',

    -- Tax
    tax_rate            numeric(6,4) NOT NULL DEFAULT 0.05
);

CREATE INDEX IF NOT EXISTS idx_purchase_orders_project_id  ON purchase_orders(project_id);
CREATE INDEX IF NOT EXISTS idx_purchase_orders_supplier_id ON purchase_orders(supplier_id);
CREATE INDEX IF NOT EXISTS idx_purchase_orders_status      ON purchase_orders(status);

ALTER TABLE purchase_orders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "purchase_orders_auth" ON purchase_orders;
CREATE POLICY "purchase_orders_auth" ON purchase_orders
    FOR ALL TO authenticated USING (true) WITH CHECK (true);


-- ────────────────────────────────────────────────────────────
-- UPDATED_AT auto-stamp trigger (reusable)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    tbl text;
BEGIN
    FOREACH tbl IN ARRAY ARRAY[
        'change_orders', 'rfis', 'project_budgets', 'subcontractors',
        'sub_contracts', 'invoices', 'material_requests', 'purchase_orders'
    ]
    LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS trg_%1$s_updated_at ON %1$s;
             CREATE TRIGGER trg_%1$s_updated_at
             BEFORE UPDATE ON %1$s
             FOR EACH ROW EXECUTE FUNCTION set_updated_at();',
            tbl
        );
    END LOOP;
END;
$$;
