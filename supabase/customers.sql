-- Customer file: one row per phone number, filled automatically from orders; stats computed from orders.
create or replace function public.norm_phone(p text) returns text language sql immutable as $$
  select case when length(regexp_replace(coalesce(p,''),'\D','','g')) >= 9 then '0'||right(regexp_replace(coalesce(p,''),'\D','','g'),9) end $$;

create table if not exists public.customers (
  phone text primary key,
  name text, wilaya text, address text, shop text,
  notes jsonb not null default '[]'::jsonb,
  blacklist boolean not null default false, blacklist_reason text,
  created_at timestamptz default now(), updated_at timestamptz default now()
);
alter table public.customers enable row level security;
drop policy if exists "staff read customers" on public.customers;
create policy "staff read customers" on public.customers for select using (public.my_role() in ('owner','confirmer'));
drop policy if exists "staff write customers" on public.customers;
create policy "staff write customers" on public.customers for insert with check (public.my_role() in ('owner','confirmer'));
drop policy if exists "staff update customers" on public.customers;
create policy "staff update customers" on public.customers for update using (public.my_role() in ('owner','confirmer')) with check (public.my_role() in ('owner','confirmer'));
drop policy if exists "owner deletes customers" on public.customers;
create policy "owner deletes customers" on public.customers for delete using (public.my_role() = 'owner');

create index if not exists orders_phone_idx on public.orders (public.norm_phone(customer->>'phone'));

create or replace function public.customer_from_order() returns trigger language plpgsql security definer set search_path = public as $$
declare ph text := public.norm_phone(new.customer->>'phone');
begin
  if ph is null then return new; end if;
  insert into public.customers(phone, name, wilaya, address)
  values (ph, nullif(trim(new.customer->>'name'),''), nullif(new.customer->>'wilaya',''), nullif(trim(new.customer->>'address'),''))
  on conflict (phone) do update set
    name = coalesce(public.customers.name, excluded.name),
    wilaya = coalesce(excluded.wilaya, public.customers.wilaya),
    address = coalesce(excluded.address, public.customers.address),
    updated_at = now();
  return new;
end $$;
drop trigger if exists customer_from_order on public.orders;
create trigger customer_from_order after insert on public.orders for each row execute function public.customer_from_order();

-- backfill from existing orders (oldest first so the latest address wins)
insert into public.customers(phone, name, wilaya, address, created_at)
select distinct on (public.norm_phone(customer->>'phone')) public.norm_phone(customer->>'phone'), nullif(trim(customer->>'name'),''), nullif(customer->>'wilaya',''), nullif(trim(customer->>'address'),''), created_at
from public.orders where public.norm_phone(customer->>'phone') is not null
order by public.norm_phone(customer->>'phone'), created_at desc
on conflict (phone) do nothing;

create or replace function public.customers_list() returns table(phone text, name text, wilaya text, shop text, blacklist boolean,
  orders int, spent bigint, delivered int, returned int, first_order timestamptz, last_order timestamptz, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if public.my_role() not in ('owner','confirmer') then raise exception 'not allowed'; end if;
  return query
  select c.phone, c.name, c.wilaya, c.shop, c.blacklist,
    coalesce(count(o.id) filter (where o.status <> 'cancelled'),0)::int,
    coalesce(sum(o.total) filter (where o.status not in ('cancelled','returned')),0)::bigint,
    coalesce(count(o.id) filter (where o.status = 'delivered'),0)::int,
    coalesce(count(o.id) filter (where o.status = 'returned'),0)::int,
    min(o.created_at), max(o.created_at), c.created_at
  from public.customers c left join public.orders o on public.norm_phone(o.customer->>'phone') = c.phone
  group by c.phone order by max(o.created_at) desc nulls last, c.created_at desc;
end $$;
revoke all on function public.customers_list() from public, anon;
grant execute on function public.customers_list() to authenticated;
