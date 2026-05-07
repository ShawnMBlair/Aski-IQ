-- Aski IQ — Sample Data Support Migration (DEV / LOCAL)
-- =============================================================================
-- Identical to the production migration except indexes are built INSIDE
-- the transaction (CREATE INDEX, no CONCURRENTLY). Faster and simpler
-- for empty / low-volume dev databases. NEVER use this against a busy
-- production tenant — it takes a brief schema lock per index.
--
-- For production, use: SupabaseMigration_SampleDataSupport_Prod.sql

BEGIN;

-- ─── Schema (sample-data columns + CHECK) ────────────────────────────────────
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
        ) THEN
            RAISE NOTICE 'Skipping % — table not present', t;
            CONTINUE;
        END IF;

        EXECUTE format($f$
            ALTER TABLE %I
              ADD COLUMN IF NOT EXISTS is_sample_data            BOOLEAN     NOT NULL DEFAULT FALSE,
              ADD COLUMN IF NOT EXISTS sample_data_batch_id      UUID,
              ADD COLUMN IF NOT EXISTS sample_data_seed_version  TEXT,
              ADD COLUMN IF NOT EXISTS sample_data_created_at    TIMESTAMPTZ,
              ADD COLUMN IF NOT EXISTS sample_data_created_by    UUID
                REFERENCES auth.users(id) ON DELETE SET NULL;
        $f$, t);

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
        EXCEPTION WHEN duplicate_object THEN
            NULL;
        END;

        -- DEV-ONLY: standard CREATE INDEX inside the transaction.
        EXECUTE format('
            CREATE INDEX IF NOT EXISTS %I
              ON %I (company_id, sample_data_batch_id)
              WHERE is_sample_data = TRUE;
        ', 'idx_' || t || '_sample_batch', t);

        RAISE NOTICE 'Sample-data columns + index added to %', t;
    END LOOP;
END $$;

-- ─── Marker immutability triggers ────────────────────────────────────────────
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

-- ─── clear_sample_data RPC ──────────────────────────────────────────────────
-- Identical to production; executive-only.
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
    v_delete_order CONSTANT TEXT[] := ARRAY[
        'lien_waivers','invoices','change_orders','rfis','daily_job_reports',
        'exception_logs','timesheet_entries','schedule_entries','incidents',
        'form_submissions','crm_attachments','crm_activities','crm_tasks',
        'handoff_checklists','crm_opportunities','crm_contacts',
        'purchase_orders','material_requests','subcontracts','subcontractors',
        'project_budgets','documents','material_sales','quotes','estimates',
        'contracts','projects','crews','equipment','certificates',
        'client_pricings','product_services','suppliers','clients'
    ];
    v_tbl TEXT;
BEGIN
    IF p_confirm_phrase IS DISTINCT FROM 'DELETE SAMPLE DATA' THEN
        RAISE EXCEPTION 'confirmation phrase mismatch'
            USING HINT = 'caller must pass DELETE SAMPLE DATA exactly';
    END IF;

    SELECT role INTO v_caller_role
    FROM employees
    WHERE id = auth.uid() AND company_id = p_company_id AND COALESCE(is_active, TRUE);
    IF v_caller_role IS NULL OR v_caller_role <> 'executive' THEN
        RAISE EXCEPTION 'caller % is not an executive of company %', auth.uid(), p_company_id
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    PERFORM set_config('aski.sample_reset_in_progress', 'true', true);
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

    INSERT INTO workflow_log (rule_id, rule_name, title, body, company_id)
    VALUES (
        gen_random_uuid(),
        'Sample Data Reset',
        format('Sample data batch %s cleared (DEV)', p_batch_id),
        format('Cleared by %s', auth.uid()),
        p_company_id
    );
END $$;

REVOKE ALL  ON FUNCTION clear_sample_data(UUID, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION clear_sample_data(UUID, UUID, TEXT) TO authenticated;

COMMIT;
