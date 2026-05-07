-- ============================================================
-- Aski IQ – CRM Module Migration
-- Run this in Supabase Dashboard → SQL Editor
-- Tables: crm_contacts, crm_opportunities, crm_tasks,
--         crm_activities, crm_checklists
-- ============================================================

-- ─────────────────────────────────────────────
-- crm_contacts
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS crm_contacts (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id  UUID        NOT NULL,
    first_name TEXT        NOT NULL DEFAULT '',
    last_name  TEXT        NOT NULL DEFAULT '',
    title      TEXT        NOT NULL DEFAULT '',
    phone      TEXT        NOT NULL DEFAULT '',
    email      TEXT        NOT NULL DEFAULT '',
    is_primary BOOLEAN     NOT NULL DEFAULT FALSE,
    notes      TEXT        NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE crm_contacts
    ADD COLUMN IF NOT EXISTS title      TEXT    NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS phone      TEXT    NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS email      TEXT    NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS is_primary BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS notes      TEXT    NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_crm_contacts_client_id ON crm_contacts (client_id);
CREATE INDEX IF NOT EXISTS idx_crm_contacts_email     ON crm_contacts (email);

-- ─────────────────────────────────────────────
-- crm_opportunities
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS crm_opportunities (
    id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id        UUID          NOT NULL,
    title            TEXT          NOT NULL DEFAULT '',
    stage            TEXT          NOT NULL DEFAULT 'new_lead',
    value            NUMERIC(14,2) NOT NULL DEFAULT 0,
    service_type     TEXT          NOT NULL DEFAULT '',
    site_address     TEXT          NOT NULL DEFAULT '',
    description      TEXT          NOT NULL DEFAULT '',
    source           TEXT          NOT NULL DEFAULT 'direct_inquiry',
    loss_reason      TEXT          NOT NULL DEFAULT '',
    competitor_name  TEXT          NOT NULL DEFAULT '',
    probability      INTEGER       NOT NULL DEFAULT 10,
    assigned_to_name TEXT          NOT NULL DEFAULT '',
    notes            TEXT          NOT NULL DEFAULT '',
    contact_id       UUID,
    estimate_id      UUID,
    quote_id         UUID,
    project_id       UUID,
    assigned_to_id   UUID,
    estimated_start  DATE,
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    won_at           TIMESTAMPTZ,
    lost_at          TIMESTAMPTZ
);

ALTER TABLE crm_opportunities
    ADD COLUMN IF NOT EXISTS service_type     TEXT          NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS site_address     TEXT          NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS description      TEXT          NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS source           TEXT          NOT NULL DEFAULT 'direct_inquiry',
    ADD COLUMN IF NOT EXISTS loss_reason      TEXT          NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS competitor_name  TEXT          NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS probability      INTEGER       NOT NULL DEFAULT 10,
    ADD COLUMN IF NOT EXISTS assigned_to_name TEXT          NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS notes            TEXT          NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS contact_id       UUID,
    ADD COLUMN IF NOT EXISTS estimate_id      UUID,
    ADD COLUMN IF NOT EXISTS quote_id         UUID,
    ADD COLUMN IF NOT EXISTS project_id       UUID,
    ADD COLUMN IF NOT EXISTS assigned_to_id   UUID,
    ADD COLUMN IF NOT EXISTS estimated_start  DATE,
    ADD COLUMN IF NOT EXISTS updated_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    ADD COLUMN IF NOT EXISTS won_at           TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS lost_at          TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_crm_opp_client_id   ON crm_opportunities (client_id);
CREATE INDEX IF NOT EXISTS idx_crm_opp_stage        ON crm_opportunities (stage);
CREATE INDEX IF NOT EXISTS idx_crm_opp_assigned_to  ON crm_opportunities (assigned_to_id);
CREATE INDEX IF NOT EXISTS idx_crm_opp_updated_at   ON crm_opportunities (updated_at DESC);

-- ─────────────────────────────────────────────
-- crm_tasks
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS crm_tasks (
    id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    title            TEXT        NOT NULL DEFAULT '',
    description      TEXT        NOT NULL DEFAULT '',
    priority         TEXT        NOT NULL DEFAULT 'normal',
    status           TEXT        NOT NULL DEFAULT 'open',
    assigned_to_name TEXT        NOT NULL DEFAULT '',
    due_date         TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at     TIMESTAMPTZ,
    client_id        UUID,
    contact_id       UUID,
    opportunity_id   UUID,
    quote_id         UUID,
    project_id       UUID,
    assigned_to_id   UUID
);

ALTER TABLE crm_tasks
    ADD COLUMN IF NOT EXISTS description      TEXT        NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS assigned_to_name TEXT        NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS due_date         TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS completed_at     TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS client_id        UUID,
    ADD COLUMN IF NOT EXISTS contact_id       UUID,
    ADD COLUMN IF NOT EXISTS opportunity_id   UUID,
    ADD COLUMN IF NOT EXISTS quote_id         UUID,
    ADD COLUMN IF NOT EXISTS project_id       UUID,
    ADD COLUMN IF NOT EXISTS assigned_to_id   UUID;

CREATE INDEX IF NOT EXISTS idx_crm_tasks_assigned_to    ON crm_tasks (assigned_to_id);
CREATE INDEX IF NOT EXISTS idx_crm_tasks_status         ON crm_tasks (status);
CREATE INDEX IF NOT EXISTS idx_crm_tasks_due_date       ON crm_tasks (due_date);
CREATE INDEX IF NOT EXISTS idx_crm_tasks_opportunity_id ON crm_tasks (opportunity_id);

-- ─────────────────────────────────────────────
-- crm_activities
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS crm_activities (
    id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    type           TEXT        NOT NULL DEFAULT 'note_added',
    title          TEXT        NOT NULL DEFAULT '',
    notes          TEXT        NOT NULL DEFAULT '',
    date           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    user_name      TEXT        NOT NULL DEFAULT '',
    client_id      UUID,
    contact_id     UUID,
    opportunity_id UUID,
    quote_id       UUID,
    project_id     UUID
);

ALTER TABLE crm_activities
    ADD COLUMN IF NOT EXISTS notes         TEXT        NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS user_name     TEXT        NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS client_id     UUID,
    ADD COLUMN IF NOT EXISTS contact_id    UUID,
    ADD COLUMN IF NOT EXISTS opportunity_id UUID,
    ADD COLUMN IF NOT EXISTS quote_id      UUID,
    ADD COLUMN IF NOT EXISTS project_id    UUID;

CREATE INDEX IF NOT EXISTS idx_crm_activities_client_id      ON crm_activities (client_id);
CREATE INDEX IF NOT EXISTS idx_crm_activities_opportunity_id ON crm_activities (opportunity_id);
CREATE INDEX IF NOT EXISTS idx_crm_activities_date           ON crm_activities (date DESC);

-- ─────────────────────────────────────────────
-- crm_checklists
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS crm_checklists (
    id             UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    title          TEXT    NOT NULL DEFAULT '',
    is_done        BOOLEAN NOT NULL DEFAULT FALSE,
    opportunity_id UUID,
    project_id     UUID
);

ALTER TABLE crm_checklists
    ADD COLUMN IF NOT EXISTS is_done        BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS opportunity_id UUID,
    ADD COLUMN IF NOT EXISTS project_id     UUID;

CREATE INDEX IF NOT EXISTS idx_crm_checklists_opportunity_id ON crm_checklists (opportunity_id);
CREATE INDEX IF NOT EXISTS idx_crm_checklists_project_id     ON crm_checklists (project_id);

-- ─────────────────────────────────────────────
-- Realtime publication (required for live updates)
-- ─────────────────────────────────────────────

ALTER PUBLICATION supabase_realtime ADD TABLE crm_opportunities;
ALTER PUBLICATION supabase_realtime ADD TABLE crm_tasks;

-- ─────────────────────────────────────────────
-- Row Level Security
-- ─────────────────────────────────────────────

ALTER TABLE crm_contacts      ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_opportunities ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_tasks         ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_activities    ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_checklists    ENABLE ROW LEVEL SECURITY;

-- Allow authenticated users full access (tighten per-org in production)

CREATE POLICY "Authenticated users can read crm_contacts"
    ON crm_contacts FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated users can upsert crm_contacts"
    ON crm_contacts FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Authenticated users can update crm_contacts"
    ON crm_contacts FOR UPDATE TO authenticated USING (true);

CREATE POLICY "Authenticated users can read crm_opportunities"
    ON crm_opportunities FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated users can upsert crm_opportunities"
    ON crm_opportunities FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Authenticated users can update crm_opportunities"
    ON crm_opportunities FOR UPDATE TO authenticated USING (true);

CREATE POLICY "Authenticated users can read crm_tasks"
    ON crm_tasks FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated users can upsert crm_tasks"
    ON crm_tasks FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Authenticated users can update crm_tasks"
    ON crm_tasks FOR UPDATE TO authenticated USING (true);
CREATE POLICY "Authenticated users can delete crm_tasks"
    ON crm_tasks FOR DELETE TO authenticated USING (true);

CREATE POLICY "Authenticated users can read crm_activities"
    ON crm_activities FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated users can insert crm_activities"
    ON crm_activities FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY "Authenticated users can read crm_checklists"
    ON crm_checklists FOR SELECT TO authenticated USING (true);
CREATE POLICY "Authenticated users can upsert crm_checklists"
    ON crm_checklists FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Authenticated users can update crm_checklists"
    ON crm_checklists FOR UPDATE TO authenticated USING (true);
