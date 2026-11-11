-- owner's check of a receipt: 'ok' (correct) or 'bad' (wrong), with an optional note
alter table public.supplier_ledger add column if not exists checked text check (checked in ('ok','bad')), add column if not exists check_note text, add column if not exists checked_at timestamptz;
