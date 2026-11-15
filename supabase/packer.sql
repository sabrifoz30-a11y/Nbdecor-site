-- Packing step: the packer decides how many parcels (and optionally the weight) of each ready order.
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('pending','owner','confirmer','preparer','driver','packer'));
alter table public.orders add column if not exists parcel_count int check (parcel_count is null or parcel_count between 1 and 50),
  add column if not exists weight_kg numeric(6,2), add column if not exists packed_at timestamptz, add column if not exists packed_by uuid references public.profiles(id);

drop policy if exists "packer reads ready and shipped" on public.orders;
create policy "packer reads ready and shipped" on public.orders for select
  using (store_id = public.my_store() and public.my_role() = 'packer' and status in ('ready','shipped'));

create or replace function public.pack_order(oid bigint, n int, kg numeric default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.orders; nm text;
begin
  if public.my_role() not in ('packer','owner') then raise exception 'not allowed'; end if;
  if n is null or n < 1 or n > 50 then raise exception 'bad parcels'; end if;
  select * into o from public.orders where id = oid and store_id = public.my_store() for update;
  if not found then raise exception 'no order'; end if;
  if o.status <> 'ready' then raise exception 'not ready'; end if;
  select name into nm from public.profiles where id = auth.uid();
  update public.orders set parcel_count = n, weight_kg = case when kg is null or kg <= 0 then null else kg end,
    packed_at = now(), packed_by = auth.uid(), updated_at = now(),
    history = history || jsonb_build_array(jsonb_build_object('at', now(), 'what', 'packed', 'by', nm, 'parcels', n, 'kg', kg))
  where id = oid returning * into o;
  return to_jsonb(o);
end $$;
revoke all on function public.pack_order(bigint, int, numeric) from public, anon;
grant execute on function public.pack_order(bigint, int, numeric) to authenticated;

-- staff accounts may now be packers
create or replace function public.admin_create_staff(p_name text, p_phone text, p_role text, p_password text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := gen_random_uuid(); em text; d text := regexp_replace(coalesce(p_phone,''),'\D','','g'); st text := public.my_store();
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'name required'; end if;
  if length(d) < 9 then raise exception 'bad phone'; end if;
  if p_role not in ('confirmer','preparer','driver','packer') then raise exception 'bad role'; end if;
  if length(coalesce(p_password,'')) < 6 then raise exception 'short password'; end if;
  em := public.staff_login_email(d);
  if exists (select 1 from auth.users where email = em) then raise exception 'phone exists'; end if;
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', em, crypt(p_password, gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('name', trim(p_name), 'phone', '0'||right(d,9), 'store_id', st), now(), now(), '', '', '', '');
  insert into auth.identities (user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (uid, uid::text, jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true), 'email', now(), now(), now());
  insert into public.profiles(id, name, phone, role, store_id) values (uid, trim(p_name), '0'||right(d,9), p_role, st)
    on conflict (id) do update set name = excluded.name, phone = excluded.phone, role = excluded.role, store_id = excluded.store_id;
  return uid;
end $$;
create or replace function public.admin_set_active(uid uuid, active boolean, p_role text default null) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  if not exists (select 1 from public.profiles where id = uid and store_id = public.my_store() and role <> 'owner') then raise exception 'not allowed'; end if;
  if active then
    if p_role not in ('confirmer','preparer','driver','packer') then raise exception 'bad role'; end if;
    update auth.users set banned_until = null where id = uid;
    update public.profiles set role = p_role where id = uid;
  else
    update auth.users set banned_until = 'infinity' where id = uid;
    delete from auth.sessions where user_id = uid;
    update public.profiles set role = 'pending' where id = uid;
  end if;
end $$;
