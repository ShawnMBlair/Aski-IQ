-- ============================================================
-- Aski IQ – CRM Architecture Migration
-- Sites + Multi-Contact System
-- Run in Supabase SQL Editor (Dashboard → SQL Editor → New Query)
-- Safe: all changes are ADDITIVE — no data is deleted.
--
-- Column name reference (confirmed from SyncEngine.swift pullClients):
--   clients.contact_name  → contact name
--   clients.email         → contact email  (NOT contact_email)
--   clients.phone         → contact phone  (NOT contact_phone)
-- ============================================================


-- ──────────────────────────────────────────────────────────────
-- PART 1: Add role + site_id to crm_contacts
-- Existing rows default to role = 'general', site_id = NULL
-- ──────────────────────────────────────────────────────────────

ALTER TABLE crm_contacts
  ADD COLUMN IF NOT EXISTS role    TEXT NOT NULL DEFAULT 'general',
  ADD COLUMN IF NOT EXISTS site_id UUID;


-- ──────────────────────────────────────────────────────────────
-- PART 2: Add site_id + primary_contact_id to estimates
-- ──────────────────────────────────────────────────────────────

ALTER TABLE estimates
  ADD COLUMN IF NOT EXISTS site_id            UUID,
  ADD COLUMN IF NOT EXISTS primary_contact_id UUID REFERENCES crm_contacts(id) ON DELETE SET NULL;


-- ──────────────────────────────────────────────────────────────
-- PART 3: Migrate existing flat client contacts → crm_contacts
--
-- Uses the actual column names in the clients table:
--   contact_name, email, phone
--
-- Only inserts for clients that:
--   (a) have at least one non-null contact field
--   (b) don't already have a row in crm_contacts
-- ──────────────────────────────────────────────────────────────

INSERT INTO crm_contacts (
  id, company_id, client_id,
  first_name, last_name,
  email, phone,
  role, is_primary,
  created_at
)
SELECT
  gen_random_uuid()                                    AS id,
  c.company_id                                         AS company_id,
  c.id                                                 AS client_id,

  -- First name: everything before the first space, fallback to 'Primary'
  COALESCE(
    NULLIF(SPLIT_PART(COALESCE(c.contact_name, ''), ' ', 1), ''),
    'Primary'
  )                                                    AS first_name,

  -- Last name: everything after the first space, NULL if single-word name
  NULLIF(
    TRIM(
      CASE
        WHEN POSITION(' ' IN COALESCE(c.contact_name, '')) > 0
        THEN SUBSTRING(c.contact_name FROM POSITION(' ' IN c.contact_name) + 1)
        ELSE ''
      END
    ),
    ''
  )                                                    AS last_name,

  c.email                                              AS email,
  c.phone                                              AS phone,
  'general'                                            AS role,
  TRUE                                                 AS is_primary,
  NOW()                                                AS created_at

FROM clients c
WHERE
  -- Only migrate clients that have at least one contact field populated
  (
    (c.contact_name IS NOT NULL AND c.contact_name <> '')
    OR (c.email      IS NOT NULL AND c.email      <> '')
    OR (c.phone      IS NOT NULL AND c.phone      <> '')
  )
  -- Skip clients that already have a contact row (idempotent)
  AND NOT EXISTS (
    SELECT 1
    FROM crm_contacts cc
    WHERE cc.client_id = c.id
  );


-- ──────────────────────────────────────────────────────────────
-- PART 4: Verify — run this SELECT to confirm the migration
-- ──────────────────────────────────────────────────────────────
-- SELECT
--   c.name         AS company,
--   cc.first_name,
--   cc.last_name,
--   cc.email,
--   cc.phone,
--   cc.role,
--   cc.is_primary
-- FROM clients c
-- JOIN crm_contacts cc ON cc.client_id = c.id
-- ORDER BY c.name;


-- ──────────────────────────────────────────────────────────────
-- PART 5: Performance indexes
-- ──────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_crm_contacts_client_id
  ON crm_contacts (client_id);

CREATE INDEX IF NOT EXISTS idx_crm_contacts_site_id
  ON crm_contacts (site_id)
  WHERE site_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_estimates_site_id
  ON estimates (site_id)
  WHERE site_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_estimates_primary_contact_id
  ON estimates (primary_contact_id)
  WHERE primary_contact_id IS NOT NULL;


-- ──────────────────────────────────────────────────────────────
-- FUTURE MIGRATION (optional — when extracting sites to own table)
-- ──────────────────────────────────────────────────────────────
--
-- CREATE TABLE client_sites (
--   id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
--   company_id       UUID NOT NULL,
--   client_id        UUID NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
--   name             TEXT NOT NULL,
--   address          TEXT,
--   city             TEXT,
--   province         TEXT,
--   postal_code      TEXT,
--   country          TEXT DEFAULT 'Canada',
--   access_notes     TEXT,
--   safety_notes     TEXT,
--   logistics_notes  TEXT,
--   is_default       BOOLEAN DEFAULT false,
--   created_at       TIMESTAMPTZ DEFAULT now()
-- );
--
-- ALTER TABLE client_sites ENABLE ROW LEVEL SECURITY;
--
-- CREATE POLICY "company members can read sites"
--   ON client_sites FOR SELECT USING (
--     company_id IN (SELECT company_id FROM profiles WHERE id = auth.uid())
--   );
-- CREATE POLICY "company members can insert sites"
--   ON client_sites FOR INSERT WITH CHECK (
--     company_id IN (SELECT company_id FROM profiles WHERE id = auth.uid())
--   );
-- CREATE POLICY "company members can update sites"
--   ON client_sites FOR UPDATE USING (
--     company_id IN (SELECT company_id FROM profiles WHERE id = auth.uid())
--   );
--
-- ──────────────────────────────────────────────────────────────
