-- =========================================================
-- WORKFLOW_SETTINGS — generalize per-role to per-(role, action)
-- Phase 6 / Wave 1 of the Aski IQ stabilization plan.
-- =========================================================
-- Purpose:
--   Today only procurement reads workflow_settings. Other modules use
--   hardcoded role lists scattered across the codebase. To generalize,
--   workflow_settings needs an action_key dimension so the same role
--   can have different capabilities + amount limits per action.
--
-- The schema change is intentionally backwards-compatible:
--   - Default value on action_key means existing rows interpret as
--     'material_request.approve' (the only action they were ever
--     gating).
--   - The old unique constraint (company_id, role_key) is replaced
--     with (company_id, role_key, action_key) — strictly looser; any
--     row that satisfied the old constraint also satisfies the new.
--   - Pull side: existing Swift WorkflowSetting decoder doesn't read
--     action_key today, but Codable ignores extra columns by default,
--     so the pull keeps working unchanged. Phase 6 / Wave 2 will add
--     the field to the Swift struct.
--
-- DO NOT apply to prod until Wave 2 ships the Swift field. The current
-- reverse pull works (extra column ignored), but PUSH from a pre-Wave-2
-- client would write rows without action_key — they'd hit the column's
-- default ('material_request.approve'), which is correct for legacy
-- rows but accidental for any future row that should have a different
-- action_key. Apply Wave 2 Swift first, then Wave 1 migration.

-- =========================================================
-- 1. Add action_key column with backwards-compatible default
-- =========================================================
alter table public.workflow_settings
    add column if not exists action_key text not null default 'material_request.approve';

-- =========================================================
-- 2. Migrate the unique constraint from (company, role) to
--    (company, role, action). Repeats are safe — drop-if-exists.
-- =========================================================
alter table public.workflow_settings
    drop constraint if exists workflow_settings_company_role_unique;

alter table public.workflow_settings
    drop constraint if exists workflow_settings_company_role_action_unique;

alter table public.workflow_settings
    add constraint workflow_settings_company_role_action_unique
    unique (company_id, role_key, action_key);

-- =========================================================
-- 3. Index on action_key for fast lookups by action
-- =========================================================
create index if not exists idx_workflow_settings_action_key
    on public.workflow_settings(action_key);

-- =========================================================
-- 4. Seed the new action namespace per (company, role) tuple
-- =========================================================
-- Existing rows already cover 'material_request.approve' (the column
-- default). Add the rest of the action keys per the design doc's
-- matrix. Idempotent via on conflict do nothing.
--
-- This seed creates DEFAULT capabilities only — admins customize per
-- tenant via the Workflow Settings admin UI. The defaults match the
-- existing hardcoded role lists across modules so behavior is preserved
-- when Wave 3 migrates each module to delegate to the engine.
--
-- The seed values below mirror the procurement seed (what already
-- exists for 'material_request.approve') — i.e. role hierarchy is
-- consistent with the rest of the app. Tier amounts only matter for
-- amount-gated actions (everything ending in `.approve` typically);
-- non-amount actions ignore approval_limit_amount.

insert into public.workflow_settings
    (company_id, role_key, action_key, approval_limit_amount,
     can_self_approve, can_create_material_request, can_approve_material_request,
     can_send_to_supplier, can_receive_materials)
select
    c.id,
    role_data.role_key,
    role_data.action_key,
    role_data.approval_limit_amount,
    role_data.can_self_approve,
    -- The four can_* columns are MR-specific and meaningless for
    -- non-MR action keys. Wave 2 will add an `is_allowed boolean`
    -- column to make non-MR actions first-class; until then,
    -- presence of a row with the right (company, role, action)
    -- means "this role can perform this action" — Wave 3 swaps
    -- the gating helpers to read that.
    false, false, false, false
from public.companies c
cross join (
    values
        -- material_request.* — already covered by the legacy default.
        -- These rows are NO-OP inserts (on conflict do nothing) since
        -- the existing rows were created with action_key default =
        -- 'material_request.approve'. Listing them here makes the seed
        -- self-documenting.

        -- purchase_order.*
        ('field_worker',    'purchase_order.create',         0,           false),
        ('foreman',         'purchase_order.create',         0,           false),
        ('project_manager', 'purchase_order.create',         0,           false),
        ('office_admin',    'purchase_order.create',         0,           false),
        ('manager',         'purchase_order.create',         0,           false),
        ('executive',       'purchase_order.create',         0,           false),
        ('owner',           'purchase_order.create',         0,           false),

        ('foreman',         'purchase_order.send',           0,           false),
        ('project_manager', 'purchase_order.send',           0,           false),
        ('office_admin',    'purchase_order.send',           0,           false),
        ('manager',         'purchase_order.send',           0,           false),
        ('executive',       'purchase_order.send',           0,           false),
        ('owner',           'purchase_order.send',           0,           false),

        ('field_worker',    'purchase_order.receive',        0,           false),
        ('foreman',         'purchase_order.receive',        0,           false),
        ('project_manager', 'purchase_order.receive',        0,           false),
        ('office_admin',    'purchase_order.receive',        0,           false),
        ('manager',         'purchase_order.receive',        0,           false),
        ('executive',       'purchase_order.receive',        0,           false),
        ('owner',           'purchase_order.receive',        0,           false),

        ('office_admin',    'purchase_order.match_invoice',  0,           false),
        ('manager',         'purchase_order.match_invoice',  0,           false),
        ('executive',       'purchase_order.match_invoice',  0,           false),
        ('owner',           'purchase_order.match_invoice',  0,           false),

        -- quote.*
        ('estimator',       'quote.approve',                 0,           false),
        ('project_manager', 'quote.approve',                 50000,       false),
        ('office_admin',    'quote.approve',                 25000,       false),
        ('manager',         'quote.approve',                 250000,      true),
        ('executive',       'quote.approve',                 999999999,   true),
        ('owner',           'quote.approve',                 999999999,   true),

        ('project_manager', 'quote.send',                    0,           false),
        ('office_admin',    'quote.send',                    0,           false),
        ('manager',         'quote.send',                    0,           false),
        ('executive',       'quote.send',                    0,           false),
        ('owner',           'quote.send',                    0,           false),

        ('project_manager', 'quote.mark_accepted',           0,           false),
        ('office_admin',    'quote.mark_accepted',           0,           false),
        ('manager',         'quote.mark_accepted',           0,           false),
        ('executive',       'quote.mark_accepted',           0,           false),
        ('owner',           'quote.mark_accepted',           0,           false),

        -- estimate.*
        ('project_manager', 'estimate.review',               0,           false),
        ('office_admin',    'estimate.review',               0,           false),
        ('manager',         'estimate.review',               0,           false),
        ('executive',       'estimate.review',               0,           false),
        ('owner',           'estimate.review',               0,           false),

        -- invoice.*
        ('office_admin',    'invoice.send',                  0,           false),
        ('manager',         'invoice.send',                  0,           false),
        ('executive',       'invoice.send',                  0,           false),
        ('owner',           'invoice.send',                  0,           false),

        ('manager',         'invoice.void',                  0,           true),
        ('executive',       'invoice.void',                  0,           true),
        ('owner',           'invoice.void',                  0,           true),

        -- change_order.*
        ('office_admin',    'change_order.approve',          5000,        false),
        ('manager',         'change_order.approve',          50000,       true),
        ('executive',       'change_order.approve',          999999999,   true),
        ('owner',           'change_order.approve',          999999999,   true),

        -- schedule.*
        ('foreman',         'schedule.edit',                 0,           false),
        ('project_manager', 'schedule.edit',                 0,           false),
        ('office_admin',    'schedule.edit',                 0,           false),
        ('manager',         'schedule.edit',                 0,           false),
        ('executive',       'schedule.edit',                 0,           false),
        ('owner',           'schedule.edit',                 0,           false),

        ('project_manager', 'schedule.override_conflict',    0,           false),
        ('manager',         'schedule.override_conflict',    0,           true),
        ('executive',       'schedule.override_conflict',    0,           true),
        ('owner',           'schedule.override_conflict',    0,           true),

        ('project_manager', 'schedule.approve_recommendation',0,          false),
        ('office_admin',    'schedule.approve_recommendation',0,          false),
        ('manager',         'schedule.approve_recommendation',0,          true),
        ('executive',       'schedule.approve_recommendation',0,          true),
        ('owner',           'schedule.approve_recommendation',0,          true),

        -- timesheet.*
        ('foreman',         'timesheet.approve',             0,           false),
        ('project_manager', 'timesheet.approve',             0,           false),
        ('office_admin',    'timesheet.approve',             0,           false),
        ('manager',         'timesheet.approve',             0,           true),
        ('executive',       'timesheet.approve',             0,           true),
        ('owner',           'timesheet.approve',             0,           true)
) as role_data(role_key, action_key, approval_limit_amount, can_self_approve)
on conflict (company_id, role_key, action_key) do nothing;
