-- ============================================================
-- Aski IQ – Commercial Module Migration
-- Run this in Supabase Dashboard → SQL Editor
-- Tables: clients, quotes, change_orders, rfis, project_budgets,
--         subcontractors, sub_contracts, invoices,
--         purchase_orders, material_requests, suppliers
-- ============================================================

-- ─────────────────────────────────────────────
-- clients
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS clients (
    id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name                  TEXT        NOT NULL,
    code                  TEXT,
    contact_name          TEXT,
    contact_email         TEXT,
    contact_phone         TEXT,
    billing_address       TEXT,
    billing_city          TEXT,
    billing_province      TEXT,
    billing_postal        TEXT,
    default_payment_terms TEXT,
    tax_exempt            BOOLEAN     NOT NULL DEFAULT FALSE,
    notes                 TEXT,
    is_active             BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE clients
    ADD COLUMN IF NOT EXISTS code                  TEXT,
    ADD COLUMN IF NOT EXISTS contact_name          TEXT,
    ADD COLUMN IF NOT EXISTS contact_email         TEXT,
    ADD COLUMN IF NOT EXISTS contact_phone         TEXT,
    ADD COLUMN IF NOT EXISTS billing_address       TEXT,
    ADD COLUMN IF NOT EXISTS billing_city          TEXT,
    ADD COLUMN IF NOT EXISTS billing_province      TEXT,
    ADD COLUMN IF NOT EXISTS billing_postal        TEXT,
    ADD COLUMN IF NOT EXISTS default_payment_terms TEXT,
    ADD COLUMN IF NOT EXISTS tax_exempt            BOOLEAN     NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS notes                 TEXT,
    ADD COLUMN IF NOT EXISTS is_active             BOOLEAN     NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_clients_name     ON clients (name);
CREATE INDEX IF NOT EXISTS idx_clients_is_active ON clients (is_active);

-- ─────────────────────────────────────────────
-- quotes
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS quotes (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    job_number          TEXT        NOT NULL,
    estimate_id         UUID        NOT NULL,
    client_id           UUID        NOT NULL REFERENCES clients(id) ON DELETE SET NULL,
    client_name         TEXT        NOT NULL,
    revision            INTEGER     NOT NULL DEFAULT 1,
    site_address        TEXT,
    prepared_by         TEXT        NOT NULL DEFAULT '',
    scope_summary       TEXT,
    inclusions          TEXT,
    exclusions          TEXT,
    assumptions         TEXT,
    subtotal            NUMERIC(14,2) NOT NULL DEFAULT 0,
    contingency_percent NUMERIC(5,2)  NOT NULL DEFAULT 0,
    payment_terms       TEXT,
    validity_days       INTEGER     NOT NULL DEFAULT 30,
    status              TEXT        NOT NULL DEFAULT 'draft',
    approved_by         TEXT,
    assigned_pm_name    TEXT,
    project_id          UUID,
    assigned_pm_id      UUID,
    quote_date          DATE        NOT NULL DEFAULT CURRENT_DATE,
    expiry_date         DATE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    approved_at         TIMESTAMPTZ,
    sent_at             TIMESTAMPTZ,
    accepted_at         TIMESTAMPTZ
);

ALTER TABLE quotes
    ADD COLUMN IF NOT EXISTS site_address        TEXT,
    ADD COLUMN IF NOT EXISTS scope_summary       TEXT,
    ADD COLUMN IF NOT EXISTS inclusions          TEXT,
    ADD COLUMN IF NOT EXISTS exclusions          TEXT,
    ADD COLUMN IF NOT EXISTS assumptions         TEXT,
    ADD COLUMN IF NOT EXISTS contingency_percent NUMERIC(5,2)  NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS payment_terms       TEXT,
    ADD COLUMN IF NOT EXISTS validity_days       INTEGER     NOT NULL DEFAULT 30,
    ADD COLUMN IF NOT EXISTS approved_by         TEXT,
    ADD COLUMN IF NOT EXISTS assigned_pm_name    TEXT,
    ADD COLUMN IF NOT EXISTS project_id          UUID,
    ADD COLUMN IF NOT EXISTS assigned_pm_id      UUID,
    ADD COLUMN IF NOT EXISTS approved_at         TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS sent_at             TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS accepted_at         TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_quotes_client_id   ON quotes (client_id);
CREATE INDEX IF NOT EXISTS idx_quotes_estimate_id ON quotes (estimate_id);
CREATE INDEX IF NOT EXISTS idx_quotes_status      ON quotes (status);

-- ─────────────────────────────────────────────
-- change_orders
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS change_orders (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    number                  TEXT        NOT NULL,
    title                   TEXT        NOT NULL,
    project_id              UUID        NOT NULL,
    type                    TEXT        NOT NULL DEFAULT 'other',
    status                  TEXT        NOT NULL DEFAULT 'draft',
    description             TEXT,
    reason                  TEXT,
    notes                   TEXT,
    cost_impact             NUMERIC(14,2) NOT NULL DEFAULT 0,
    schedule_impact_days    INTEGER     NOT NULL DEFAULT 0,
    line_items_json         TEXT        NOT NULL DEFAULT '[]',
    submitted_date          TIMESTAMPTZ,
    approved_date           TIMESTAMPTZ,
    rejected_date           TIMESTAMPTZ,
    approved_by_name        TEXT,
    client_reference_number TEXT,
    last_modified_by        TEXT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE change_orders
    ADD COLUMN IF NOT EXISTS description             TEXT,
    ADD COLUMN IF NOT EXISTS reason                  TEXT,
    ADD COLUMN IF NOT EXISTS notes                   TEXT,
    ADD COLUMN IF NOT EXISTS line_items_json         TEXT NOT NULL DEFAULT '[]',
    ADD COLUMN IF NOT EXISTS submitted_date          TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS approved_date           TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS rejected_date           TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS approved_by_name        TEXT,
    ADD COLUMN IF NOT EXISTS client_reference_number TEXT,
    ADD COLUMN IF NOT EXISTS last_modified_by        TEXT,
    ADD COLUMN IF NOT EXISTS updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_change_orders_project_id ON change_orders (project_id);
CREATE INDEX IF NOT EXISTS idx_change_orders_status     ON change_orders (status);

-- ─────────────────────────────────────────────
-- rfis
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS rfis (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    number              TEXT        NOT NULL,
    title               TEXT        NOT NULL,
    project_id          UUID        NOT NULL,
    status              TEXT        NOT NULL DEFAULT 'draft',
    priority            TEXT        NOT NULL DEFAULT 'normal',
    category            TEXT        NOT NULL DEFAULT 'other',
    question            TEXT,
    reference           TEXT,
    submitted_by_name   TEXT,
    answer              TEXT,
    answered_by_name    TEXT,
    internal_notes      TEXT,
    has_cost_impact     BOOLEAN     NOT NULL DEFAULT FALSE,
    has_schedule_impact BOOLEAN     NOT NULL DEFAULT FALSE,
    required_by_date    TIMESTAMPTZ,
    submitted_date      TIMESTAMPTZ,
    answered_date       TIMESTAMPTZ,
    last_modified_by    TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE rfis
    ADD COLUMN IF NOT EXISTS question            TEXT,
    ADD COLUMN IF NOT EXISTS reference           TEXT,
    ADD COLUMN IF NOT EXISTS submitted_by_name   TEXT,
    ADD COLUMN IF NOT EXISTS answer              TEXT,
    ADD COLUMN IF NOT EXISTS answered_by_name    TEXT,
    ADD COLUMN IF NOT EXISTS internal_notes      TEXT,
    ADD COLUMN IF NOT EXISTS has_cost_impact     BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS has_schedule_impact BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS required_by_date    TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS submitted_date      TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS answered_date       TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_modified_by    TEXT,
    ADD COLUMN IF NOT EXISTS updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_rfis_project_id ON rfis (project_id);
CREATE INDEX IF NOT EXISTS idx_rfis_status     ON rfis (status);

-- ─────────────────────────────────────────────
-- project_budgets
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS project_budgets (
    id                      UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id              UUID          NOT NULL UNIQUE,
    original_contract_value NUMERIC(14,2) NOT NULL DEFAULT 0,
    contingency_amount      NUMERIC(14,2) NOT NULL DEFAULT 0,
    lines_json              TEXT          NOT NULL DEFAULT '[]',
    last_modified_by        TEXT,
    created_at              TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

ALTER TABLE project_budgets
    ADD COLUMN IF NOT EXISTS lines_json       TEXT        NOT NULL DEFAULT '[]',
    ADD COLUMN IF NOT EXISTS last_modified_by TEXT,
    ADD COLUMN IF NOT EXISTS updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_project_budgets_project_id ON project_budgets (project_id);

-- ─────────────────────────────────────────────
-- subcontractors
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS subcontractors (
    id                              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    company_name                    TEXT        NOT NULL,
    trade                           TEXT        NOT NULL DEFAULT '',
    status                          TEXT        NOT NULL DEFAULT 'active',
    contact_name                    TEXT,
    contact_title                   TEXT,
    email                           TEXT,
    phone                           TEXT,
    address                         TEXT,
    insurance_policy_number         TEXT,
    insurance_expiry                DATE,
    insurance_amount                NUMERIC(14,2),
    wcb_account                     TEXT,
    wcb_expiry                      DATE,
    wcb_clearance_letter_received   BOOLEAN     NOT NULL DEFAULT FALSE,
    has_cor                         BOOLEAN     NOT NULL DEFAULT FALSE,
    cor_expiry                      DATE,
    notes                           TEXT,
    rating                          INTEGER     NOT NULL DEFAULT 3,
    last_modified_by                TEXT,
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE subcontractors
    ADD COLUMN IF NOT EXISTS contact_title                   TEXT,
    ADD COLUMN IF NOT EXISTS insurance_policy_number         TEXT,
    ADD COLUMN IF NOT EXISTS insurance_expiry                DATE,
    ADD COLUMN IF NOT EXISTS insurance_amount                NUMERIC(14,2),
    ADD COLUMN IF NOT EXISTS wcb_account                     TEXT,
    ADD COLUMN IF NOT EXISTS wcb_expiry                      DATE,
    ADD COLUMN IF NOT EXISTS wcb_clearance_letter_received   BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS has_cor                         BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS cor_expiry                      DATE,
    ADD COLUMN IF NOT EXISTS rating                          INTEGER NOT NULL DEFAULT 3,
    ADD COLUMN IF NOT EXISTS last_modified_by                TEXT,
    ADD COLUMN IF NOT EXISTS updated_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_subcontractors_status ON subcontractors (status);
CREATE INDEX IF NOT EXISTS idx_subcontractors_trade  ON subcontractors (trade);

-- ─────────────────────────────────────────────
-- sub_contracts
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS sub_contracts (
    id                UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_number   TEXT          NOT NULL,
    subcontractor_id  UUID          NOT NULL REFERENCES subcontractors(id) ON DELETE SET NULL,
    project_id        UUID          NOT NULL,
    status            TEXT          NOT NULL DEFAULT 'draft',
    scope             TEXT          NOT NULL DEFAULT '',
    contract_value    NUMERIC(14,2) NOT NULL DEFAULT 0,
    retention_percent NUMERIC(5,2)  NOT NULL DEFAULT 10,
    invoiced_to_date  NUMERIC(14,2) NOT NULL DEFAULT 0,
    paid_to_date      NUMERIC(14,2) NOT NULL DEFAULT 0,
    start_date        DATE,
    end_date          DATE,
    payment_terms     TEXT,
    notes             TEXT,
    executed_date     DATE,
    last_modified_by  TEXT,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

ALTER TABLE sub_contracts
    ADD COLUMN IF NOT EXISTS scope             TEXT        NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS retention_percent NUMERIC(5,2) NOT NULL DEFAULT 10,
    ADD COLUMN IF NOT EXISTS invoiced_to_date  NUMERIC(14,2) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS paid_to_date      NUMERIC(14,2) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS payment_terms     TEXT,
    ADD COLUMN IF NOT EXISTS notes             TEXT,
    ADD COLUMN IF NOT EXISTS executed_date     DATE,
    ADD COLUMN IF NOT EXISTS last_modified_by  TEXT,
    ADD COLUMN IF NOT EXISTS updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_sub_contracts_subcontractor_id ON sub_contracts (subcontractor_id);
CREATE INDEX IF NOT EXISTS idx_sub_contracts_project_id       ON sub_contracts (project_id);
CREATE INDEX IF NOT EXISTS idx_sub_contracts_status           ON sub_contracts (status);

-- ─────────────────────────────────────────────
-- invoices
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS invoices (
    id                UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_number    TEXT          NOT NULL,
    project_id        UUID,
    client_id         UUID,
    invoice_date      DATE          NOT NULL DEFAULT CURRENT_DATE,
    due_date          DATE          NOT NULL,
    sent_at           TIMESTAMPTZ,
    paid_at           TIMESTAMPTZ,
    status            TEXT          NOT NULL DEFAULT 'draft',
    bill_to_name      TEXT          NOT NULL DEFAULT '',
    bill_to_address   TEXT          NOT NULL DEFAULT '',
    po_number         TEXT          NOT NULL DEFAULT '',
    terms             TEXT          NOT NULL DEFAULT '',
    notes             TEXT          NOT NULL DEFAULT '',
    internal_notes    TEXT          NOT NULL DEFAULT '',
    line_items_json   TEXT          NOT NULL DEFAULT '[]',
    payments_json     TEXT          NOT NULL DEFAULT '[]',
    tax_rate          NUMERIC(5,4)  NOT NULL DEFAULT 0,
    last_modified_by  TEXT,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

ALTER TABLE invoices
    ADD COLUMN IF NOT EXISTS bill_to_name     TEXT        NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS bill_to_address  TEXT        NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS po_number        TEXT        NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS terms            TEXT        NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS internal_notes   TEXT        NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS line_items_json  TEXT        NOT NULL DEFAULT '[]',
    ADD COLUMN IF NOT EXISTS payments_json    TEXT        NOT NULL DEFAULT '[]',
    ADD COLUMN IF NOT EXISTS tax_rate         NUMERIC(5,4) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS last_modified_by TEXT,
    ADD COLUMN IF NOT EXISTS updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_invoices_client_id  ON invoices (client_id);
CREATE INDEX IF NOT EXISTS idx_invoices_project_id ON invoices (project_id);
CREATE INDEX IF NOT EXISTS idx_invoices_status     ON invoices (status);
CREATE INDEX IF NOT EXISTS idx_invoices_due_date   ON invoices (due_date);

-- ─────────────────────────────────────────────
-- suppliers
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS suppliers (
    id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name             TEXT        NOT NULL,
    contact_name     TEXT,
    phone            TEXT,
    email            TEXT,
    address          TEXT,
    account_number   TEXT,
    notes            TEXT,
    is_preferred     BOOLEAN     NOT NULL DEFAULT FALSE,
    categories_json  TEXT        NOT NULL DEFAULT '[]',
    last_modified_by TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE suppliers
    ADD COLUMN IF NOT EXISTS account_number   TEXT,
    ADD COLUMN IF NOT EXISTS is_preferred     BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS categories_json  TEXT    NOT NULL DEFAULT '[]',
    ADD COLUMN IF NOT EXISTS last_modified_by TEXT,
    ADD COLUMN IF NOT EXISTS updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_suppliers_name         ON suppliers (name);
CREATE INDEX IF NOT EXISTS idx_suppliers_is_preferred ON suppliers (is_preferred);

-- ─────────────────────────────────────────────
-- material_requests
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS material_requests (
    id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    request_number    TEXT        NOT NULL,
    project_id        UUID        NOT NULL,
    requested_by_name TEXT        NOT NULL DEFAULT '',
    request_date      DATE        NOT NULL DEFAULT CURRENT_DATE,
    required_by_date  DATE,
    status            TEXT        NOT NULL DEFAULT 'draft',
    line_items_json   TEXT        NOT NULL DEFAULT '[]',
    notes             TEXT,
    site_location     TEXT,
    approved_by_name  TEXT,
    approved_at       TIMESTAMPTZ,
    purchase_order_id UUID,
    last_modified_by  TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE material_requests
    ADD COLUMN IF NOT EXISTS required_by_date  DATE,
    ADD COLUMN IF NOT EXISTS line_items_json   TEXT        NOT NULL DEFAULT '[]',
    ADD COLUMN IF NOT EXISTS notes             TEXT,
    ADD COLUMN IF NOT EXISTS site_location     TEXT,
    ADD COLUMN IF NOT EXISTS approved_by_name  TEXT,
    ADD COLUMN IF NOT EXISTS approved_at       TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS purchase_order_id UUID,
    ADD COLUMN IF NOT EXISTS last_modified_by  TEXT,
    ADD COLUMN IF NOT EXISTS updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_material_requests_project_id ON material_requests (project_id);
CREATE INDEX IF NOT EXISTS idx_material_requests_status     ON material_requests (status);

-- ─────────────────────────────────────────────
-- purchase_orders
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS purchase_orders (
    id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    po_number           TEXT          NOT NULL,
    project_id          UUID          NOT NULL,
    supplier_id         UUID,
    supplier_name       TEXT          NOT NULL DEFAULT '',
    issue_date          DATE          NOT NULL DEFAULT CURRENT_DATE,
    required_date       DATE,
    received_date       DATE,
    status              TEXT          NOT NULL DEFAULT 'draft',
    material_request_id UUID,
    line_items_json     TEXT          NOT NULL DEFAULT '[]',
    delivery_address    TEXT,
    terms               TEXT,
    notes               TEXT,
    tax_rate            NUMERIC(5,4)  NOT NULL DEFAULT 0,
    last_modified_by    TEXT,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

ALTER TABLE purchase_orders
    ADD COLUMN IF NOT EXISTS supplier_name       TEXT        NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS required_date       DATE,
    ADD COLUMN IF NOT EXISTS received_date       DATE,
    ADD COLUMN IF NOT EXISTS material_request_id UUID,
    ADD COLUMN IF NOT EXISTS line_items_json     TEXT        NOT NULL DEFAULT '[]',
    ADD COLUMN IF NOT EXISTS delivery_address    TEXT,
    ADD COLUMN IF NOT EXISTS terms               TEXT,
    ADD COLUMN IF NOT EXISTS notes               TEXT,
    ADD COLUMN IF NOT EXISTS tax_rate            NUMERIC(5,4) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS last_modified_by    TEXT,
    ADD COLUMN IF NOT EXISTS updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_purchase_orders_project_id  ON purchase_orders (project_id);
CREATE INDEX IF NOT EXISTS idx_purchase_orders_supplier_id ON purchase_orders (supplier_id);
CREATE INDEX IF NOT EXISTS idx_purchase_orders_status      ON purchase_orders (status);

-- ─────────────────────────────────────────────
-- Row Level Security (enable, then apply policies)
-- ─────────────────────────────────────────────

ALTER TABLE clients          ENABLE ROW LEVEL SECURITY;
ALTER TABLE quotes            ENABLE ROW LEVEL SECURITY;
ALTER TABLE change_orders    ENABLE ROW LEVEL SECURITY;
ALTER TABLE rfis              ENABLE ROW LEVEL SECURITY;
ALTER TABLE project_budgets  ENABLE ROW LEVEL SECURITY;
ALTER TABLE subcontractors   ENABLE ROW LEVEL SECURITY;
ALTER TABLE sub_contracts    ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoices          ENABLE ROW LEVEL SECURITY;
ALTER TABLE suppliers         ENABLE ROW LEVEL SECURITY;
ALTER TABLE material_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_orders   ENABLE ROW LEVEL SECURITY;

-- Service role bypass (used by SyncEngine via anon key with service privileges)
-- Adjust to match your auth setup. For dev, you may use a permissive policy:

CREATE POLICY "Authenticated users can read clients"
    ON clients FOR SELECT TO authenticated USING (true);

CREATE POLICY "Authenticated users can upsert clients"
    ON clients FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY "Authenticated users can update clients"
    ON clients FOR UPDATE TO authenticated USING (true);

-- Repeat pattern for other tables as needed. For production, scope these
-- policies to the user's organization_id or profile role.
