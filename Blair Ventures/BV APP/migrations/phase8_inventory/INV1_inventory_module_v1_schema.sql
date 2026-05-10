-- =========================================================
-- INVENTORY MODULE v1 — Phase 8, kicks off post-stabilization
-- =========================================================
-- Purpose:
--   Stand up the foundational inventory schema referenced by the FUTURE
--   marker comment in `Procurement.swift::submitMaterialRequest` (around
--   line 442). The module tracks stockable SKUs, where they live, how
--   much is on hand, and movements between locations or out to projects.
--
-- v1 scope:
--   - inventory_items        — stockable SKUs (cost code, unit, default
--                              location, optional product_service link)
--   - stock_locations        — warehouse / yard / project staging
--   - inventory_stock_levels — qty-on-hand per (item × location)
--   - inventory_transfers    — movement audit trail
--
-- Deferred to v2 (out of scope for this migration):
--   - Reservations (hold-for-planned-project)
--   - Low-stock thresholds + reorder automation
--   - Multi-unit conversions (kg vs tonne, ea vs case)
--   - Barcode scanning + lookup
--
-- Multi-tenancy: every table has company_id NOT NULL with FK + RLS so a
-- field worker in Company A can never see Company B's stock. The pattern
-- mirrors what procurement uses.
--
-- Soft-delete: standard (is_deleted / deleted_at / deleted_by) on every
-- table. The Phase 5 / Wave 1 soft-delete-aware partial UNIQUE pattern
-- applies on inventory_items.sku.

-- =========================================================
-- 1. inventory_items
-- =========================================================
create table if not exists public.inventory_items (
    id              uuid primary key default gen_random_uuid(),
    company_id      uuid not null references public.companies(id) on delete cascade,
    sku             text not null,
    name            text not null,
    description     text,
    unit            text not null default 'ea',  -- 'ea', 'kg', 'l', 'box', 'm', etc.
    cost_code       text not null default '',
    -- Optional: link to product_services so estimating can suggest
    -- inventory items that match a line item's product/service.
    product_service_id uuid references public.product_services(id) on delete set null,
    -- Default location new stock arrives at (e.g. "Main Yard").
    default_location_id uuid,  -- FK added below after stock_locations is created
    -- Cost basis snapshot — actual valuation lives in stock_levels (per-
    -- location avg cost). This is the catalog price used for new arrivals.
    standard_cost   numeric(12,2),
    is_active       boolean not null default true,
    notes           text,

    -- Audit + soft-delete (matches the pattern from soft-delete migration)
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    last_modified_by text not null default '',
    last_modified_at timestamptz not null default now(),
    sync_status     text not null default 'synced',
    is_deleted      boolean not null default false,
    deleted_at      timestamptz,
    deleted_by      text
);

-- Per-(company, sku) unique on live rows; mirrors Phase 3 pattern.
drop index if exists public.inventory_items_company_sku_unique;
create unique index inventory_items_company_sku_unique
    on public.inventory_items (company_id, sku)
    where is_deleted = false;

-- =========================================================
-- 2. stock_locations
-- =========================================================
create table if not exists public.stock_locations (
    id            uuid primary key default gen_random_uuid(),
    company_id    uuid not null references public.companies(id) on delete cascade,
    name          text not null,
    code          text not null default '',  -- short code e.g. "MAIN", "YARD-N"
    description   text,
    location_type text not null default 'warehouse',  -- 'warehouse', 'yard', 'site_staging', 'mobile'
    address       text,
    is_active     boolean not null default true,
    is_default    boolean not null default false,  -- 1 default location per company

    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    last_modified_by text not null default '',
    last_modified_at timestamptz not null default now(),
    sync_status   text not null default 'synced',
    is_deleted    boolean not null default false,
    deleted_at    timestamptz,
    deleted_by    text
);

-- Per-(company, code) unique on live rows for quick lookups.
drop index if exists public.stock_locations_company_code_unique;
create unique index stock_locations_company_code_unique
    on public.stock_locations (company_id, code)
    where is_deleted = false and code <> '';

-- One default location per company (partial unique).
drop index if exists public.stock_locations_one_default_per_company;
create unique index stock_locations_one_default_per_company
    on public.stock_locations (company_id)
    where is_default = true and is_deleted = false;

-- Now backfill the FK on inventory_items.default_location_id
do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conname = 'inventory_items_default_location_fkey'
    ) then
        alter table public.inventory_items
            add constraint inventory_items_default_location_fkey
            foreign key (default_location_id)
            references public.stock_locations(id) on delete set null;
    end if;
end $$;

-- =========================================================
-- 3. inventory_stock_levels — qty-on-hand per (item × location)
-- =========================================================
create table if not exists public.inventory_stock_levels (
    id            uuid primary key default gen_random_uuid(),
    company_id    uuid not null references public.companies(id) on delete cascade,
    item_id       uuid not null references public.inventory_items(id) on delete cascade,
    location_id   uuid not null references public.stock_locations(id) on delete cascade,
    quantity_on_hand numeric(14,3) not null default 0,
    -- Per-location average cost — moves with each receipt at standard_cost
    -- via weighted-average. v2 will track method (avg vs FIFO) explicitly.
    avg_unit_cost numeric(12,2),
    last_counted_at timestamptz,  -- physical count timestamp
    last_counted_by text,
    notes         text,

    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    last_modified_by text not null default '',
    last_modified_at timestamptz not null default now(),
    sync_status   text not null default 'synced',
    is_deleted    boolean not null default false,
    deleted_at    timestamptz,
    deleted_by    text
);

-- Each item exists in each location at most once (live rows).
drop index if exists public.inventory_stock_levels_item_location_unique;
create unique index inventory_stock_levels_item_location_unique
    on public.inventory_stock_levels (item_id, location_id)
    where is_deleted = false;

-- Hot-path index: company-scoped lookups by item.
create index if not exists inventory_stock_levels_company_item_idx
    on public.inventory_stock_levels (company_id, item_id)
    where is_deleted = false;

-- =========================================================
-- 4. inventory_transfers — movement audit trail
-- =========================================================
create table if not exists public.inventory_transfers (
    id              uuid primary key default gen_random_uuid(),
    company_id      uuid not null references public.companies(id) on delete cascade,
    transfer_number text not null,  -- BV-XFR-2026-0001
    item_id         uuid not null references public.inventory_items(id) on delete cascade,

    -- Source: location (always required for outbound moves)
    from_location_id uuid not null references public.stock_locations(id) on delete restrict,

    -- Destination: EITHER another location (location-to-location move)
    -- OR a project (issue-out — quantity leaves inventory permanently)
    -- OR a material_request (filled from inventory rather than purchased).
    -- Exactly one of {to_location_id, to_project_id, to_material_request_id}
    -- must be non-null (enforced via CHECK below).
    to_location_id        uuid references public.stock_locations(id) on delete restrict,
    to_project_id         uuid references public.projects(id) on delete set null,
    to_material_request_id uuid references public.material_requests(id) on delete set null,

    quantity      numeric(14,3) not null check (quantity > 0),
    unit_cost     numeric(12,2),  -- snapshotted from source location's avg_unit_cost at transfer time
    notes         text,
    transferred_by_name text not null default '',
    transferred_at timestamptz not null default now(),

    -- Audit + soft-delete
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    last_modified_by text not null default '',
    last_modified_at timestamptz not null default now(),
    sync_status   text not null default 'synced',
    is_deleted    boolean not null default false,
    deleted_at    timestamptz,
    deleted_by    text
);

-- Exactly one destination must be set.
alter table public.inventory_transfers
    drop constraint if exists inventory_transfers_single_destination;
alter table public.inventory_transfers
    add constraint inventory_transfers_single_destination
    check (
        (to_location_id is not null)::int +
        (to_project_id  is not null)::int +
        (to_material_request_id is not null)::int = 1
    );

-- Per-(company, transfer_number) unique on live rows; mirrors the Phase 3
-- pattern for material_request_number / po_number.
drop index if exists public.inventory_transfers_company_number_unique;
create unique index inventory_transfers_company_number_unique
    on public.inventory_transfers (company_id, transfer_number)
    where is_deleted = false;

-- Hot-path indexes for dashboards
create index if not exists inventory_transfers_company_transferred_idx
    on public.inventory_transfers (company_id, transferred_at desc)
    where is_deleted = false;
create index if not exists inventory_transfers_item_idx
    on public.inventory_transfers (item_id, transferred_at desc)
    where is_deleted = false;

-- =========================================================
-- 5. RLS — tenant isolation
-- =========================================================
-- Same pattern as procurement: every read/write goes through
-- get_my_company_id() which is set by the auth path.

alter table public.inventory_items         enable row level security;
alter table public.stock_locations         enable row level security;
alter table public.inventory_stock_levels  enable row level security;
alter table public.inventory_transfers     enable row level security;

-- Generic "you can read/write your company's rows" policy per table.
do $$
declare t text;
begin
    for t in select unnest(array[
        'inventory_items','stock_locations',
        'inventory_stock_levels','inventory_transfers'
    ])
    loop
        execute format(
            'drop policy if exists %I_company_isolation on public.%I',
            t, t
        );
        execute format(
            'create policy %I_company_isolation on public.%I '
            'for all using (company_id = public.get_my_company_id()) '
            'with check (company_id = public.get_my_company_id())',
            t, t
        );
    end loop;
end $$;

-- =========================================================
-- 6. Update trigger — auto-stamp updated_at on every row mutation.
-- =========================================================
do $$
declare t text;
begin
    for t in select unnest(array[
        'inventory_items','stock_locations',
        'inventory_stock_levels','inventory_transfers'
    ])
    loop
        execute format(
            'drop trigger if exists set_updated_at on public.%I',
            t
        );
        execute format(
            'create trigger set_updated_at before update on public.%I '
            'for each row execute function public.set_updated_at()',
            t
        );
    end loop;
end $$;

-- =========================================================
-- 7. Default seed — create one default stock location per company
-- =========================================================
-- Idempotent: skip companies that already have a default location.
insert into public.stock_locations
    (company_id, name, code, location_type, is_default, is_active)
select
    c.id,
    'Main Yard',
    'MAIN',
    'yard',
    true,
    true
from public.companies c
where not exists (
    select 1 from public.stock_locations sl
    where sl.company_id = c.id
      and sl.is_default = true
      and sl.is_deleted = false
);

-- =========================================================
-- 8. Function privilege hardening (mirrors SEC1+SEC3 pattern)
-- =========================================================
-- The set_updated_at trigger function should not be callable via REST.
-- It's already locked down by SEC1/SEC2/SEC3, so this is a no-op
-- comment for traceability — the policy is inherited.

comment on table public.inventory_items is
    'Stockable SKUs per company. Phase 8 / Inventory v1.';
comment on table public.stock_locations is
    'Where inventory lives — yards, warehouses, mobile units. Phase 8.';
comment on table public.inventory_stock_levels is
    'Quantity-on-hand per (item × location). Updated by inventory_transfers and physical counts.';
comment on table public.inventory_transfers is
    'Audit trail of every inventory movement. Single destination per row (location, project, or material_request).';
