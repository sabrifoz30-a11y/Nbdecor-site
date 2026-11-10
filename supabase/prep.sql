-- preparation checklist: per item {got, st:'ok'|'part'|'miss'}, keyed by item index
alter table public.orders add column if not exists prep jsonb not null default '{}'::jsonb;
alter table public.orders add column if not exists prepared_at timestamptz;
