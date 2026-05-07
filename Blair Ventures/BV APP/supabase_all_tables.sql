-- ============================================================
-- Blair Ventures Field OS  –  COMPLETE DATABASE SCHEMA
-- Run once in: Supabase Dashboard → SQL Editor → New query
--
-- Covers ALL 29 tables. Safe to re-run (IF NOT EXISTS / OR REPLACE).
-- Run supabase_commercial_tables.sql afterward if you only need
-- the 9 commercial tables on top of an existing install.
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- HELPER: auto-stamp updated_at
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- ────────────────────────────────────────────────────────────
-- 1. PROFILES  (mirrors Supabase auth.users)
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS profiles (
    id          uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email       text        NOT NULL,
    full_name   text        NOT NULL DEFAULT '',
    role        text        NOT NULL DEFAULT 'field_worker',
    is_active   boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "profiles_auth" ON profiles;
CREATE POLICY "profiles_auth" ON profiles
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Auto-create profile on sign-up
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO profiles (id, email, full_name)
    VALUES (NEW.id, NEW.email, COALESCE(NEW.raw_user_meta_data->>'full_name', ''))
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION handle_new_user();


-- ────────────────────────────────────────────────────────────
-- 2. PROJECTS
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS projects (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id         text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    sync_status         text        NOT NULL DEFAULT 'synced',
    last_modified_by    text        NOT NULL DEFAULT '',
    last_modified_at    timestamptz NOT NULL DEFAULT now(),

    name                text        NOT NULL,
    client_name         text        NOT NULL DEFAULT '',
    status              text        NOT NULL DEFAULT 'active',
    start_date          timestamptz,
    end_date            timestamptz,
    site_address        text,
    notes               text,
    job_number          text,
    assigned_pm_id      uuid,
    assigned_pm_name    text,
    estimated_budget    numeric(14,2),
    contract_value      numeric(14,2)
);

CREATE INDEX IF NOT EXISTS idx_projects_status ON projects(status);

ALTER TABLE projects ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "projects_auth" ON projects;
CREATE POLICY "projects_auth" ON projects
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP TRIGGER IF EXISTS trg_projects_updated_at ON projects;
CREATE TRIGGER trg_projects_updated_at
    BEFORE UPDATE ON projects FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ────────────────────────────────────────────────────────────
-- 3. PROJECT ASSIGNMENTS  (user ↔ project membership)
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS project_assignments (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id  uuid        NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    user_id     uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    role        text        NOT NULL DEFAULT 'field_worker',
    assigned_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (project_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_project_assignments_user_id    ON project_assignments(user_id);
CREATE INDEX IF NOT EXISTS idx_project_assignments_project_id ON project_assignments(project_id);

ALTER TABLE project_assignments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "project_assignments_auth" ON project_assignments;
CREATE POLICY "project_assignments_auth" ON project_assignments
    FOR ALL TO authenticated USING (true) WITH CHECK (true);


-- ────────────────────────────────────────────────────────────
-- 4. EMPLOYEES
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS employees (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id      text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    sync_status      text        NOT NULL DEFAULT 'synced',
    last_modified_by text        NOT NULL DEFAULT '',
    last_modified_at timestamptz NOT NULL DEFAULT now(),

    first_name       text        NOT NULL,
    last_name        text        NOT NULL,
    email            text,
    phone            text,
    role             text        NOT NULL DEFAULT 'foreman',
    trade            text,
    certifications   text        NOT NULL DEFAULT '[]',  -- JSON array
    regular_rate     numeric(8,2),
    overtime_rate    numeric(8,2),
    is_active        boolean     NOT NULL DEFAULT true
);

ALTER TABLE employees ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "employees_auth" ON employees;
CREATE POLICY "employees_auth" ON employees
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP TRIGGER IF EXISTS trg_employees_updated_at ON employees;
CREATE TRIGGER trg_employees_updated_at
    BEFORE UPDATE ON employees FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ────────────────────────────────────────────────────────────
-- 5. CREWS
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crews (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id      text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    sync_status      text        NOT NULL DEFAULT 'synced',
    last_modified_by text        NOT NULL DEFAULT '',
    last_modified_at timestamptz NOT NULL DEFAULT now(),

    name             text        NOT NULL,
    foreman_id       uuid,
    is_active        boolean     NOT NULL DEFAULT true,
    notes            text
);

ALTER TABLE crews ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "crews_auth" ON crews;
CREATE POLICY "crews_auth" ON crews
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP TRIGGER IF EXISTS trg_crews_updated_at ON crews;
CREATE TRIGGER trg_crews_updated_at
    BEFORE UPDATE ON crews FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ────────────────────────────────────────────────────────────
-- 6. CREW MEMBERS  (crew ↔ employee membership)
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS crew_members (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    crew_id     uuid NOT NULL REFERENCES crews(id) ON DELETE CASCADE,
    employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    UNIQUE (crew_id, employee_id)
);

CREATE INDEX IF NOT EXISTS idx_crew_members_crew_id     ON crew_members(crew_id);
CREATE INDEX IF NOT EXISTS idx_crew_members_employee_id ON crew_members(employee_id);

ALTER TABLE crew_members ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "crew_members_auth" ON crew_members;
CREATE POLICY "crew_members_auth" ON crew_members
    FOR ALL TO authenticated USING (true) WITH CHECK (true);


-- ────────────────────────────────────────────────────────────
-- 7. SCHEDULE ENTRIES
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS schedule_entries (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id      text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    sync_status      text        NOT NULL DEFAULT 'synced',
    last_modified_by text        NOT NULL DEFAULT '',
    last_modified_at timestamptz NOT NULL DEFAULT now(),

    project_id       uuid        REFERENCES projects(id) ON DELETE SET NULL,
    crew_id          uuid        REFERENCES crews(id) ON DELETE SET NULL,
    employee_ids     text        NOT NULL DEFAULT '[]',  -- JSON array of UUIDs
    date             date        NOT NULL,
    start_time       text,
    end_time         text,
    shift_type       text        NOT NULL DEFAULT 'regular',
    notes            text
);

CREATE INDEX IF NOT EXISTS idx_schedule_entries_date       ON schedule_entries(date);
CREATE INDEX IF NOT EXISTS idx_schedule_entries_project_id ON schedule_entries(project_id);

ALTER TABLE schedule_entries ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "schedule_entries_auth" ON schedule_entries;
CREATE POLICY "schedule_entries_auth" ON schedule_entries
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP TRIGGER IF EXISTS trg_schedule_entries_updated_at ON schedule_entries;
CREATE TRIGGER trg_schedule_entries_updated_at
    BEFORE UPDATE ON schedule_entries FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ────────────────────────────────────────────────────────────
-- 8. TIMESHEET ENTRIES
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS timesheet_entries (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id      text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    sync_status      text        NOT NULL DEFAULT 'synced',
    last_modified_by text        NOT NULL DEFAULT '',
    last_modified_at timestamptz NOT NULL DEFAULT now(),

    employee_id      uuid        REFERENCES employees(id) ON DELETE SET NULL,
    project_id       uuid        REFERENCES projects(id) ON DELETE SET NULL,
    crew_id          uuid,
    work_date        date        NOT NULL,
    regular_hours    numeric(5,2) NOT NULL DEFAULT 0,
    overtime_hours   numeric(5,2) NOT NULL DEFAULT 0,
    double_hours     numeric(5,2) NOT NULL DEFAULT 0,
    trade            text,
    cost_code        text,
    notes            text,
    approval_status  text        NOT NULL DEFAULT 'pending',
    approved_by_id   uuid,
    approved_at      timestamptz,
    clock_in_at      timestamptz,
    clock_out_at     timestamptz
);

CREATE INDEX IF NOT EXISTS idx_timesheet_entries_employee_id ON timesheet_entries(employee_id);
CREATE INDEX IF NOT EXISTS idx_timesheet_entries_project_id  ON timesheet_entries(project_id);
CREATE INDEX IF NOT EXISTS idx_timesheet_entries_work_date   ON timesheet_entries(work_date);

ALTER TABLE timesheet_entries ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "timesheet_entries_auth" ON timesheet_entries;
CREATE POLICY "timesheet_entries_auth" ON timesheet_entries
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP TRIGGER IF EXISTS trg_timesheet_entries_updated_at ON timesheet_entries;
CREATE TRIGGER trg_timesheet_entries_updated_at
    BEFORE UPDATE ON timesheet_entries FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ────────────────────────────────────────────────────────────
-- 9. EXCEPTION LOGS  (timesheet exceptions / anomalies)
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS exception_logs (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id      text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    sync_status      text        NOT NULL DEFAULT 'synced',
    last_modified_by text        NOT NULL DEFAULT '',
    last_modified_at timestamptz NOT NULL DEFAULT now(),

    timesheet_id     uuid,
    employee_id      uuid,
    project_id       uuid,
    exception_type   text        NOT NULL DEFAULT 'other',
    description      text        NOT NULL DEFAULT '',
    severity         text        NOT NULL DEFAULT 'low',
    resolved         boolean     NOT NULL DEFAULT false,
    resolved_by      text,
    resolved_at      timestamptz,
    notes            text
);

ALTER TABLE exception_logs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "exception_logs_auth" ON exception_logs;
CREATE POLICY "exception_logs_auth" ON exception_logs
    FOR ALL TO authenticated USING (true) WITH CHECK (true);


-- ────────────────────────────────────────────────────────────
-- 10. FORM TEMPLATES
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS form_templates (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id      text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    sync_status      text        NOT NULL DEFAULT 'synced',
    last_modified_by text        NOT NULL DEFAULT '',
    last_modified_at timestamptz NOT NULL DEFAULT now(),

    name             text        NOT NULL,
    category         text        NOT NULL DEFAULT 'general',
    description      text,
    is_active        boolean     NOT NULL DEFAULT true,
    requires_signature boolean   NOT NULL DEFAULT false,
    version          integer     NOT NULL DEFAULT 1,
    fields_json      text        NOT NULL DEFAULT '[]'  -- JSON array of FormField
);

ALTER TABLE form_templates ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "form_templates_auth" ON form_templates;
CREATE POLICY "form_templates_auth" ON form_templates
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP TRIGGER IF EXISTS trg_form_templates_updated_at ON form_templates;
CREATE TRIGGER trg_form_templates_updated_at
    BEFORE UPDATE ON form_templates FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ────────────────────────────────────────────────────────────
-- 11. FORM SUBMISSIONS
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS form_submissions (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id      text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    sync_status      text        NOT NULL DEFAULT 'synced',
    last_modified_by text        NOT NULL DEFAULT '',
    last_modified_at timestamptz NOT NULL DEFAULT now(),

    template_id      uuid        REFERENCES form_templates(id) ON DELETE SET NULL,
    template_version integer     NOT NULL DEFAULT 1,
    project_id       uuid        REFERENCES projects(id) ON DELETE SET NULL,
    submitted_by     text        NOT NULL DEFAULT '',
    submitted_at     timestamptz,
    is_draft         boolean     NOT NULL DEFAULT false,
    is_signed        boolean     NOT NULL DEFAULT false,
    signed_by        text,
    signed_at        timestamptz,
    audit_hash       text,
    link_type        text        NOT NULL DEFAULT 'none',
    linked_name      text,
    linked_address   text,
    responses_json   text        NOT NULL DEFAULT '[]'  -- JSON array of FormFieldResponse (no photoData)
);

CREATE INDEX IF NOT EXISTS idx_form_submissions_project_id   ON form_submissions(project_id);
CREATE INDEX IF NOT EXISTS idx_form_submissions_template_id  ON form_submissions(template_id);
CREATE INDEX IF NOT EXISTS idx_form_submissions_submitted_at ON form_submissions(submitted_at);

ALTER TABLE form_submissions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "form_submissions_auth" ON form_submissions;
CREATE POLICY "form_submissions_auth" ON form_submissions
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP TRIGGER IF EXISTS trg_form_submissions_updated_at ON form_submissions;
CREATE TRIGGER trg_form_submissions_updated_at
    BEFORE UPDATE ON form_submissions FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ────────────────────────────────────────────────────────────
-- 12. ESTIMATES
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS estimates (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id      text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    sync_status      text        NOT NULL DEFAULT 'synced',
    last_modified_by text        NOT NULL DEFAULT '',
    last_modified_at timestamptz NOT NULL DEFAULT now(),

    name             text        NOT NULL,
    job_number       text        NOT NULL DEFAULT '',
    client_id        uuid,
    project_id       uuid        REFERENCES projects(id) ON DELETE SET NULL,
    status           text        NOT NULL DEFAULT 'estimating',
    pricing_type     text        NOT NULL DEFAULT 'lump_sum',
    opportunity_type text        NOT NULL DEFAULT 'new_work',
    revision_number  integer     NOT NULL DEFAULT 0,
    estimator_id     uuid,
    bid_due_date     timestamptz,
    scope_description text,
    notes            text,
    overhead_percent  numeric(6,3) NOT NULL DEFAULT 0,
    profit_percent    numeric(6,3) NOT NULL DEFAULT 0,
    contingency_percent numeric(6,3) NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_estimates_status ON estimates(status);

ALTER TABLE estimates ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "estimates_auth" ON estimates;
CREATE POLICY "estimates_auth" ON estimates
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP TRIGGER IF EXISTS trg_estimates_updated_at ON estimates;
CREATE TRIGGER trg_estimates_updated_at
    BEFORE UPDATE ON estimates FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ────────────────────────────────────────────────────────────
-- 13. ESTIMATE LINE ITEMS
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS estimate_line_items (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    estimate_id         uuid        NOT NULL REFERENCES estimates(id) ON DELETE CASCADE,
    code                text        NOT NULL DEFAULT '',
    description         text        NOT NULL DEFAULT '',
    unit                text        NOT NULL DEFAULT 'LS',
    estimated_quantity  numeric(12,4) NOT NULL DEFAULT 1,
    unit_rate           numeric(12,4) NOT NULL DEFAULT 0,
    sort_order          integer     NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_estimate_line_items_estimate_id ON estimate_line_items(estimate_id);

ALTER TABLE estimate_line_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "estimate_line_items_auth" ON estimate_line_items;
CREATE POLICY "estimate_line_items_auth" ON estimate_line_items
    FOR ALL TO authenticated USING (true) WITH CHECK (true);


-- ────────────────────────────────────────────────────────────
-- 14. AUDIT SNAPSHOTS  (immutable compliance trail)
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_snapshots (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at    timestamptz NOT NULL DEFAULT now(),
    record_type   text        NOT NULL,   -- 'form_submission', 'incident', etc.
    record_id     uuid        NOT NULL,
    event_type    text        NOT NULL,   -- 'submitted', 'approved', 'deleted', etc.
    performed_by  text        NOT NULL DEFAULT '',
    snapshot_json text        NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_audit_snapshots_record_id ON audit_snapshots(record_id);

ALTER TABLE audit_snapshots ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "audit_snapshots_auth" ON audit_snapshots;
CREATE POLICY "audit_snapshots_auth" ON audit_snapshots
    FOR SELECT TO authenticated USING (true);
-- INSERT only (no update/delete – immutable)
CREATE POLICY "audit_snapshots_insert" ON audit_snapshots
    FOR INSERT TO authenticated WITH CHECK (true);


-- ────────────────────────────────────────────────────────────
-- 15. INCIDENTS
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS incidents (
    id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id          text,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    sync_status          text        NOT NULL DEFAULT 'synced',
    last_modified_by     text        NOT NULL DEFAULT '',
    last_modified_at     timestamptz NOT NULL DEFAULT now(),

    title                text        NOT NULL,
    incident_type        text        NOT NULL DEFAULT 'near_miss',
    severity             text        NOT NULL DEFAULT 'medium',
    status               text        NOT NULL DEFAULT 'open',
    project_id           uuid        REFERENCES projects(id) ON DELETE SET NULL,
    reported_by_id       uuid,
    reported_by_name     text        NOT NULL DEFAULT '',
    incident_date        timestamptz NOT NULL DEFAULT now(),
    incident_time        timestamptz NOT NULL DEFAULT now(),
    location_description text,
    description          text        NOT NULL DEFAULT '',
    immediate_actions    text,
    root_cause           text,
    corrective_actions   text,
    witnesses            text        NOT NULL DEFAULT '[]',  -- JSON array

    -- Injury
    injured_person_name  text,
    injury_description   text,
    medical_treatment    text,
    work_days_lost       integer,

    -- Regulatory
    reportable_to_wcb    boolean     NOT NULL DEFAULT false,
    wcb_claim_number     text,
    reportable_to_ohs    boolean     NOT NULL DEFAULT false,

    -- Signature
    is_signed            boolean     NOT NULL DEFAULT false,
    signed_by            text,
    signed_at            timestamptz,
    audit_hash           text
);

CREATE INDEX IF NOT EXISTS idx_incidents_project_id    ON incidents(project_id);
CREATE INDEX IF NOT EXISTS idx_incidents_status        ON incidents(status);
CREATE INDEX IF NOT EXISTS idx_incidents_incident_date ON incidents(incident_date);

ALTER TABLE incidents ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "incidents_auth" ON incidents;
CREATE POLICY "incidents_auth" ON incidents
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP TRIGGER IF EXISTS trg_incidents_updated_at ON incidents;
CREATE TRIGGER trg_incidents_updated_at
    BEFORE UPDATE ON incidents FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ────────────────────────────────────────────────────────────
-- 16. CERTIFICATES  (employee compliance / training records)
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS certificates (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id      text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    sync_status      text        NOT NULL DEFAULT 'synced',
    last_modified_by text        NOT NULL DEFAULT '',
    last_modified_at timestamptz NOT NULL DEFAULT now(),

    employee_id      uuid        REFERENCES employees(id) ON DELETE CASCADE,
    cert_type        text        NOT NULL DEFAULT 'other',
    name             text        NOT NULL,
    issuer           text,
    issue_date       date,
    expiry_date      date,
    certificate_number text,
    notes            text
);

CREATE INDEX IF NOT EXISTS idx_certificates_employee_id ON certificates(employee_id);
CREATE INDEX IF NOT EXISTS idx_certificates_expiry_date ON certificates(expiry_date);

ALTER TABLE certificates ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "certificates_auth" ON certificates;
CREATE POLICY "certificates_auth" ON certificates
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP TRIGGER IF EXISTS trg_certificates_updated_at ON certificates;
CREATE TRIGGER trg_certificates_updated_at
    BEFORE UPDATE ON certificates FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ────────────────────────────────────────────────────────────
-- 17. CLIENTS
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS clients (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id      text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    sync_status      text        NOT NULL DEFAULT 'synced',
    last_modified_by text        NOT NULL DEFAULT '',
    last_modified_at timestamptz NOT NULL DEFAULT now(),

    name             text        NOT NULL,
    contact_name     text,
    email            text,
    phone            text,
    address          text,
    city             text,
    province         text,
    postal_code      text,
    notes            text,
    is_active        boolean     NOT NULL DEFAULT true
);

ALTER TABLE clients ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "clients_auth" ON clients;
CREATE POLICY "clients_auth" ON clients
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP TRIGGER IF EXISTS trg_clients_updated_at ON clients;
CREATE TRIGGER trg_clients_updated_at
    BEFORE UPDATE ON clients FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ────────────────────────────────────────────────────────────
-- 18. QUOTES  (client-facing pricing documents)
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS quotes (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id         text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    sync_status         text        NOT NULL DEFAULT 'synced',
    last_modified_by    text        NOT NULL DEFAULT '',
    last_modified_at    timestamptz NOT NULL DEFAULT now(),

    job_number          text        NOT NULL DEFAULT '',
    client_id           uuid        REFERENCES clients(id) ON DELETE SET NULL,
    client_name         text        NOT NULL DEFAULT '',
    status              text        NOT NULL DEFAULT 'draft',
    quote_date          timestamptz NOT NULL DEFAULT now(),
    expiry_date         timestamptz NOT NULL,
    prepared_by         text        NOT NULL DEFAULT '',
    revision            integer     NOT NULL DEFAULT 0,
    validity_days       integer     NOT NULL DEFAULT 30,
    site_address        text,
    scope_summary       text        NOT NULL DEFAULT '',
    inclusions          text        NOT NULL DEFAULT '',
    exclusions          text        NOT NULL DEFAULT '',
    assumptions         text        NOT NULL DEFAULT '',
    payment_terms       text        NOT NULL DEFAULT '',
    contingency_percent numeric(6,3) NOT NULL DEFAULT 0,
    line_items_json     text        NOT NULL DEFAULT '[]'  -- JSON array of CostCodeItem
);

ALTER TABLE quotes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "quotes_auth" ON quotes;
CREATE POLICY "quotes_auth" ON quotes
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP TRIGGER IF EXISTS trg_quotes_updated_at ON quotes;
CREATE TRIGGER trg_quotes_updated_at
    BEFORE UPDATE ON quotes FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ────────────────────────────────────────────────────────────
-- 19. DAILY JOB REPORTS
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS daily_job_reports (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id      text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    sync_status      text        NOT NULL DEFAULT 'synced',
    last_modified_by text        NOT NULL DEFAULT '',
    last_modified_at timestamptz NOT NULL DEFAULT now(),

    project_id       uuid        REFERENCES projects(id) ON DELETE SET NULL,
    report_date      date        NOT NULL,
    prepared_by      text        NOT NULL DEFAULT '',
    weather          text,
    temperature_high numeric(5,1),
    temperature_low  numeric(5,1),
    work_summary     text        NOT NULL DEFAULT '',
    manpower_count   integer     NOT NULL DEFAULT 0,
    delays           text,
    safety_notes     text,
    visitor_log      text        NOT NULL DEFAULT '[]',  -- JSON array
    is_signed        boolean     NOT NULL DEFAULT false,
    signed_by        text,
    signed_at        timestamptz
);

CREATE INDEX IF NOT EXISTS idx_daily_job_reports_project_id  ON daily_job_reports(project_id);
CREATE INDEX IF NOT EXISTS idx_daily_job_reports_report_date ON daily_job_reports(report_date);

ALTER TABLE daily_job_reports ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "daily_job_reports_auth" ON daily_job_reports;
CREATE POLICY "daily_job_reports_auth" ON daily_job_reports
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP TRIGGER IF EXISTS trg_daily_job_reports_updated_at ON daily_job_reports;
CREATE TRIGGER trg_daily_job_reports_updated_at
    BEFORE UPDATE ON daily_job_reports FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ────────────────────────────────────────────────────────────
-- 20. EQUIPMENT
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS equipment (
    id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id       text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    sync_status       text        NOT NULL DEFAULT 'synced',
    last_modified_by  text        NOT NULL DEFAULT '',
    last_modified_at  timestamptz NOT NULL DEFAULT now(),

    name              text        NOT NULL,
    asset_tag         text,
    serial_number     text,
    equipment_type    text        NOT NULL DEFAULT 'other',
    status            text        NOT NULL DEFAULT 'available',
    assigned_project_id uuid      REFERENCES projects(id) ON DELETE SET NULL,
    year              integer,
    make              text,
    model             text,
    notes             text,
    last_service_date date,
    next_service_date date,
    next_inspection_date date,
    hourly_rate       numeric(8,2)
);

CREATE INDEX IF NOT EXISTS idx_equipment_status ON equipment(status);

ALTER TABLE equipment ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "equipment_auth" ON equipment;
CREATE POLICY "equipment_auth" ON equipment
    FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP TRIGGER IF EXISTS trg_equipment_updated_at ON equipment;
CREATE TRIGGER trg_equipment_updated_at
    BEFORE UPDATE ON equipment FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ────────────────────────────────────────────────────────────
-- COMMERCIAL TABLES (21-29)  — same as supabase_commercial_tables.sql
-- ────────────────────────────────────────────────────────────

-- 21. CHANGE ORDERS
CREATE TABLE IF NOT EXISTS change_orders (
    id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id             text,
    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now(),
    sync_status             text        NOT NULL DEFAULT 'synced',
    last_modified_by        text        NOT NULL DEFAULT '',
    last_modified_at        timestamptz NOT NULL DEFAULT now(),
    number                  text        NOT NULL,
    title                   text        NOT NULL,
    project_id              uuid        NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    type                    text        NOT NULL DEFAULT 'owner_initiated',
    status                  text        NOT NULL DEFAULT 'draft',
    cost_impact             numeric(14,2) NOT NULL DEFAULT 0,
    schedule_impact_days    integer     NOT NULL DEFAULT 0,
    description             text        NOT NULL DEFAULT '',
    reason                  text,
    notes                   text,
    line_items_json         text        NOT NULL DEFAULT '[]',
    submitted_date          timestamptz,
    approved_date           timestamptz,
    rejected_date           timestamptz,
    created_by_id           uuid,
    approved_by_name        text,
    client_reference_number text
);
CREATE INDEX IF NOT EXISTS idx_change_orders_project_id ON change_orders(project_id);
CREATE INDEX IF NOT EXISTS idx_change_orders_status     ON change_orders(status);
ALTER TABLE change_orders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "change_orders_auth" ON change_orders;
CREATE POLICY "change_orders_auth" ON change_orders FOR ALL TO authenticated USING (true) WITH CHECK (true);
DROP TRIGGER IF EXISTS trg_change_orders_updated_at ON change_orders;
CREATE TRIGGER trg_change_orders_updated_at BEFORE UPDATE ON change_orders FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 22. RFIs
CREATE TABLE IF NOT EXISTS rfis (
    id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id             text,
    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now(),
    sync_status             text        NOT NULL DEFAULT 'synced',
    last_modified_by        text        NOT NULL DEFAULT '',
    last_modified_at        timestamptz NOT NULL DEFAULT now(),
    number                  text        NOT NULL,
    title                   text        NOT NULL,
    project_id              uuid        NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    status                  text        NOT NULL DEFAULT 'draft',
    priority                text        NOT NULL DEFAULT 'normal',
    category                text        NOT NULL DEFAULT 'other',
    question                text        NOT NULL DEFAULT '',
    reference               text,
    submitted_by_id         uuid,
    submitted_by_name       text,
    submitted_date          timestamptz,
    required_by_date        timestamptz,
    answer                  text,
    answered_by_name        text,
    answered_date           timestamptz,
    has_cost_impact         boolean     NOT NULL DEFAULT false,
    has_schedule_impact     boolean     NOT NULL DEFAULT false,
    linked_change_order_id  uuid,
    internal_notes          text,
    closed_date             timestamptz
);
CREATE INDEX IF NOT EXISTS idx_rfis_project_id ON rfis(project_id);
CREATE INDEX IF NOT EXISTS idx_rfis_status     ON rfis(status);
ALTER TABLE rfis ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "rfis_auth" ON rfis;
CREATE POLICY "rfis_auth" ON rfis FOR ALL TO authenticated USING (true) WITH CHECK (true);
DROP TRIGGER IF EXISTS trg_rfis_updated_at ON rfis;
CREATE TRIGGER trg_rfis_updated_at BEFORE UPDATE ON rfis FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 23. PROJECT BUDGETS
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
    lines_json              text        NOT NULL DEFAULT '[]'
);
CREATE INDEX IF NOT EXISTS idx_project_budgets_project_id ON project_budgets(project_id);
ALTER TABLE project_budgets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "project_budgets_auth" ON project_budgets;
CREATE POLICY "project_budgets_auth" ON project_budgets FOR ALL TO authenticated USING (true) WITH CHECK (true);
DROP TRIGGER IF EXISTS trg_project_budgets_updated_at ON project_budgets;
CREATE TRIGGER trg_project_budgets_updated_at BEFORE UPDATE ON project_budgets FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 24. SUBCONTRACTORS
CREATE TABLE IF NOT EXISTS subcontractors (
    id                              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id                     text,
    created_at                      timestamptz NOT NULL DEFAULT now(),
    updated_at                      timestamptz NOT NULL DEFAULT now(),
    sync_status                     text        NOT NULL DEFAULT 'synced',
    last_modified_by                text        NOT NULL DEFAULT '',
    last_modified_at                timestamptz NOT NULL DEFAULT now(),
    company_name                    text        NOT NULL,
    trade                           text,
    status                          text        NOT NULL DEFAULT 'active',
    contact_name                    text,
    contact_title                   text,
    email                           text,
    phone                           text,
    address                         text,
    insurance_policy_number         text,
    insurance_expiry                timestamptz,
    insurance_amount                numeric(14,2),
    wcb_account                     text,
    wcb_expiry                      timestamptz,
    wcb_clearance_letter_received   boolean     NOT NULL DEFAULT false,
    has_cor                         boolean     NOT NULL DEFAULT false,
    cor_expiry                      timestamptz,
    notes                           text,
    rating                          integer     CHECK (rating IS NULL OR rating BETWEEN 1 AND 5)
);
CREATE INDEX IF NOT EXISTS idx_subcontractors_status ON subcontractors(status);
ALTER TABLE subcontractors ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "subcontractors_auth" ON subcontractors;
CREATE POLICY "subcontractors_auth" ON subcontractors FOR ALL TO authenticated USING (true) WITH CHECK (true);
DROP TRIGGER IF EXISTS trg_subcontractors_updated_at ON subcontractors;
CREATE TRIGGER trg_subcontractors_updated_at BEFORE UPDATE ON subcontractors FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 25. SUB-CONTRACTS
CREATE TABLE IF NOT EXISTS sub_contracts (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id         text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    sync_status         text        NOT NULL DEFAULT 'synced',
    last_modified_by    text        NOT NULL DEFAULT '',
    last_modified_at    timestamptz NOT NULL DEFAULT now(),
    contract_number     text        NOT NULL,
    subcontractor_id    uuid        NOT NULL REFERENCES subcontractors(id) ON DELETE CASCADE,
    project_id          uuid        NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    status              text        NOT NULL DEFAULT 'draft',
    scope               text        NOT NULL DEFAULT '',
    contract_value      numeric(14,2) NOT NULL DEFAULT 0,
    retention_percent   numeric(5,2)  NOT NULL DEFAULT 10,
    invoiced_to_date    numeric(14,2) NOT NULL DEFAULT 0,
    paid_to_date        numeric(14,2) NOT NULL DEFAULT 0,
    start_date          timestamptz,
    end_date            timestamptz,
    payment_terms       text,
    notes               text,
    executed_date       timestamptz
);
CREATE INDEX IF NOT EXISTS idx_sub_contracts_project_id       ON sub_contracts(project_id);
CREATE INDEX IF NOT EXISTS idx_sub_contracts_subcontractor_id ON sub_contracts(subcontractor_id);
ALTER TABLE sub_contracts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "sub_contracts_auth" ON sub_contracts;
CREATE POLICY "sub_contracts_auth" ON sub_contracts FOR ALL TO authenticated USING (true) WITH CHECK (true);
DROP TRIGGER IF EXISTS trg_sub_contracts_updated_at ON sub_contracts;
CREATE TRIGGER trg_sub_contracts_updated_at BEFORE UPDATE ON sub_contracts FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 26. INVOICES
CREATE TABLE IF NOT EXISTS invoices (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id      text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    sync_status      text        NOT NULL DEFAULT 'synced',
    last_modified_by text        NOT NULL DEFAULT '',
    last_modified_at timestamptz NOT NULL DEFAULT now(),
    invoice_number   text        NOT NULL,
    project_id       uuid        REFERENCES projects(id) ON DELETE SET NULL,
    client_id        uuid,
    invoice_date     timestamptz NOT NULL DEFAULT now(),
    due_date         timestamptz NOT NULL,
    sent_at          timestamptz,
    paid_at          timestamptz,
    status           text        NOT NULL DEFAULT 'draft',
    bill_to_name     text        NOT NULL DEFAULT '',
    bill_to_address  text        NOT NULL DEFAULT '',
    po_number        text        NOT NULL DEFAULT '',
    terms            text        NOT NULL DEFAULT 'Net 30',
    notes            text        NOT NULL DEFAULT '',
    internal_notes   text        NOT NULL DEFAULT '',
    line_items_json  text        NOT NULL DEFAULT '[]',
    payments_json    text        NOT NULL DEFAULT '[]',
    tax_rate         numeric(6,4) NOT NULL DEFAULT 0.05
);
CREATE INDEX IF NOT EXISTS idx_invoices_project_id ON invoices(project_id);
CREATE INDEX IF NOT EXISTS idx_invoices_status     ON invoices(status);
ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "invoices_auth" ON invoices;
CREATE POLICY "invoices_auth" ON invoices FOR ALL TO authenticated USING (true) WITH CHECK (true);
DROP TRIGGER IF EXISTS trg_invoices_updated_at ON invoices;
CREATE TRIGGER trg_invoices_updated_at BEFORE UPDATE ON invoices FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 27. SUPPLIERS
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
    categories_json text       NOT NULL DEFAULT '[]'
);
ALTER TABLE suppliers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "suppliers_auth" ON suppliers;
CREATE POLICY "suppliers_auth" ON suppliers FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 28. MATERIAL REQUESTS
CREATE TABLE IF NOT EXISTS material_requests (
    id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    sync_status       text        NOT NULL DEFAULT 'synced',
    request_number    text        NOT NULL,
    project_id        uuid        REFERENCES projects(id) ON DELETE SET NULL,
    requested_by_id   uuid,
    requested_by_name text        NOT NULL DEFAULT '',
    request_date      timestamptz NOT NULL DEFAULT now(),
    required_by_date  timestamptz,
    status            text        NOT NULL DEFAULT 'draft',
    line_items_json   text        NOT NULL DEFAULT '[]',
    notes             text        NOT NULL DEFAULT '',
    site_location     text        NOT NULL DEFAULT '',
    approved_by_name  text        NOT NULL DEFAULT '',
    approved_at       timestamptz,
    purchase_order_id uuid
);
CREATE INDEX IF NOT EXISTS idx_material_requests_project_id ON material_requests(project_id);
CREATE INDEX IF NOT EXISTS idx_material_requests_status     ON material_requests(status);
ALTER TABLE material_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "material_requests_auth" ON material_requests;
CREATE POLICY "material_requests_auth" ON material_requests FOR ALL TO authenticated USING (true) WITH CHECK (true);
DROP TRIGGER IF EXISTS trg_material_requests_updated_at ON material_requests;
CREATE TRIGGER trg_material_requests_updated_at BEFORE UPDATE ON material_requests FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 29. PURCHASE ORDERS
CREATE TABLE IF NOT EXISTS purchase_orders (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    sync_status         text        NOT NULL DEFAULT 'synced',
    po_number           text        NOT NULL,
    project_id          uuid        REFERENCES projects(id) ON DELETE SET NULL,
    supplier_id         uuid        REFERENCES suppliers(id) ON DELETE SET NULL,
    supplier_name       text        NOT NULL DEFAULT '',
    issue_date          timestamptz NOT NULL DEFAULT now(),
    required_date       timestamptz,
    received_date       timestamptz,
    status              text        NOT NULL DEFAULT 'draft',
    material_request_id uuid        REFERENCES material_requests(id) ON DELETE SET NULL,
    line_items_json     text        NOT NULL DEFAULT '[]',
    delivery_address    text        NOT NULL DEFAULT '',
    terms               text        NOT NULL DEFAULT '',
    notes               text        NOT NULL DEFAULT '',
    internal_notes      text        NOT NULL DEFAULT '',
    tax_rate            numeric(6,4) NOT NULL DEFAULT 0.05
);
CREATE INDEX IF NOT EXISTS idx_purchase_orders_project_id  ON purchase_orders(project_id);
CREATE INDEX IF NOT EXISTS idx_purchase_orders_supplier_id ON purchase_orders(supplier_id);
ALTER TABLE purchase_orders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "purchase_orders_auth" ON purchase_orders;
CREATE POLICY "purchase_orders_auth" ON purchase_orders FOR ALL TO authenticated USING (true) WITH CHECK (true);
DROP TRIGGER IF EXISTS trg_purchase_orders_updated_at ON purchase_orders;
CREATE TRIGGER trg_purchase_orders_updated_at BEFORE UPDATE ON purchase_orders FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ════════════════════════════════════════════════════════════
-- Done.  All 29 tables, RLS enabled, updated_at triggers set.
-- ════════════════════════════════════════════════════════════
