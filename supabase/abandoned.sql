-- Abandoned checkouts: the shop saves the cart + delivery info once the customer typed a valid phone but did not send the order.
create table if not exists public.abandoned_carts(
  id bigserial primary key, store_id text not null, sid text not null,
  customer jsonb not null default '{}', items jsonb not null default '[]', total numeric default 0,
  status text not null default 'open' check (status in ('open','contacted','ordered')),
  order_id bigint, contacted_by text, created_at timestamptz default now(), updated_at timestamptz default now(),
  unique(store_id, sid));
create index if not exists abandoned_carts_store_idx on public.abandoned_carts(store_id, status, updated_at desc);
alter table public.abandoned_carts enable row level security;
drop policy if exists "staff read abandoned" on public.abandoned_carts;
create policy "staff read abandoned" on public.abandoned_carts for select using (store_id = public.my_store() and public.my_role() in ('owner','confirmer'));
drop policy if exists "staff update abandoned" on public.abandoned_carts;
create policy "staff update abandoned" on public.abandoned_carts for update using (store_id = public.my_store() and public.my_role() in ('owner','confirmer'));
drop policy if exists "staff delete abandoned" on public.abandoned_carts;
create policy "staff delete abandoned" on public.abandoned_carts for delete using (store_id = public.my_store() and public.my_role() in ('owner','confirmer'));

create or replace function public.save_abandoned(store text, sid text, customer jsonb, items jsonb, total numeric) returns void language plpgsql security definer set search_path = public as $$
#variable_conflict use_variable
declare ph text;
begin
  if store !~ '^[a-z0-9-]{1,40}$' or sid !~ '^[a-z0-9]{8,40}$' then return; end if;
  if not exists (select 1 from public.stores where id = store) then return; end if;
  ph := public.dz_phone(customer->>'phone'); if ph is null then return; end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 or jsonb_array_length(items) > 200 or length(items::text) > 100000 or length(customer::text) > 4000 then return; end if;
  customer := jsonb_set(customer, '{phone}', to_jsonb(ph));
  -- an order from this phone in the last hour means it was not abandoned
  if exists (select 1 from public.orders o where o.store_id = store and public.dz_phone(o.customer->>'phone') = ph and o.created_at > now() - interval '1 hour') then return; end if;
  insert into public.abandoned_carts(store_id, sid, customer, items, total)
    values (store, sid, customer, items, greatest(coalesce(total,0),0))
  on conflict on constraint abandoned_carts_store_id_sid_key do update set customer = excluded.customer, items = excluded.items, total = excluded.total, updated_at = now(),
    status = case when abandoned_carts.status = 'ordered' then 'open' else abandoned_carts.status end, order_id = case when abandoned_carts.status = 'ordered' then null else abandoned_carts.order_id end;
end $$;
revoke all on function public.save_abandoned(text, text, jsonb, jsonb, numeric) from public;
grant execute on function public.save_abandoned(text, text, jsonb, jsonb, numeric) to anon, authenticated;

-- when the customer orders, their open abandoned carts are marked as ordered
create or replace function public.abandoned_mark_ordered() returns trigger language plpgsql security definer set search_path = public as $$
declare ph text;
begin
  ph := public.dz_phone(new.customer->>'phone');
  if ph is not null then
    update public.abandoned_carts set status = 'ordered', order_id = new.id, updated_at = now()
      where store_id = new.store_id and status <> 'ordered' and customer->>'phone' = ph;
  end if;
  return new;
exception when others then return new;
end $$;
drop trigger if exists orders_abandoned on public.orders;
create trigger orders_abandoned after insert on public.orders for each row execute function public.abandoned_mark_ordered();
