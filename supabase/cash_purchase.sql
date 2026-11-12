-- cash purchase: recorded with its receipt, does not change what you owe the supplier
alter table public.supplier_ledger drop constraint if exists supplier_ledger_kind_check;
alter table public.supplier_ledger add constraint supplier_ledger_kind_check check (kind in ('buy','pay','cash'));

alter table public.order_purchases add column if not exists kind text not null default 'buy';
drop function if exists public.record_purchase(bigint, jsonb);
create or replace function public.record_purchase(oid bigint, lines jsonb, k text default 'buy') returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.orders; s record; nm text; tot int := 0; st text := public.my_store();
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  if k not in ('buy','cash') then raise exception 'bad kind'; end if;
  select * into o from public.orders where id = oid and store_id = st for update;
  if not found then raise exception 'no order'; end if;
  if exists (select 1 from public.order_purchases where order_id = oid) then raise exception 'already recorded'; end if;
  select name into nm from public.profiles where id = auth.uid();
  for s in select (l->>'supplier_id')::bigint sid, sum((l->>'cost')::int * (l->>'qty')::int)::int amt from jsonb_array_elements(lines) l
           where (l->>'supplier_id') is not null group by 1 loop
    if not exists (select 1 from public.suppliers where id = s.sid and store_id = st) then raise exception 'bad supplier'; end if;
    if s.amt > 0 then insert into public.supplier_ledger(store_id, supplier_id, kind, amount, order_id, note, by_name) values (st, s.sid, k, s.amt, oid, 'طلبية #'||oid, nm); tot := tot + s.amt; end if;
  end loop;
  insert into public.order_purchases(store_id, order_id, cost, lines, by_name, kind) values (st, oid, tot, lines, nm, k);
  return jsonb_build_object('cost', tot);
end $$;
revoke all on function public.record_purchase(bigint, jsonb, text) from public, anon;
grant execute on function public.record_purchase(bigint, jsonb, text) to authenticated;
