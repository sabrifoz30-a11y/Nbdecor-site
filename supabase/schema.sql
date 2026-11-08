-- nbdecor: products, settings, staff profiles, orders
create table if not exists public.settings (id int primary key default 1, data jsonb not null default '{}'::jsonb, updated_at timestamptz default now(), constraint one_row check (id = 1));
create table if not exists public.products (id text primary key, ref text, cat text, sort_ref text, data jsonb not null, updated_at timestamptz default now());
create table if not exists public.profiles (id uuid primary key references auth.users(id) on delete cascade, name text, phone text, role text not null default 'pending' check (role in ('pending','owner','confirmer','preparer')), created_at timestamptz default now());
create sequence if not exists public.order_no start 1001;
create table if not exists public.orders (
  id bigint primary key default nextval('public.order_no'),
  created_at timestamptz default now(),
  status text not null default 'new' check (status in ('new','confirming','confirmed','preparing','missing','ready','shipped','delivered','returned','cancelled')),
  customer jsonb not null,
  items jsonb not null,
  total int not null default 0,
  shipping int not null default 0,
  parcels jsonb not null default '[]'::jsonb,
  proof text,
  notes text,
  tracking text,
  confirmed_by uuid references public.profiles(id),
  prepared_by uuid references public.profiles(id),
  history jsonb not null default '[]'::jsonb,
  updated_at timestamptz default now()
);

create or replace function public.my_role() returns text language sql stable security definer set search_path = public as $$
  select coalesce((select role from public.profiles where id = auth.uid()), 'anon') $$;

-- new auth users get a pending profile; the very first user becomes owner
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, name, role)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1)),
          case when not exists (select 1 from public.profiles where role='owner') then 'owner' else 'pending' end)
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- customers place orders only through this function (validated, numbered)
create or replace function public.place_order(customer jsonb, items jsonb) returns bigint language plpgsql security definer set search_path = public as $$
declare oid bigint; tot int := 0; it jsonb;
begin
  if coalesce(trim(customer->>'name'),'') = '' or length(regexp_replace(coalesce(customer->>'phone',''),'\D','','g')) < 9 then raise exception 'missing customer info'; end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 or jsonb_array_length(items) > 300 then raise exception 'bad items'; end if;
  for it in select * from jsonb_array_elements(items) loop
    tot := tot + greatest(0, coalesce((it->>'price')::int,0)) * greatest(1, coalesce((it->>'qty')::int,1));
  end loop;
  insert into public.orders(customer, items, total, history)
  values (customer, items, tot, jsonb_build_array(jsonb_build_object('at', now(), 'what', 'new')))
  returning id into oid;
  return oid;
end $$;
grant execute on function public.place_order(jsonb, jsonb) to anon, authenticated;

alter table public.settings enable row level security;
alter table public.products enable row level security;
alter table public.profiles enable row level security;
alter table public.orders enable row level security;

drop policy if exists "read settings" on public.settings;
create policy "read settings" on public.settings for select using (true);
drop policy if exists "owner writes settings" on public.settings;
create policy "owner writes settings" on public.settings for all using (public.my_role()='owner') with check (public.my_role()='owner');

drop policy if exists "read products" on public.products;
create policy "read products" on public.products for select using (true);
drop policy if exists "owner writes products" on public.products;
create policy "owner writes products" on public.products for all using (public.my_role()='owner') with check (public.my_role()='owner');

drop policy if exists "see own or owner sees all" on public.profiles;
create policy "see own or owner sees all" on public.profiles for select using (id = auth.uid() or public.my_role() in ('owner','confirmer','preparer'));
drop policy if exists "owner manages staff" on public.profiles;
create policy "owner manages staff" on public.profiles for update using (public.my_role()='owner') with check (public.my_role()='owner');

drop policy if exists "staff read orders" on public.orders;
create policy "staff read orders" on public.orders for select using (public.my_role() in ('owner','confirmer','preparer'));
drop policy if exists "staff update orders" on public.orders;
create policy "staff update orders" on public.orders for update using (public.my_role() in ('owner','confirmer','preparer')) with check (public.my_role() in ('owner','confirmer','preparer'));
drop policy if exists "owner deletes orders" on public.orders;
create policy "owner deletes orders" on public.orders for delete using (public.my_role()='owner');

-- storage: product photos (public) and confirmation screenshots (staff only)
insert into storage.buckets (id, name, public) values ('products','products',true) on conflict (id) do nothing;
insert into storage.buckets (id, name, public) values ('proofs','proofs',false) on conflict (id) do nothing;
drop policy if exists "owner uploads product photos" on storage.objects;
create policy "owner uploads product photos" on storage.objects for insert to authenticated with check (bucket_id='products' and public.my_role()='owner');
drop policy if exists "owner edits product photos" on storage.objects;
create policy "owner edits product photos" on storage.objects for update to authenticated using (bucket_id='products' and public.my_role()='owner');
drop policy if exists "staff upload proofs" on storage.objects;
create policy "staff upload proofs" on storage.objects for insert to authenticated with check (bucket_id='proofs' and public.my_role() in ('owner','confirmer'));
drop policy if exists "staff read proofs" on storage.objects;
create policy "staff read proofs" on storage.objects for select to authenticated using (bucket_id='proofs' and public.my_role() in ('owner','confirmer'));

-- v2: no automatic owner; the owner is promoted by hand after signing up
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, name, phone, role)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1)), new.raw_user_meta_data->>'phone', 'pending')
  on conflict (id) do nothing;
  return new;
end $$;
