-- Aski IQ — Sample Data Support Migration (PRODUCTION)
-- =============================================================================
-- Adds tenant-scoped sample-data tracking to operational tables, plus
-- indexes, RLS update guards, and the executive-only `clear_sample_data`
-- RPC.
--
-- PRODUCTION VARIANT
--   * Schema changes (ALTER TABLE) run inside a single transaction —
--     metadata-only on Postgres 11+, no full-table rewrite for boolean
--     defaults.
--   * Index creation runs OUTSIDE the transaction with
--     CREATE INDEX CONCURRENTLY (Postgres requires concurrent indexes
--     to be in their own transaction). The block is wrapped in a DO so
--     it can iterate over operational tables without copy-paste.
--   * Triggers, constraints, and the RPC run inside the main transaction.
--
-- ROLLOUT
--   1. Apply this file end-to-end. Postgres skips concurrent index
--      creation that's already been done (IF NOT EXISTS).
--   2. Re-runnable. Idempotent at every step.
--   3. Zero-downtime: ALTER TABLE ADD COLUMN with a constant default
--      is metadata-only and won't lock against reads.
--
-- COMPATIBLE WITH
--   * Postgres 11+ (boolean default add is metadata-only)
--   * Postgres 15+ (ADD CONSTRAINT IF NOT EXISTS for CHECK)
--   * Earlier than 15 → swap the CHECK ADD to a DO block that catches
--     `duplicate_object` exceptions.

-- =============================================================================
-- PART 1 — Schema (transactional)
-- =============================================================================

BEGIN;

DO $$
DECLARE
    t TEXT;
    operational_tables CONSTANT TEXT[] := ARRAY[
        'clients',                'projects',          'estimates',         'quotes',
        'change_orders',          'invoices',          'material_sales',
        'material_requests',      'purchase_orders',   'suppliers',
        'subcontractors',         'subcontracts',      'contracts',
        'lien_waivers',           'project_budgets',   'rfis',
        'daily_job_reports',      'equipment',         'crews',
        'schedule_entries',       'timesheet_entries', 'exception_logs',
        'incidents',              'form_submissions',
        'crm_contacts',           'crm_opportunities', 'crm_tasks',
        'crm_activities',         'crm_attachments',   'handoff_checklists',
        'product_services',       'client_pricings',   'certificates',
        'documents'
    ];
BEGIN
    FOREACH t IN ARRAY operational_tables LOOP
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = 'public' AND table_name = t
        ) THEN
            RAISE NOTICE 'Skipping % — table not present in this environment', t;
            CONTINUE;
        END IF;

        -- 1a. Add the 5 sample-data columns. ADD COLUMN with a constant
        -- DEFAULT is metadata-only on PG11+ — no table rewrite, no row lock.
        EXECUTE format($f$
            ALTER TABLE %I
              ADD COLUMN IF NOT EXISTS is_sample_data            BOOLEAN     NOT NULL DEFAULT FALSE,
              ADD COLUMN IF NOT EXISTS sample_data_batch_id      UUID,
              ADD COLUMN IF NOT EXISTS sample_data_seed_version  TEXT,
              ADD COLUMN IF NOT EXISTS sample_data_created_at    TIMESTAMPTZ,
              ADD COLUMN IF NOT EXISTS sample_data_created_by    UUID
                REFERENCES auth.users(id) ON DELETE SET NULL;
        $f$, t);

        -- 1b. Consistency CHECK — a row marked sample must have full
        -- metadata. PG15+ supports IF NOT EXISTS on ADD CONSTRAINT.
        BEGIN
            EXECUTE format($f$
                ALTER TABLE %I
                  ADD CONSTRAINT %I CHECK (
                    NOT is_sample_data
                    OR (sample_data_batch_id      IS NOT NULL
                        AND sample_data_seed_version IS NOT NULL
                        AND sample_data_created_at   IS NOT NULL)
                  );
            $f$, t, t || '_sample_metadata_chk');
        EXCEPTION
            WHEN duplicate_object THEN
                NULL;  -- constraint already exists
        END;

        RAISE NOTICE 'Sample-data columns + CHECK added to %', t;
    END LOOP;
END $$;

-- =============================================================================
-- PART 2 — Marker immutability triggers (transactional)
-- =============================================================================
-- Once a row is marked sample, the marker fields are immutable from any
-- normal app path. Only the `clear_sample_data` RPC sets a session var
-- that lets the trigger pass through. This prevents a buggy or malicious
-- code path from "laundering" sample data into looking real.

DO $$
DECLARE
    t TEXT;
    operational_tables CONSTANT TEXT[] := ARRAY[
        'clients','projects','estimates','quotes','change_orders','invoices',
        'material_sales','material_requests','purchase_orders','suppliers',
        'subcontractors','subcontracts','contracts','lien_waivers','project_budgets',
        'rfis','daily_job_reports','equipment','crews','schedule_entries',
        'timesheet_entries','exception_logs','incidents','form_submissions',
        'crm_contacts','crm_opportunities','crm_tasks','crm_activities',
        'crm_attachments','handoff_checklists','product_services','client_pricings',
        'certificates','documents'
    ];
BEGIN
    FOREACH t IN ARRAY operational_tables LOOP
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = 'public' AND table_name = t
        ) THEN CONTINUE; END IF;

        EXECUTE format($f$
            CREATE OR REPLACE FUNCTION %I() RETURNS TRIGGER AS $body$
            BEGIN
              -- Reset RPC sets this session var to bypass the lock.
              IF current_setting('aski.sample_reset_in_progress', TRUE) = 'true' THEN
                RETURN NEW;
              END IF;
              IF OLD.is_sample_data IS DISTINCT FROM NEW.is_sample_data
                 OR OLD.sample_data_batch_id IS DISTINCT FROM NEW.sample_data_batch_id THEN
                RAISE EXCEPTION 'sample-data marker fields are immutable'
                  USING ERRCODE = 'check_violation';
              END IF;
              RETURN NEW;
            END $body$ LANGUAGE plpgsql;
        $f$, 'fn_' || t || '_lock_sample_marker');

        EXECUTE format('
            DROP TRIGGER IF EXISTS %I ON %I;
            CREATE TRIGGER %I
              BEFORE UPDATE ON %I
              FOR EACH ROW EXECUTE FUNCTION %I();
        ',
            'trg_' || t || '_lock_sample_marker', t,
            'trg_' || t || '_lock_sample_marker', t,
            'fn_'  || t || '_lock_sample_marker');
    END LOOP;
END $$;

-- =============================================================================
-- PART 3 — clear_sample_data RPC (transactional)
-- =============================================================================
-- SECURITY DEFINER so the function runs as table owner and can bypass
-- RLS only for the explicit DELETE pattern below. Caller is verified by:
--   * typed confirmation phrase
--   * `executive` role check (NOT officeAdmin — destructive op)
--   * company_id ownership

CREATE OR REPLACE FUNCTION clear_sample_data(
    p_company_id     UUID,
    p_batch_id       UUID,
    p_confirm_phrase TEXT
) RETURNS TABLE (table_name TEXT, rows_deleted BIGINT)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
DECLARE
    v_caller_role     TEXT;
    v_per_table_count BIGINT;
    -- Topologically sorted: leaves before roots.
    v_delete_order CONSTANT TEXT[] := ARRAY[
        'lien_waivers',
        'invoices',
        'change_orders',
        'rfis',
        'daily_job_reports',
        'exception_logs',
        'timesheet_entries',
        'schedule_entries',
        'incidents',
        'form_submissions',
        'crm_attachments',
        'crm_activities',
        'crm_tasks',
        'handoff_checklists',
        'crm_opportunities',
        'crm_contacts',
        'purchase_orders',
        'material_requests',
        'subcontracts',
        'subcontractors',
        'project_budgets',
        'documents',
        'material_sales',
        'quotes',
        'estimates',
        'contracts',
        'projects',
        'crews',
        'equipment',
        'certificates',
        'client_pricings',
        'product_services',
        'suppliers',
        'clients'
    ];
    v_tbl TEXT;
BEGIN
    -- Confirmation gate
    IF p_confirm_phrase IS DISTINCT FROM 'DELETE SAMPLE DATA' THEN
        RAISE EXCEPTION 'confirmation phrase mismatch'
            USING HINT = 'caller must pass DELETE SAMPLE DATA exactly';
    END IF;

    -- Caller authorization — executive only (not office_admin)
    SELECT role INTO v_caller_role
    FROM employees
    WHERE id = auth.uid() AND company_id = p_company_id AND COALESCE(is_active, TRUE);
    IF v_caller_role IS NULL OR v_caller_role <> 'executive' THEN
        RAISE EXCEPTION 'caller % is not an executive of company %', auth.uid(), p_company_id
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- Bypass marker-immutability trigger for this transaction only.
    PERFORM set_config('aski.sample_reset_in_progress', 'true', true);

    -- Serialize against any concurrent load/reset for this company.
    PERFORM pg_advisory_xact_lock(hashtext('sample_data_' || p_company_id::text));

    FOREACH v_tbl IN ARRAY v_delete_order LOOP
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = 'public' AND table_name = v_tbl
        ) THEN CONTINUE; END IF;

        EXECUTE format($f$
            WITH d AS (
              DELETE FROM %I
              WHERE company_id = $1
                AND is_sample_data = TRUE
                AND sample_data_batch_id = $2
              RETURNING 1
            )
            SELECT count(*) FROM d;
        $f$, v_tbl) INTO v_per_table_count USING p_company_id, p_batch_id;

        table_name   := v_tbl;
        rows_deleted := v_per_table_count;
        RETURN NEXT;
    END LOOP;

    -- Audit summary row
    INSERT INTO workflow_log (rule_id, rule_name, title, body, company_id)
    VALUES (
        gen_random_uuid(),
        'Sample Data Reset',
        format('Sample data batch %s cleared', p_batch_id),
        format('Cleared by %s', auth.uid()),
        p_company_id
    );
END $$;

REVOKE ALL  ON FUNCTION clear_sample_data(UUID, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION clear_sample_data(UUID, UUID, TEXT) TO authenticated;

COMMIT;

-- =============================================================================
-- PART 4 — Indexes (CONCURRENT, OUTSIDE the transaction)
-- =============================================================================
-- Each CREATE INDEX CONCURRENTLY must run on its own (cannot be inside
-- a multi-statement transaction). We emit one statement per table.
-- Each is IF NOT EXISTS so the file is re-runnable.
--
-- NOTE: psql interprets each line with `;` as a separate transaction
-- here. If running through the Supabase migration runner, ensure the
-- runner emits these statements without wrapping them in a transaction.
-- (Supabase CLI: place this file in `supabase/migrations/` and the
-- CLI will handle the split correctly because of the COMMIT above.)

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_clients_sample_batch              ON clients              (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_projects_sample_batch             ON projects             (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_estimates_sample_batch            ON estimates            (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_quotes_sample_batch               ON quotes               (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_change_orders_sample_batch        ON change_orders        (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_invoices_sample_batch             ON invoices             (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_material_sales_sample_batch       ON material_sales       (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_material_requests_sample_batch    ON material_requests    (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_purchase_orders_sample_batch      ON purchase_orders      (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_suppliers_sample_batch            ON suppliers            (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_subcontractors_sample_batch       ON subcontractors       (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_subcontracts_sample_batch         ON subcontracts         (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_contracts_sample_batch            ON contracts            (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_lien_waivers_sample_batch         ON lien_waivers         (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_project_budgets_sample_batch      ON project_budgets      (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_rfis_sample_batch                 ON rfis                 (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_daily_job_reports_sample_batch    ON daily_job_reports    (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_equipment_sample_batch            ON equipment            (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_crews_sample_batch                ON crews                (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_schedule_entries_sample_batch     ON schedule_entries     (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_timesheet_entries_sample_batch    ON timesheet_entries    (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_exception_logs_sample_batch       ON exception_logs       (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_incidents_sample_batch            ON incidents            (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_form_submissions_sample_batch     ON form_submissions     (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_crm_contacts_sample_batch         ON crm_contacts         (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_crm_opportunities_sample_batch    ON crm_opportunities    (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_crm_tasks_sample_batch            ON crm_tasks            (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_crm_activities_sample_batch       ON crm_activities       (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_crm_attachments_sample_batch      ON crm_attachments      (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_handoff_checklists_sample_batch   ON handoff_checklists   (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_product_services_sample_batch     ON product_services     (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_client_pricings_sample_batch      ON client_pricings      (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_certificates_sample_batch         ON certificates         (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_documents_sample_batch            ON documents            (company_id, sample_data_batch_id) WHERE is_sample_data = TRUE;

-- =============================================================================
-- DONE
-- =============================================================================
-- Post-deploy: verify with
--   SELECT table_name, count(*) FROM information_schema.columns
--   WHERE column_name = 'is_sample_data' GROUP BY table_name;
