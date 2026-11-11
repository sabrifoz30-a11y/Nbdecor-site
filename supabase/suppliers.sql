-- Suppliers, purchase prices and supplier credit. Owner only (never in the public products table).
create table if not exists public.suppliers (id bigserial primary key, name text not null, phone text, place text, notes text, created_at timestamptz default now());
create table if not exists public.product_costs (product_id text not null references public.products(id) on delete cascade, supplier_id bigint not null references public.suppliers(id) on delete cascade,
  cost int not null check (cost >= 0), is_main boolean not null default false, updated_at timestamptz default now(), primary key (product_id, supplier_id));
create table if not exists public.cost_history (id bigserial primary key, product_id text not null, supplier_id bigint, cost int, at timestamptz default now());
create table if not exists public.supplier_ledger (id bigserial primary key, supplier_id bigint not null references public.suppliers(id) on delete cascade,
  kind text not null check (kind in ('buy','pay')), amount int not null check (amount > 0), order_id bigint references public.orders(id) on delete set null,
  note text, at timestamptz default now(), by_name text);
-- kept out of orders, which workers can read
create table if not exists public.order_purchases (order_id bigint primary key references public.orders(id) on delete cascade, cost int not null, lines jsonb not null, at timestamptz default now(), by_name text);

do $$ declare t text; begin
  foreach t in array array['suppliers','product_costs','cost_history','supplier_ledger','order_purchases'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "owner only" on public.%I', t);
    execute format('create policy "owner only" on public.%I for all using (public.my_role() = ''owner'') with check (public.my_role() = ''owner'')', t);
  end loop; end $$;

create or replace function public.cost_hist() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.cost is distinct from old.cost then
    insert into public.cost_history(product_id, supplier_id, cost) values (new.product_id, new.supplier_id, new.cost);
  end if; return new;
end $$;
drop trigger if exists cost_hist on public.product_costs;
create trigger cost_hist after insert or update on public.product_costs for each row execute function public.cost_hist();

-- record what an order cost: one 'buy' entry per supplier (credit), once per order
create or replace function public.record_purchase(oid bigint, lines jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.orders; s record; nm text; tot int := 0;
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  select * into o from public.orders where id = oid for update;
  if not found then raise exception 'no order'; end if;
  if exists (select 1 from public.order_purchases where order_id = oid) then raise exception 'already recorded'; end if;
  select name into nm from public.profiles where id = auth.uid();
  for s in select (l->>'supplier_id')::bigint sid, sum((l->>'cost')::int * (l->>'qty')::int)::int amt from jsonb_array_elements(lines) l
           where (l->>'supplier_id') is not null group by 1 loop
    if s.amt > 0 then insert into public.supplier_ledger(supplier_id, kind, amount, order_id, note, by_name) values (s.sid, 'buy', s.amt, oid, 'طلبية #'||oid, nm); tot := tot + s.amt; end if;
  end loop;
  insert into public.order_purchases(order_id, cost, lines, by_name) values (oid, tot, lines, nm);
  return jsonb_build_object('cost', tot);
end $$;
revoke all on function public.record_purchase(bigint, jsonb) from public, anon;
grant execute on function public.record_purchase(bigint, jsonb) to authenticated;

alter table public.orders drop column if exists purchase;
