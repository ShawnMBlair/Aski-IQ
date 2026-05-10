-- =========================================================
-- DAILY JOB REPORTS — add report_number column + backfill + partial unique
-- Phase 3 / Schema-gap pre-migration of the Aski IQ stabilization plan.
-- =========================================================
-- Purpose:
--   Closes the "DJR numbers don't survive sync round-trips" gap surfaced
--   by the Phase 3 audit. Before this migration, prod's `daily_job_reports`
--   table has no `report_number` / `number` column; Swift
--   `DailyJobReport.reportNumber` exists locally but `pushPendingDJRs`
--   doesn't include it in the upsert payload, so different devices show
--   different numbers for the same DJR row. Audit / reporting can't
--   reference a stable DJR identifier.
--
-- What this does:
--   1. Adds `report_number text` nullable so existing rows survive.
--   2. Backfills existing rows with `DJR-<project.job_number>-NNN`
--      sequenced per (company_id, project_id) ordered by (report_date, id)
--      — same shape Swift's nextDJRNumber() produces. Falls back to
--      `DJR-PRJ-NNN` when the parent project has no job_number, mirroring
--      Swift's `prefix = project?.jobNumber ?? "PRJ"`.
--   3. Sets NOT NULL once every row is filled.
--   4. Adds a partial unique index scoped to (company_id, project_id,
--      report_number) WHERE is_deleted = false. Per-project scope (not
--      per-company) because Swift's nextDJRNumber() filters by projectID
--      — sequence space is per-project, by design.
--
-- Why partial (`WHERE is_deleted = false`):
--   Same reason as every other Phase 3 module — soft-deleted rows
--   shouldn't permanently burn their number, and the SyncEngine pull
--   filters `is_deleted = false`, so the local max+1 calculation can't
--   see them anyway.
--
-- Idempotency:
--   - The column add is wrapped in IF NOT EXISTS.
--   - The backfill only touches rows where report_number IS NULL, so
--     re-running this migration after the first prod-apply is a no-op.
--   - The NOT NULL set is conditional on no NULLs remaining (safe re-run).
--   - The index drop+recreate guarantees the partial predicate.
--
-- Companion Swift change (NOT YET LANDED — separate commit follows):
--   - SyncEngine.pullDJRs decodes a new `report_number` field on DJRRow.
--   - SyncEngine.pushPendingDJRs adds `"report_number": .string(...)` to
--     the upsert payload.
--   - DailyJobReport.swift's SCHEMA GAP doc-comment is removed.
--
-- Sync engine retry:
--   pushPendingDJRs already wires through SyncErrorMapper (Phase 2), so
--   when the partial-unique catches a duplicate the user sees "This
--   number is already in use. The sync engine will retry with the next
--   available number." Same pattern as every other Phase 3 module.
--
-- Apply order:
--   Apply this BEFORE the rest of the phase3_drafts batch — the others
--   only touch tables that already have their number column. This one
--   adds the column, so it's the foundational step for DJR.

-- 1. Column add ----------------------------------------------------------

alter table public.daily_job_reports
    add column if not exists report_number text;

-- 2. Backfill ------------------------------------------------------------
-- Rows currently without a report_number get one assigned by report_date
-- ordering within (company_id, project_id). The sequence number is
-- zero-padded to 3 digits to match Swift's String(format: "%03d", ...).
--
-- Project prefix:
--   COALESCE(p.job_number, 'PRJ') mirrors Swift's
--   `let prefix = project?.jobNumber ?? "PRJ"`.

with seq as (
    select
        d.id,
        d.company_id,
        d.project_id,
        coalesce(p.job_number, 'PRJ') as prefix,
        row_number() over (
            partition by d.company_id, d.project_id
            order by d.report_date asc, d.id asc
        ) as n
    from public.daily_job_reports d
    left join public.projects p on p.id = d.project_id
    where d.report_number is null
)
update public.daily_job_reports d
   set report_number = 'DJR-' || seq.prefix || '-' || lpad(seq.n::text, 3, '0')
  from seq
 where d.id = seq.id
   and d.report_number is null;

-- 3. NOT NULL once everything is filled ---------------------------------
-- Conditional so re-runs that find rows still NULL (shouldn't happen, but
-- defensive) skip rather than erroring out.

do $$
begin
    if not exists (
        select 1 from public.daily_job_reports where report_number is null
    ) then
        alter table public.daily_job_reports
            alter column report_number set not null;
    end if;
end $$;

-- 4. Partial unique index ------------------------------------------------

drop index if exists public.daily_job_reports_company_project_number_unique;

create unique index daily_job_reports_company_project_number_unique
    on public.daily_job_reports (company_id, project_id, report_number)
    where is_deleted = false;
