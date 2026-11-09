-- Delivery worker ("driver"): sees orders ready to hand to the carrier, photographs the bordereau, marks them sent.
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('pending','owner','confirmer','preparer','driver'));
alter table public.orders add column if not exists bordereau text, add column if not exists shipped_at timestamptz, add column if not exists shipped_by uuid references public.profiles(id);

drop policy if exists "driver reads ready and shipped" on public.orders;
create policy "driver reads ready and shipped" on public.orders for select
  using (public.my_role() = 'driver' and status in ('ready','shipped'));

drop policy if exists "see own or owner sees all" on public.profiles;
create policy "see own or owner sees all" on public.profiles for select using (id = auth.uid() or public.my_role() in ('owner','confirmer','preparer'));

create or replace function public.driver_ship(oid bigint, photo text, trk text default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.orders; nm text;
begin
  if public.my_role() not in ('driver','owner') then raise exception 'not allowed'; end if;
  if photo is null or photo !~ ('^bordereau/'||oid||'-[0-9]+\.jpg$') then raise exception 'photo required'; end if;
  select * into o from public.orders where id = oid for update;
  if not found then raise exception 'no order'; end if;
  if o.status <> 'ready' then raise exception 'not ready'; end if;
  select name into nm from public.profiles where id = auth.uid();
  update public.orders set status = 'shipped', bordereau = photo, tracking = nullif(trim(coalesce(trk,'')),''),
    shipped_at = now(), shipped_by = auth.uid(), updated_at = now(),
    history = history || jsonb_build_array(jsonb_build_object('at', now(), 'what', 'shipped', 'by', nm))
  where id = oid returning * into o;
  return to_jsonb(o);
end $$;
revoke all on function public.driver_ship(bigint,text,text) from public, anon;
grant execute on function public.driver_ship(bigint,text,text) to authenticated;

drop policy if exists "driver uploads bordereau" on storage.objects;
create policy "driver uploads bordereau" on storage.objects for insert to authenticated
  with check (bucket_id = 'proofs' and name like 'bordereau/%' and public.my_role() in ('driver','owner'));
drop policy if exists "driver reads bordereau" on storage.objects;
create policy "driver reads bordereau" on storage.objects for select to authenticated
  using (bucket_id = 'proofs' and name like 'bordereau/%' and public.my_role() = 'driver');
