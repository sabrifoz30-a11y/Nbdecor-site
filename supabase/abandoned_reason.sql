-- Why a checkout was abandoned: the shop saves where the customer stopped (why), staff note the reason given on the phone.
alter table public.abandoned_carts add column if not exists why jsonb, add column if not exists reason text, add column if not exists reason_note text;
create or replace function public.save_abandoned(store text, sid text, customer jsonb, items jsonb, total numeric) returns void language plpgsql security definer set search_path = public as $$
#variable_conflict use_variable
declare ph text; w jsonb;
begin
  if store !~ '^[a-z0-9-]{1,40}$' or sid !~ '^[a-z0-9]{8,40}$' then return; end if;
  if not exists (select 1 from public.stores where id = store) then return; end if;
  ph := public.dz_phone(customer->>'phone'); if ph is null then return; end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 or jsonb_array_length(items) > 200 or length(items::text) > 100000 or length(customer::text) > 4000 then return; end if;
  w := case when jsonb_typeof(customer->'why') = 'object' and length((customer->'why')::text) < 2000 then customer->'why' end;
  customer := jsonb_set(customer - 'why', '{phone}', to_jsonb(ph));
  -- an order from this phone in the last hour means it was not abandoned
  if exists (select 1 from public.orders o where o.store_id = store and public.dz_phone(o.customer->>'phone') = ph and o.created_at > now() - interval '1 hour') then return; end if;
  insert into public.abandoned_carts(store_id, sid, customer, items, total, why)
    values (store, sid, customer, items, greatest(coalesce(total,0),0), w)
  on conflict on constraint abandoned_carts_store_id_sid_key do update set why = coalesce(excluded.why, abandoned_carts.why), customer = excluded.customer, items = excluded.items, total = excluded.total, updated_at = now(),
    status = case when abandoned_carts.status = 'ordered' then 'open' else abandoned_carts.status end, order_id = case when abandoned_carts.status = 'ordered' then null else abandoned_carts.order_id end;
end $$;
revoke all on function public.save_abandoned(text, text, jsonb, jsonb, numeric) from public;
grant execute on function public.save_abandoned(text, text, jsonb, jsonb, numeric) to anon, authenticated;
