-- communes (البلديات) per delivery company, synced from the carrier; the shop reads them publicly
create table if not exists public.communes (
  store_id text not null references public.stores(id) on delete cascade default public.my_store(),
  company_id text not null, wilaya int not null, name text not null, postal text, desk boolean not null default false,
  primary key (store_id, company_id, wilaya, name));
alter table public.communes enable row level security;
drop policy if exists "read communes" on public.communes;
create policy "read communes" on public.communes for select using (true);
drop policy if exists "owner writes communes" on public.communes;
create policy "owner writes communes" on public.communes for all using (store_id = public.my_store() and public.my_role()='owner') with check (store_id = public.my_store() and public.my_role()='owner');
