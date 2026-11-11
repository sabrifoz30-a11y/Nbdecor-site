-- photo of the supplier's receipt on a ledger entry; private bucket, owner only
alter table public.supplier_ledger add column if not exists photo text;
insert into storage.buckets (id, name, public) values ('receipts','receipts',false) on conflict (id) do nothing;
drop policy if exists "owner receipts insert" on storage.objects;
create policy "owner receipts insert" on storage.objects for insert to authenticated with check (bucket_id='receipts' and public.my_role()='owner');
drop policy if exists "owner receipts read" on storage.objects;
create policy "owner receipts read" on storage.objects for select to authenticated using (bucket_id='receipts' and public.my_role()='owner');
drop policy if exists "owner receipts delete" on storage.objects;
create policy "owner receipts delete" on storage.objects for delete to authenticated using (bucket_id='receipts' and public.my_role()='owner');
