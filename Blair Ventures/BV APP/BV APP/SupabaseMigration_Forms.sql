-- ============================================================
-- Aski IQ – Forms Storage Migration
-- Run this in Supabase Dashboard → SQL Editor
-- ============================================================

-- ----------------------------------------
-- form_templates: add rich field columns
-- ----------------------------------------
ALTER TABLE form_templates
  ADD COLUMN IF NOT EXISTS form_description  TEXT,
  ADD COLUMN IF NOT EXISTS is_archived       BOOLEAN     NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS version           INTEGER     NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS fields_json       TEXT        NOT NULL DEFAULT '[]',
  ADD COLUMN IF NOT EXISTS groups_json       TEXT        NOT NULL DEFAULT '[]',
  ADD COLUMN IF NOT EXISTS last_modified_by  TEXT,
  ADD COLUMN IF NOT EXISTS updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Index for active template lookups
CREATE INDEX IF NOT EXISTS idx_form_templates_is_archived
  ON form_templates (is_archived);

-- ----------------------------------------
-- form_submissions: add all missing columns
-- ----------------------------------------
ALTER TABLE form_submissions
  ADD COLUMN IF NOT EXISTS template_version   INTEGER     NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS submitted_at       TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS signed_at          TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS signed_by          TEXT,
  ADD COLUMN IF NOT EXISTS is_draft           BOOLEAN     NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS is_archived        BOOLEAN     NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS link_type          TEXT        NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS linked_name        TEXT,
  ADD COLUMN IF NOT EXISTS linked_address     TEXT,
  ADD COLUMN IF NOT EXISTS linked_coordinate  TEXT,         -- JSON: {latitude, longitude, address}
  ADD COLUMN IF NOT EXISTS responses_json     TEXT        NOT NULL DEFAULT '[]',
  ADD COLUMN IF NOT EXISTS audit_hash         TEXT,
  ADD COLUMN IF NOT EXISTS last_modified_by   TEXT,
  ADD COLUMN IF NOT EXISTS updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_form_submissions_project_id
  ON form_submissions (project_id);

CREATE INDEX IF NOT EXISTS idx_form_submissions_is_draft
  ON form_submissions (is_draft);

CREATE INDEX IF NOT EXISTS idx_form_submissions_is_archived
  ON form_submissions (is_archived);

CREATE INDEX IF NOT EXISTS idx_form_submissions_link_type
  ON form_submissions (link_type);

CREATE INDEX IF NOT EXISTS idx_form_submissions_submitted_at
  ON form_submissions (submitted_at DESC);

-- ----------------------------------------
-- Storage bucket for form photos (run separately)
-- ----------------------------------------
-- In Supabase Dashboard → Storage → New Bucket:
--   Name: form-photos
--   Public: false
--   File size limit: 5MB
--   Allowed MIME types: image/jpeg, image/png
--
-- Then add this RLS policy:
-- INSERT INTO storage.policies (name, bucket_id, operation, definition)
-- VALUES (
--   'Authenticated users can upload form photos',
--   'form-photos',
--   'INSERT',
--   'auth.role() = ''authenticated'''
-- );

-- ----------------------------------------
-- Row Level Security (recommended)
-- ----------------------------------------
-- Enable RLS on both tables if not already done:
-- ALTER TABLE form_templates  ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE form_submissions ENABLE ROW LEVEL SECURITY;
--
-- Allow all authenticated users to read templates:
-- CREATE POLICY "Authenticated read templates"
--   ON form_templates FOR SELECT
--   USING (auth.role() = 'authenticated');
--
-- Allow all authenticated users to read/write submissions:
-- CREATE POLICY "Authenticated read submissions"
--   ON form_submissions FOR SELECT
--   USING (auth.role() = 'authenticated');
--
-- CREATE POLICY "Authenticated insert submissions"
--   ON form_submissions FOR INSERT
--   WITH CHECK (auth.role() = 'authenticated');
--
-- CREATE POLICY "Authenticated update submissions"
--   ON form_submissions FOR UPDATE
--   USING (auth.role() = 'authenticated');
