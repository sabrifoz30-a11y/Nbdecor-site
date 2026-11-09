-- The owner creates worker accounts (login = phone number + password). No e-mail needed:
-- the account's internal e-mail is <phone>@nbdecor.invalid (reserved .invalid TLD, never receives mail).
create or replace function public.staff_login_email(p text) returns text language sql immutable as $$
  select '0'||right(regexp_replace(coalesce(p,''),'\D','','g'),9)||'@nbdecor.invalid' $$;
grant execute on function public.staff_login_email(text) to anon, authenticated;

create or replace function public.admin_create_staff(p_name text, p_phone text, p_role text, p_password text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := gen_random_uuid(); em text; d text := regexp_replace(coalesce(p_phone,''),'\D','','g');
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'name required'; end if;
  if length(d) < 9 then raise exception 'bad phone'; end if;
  if p_role not in ('confirmer','preparer','driver') then raise exception 'bad role'; end if;
  if length(coalesce(p_password,'')) < 6 then raise exception 'short password'; end if;
  em := public.staff_login_email(d);
  if exists (select 1 from auth.users where email = em) then raise exception 'phone exists'; end if;
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', em, crypt(p_password, gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('name', trim(p_name), 'phone', '0'||right(d,9)), now(), now(), '', '', '', '');
  insert into auth.identities (user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (uid, uid::text, jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true), 'email', now(), now(), now());
  insert into public.profiles(id, name, phone, role) values (uid, trim(p_name), '0'||right(d,9), p_role)
    on conflict (id) do update set name = excluded.name, phone = excluded.phone, role = excluded.role;
  return uid;
end $$;

create or replace function public.admin_set_password(uid uuid, p_password text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  if length(coalesce(p_password,'')) < 6 then raise exception 'short password'; end if;
  if (select role from public.profiles where id = uid) = 'owner' then raise exception 'not allowed'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = uid;
end $$;

-- stop / restart a worker: blocks login and removes access, keeps their history on orders
create or replace function public.admin_set_active(uid uuid, active boolean, p_role text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  if (select role from public.profiles where id = uid) = 'owner' then raise exception 'not allowed'; end if;
  if active then
    if p_role not in ('confirmer','preparer','driver') then raise exception 'bad role'; end if;
    update auth.users set banned_until = null where id = uid;
    update public.profiles set role = p_role where id = uid;
  else
    update auth.users set banned_until = 'infinity' where id = uid;
    delete from auth.sessions where user_id = uid;
    update public.profiles set role = 'pending' where id = uid;
  end if;
end $$;

create or replace function public.admin_staff_status() returns table(id uuid, login text, banned boolean)
language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  return query select u.id, case when u.email like '%@nbdecor.invalid' then split_part(u.email,'@',1) else u.email::text end, coalesce(u.banned_until > now(), false) from auth.users u;
end $$;

revoke all on function public.admin_create_staff(text,text,text,text) from public, anon;
revoke all on function public.admin_set_password(uuid,text) from public, anon;
revoke all on function public.admin_set_active(uuid,boolean,text) from public, anon;
revoke all on function public.admin_staff_status() from public, anon;
grant execute on function public.admin_create_staff(text,text,text,text) to authenticated;
grant execute on function public.admin_set_password(uuid,text) to authenticated;
grant execute on function public.admin_set_active(uuid,boolean,text) to authenticated;
grant execute on function public.admin_staff_status() to authenticated;
