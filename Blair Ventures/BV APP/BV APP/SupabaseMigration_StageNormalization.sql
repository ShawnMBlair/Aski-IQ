-- Aski IQ — CRM stage value normalization
--
-- BACKGROUND: live data carried 10 distinct stage strings (mixed
-- TitleCase + lowercase_snake_case) that mapped to only 7 logical
-- stages. The drift came from SQL functions writing lowercase
-- ('new_lead', 'won') while the iOS OpportunityStage enum's
-- canonical raw values are TitleCase ('New Lead', 'Won').
--
-- Mixed casing corrupted pipeline reporting because GROUP BY treated
-- 'Won' and 'won' as different stages. This migration:
--
--   1. Audits every change to backfill_log
--   2. Normalizes 6 affected rows to canonical TitleCase
--   3. Patches auto_link_opportunity_for_commercial_record() to write
--      'New Lead' instead of 'new_lead'
--   4. Patches accept_quote_via_token() to write 'Won' instead of 'won'
--   5. Adds a CHECK constraint on stage to prevent future drift
--
-- VERIFIED POST-MIGRATION (2026-05):
--   New Lead: 14 rows
--   Won:       9 rows
--   Lost:      3 rows
--   Follow-Up: 2 rows
--   Estimate:  1 row
--   Quote Sent: 1 row
--   Site Visit: 1 row
--   ─── 31 total, 7 canonical stages, no drift

-- See live migration `normalize_crm_opportunity_stage_values` for the
-- full applied SQL. Reproduced here:

INSERT INTO public.backfill_log (run_label, table_name, row_id, action, source_path, details)
SELECT
  'stage_normalization_2026_05',
  'crm_opportunities',
  id,
  'normalized_stage',
  CASE stage
    WHEN 'won'        THEN 'won → Won'
    WHEN 'new_lead'   THEN 'new_lead → New Lead'
    WHEN 'follow_up'  THEN 'follow_up → Follow-Up'
    WHEN 'quote_sent' THEN 'quote_sent → Quote Sent'
    WHEN 'site_visit' THEN 'site_visit → Site Visit'
    ELSE stage || ' (unchanged)'
  END,
  jsonb_build_object('old_stage', stage)
FROM public.crm_opportunities
WHERE stage IN ('won', 'new_lead', 'follow_up', 'quote_sent', 'site_visit');

UPDATE public.crm_opportunities SET stage = 'Won'        WHERE stage = 'won';
UPDATE public.crm_opportunities SET stage = 'New Lead'   WHERE stage = 'new_lead';
UPDATE public.crm_opportunities SET stage = 'Follow-Up'  WHERE stage = 'follow_up';
UPDATE public.crm_opportunities SET stage = 'Quote Sent' WHERE stage = 'quote_sent';
UPDATE public.crm_opportunities SET stage = 'Site Visit' WHERE stage = 'site_visit';

-- The auto_link trigger function + accept_quote_via_token RPC bodies
-- were re-deployed with TitleCase 'New Lead' / 'Won'. See live migration.

ALTER TABLE public.crm_opportunities DROP CONSTRAINT IF EXISTS crm_opportunities_stage_chk;
ALTER TABLE public.crm_opportunities ADD CONSTRAINT crm_opportunities_stage_chk
  CHECK (stage IN (
    'New Lead', 'Contacted', 'Site Visit', 'Estimate',
    'Quote Sent', 'Follow-Up', 'Won', 'Lost'
  ));
