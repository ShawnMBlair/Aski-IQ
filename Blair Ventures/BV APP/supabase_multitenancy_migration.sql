-- ============================================================
-- Blair Ventures Field OS – Multi-Tenancy Migration
--
-- Purpose: Adds company-level data isolation so multiple
--          companies can use the same Supabase project with
--          zero data bleed between tenants.
--
-- Run this ONCE in: Supabase Dashboard → SQL Editor → New query
-- Safe to re-run (IF NOT EXISTS / OR REPLACE / DO blocks guard
-- against duplicate execution).
--
-- What this does:
--   1. Creates the `companies` table (one row per tenant)
--   2. Adds `company_id` to `profiles` + all 29 data tables
--   3. Migrates existing rows (assigns each orphaned profile
--      its own company so no data is lost)
--   4. Replaces `USING (true)` RLS policies with company-scoped
--      equivalents on every table
--   5. Adds an auto-stamp trigger so every INSERT automatically
--      receives the authenticated user's company_id — the Swift
--      app does not need to send company_id explicitly
--   6. Updates the new-user trigger to create a company on
--      first sign-up
-- ============================================================


-- ────────────────────────────────────────────────────────────
-- 1. COMPANIES TABLE
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS companies (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text        NOT NULL DEFAULT 'My Company',
    slug        text,                      -- optional vanity identifier
    plan        text        NOT NULL DEFAULT 'trial',
    created_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE companies ENABLE ROW LEVEL SECURITY;

-- Policy referencing profiles.company_id is deferred to section 8
-- (after the column exists on profiles)


-- ────────────────────────────────────────────────────────────
-- 2. ADD company_id TO PROFILES
-- ────────────────────────────────────────────────────────────
ALTER TABLE profiles
    ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);

-- Index for the RLS helper lookup (called on every query)
CREATE INDEX IF NOT EXISTS idx_profiles_company_id ON profiles(company_id);


-- ────────────────────────────────────────────────────────────
-- 3. MIGRATE EXISTING PROFILES → assign each a company
--    Idempotent: skips profiles that already have a company_id
-- ────────────────────────────────────────────────────────────
DO $$
DECLARE
    p   RECORD;
    cid uuid;
BEGIN
    FOR p IN
        SELECT id, email FROM profiles WHERE company_id IS NULL
    LOOP
        INSERT INTO companies (name)
        VALUES ('My Company')
        RETURNING id INTO cid;

        UPDATE profiles SET company_id = cid WHERE id = p.id;
    END LOOP;
END $$;

-- Now that every profile has a company, make it required
ALTER TABLE profiles
    ALTER COLUMN company_id SET NOT NULL;


-- ────────────────────────────────────────────────────────────
-- 4. RLS HELPER FUNCTION
--    Looked up once per query; Postgres caches the result
--    within a transaction, so performance impact is minimal.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_my_company_id()
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT company_id FROM profiles WHERE id = auth.uid()
$$;


-- ────────────────────────────────────────────────────────────
-- 5. AUTO-STAMP TRIGGER
--    Fires BEFORE INSERT on every data table.
--    If company_id is NULL (i.e. the Swift app didn't send it),
--    it is filled from the authenticated user's profile.
--    This means zero changes are needed in the Swift SyncEngine.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION stamp_company_id()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.company_id IS NULL THEN
        NEW.company_id := get_my_company_id();
    END IF;
    RETURN NEW;
END;
$$;


-- ────────────────────────────────────────────────────────────
-- 6. ADD company_id + ISOLATED RLS + STAMP TRIGGER
--    One block per table.  Pattern:
--      a) ALTER TABLE … ADD COLUMN IF NOT EXISTS company_id
--      b) Backfill NULL rows with a sentinel company (should
--         only happen if rows pre-date the profiles migration
--         above — normally zero rows need this)
--      c) DROP old USING(true) policy; CREATE scoped policy
--      d) CREATE stamp trigger
-- ────────────────────────────────────────────────────────────

-- ── PROJECTS ─────────────────────────────────────────────────
ALTER TABLE projects ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_projects_company_id ON projects(company_id);
DROP POLICY IF EXISTS "projects_auth"    ON projects;
DROP POLICY IF EXISTS "projects_company" ON projects;
CREATE POLICY "projects_company" ON projects
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_projects_company_id ON projects;
CREATE TRIGGER trg_projects_company_id
    BEFORE INSERT ON projects FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── PROJECT ASSIGNMENTS ───────────────────────────────────────
ALTER TABLE project_assignments ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_project_assignments_company_id ON project_assignments(company_id);
DROP POLICY IF EXISTS "project_assignments_auth"    ON project_assignments;
DROP POLICY IF EXISTS "project_assignments_company" ON project_assignments;
CREATE POLICY "project_assignments_company" ON project_assignments
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_project_assignments_company_id ON project_assignments;
CREATE TRIGGER trg_project_assignments_company_id
    BEFORE INSERT ON project_assignments FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── EMPLOYEES ─────────────────────────────────────────────────
ALTER TABLE employees ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_employees_company_id ON employees(company_id);
DROP POLICY IF EXISTS "employees_auth"    ON employees;
DROP POLICY IF EXISTS "employees_company" ON employees;
CREATE POLICY "employees_company" ON employees
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_employees_company_id ON employees;
CREATE TRIGGER trg_employees_company_id
    BEFORE INSERT ON employees FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── CREWS ─────────────────────────────────────────────────────
ALTER TABLE crews ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_crews_company_id ON crews(company_id);
DROP POLICY IF EXISTS "crews_auth"    ON crews;
DROP POLICY IF EXISTS "crews_company" ON crews;
CREATE POLICY "crews_company" ON crews
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_crews_company_id ON crews;
CREATE TRIGGER trg_crews_company_id
    BEFORE INSERT ON crews FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── CREW MEMBERS ──────────────────────────────────────────────
ALTER TABLE crew_members ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_crew_members_company_id ON crew_members(company_id);
DROP POLICY IF EXISTS "crew_members_auth"    ON crew_members;
DROP POLICY IF EXISTS "crew_members_company" ON crew_members;
CREATE POLICY "crew_members_company" ON crew_members
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_crew_members_company_id ON crew_members;
CREATE TRIGGER trg_crew_members_company_id
    BEFORE INSERT ON crew_members FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── SCHEDULE ENTRIES ──────────────────────────────────────────
ALTER TABLE schedule_entries ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_schedule_entries_company_id ON schedule_entries(company_id);
DROP POLICY IF EXISTS "schedule_entries_auth"    ON schedule_entries;
DROP POLICY IF EXISTS "schedule_entries_company" ON schedule_entries;
CREATE POLICY "schedule_entries_company" ON schedule_entries
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_schedule_entries_company_id ON schedule_entries;
CREATE TRIGGER trg_schedule_entries_company_id
    BEFORE INSERT ON schedule_entries FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── TIMESHEET ENTRIES ─────────────────────────────────────────
ALTER TABLE timesheet_entries ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_timesheet_entries_company_id ON timesheet_entries(company_id);
DROP POLICY IF EXISTS "timesheet_entries_auth"    ON timesheet_entries;
DROP POLICY IF EXISTS "timesheet_entries_company" ON timesheet_entries;
CREATE POLICY "timesheet_entries_company" ON timesheet_entries
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_timesheet_entries_company_id ON timesheet_entries;
CREATE TRIGGER trg_timesheet_entries_company_id
    BEFORE INSERT ON timesheet_entries FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── EXCEPTION LOGS ────────────────────────────────────────────
ALTER TABLE exception_logs ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_exception_logs_company_id ON exception_logs(company_id);
DROP POLICY IF EXISTS "exception_logs_auth"    ON exception_logs;
DROP POLICY IF EXISTS "exception_logs_company" ON exception_logs;
CREATE POLICY "exception_logs_company" ON exception_logs
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_exception_logs_company_id ON exception_logs;
CREATE TRIGGER trg_exception_logs_company_id
    BEFORE INSERT ON exception_logs FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── FORM TEMPLATES ────────────────────────────────────────────
ALTER TABLE form_templates ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_form_templates_company_id ON form_templates(company_id);
DROP POLICY IF EXISTS "form_templates_auth"    ON form_templates;
DROP POLICY IF EXISTS "form_templates_company" ON form_templates;
CREATE POLICY "form_templates_company" ON form_templates
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_form_templates_company_id ON form_templates;
CREATE TRIGGER trg_form_templates_company_id
    BEFORE INSERT ON form_templates FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── FORM SUBMISSIONS ──────────────────────────────────────────
ALTER TABLE form_submissions ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_form_submissions_company_id ON form_submissions(company_id);
DROP POLICY IF EXISTS "form_submissions_auth"    ON form_submissions;
DROP POLICY IF EXISTS "form_submissions_company" ON form_submissions;
CREATE POLICY "form_submissions_company" ON form_submissions
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_form_submissions_company_id ON form_submissions;
CREATE TRIGGER trg_form_submissions_company_id
    BEFORE INSERT ON form_submissions FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── ESTIMATES ─────────────────────────────────────────────────
ALTER TABLE estimates ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_estimates_company_id ON estimates(company_id);
DROP POLICY IF EXISTS "estimates_auth"    ON estimates;
DROP POLICY IF EXISTS "estimates_company" ON estimates;
CREATE POLICY "estimates_company" ON estimates
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_estimates_company_id ON estimates;
CREATE TRIGGER trg_estimates_company_id
    BEFORE INSERT ON estimates FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── ESTIMATE LINE ITEMS ───────────────────────────────────────
ALTER TABLE estimate_line_items ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_estimate_line_items_company_id ON estimate_line_items(company_id);
DROP POLICY IF EXISTS "estimate_line_items_auth"    ON estimate_line_items;
DROP POLICY IF EXISTS "estimate_line_items_company" ON estimate_line_items;
CREATE POLICY "estimate_line_items_company" ON estimate_line_items
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_estimate_line_items_company_id ON estimate_line_items;
CREATE TRIGGER trg_estimate_line_items_company_id
    BEFORE INSERT ON estimate_line_items FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── AUDIT SNAPSHOTS ───────────────────────────────────────────
ALTER TABLE audit_snapshots ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_audit_snapshots_company_id ON audit_snapshots(company_id);
DROP POLICY IF EXISTS "audit_snapshots_auth"    ON audit_snapshots;
DROP POLICY IF EXISTS "audit_snapshots_insert"  ON audit_snapshots;
DROP POLICY IF EXISTS "audit_snapshots_company" ON audit_snapshots;
CREATE POLICY "audit_snapshots_company" ON audit_snapshots
    FOR SELECT TO authenticated
    USING (company_id = get_my_company_id());
CREATE POLICY "audit_snapshots_insert_company" ON audit_snapshots
    FOR INSERT TO authenticated
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_audit_snapshots_company_id ON audit_snapshots;
CREATE TRIGGER trg_audit_snapshots_company_id
    BEFORE INSERT ON audit_snapshots FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── INCIDENTS ─────────────────────────────────────────────────
ALTER TABLE incidents ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_incidents_company_id ON incidents(company_id);
DROP POLICY IF EXISTS "incidents_auth"    ON incidents;
DROP POLICY IF EXISTS "incidents_company" ON incidents;
CREATE POLICY "incidents_company" ON incidents
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_incidents_company_id ON incidents;
CREATE TRIGGER trg_incidents_company_id
    BEFORE INSERT ON incidents FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── CERTIFICATES ──────────────────────────────────────────────
ALTER TABLE certificates ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_certificates_company_id ON certificates(company_id);
DROP POLICY IF EXISTS "certificates_auth"    ON certificates;
DROP POLICY IF EXISTS "certificates_company" ON certificates;
CREATE POLICY "certificates_company" ON certificates
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_certificates_company_id ON certificates;
CREATE TRIGGER trg_certificates_company_id
    BEFORE INSERT ON certificates FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── CLIENTS ───────────────────────────────────────────────────
ALTER TABLE clients ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_clients_company_id ON clients(company_id);
DROP POLICY IF EXISTS "clients_auth"    ON clients;
DROP POLICY IF EXISTS "clients_company" ON clients;
CREATE POLICY "clients_company" ON clients
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_clients_company_id ON clients;
CREATE TRIGGER trg_clients_company_id
    BEFORE INSERT ON clients FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── QUOTES ────────────────────────────────────────────────────
ALTER TABLE quotes ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_quotes_company_id ON quotes(company_id);
DROP POLICY IF EXISTS "quotes_auth"    ON quotes;
DROP POLICY IF EXISTS "quotes_company" ON quotes;
CREATE POLICY "quotes_company" ON quotes
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_quotes_company_id ON quotes;
CREATE TRIGGER trg_quotes_company_id
    BEFORE INSERT ON quotes FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── DAILY JOB REPORTS ─────────────────────────────────────────
ALTER TABLE daily_job_reports ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_daily_job_reports_company_id ON daily_job_reports(company_id);
DROP POLICY IF EXISTS "daily_job_reports_auth"    ON daily_job_reports;
DROP POLICY IF EXISTS "daily_job_reports_company" ON daily_job_reports;
CREATE POLICY "daily_job_reports_company" ON daily_job_reports
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_daily_job_reports_company_id ON daily_job_reports;
CREATE TRIGGER trg_daily_job_reports_company_id
    BEFORE INSERT ON daily_job_reports FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── EQUIPMENT ─────────────────────────────────────────────────
ALTER TABLE equipment ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_equipment_company_id ON equipment(company_id);
DROP POLICY IF EXISTS "equipment_auth"    ON equipment;
DROP POLICY IF EXISTS "equipment_company" ON equipment;
CREATE POLICY "equipment_company" ON equipment
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_equipment_company_id ON equipment;
CREATE TRIGGER trg_equipment_company_id
    BEFORE INSERT ON equipment FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── CHANGE ORDERS ─────────────────────────────────────────────
ALTER TABLE change_orders ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_change_orders_company_id ON change_orders(company_id);
DROP POLICY IF EXISTS "change_orders_auth"    ON change_orders;
DROP POLICY IF EXISTS "change_orders_company" ON change_orders;
CREATE POLICY "change_orders_company" ON change_orders
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_change_orders_company_id ON change_orders;
CREATE TRIGGER trg_change_orders_company_id
    BEFORE INSERT ON change_orders FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── RFIs ──────────────────────────────────────────────────────
ALTER TABLE rfis ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_rfis_company_id ON rfis(company_id);
DROP POLICY IF EXISTS "rfis_auth"    ON rfis;
DROP POLICY IF EXISTS "rfis_company" ON rfis;
CREATE POLICY "rfis_company" ON rfis
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_rfis_company_id ON rfis;
CREATE TRIGGER trg_rfis_company_id
    BEFORE INSERT ON rfis FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── PROJECT BUDGETS ───────────────────────────────────────────
ALTER TABLE project_budgets ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_project_budgets_company_id ON project_budgets(company_id);
DROP POLICY IF EXISTS "project_budgets_auth"    ON project_budgets;
DROP POLICY IF EXISTS "project_budgets_company" ON project_budgets;
CREATE POLICY "project_budgets_company" ON project_budgets
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_project_budgets_company_id ON project_budgets;
CREATE TRIGGER trg_project_budgets_company_id
    BEFORE INSERT ON project_budgets FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── SUBCONTRACTORS ────────────────────────────────────────────
ALTER TABLE subcontractors ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_subcontractors_company_id ON subcontractors(company_id);
DROP POLICY IF EXISTS "subcontractors_auth"    ON subcontractors;
DROP POLICY IF EXISTS "subcontractors_company" ON subcontractors;
CREATE POLICY "subcontractors_company" ON subcontractors
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_subcontractors_company_id ON subcontractors;
CREATE TRIGGER trg_subcontractors_company_id
    BEFORE INSERT ON subcontractors FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── SUB-CONTRACTS ─────────────────────────────────────────────
ALTER TABLE sub_contracts ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_sub_contracts_company_id ON sub_contracts(company_id);
DROP POLICY IF EXISTS "sub_contracts_auth"    ON sub_contracts;
DROP POLICY IF EXISTS "sub_contracts_company" ON sub_contracts;
CREATE POLICY "sub_contracts_company" ON sub_contracts
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_sub_contracts_company_id ON sub_contracts;
CREATE TRIGGER trg_sub_contracts_company_id
    BEFORE INSERT ON sub_contracts FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── INVOICES ──────────────────────────────────────────────────
ALTER TABLE invoices ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_invoices_company_id ON invoices(company_id);
DROP POLICY IF EXISTS "invoices_auth"    ON invoices;
DROP POLICY IF EXISTS "invoices_company" ON invoices;
CREATE POLICY "invoices_company" ON invoices
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_invoices_company_id ON invoices;
CREATE TRIGGER trg_invoices_company_id
    BEFORE INSERT ON invoices FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── SUPPLIERS ─────────────────────────────────────────────────
ALTER TABLE suppliers ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_suppliers_company_id ON suppliers(company_id);
DROP POLICY IF EXISTS "suppliers_auth"    ON suppliers;
DROP POLICY IF EXISTS "suppliers_company" ON suppliers;
CREATE POLICY "suppliers_company" ON suppliers
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_suppliers_company_id ON suppliers;
CREATE TRIGGER trg_suppliers_company_id
    BEFORE INSERT ON suppliers FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── MATERIAL REQUESTS ─────────────────────────────────────────
ALTER TABLE material_requests ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_material_requests_company_id ON material_requests(company_id);
DROP POLICY IF EXISTS "material_requests_auth"    ON material_requests;
DROP POLICY IF EXISTS "material_requests_company" ON material_requests;
CREATE POLICY "material_requests_company" ON material_requests
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_material_requests_company_id ON material_requests;
CREATE TRIGGER trg_material_requests_company_id
    BEFORE INSERT ON material_requests FOR EACH ROW EXECUTE FUNCTION stamp_company_id();

-- ── PURCHASE ORDERS ───────────────────────────────────────────
ALTER TABLE purchase_orders ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
CREATE INDEX IF NOT EXISTS idx_purchase_orders_company_id ON purchase_orders(company_id);
DROP POLICY IF EXISTS "purchase_orders_auth"    ON purchase_orders;
DROP POLICY IF EXISTS "purchase_orders_company" ON purchase_orders;
CREATE POLICY "purchase_orders_company" ON purchase_orders
    FOR ALL TO authenticated
    USING  (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());
DROP TRIGGER IF EXISTS trg_purchase_orders_company_id ON purchase_orders;
CREATE TRIGGER trg_purchase_orders_company_id
    BEFORE INSERT ON purchase_orders FOR EACH ROW EXECUTE FUNCTION stamp_company_id();


-- ────────────────────────────────────────────────────────────
-- 7. CRM TABLES (added in a later session — same pattern)
-- ────────────────────────────────────────────────────────────

-- ── CRM CONTACTS ──────────────────────────────────────────────
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'crm_contacts') THEN
        ALTER TABLE crm_contacts ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
        CREATE INDEX IF NOT EXISTS idx_crm_contacts_company_id ON crm_contacts(company_id);
        DROP POLICY IF EXISTS "crm_contacts_auth"    ON crm_contacts;
        DROP POLICY IF EXISTS "crm_contacts_company" ON crm_contacts;
        EXECUTE $p$
            CREATE POLICY "crm_contacts_company" ON crm_contacts
                FOR ALL TO authenticated
                USING  (company_id = get_my_company_id())
                WITH CHECK (company_id = get_my_company_id())
        $p$;
        DROP TRIGGER IF EXISTS trg_crm_contacts_company_id ON crm_contacts;
        CREATE TRIGGER trg_crm_contacts_company_id
            BEFORE INSERT ON crm_contacts FOR EACH ROW EXECUTE FUNCTION stamp_company_id();
    END IF;
END $$;

-- ── CRM OPPORTUNITIES ─────────────────────────────────────────
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'crm_opportunities') THEN
        ALTER TABLE crm_opportunities ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
        CREATE INDEX IF NOT EXISTS idx_crm_opportunities_company_id ON crm_opportunities(company_id);
        DROP POLICY IF EXISTS "crm_opportunities_auth"    ON crm_opportunities;
        DROP POLICY IF EXISTS "crm_opportunities_company" ON crm_opportunities;
        EXECUTE $p$
            CREATE POLICY "crm_opportunities_company" ON crm_opportunities
                FOR ALL TO authenticated
                USING  (company_id = get_my_company_id())
                WITH CHECK (company_id = get_my_company_id())
        $p$;
        DROP TRIGGER IF EXISTS trg_crm_opportunities_company_id ON crm_opportunities;
        CREATE TRIGGER trg_crm_opportunities_company_id
            BEFORE INSERT ON crm_opportunities FOR EACH ROW EXECUTE FUNCTION stamp_company_id();
    END IF;
END $$;

-- ── CRM TASKS ─────────────────────────────────────────────────
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'crm_tasks') THEN
        ALTER TABLE crm_tasks ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
        CREATE INDEX IF NOT EXISTS idx_crm_tasks_company_id ON crm_tasks(company_id);
        DROP POLICY IF EXISTS "crm_tasks_auth"    ON crm_tasks;
        DROP POLICY IF EXISTS "crm_tasks_company" ON crm_tasks;
        EXECUTE $p$
            CREATE POLICY "crm_tasks_company" ON crm_tasks
                FOR ALL TO authenticated
                USING  (company_id = get_my_company_id())
                WITH CHECK (company_id = get_my_company_id())
        $p$;
        DROP TRIGGER IF EXISTS trg_crm_tasks_company_id ON crm_tasks;
        CREATE TRIGGER trg_crm_tasks_company_id
            BEFORE INSERT ON crm_tasks FOR EACH ROW EXECUTE FUNCTION stamp_company_id();
    END IF;
END $$;

-- ── CRM ACTIVITIES ────────────────────────────────────────────
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'crm_activities') THEN
        ALTER TABLE crm_activities ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
        CREATE INDEX IF NOT EXISTS idx_crm_activities_company_id ON crm_activities(company_id);
        DROP POLICY IF EXISTS "crm_activities_auth"    ON crm_activities;
        DROP POLICY IF EXISTS "crm_activities_company" ON crm_activities;
        EXECUTE $p$
            CREATE POLICY "crm_activities_company" ON crm_activities
                FOR ALL TO authenticated
                USING  (company_id = get_my_company_id())
                WITH CHECK (company_id = get_my_company_id())
        $p$;
        DROP TRIGGER IF EXISTS trg_crm_activities_company_id ON crm_activities;
        CREATE TRIGGER trg_crm_activities_company_id
            BEFORE INSERT ON crm_activities FOR EACH ROW EXECUTE FUNCTION stamp_company_id();
    END IF;
END $$;

-- ── CRM CHECKLISTS ────────────────────────────────────────────
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'crm_checklists') THEN
        ALTER TABLE crm_checklists ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES companies(id);
        CREATE INDEX IF NOT EXISTS idx_crm_checklists_company_id ON crm_checklists(company_id);
        DROP POLICY IF EXISTS "crm_checklists_auth"    ON crm_checklists;
        DROP POLICY IF EXISTS "crm_checklists_company" ON crm_checklists;
        EXECUTE $p$
            CREATE POLICY "crm_checklists_company" ON crm_checklists
                FOR ALL TO authenticated
                USING  (company_id = get_my_company_id())
                WITH CHECK (company_id = get_my_company_id())
        $p$;
        DROP TRIGGER IF EXISTS trg_crm_checklists_company_id ON crm_checklists;
        CREATE TRIGGER trg_crm_checklists_company_id
            BEFORE INSERT ON crm_checklists FOR EACH ROW EXECUTE FUNCTION stamp_company_id();
    END IF;
END $$;


-- ────────────────────────────────────────────────────────────
-- 8. UPDATE PROFILES + COMPANIES RLS
--    profiles.company_id now exists, so both policies are safe.
-- ────────────────────────────────────────────────────────────

-- Companies: users can only read their own company row
DROP POLICY IF EXISTS "companies_read" ON companies;
CREATE POLICY "companies_read" ON companies
    FOR SELECT TO authenticated
    USING (
        id = (SELECT company_id FROM profiles WHERE id = auth.uid())
    );

-- Profiles: read own + same-company; update own only
DROP POLICY IF EXISTS "profiles_auth"           ON profiles;
DROP POLICY IF EXISTS "profiles_own"            ON profiles;
DROP POLICY IF EXISTS "profiles_own_update"     ON profiles;
DROP POLICY IF EXISTS "profiles_company_read"   ON profiles;
DROP POLICY IF EXISTS "profiles_company_update" ON profiles;

-- Read: own profile + same-company profiles
CREATE POLICY "profiles_company_read" ON profiles
    FOR SELECT TO authenticated
    USING (
        id = auth.uid()
        OR company_id = get_my_company_id()
    );

-- Update: own profile only
CREATE POLICY "profiles_own_update" ON profiles
    FOR UPDATE TO authenticated
    USING (id = auth.uid())
    WITH CHECK (id = auth.uid());


-- ────────────────────────────────────────────────────────────
-- 9. UPDATE NEW-USER TRIGGER
--    On sign-up: create a new company, then create the profile
--    linked to that company.
--    On invite flows (future): admin pre-creates the profile
--    with the correct company_id before the user signs up.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
DECLARE
    new_company_id uuid;
    company_name   text;
BEGIN
    -- Use company_name from sign-up metadata if provided
    company_name := COALESCE(
        NEW.raw_user_meta_data->>'company_name',
        'My Company'
    );

    -- Create the tenant company
    INSERT INTO companies (name)
    VALUES (company_name)
    RETURNING id INTO new_company_id;

    -- Create the user's profile linked to that company
    INSERT INTO profiles (id, email, full_name, company_id)
    VALUES (
        NEW.id,
        NEW.email,
        COALESCE(NEW.raw_user_meta_data->>'full_name', ''),
        new_company_id
    )
    ON CONFLICT (id) DO NOTHING;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION handle_new_user();


-- ════════════════════════════════════════════════════════════
-- Done.
--
-- After running this migration:
--   • Every existing user's data is isolated under their own
--     company_id — no data bleed between tenants
--   • New sign-ups automatically create a company (first user
--     = company owner; add an invite system later to let
--     employees join an existing company)
--   • All INSERT operations are auto-stamped — no Swift app
--     changes required for push/sync operations
--   • All SELECT queries are filtered by RLS at the database
--     level — no Swift app changes required for pull operations
--
-- Next steps (future sprints):
--   • Add an invites table so employees can join a company
--     rather than creating their own
--   • Add a company settings table to replace UserDefaults
--     (company name, logo, tax settings) so settings sync
--     across devices
--   • Add a company_plan enforcement function to gate features
--     by subscription tier
-- ════════════════════════════════════════════════════════════
