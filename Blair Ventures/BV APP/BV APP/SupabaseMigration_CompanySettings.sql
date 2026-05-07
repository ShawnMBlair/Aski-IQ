-- Aski IQ — company_settings migration
-- =============================================================================
-- Replaces device-local UserDefaults persistence (which leaked across tenants
-- on the same device and was wiped by sign-out) with a server-side, RLS-scoped
-- table.
--
-- One row per company. Auto-created when setup_new_user creates a company.
-- All fields except company_id are nullable so the row exists immediately
-- and the iOS client populates them via Save when the user fills them in.
--
-- IMPORTANT
-- `name`, `address`, etc. are duplicated here from `companies` to keep all
-- editable fields in one place. The Settings UI writes to this table; the
-- legacy `companies.name` is kept in sync via a trigger so existing queries
-- (Spotlight, dashboards) keep working.

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Table
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.company_settings (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id            uuid NOT NULL UNIQUE
                          REFERENCES public.companies(id) ON DELETE CASCADE,

    -- Company info (mirrors companies.name; trigger below keeps them in sync)
    name                  text,
    address               text,
    phone                 text,
    email                 text,

    -- Commercial defaults
    currency              text     NOT NULL DEFAULT 'CAD'
                          CHECK (length(currency) = 3 AND currency = upper(currency)),
    tax_label             text     NOT NULL DEFAULT 'GST',
    tax_rate              numeric(7,4) NOT NULL DEFAULT 0.0500
                          CHECK (tax_rate >= 0 AND tax_rate <= 1),
    default_contingency   numeric(7,4) NOT NULL DEFAULT 0.0500
                          CHECK (default_contingency >= 0 AND default_contingency <= 1),
    default_payment_terms text     NOT NULL DEFAULT 'Net 30',
    default_quote_validity_days integer NOT NULL DEFAULT 30
                          CHECK (default_quote_validity_days > 0),

    -- Job number sequence (server-authoritative — replaces UserDefaults)
    job_prefix            text     NOT NULL DEFAULT 'AKI',
    next_job_number       integer  NOT NULL DEFAULT 1
                          CHECK (next_job_number > 0),

    -- Annual revenue target — used by dashboard charts
    annual_revenue_target numeric(14,2) NOT NULL DEFAULT 0,

    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_company_settings_company_id
    ON public.company_settings (company_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. RLS — only members of the company can SELECT; only admins can UPDATE
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.company_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS company_settings_select ON public.company_settings;
CREATE POLICY company_settings_select ON public.company_settings
    FOR SELECT
    USING (
        company_id IN (
            SELECT company_id FROM public.profiles
            WHERE id = auth.uid()
        )
    );

DROP POLICY IF EXISTS company_settings_update ON public.company_settings;
CREATE POLICY company_settings_update ON public.company_settings
    FOR UPDATE
    USING (
        company_id IN (
            SELECT company_id FROM public.profiles
            WHERE id = auth.uid()
              AND role IN ('executive', 'manager', 'office_admin')
        )
    );

-- INSERT goes through the trigger below (SECURITY DEFINER) — direct INSERT
-- from authenticated users is forbidden.
DROP POLICY IF EXISTS company_settings_insert_none ON public.company_settings;
CREATE POLICY company_settings_insert_none ON public.company_settings
    FOR INSERT
    WITH CHECK (false);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Auto-create one settings row per company
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_create_company_settings()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
    INSERT INTO public.company_settings (company_id, name)
    VALUES (NEW.id, NEW.name)
    ON CONFLICT (company_id) DO NOTHING;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_companies_create_settings ON public.companies;
CREATE TRIGGER trg_companies_create_settings
    AFTER INSERT ON public.companies
    FOR EACH ROW EXECUTE FUNCTION public.fn_create_company_settings();

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Keep companies.name in sync when company_settings.name is updated
-- (legacy code reads companies.name; new UI writes company_settings.name)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_sync_company_name()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
    IF NEW.name IS DISTINCT FROM OLD.name AND NEW.name IS NOT NULL THEN
        UPDATE public.companies
        SET name = NEW.name
        WHERE id = NEW.company_id;
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_company_settings_sync_name ON public.company_settings;
CREATE TRIGGER trg_company_settings_sync_name
    BEFORE UPDATE ON public.company_settings
    FOR EACH ROW EXECUTE FUNCTION public.fn_sync_company_name();

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Backfill: create a settings row for every existing company that doesn't
-- have one (so existing tenants don't 404 on first Settings load)
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.company_settings (company_id, name)
SELECT c.id, c.name
FROM public.companies c
WHERE NOT EXISTS (
    SELECT 1 FROM public.company_settings cs WHERE cs.company_id = c.id
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Server-side job-number generator (atomic increment)
-- Returns the next number AND increments the counter in one transaction so
-- two devices can't ever produce the same job number.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_job_number(p_company_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
    v_prefix text;
    v_number integer;
    v_year   integer := EXTRACT(year FROM now())::int;
BEGIN
    -- Caller must be a member of this company. RLS doesn't apply to
    -- SECURITY DEFINER functions, so we enforce it manually.
    IF NOT EXISTS (
        SELECT 1 FROM public.profiles
        WHERE id = auth.uid() AND company_id = p_company_id
    ) THEN
        RAISE EXCEPTION 'caller is not a member of company %', p_company_id;
    END IF;

    UPDATE public.company_settings
    SET next_job_number = next_job_number + 1
    WHERE company_id = p_company_id
    RETURNING job_prefix, (next_job_number - 1) INTO v_prefix, v_number;

    IF v_prefix IS NULL THEN
        RAISE EXCEPTION 'company_settings row missing for %', p_company_id;
    END IF;

    RETURN format('%s-%s-%s', v_prefix, v_year, lpad(v_number::text, 4, '0'));
END;
$$;

REVOKE ALL ON FUNCTION public.next_job_number(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.next_job_number(uuid) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. ensure_company_settings — defensive load-or-create
-- ─────────────────────────────────────────────────────────────────────────────
-- The auto-create trigger + backfill should always leave a row in place,
-- but the iOS service calls this RPC as a safety net for:
--   * Older tenants where the trigger wasn't installed when the company
--     was created
--   * Migration not yet applied in a particular environment (dev branch
--     databases, preview deployments)
--   * Future onboarding flows that create a company outside the
--     `setup_new_user` path
--
-- INSERT into company_settings is blocked for end-users by the
-- company_settings_insert_none policy; this SECURITY DEFINER function
-- is the only legitimate INSERT path. Caller must be a member of the
-- company; we re-check via auth.uid() so the function can't be used
-- to create rows for foreign tenants.
--
-- Returns the (existing or newly inserted) row.

CREATE OR REPLACE FUNCTION public.ensure_company_settings(p_company_id uuid)
RETURNS public.company_settings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
    v_caller_company uuid;
    v_row public.company_settings;
BEGIN
    -- Membership gate
    SELECT company_id INTO v_caller_company
    FROM public.profiles
    WHERE id = auth.uid();

    IF v_caller_company IS NULL OR v_caller_company <> p_company_id THEN
        RAISE EXCEPTION 'caller is not a member of company %', p_company_id
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- Try to read first
    SELECT * INTO v_row
    FROM public.company_settings
    WHERE company_id = p_company_id;

    IF FOUND THEN
        RETURN v_row;
    END IF;

    -- Create with defaults — pull the company name in for the snapshot
    INSERT INTO public.company_settings (company_id, name)
    SELECT c.id, c.name FROM public.companies c WHERE c.id = p_company_id
    ON CONFLICT (company_id) DO NOTHING;

    -- Re-select (the INSERT above is on-conflict-do-nothing, so we
    -- guarantee a return value even if a concurrent caller raced us)
    SELECT * INTO v_row
    FROM public.company_settings
    WHERE company_id = p_company_id;

    RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.ensure_company_settings(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ensure_company_settings(uuid) TO authenticated;

COMMIT;
