-- ============ Multi-store foundation ============
-- Every row belongs to a store. A user (owner or worker) belongs to one store (profiles.store_id).
-- The current shop becomes store 'nbdecor'. Nothing changes for it.

create table if not exists public.stores (
  id text primary key check (id ~ '^[a-z0-9][a-z0-9-]{1,39}$'),
  name text not null,
  owner_id uuid references auth.users(id) on delete set null,
  status text not null default 'active' check (status in ('active','trial','suspended')),
  plan text, created_at timestamptz default now()
);
insert into public.stores(id, name, owner_id)
  select 'nbdecor', 'ورد الجملة', (select id from public.profiles where role='owner' order by created_at limit 1)
  on conflict (id) do nothing;
alter table public.stores enable row level security;
drop policy if exists "read stores" on public.stores;
create policy "read stores" on public.stores for select using (true);

alter table public.profiles add column if not exists store_id text references public.stores(id);
update public.profiles set store_id = 'nbdecor' where store_id is null;

create or replace function public.my_store() returns text language sql stable security definer set search_path = public as $$
  select store_id from public.profiles where id = auth.uid() $$;
-- role inside my store (a user without a store has no role)
create or replace function public.my_role() returns text language sql stable security definer set search_path = public as $$
  select coalesce((select role from public.profiles where id = auth.uid() and store_id is not null), 'anon') $$;

-- store_id on every data table; existing rows -> nbdecor; new rows default to the caller's store
do $$ declare t text; begin
  foreach t in array array['products','orders','customers','suppliers','product_costs','cost_history','supplier_ledger','order_purchases','secrets','capi_log','settings'] loop
    execute format('alter table public.%I add column if not exists store_id text references public.stores(id) on delete cascade', t);
    execute format('update public.%I set store_id = ''nbdecor'' where store_id is null', t);
    execute format('alter table public.%I alter column store_id set default public.my_store()', t);
    execute format('alter table public.%I alter column store_id set not null', t);
    execute format('create index if not exists %I on public.%I(store_id)', t||'_store_idx', t);
  end loop; end $$;

-- settings: one row per store
alter table public.settings drop constraint if exists settings_pkey;
alter table public.settings alter column id drop not null;
alter table public.settings add primary key (store_id);
-- secrets: key unique per store
alter table public.secrets drop constraint if exists secrets_pkey;
alter table public.secrets add primary key (store_id, key);
-- customers: phone unique per store
alter table public.customers drop constraint if exists customers_pkey;
alter table public.customers add primary key (store_id, phone);

-- ---------- RLS: same rules as before, limited to my store ----------
drop policy if exists "owner reads capi log" on public.capi_log;
create policy "owner reads capi log" on public.capi_log for select using (store_id = public.my_store() and public.my_role()='owner');
do $$ declare t text; begin
  foreach t in array array['cost_history','order_purchases','product_costs','supplier_ledger','suppliers'] loop
    execute format('drop policy if exists "owner only" on public.%I', t);
    execute format('create policy "owner only" on public.%I for all using (store_id = public.my_store() and public.my_role() = ''owner'') with check (store_id = public.my_store() and public.my_role() = ''owner'')', t);
  end loop; end $$;
drop policy if exists "owner deletes customers" on public.customers;
create policy "owner deletes customers" on public.customers for delete using (store_id = public.my_store() and public.my_role()='owner');
drop policy if exists "staff read customers" on public.customers;
create policy "staff read customers" on public.customers for select using (store_id = public.my_store() and public.my_role() in ('owner','confirmer'));
drop policy if exists "staff update customers" on public.customers;
create policy "staff update customers" on public.customers for update using (store_id = public.my_store() and public.my_role() in ('owner','confirmer')) with check (store_id = public.my_store() and public.my_role() in ('owner','confirmer'));
drop policy if exists "staff write customers" on public.customers;
create policy "staff write customers" on public.customers for insert with check (store_id = public.my_store() and public.my_role() in ('owner','confirmer'));
drop policy if exists "driver reads ready and shipped" on public.orders;
create policy "driver reads ready and shipped" on public.orders for select using (store_id = public.my_store() and public.my_role()='driver' and status in ('ready','shipped'));
drop policy if exists "owner deletes orders" on public.orders;
create policy "owner deletes orders" on public.orders for delete using (store_id = public.my_store() and public.my_role()='owner');
drop policy if exists "staff read orders" on public.orders;
create policy "staff read orders" on public.orders for select using (store_id = public.my_store() and public.my_role() in ('owner','confirmer','preparer'));
drop policy if exists "staff update orders" on public.orders;
create policy "staff update orders" on public.orders for update using (store_id = public.my_store() and public.my_role() in ('owner','confirmer','preparer')) with check (store_id = public.my_store() and public.my_role() in ('owner','confirmer','preparer'));
drop policy if exists "owner writes products" on public.products;
create policy "owner writes products" on public.products for all using (store_id = public.my_store() and public.my_role()='owner') with check (store_id = public.my_store() and public.my_role()='owner');
drop policy if exists "owner manages staff" on public.profiles;
create policy "owner manages staff" on public.profiles for update using (store_id = public.my_store() and public.my_role()='owner' and role <> 'owner') with check (store_id = public.my_store() and role <> 'owner');
drop policy if exists "see own or owner sees all" on public.profiles;
create policy "see own or owner sees all" on public.profiles for select using (id = auth.uid() or (store_id = public.my_store() and public.my_role() in ('owner','confirmer','preparer')));
drop policy if exists "owner writes settings" on public.settings;
create policy "owner writes settings" on public.settings for all using (store_id = public.my_store() and public.my_role()='owner') with check (store_id = public.my_store() and public.my_role()='owner');
-- products and settings stay publicly readable (the shop needs them); the shop filters by store

-- ---------- storage: files live under <store>/...; older files (no store folder) belong to nbdecor ----------
create or replace function public.path_store(p text) returns text language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from public.stores s where s.id = split_part(p,'/',1)) then split_part(p,'/',1) else 'nbdecor' end $$;
drop policy if exists "driver reads bordereau" on storage.objects;
create policy "driver reads bordereau" on storage.objects for select to authenticated using (bucket_id='proofs' and name like '%bordereau/%' and public.path_store(name)=public.my_store() and public.my_role()='driver');
drop policy if exists "driver uploads bordereau" on storage.objects;
create policy "driver uploads bordereau" on storage.objects for insert to authenticated with check (bucket_id='proofs' and name like '%bordereau/%' and public.path_store(name)=public.my_store() and public.my_role() in ('driver','owner'));
drop policy if exists "owner edits product photos" on storage.objects;
create policy "owner edits product photos" on storage.objects for update to authenticated using (bucket_id='products' and public.path_store(name)=public.my_store() and public.my_role()='owner');
drop policy if exists "owner uploads product photos" on storage.objects;
create policy "owner uploads product photos" on storage.objects for insert to authenticated with check (bucket_id='products' and public.path_store(name)=public.my_store() and public.my_role()='owner');
drop policy if exists "owner receipts delete" on storage.objects;
create policy "owner receipts delete" on storage.objects for delete to authenticated using (bucket_id='receipts' and public.path_store(name)=public.my_store() and public.my_role()='owner');
drop policy if exists "owner receipts insert" on storage.objects;
create policy "owner receipts insert" on storage.objects for insert to authenticated with check (bucket_id='receipts' and public.path_store(name)=public.my_store() and public.my_role()='owner');
drop policy if exists "owner receipts read" on storage.objects;
create policy "owner receipts read" on storage.objects for select to authenticated using (bucket_id='receipts' and public.path_store(name)=public.my_store() and public.my_role()='owner');
drop policy if exists "staff read proofs" on storage.objects;
create policy "staff read proofs" on storage.objects for select to authenticated using (bucket_id='proofs' and public.path_store(name)=public.my_store() and public.my_role() in ('owner','confirmer'));
drop policy if exists "staff upload proofs" on storage.objects;
create policy "staff upload proofs" on storage.objects for insert to authenticated with check (bucket_id='proofs' and public.path_store(name)=public.my_store() and public.my_role() in ('owner','confirmer'));

-- ---------- functions ----------
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, name, phone, role, store_id)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1)), new.raw_user_meta_data->>'phone', 'pending', nullif(new.raw_user_meta_data->>'store_id',''))
  on conflict (id) do nothing;
  return new;
end $$;

create or replace function public.secret_status(k text) returns jsonb language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  select updated_at, right(value, 4) as tail into r from public.secrets where store_id = public.my_store() and key = k;
  if not found then return jsonb_build_object('set', false); end if;
  return jsonb_build_object('set', true, 'updated_at', r.updated_at, 'tail', r.tail);
end $$;
create or replace function public.set_secret(k text, v text) returns void language plpgsql security definer set search_path = public as $$
declare st text := public.my_store();
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  if not (k in ('fb_capi_token','tt_events_token') or k ~ '^carrier:[a-z0-9_-]{1,40}$') then raise exception 'unknown key'; end if;
  if v is null or length(trim(v)) = 0 then delete from public.secrets where store_id = st and key = k;
  else insert into public.secrets(store_id, key, value, updated_at) values (st, k, trim(v), now()) on conflict (store_id, key) do update set value = excluded.value, updated_at = now(); end if;
end $$;
create or replace function public.capi_last(p text default 'meta') returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  select jsonb_build_object('order_id', l.order_id, 'at', l.created_at, 'status', h.status_code, 'body', left(h.content, 300), 'error', h.error_msg)
    into r from public.capi_log l left join net._http_response h on h.id = l.request_id where l.platform = p and l.store_id = public.my_store() order by l.id desc limit 1;
  return coalesce(r, '{}'::jsonb);
end $$;

create or replace function public.capi_purchase() returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare tok text; s jsonb; px text; ph text; body jsonb; rid bigint; nm text;
begin
  select value into tok from public.secrets where store_id = new.store_id and key = 'fb_capi_token';
  select data into s from public.settings where store_id = new.store_id;
  px := regexp_replace(coalesce(s->>'fbPixel',''), '\D', '', 'g');
  if tok is null or px = '' or coalesce(s->>'fbPixelOn','true') = 'false' then return new; end if;
  ph := regexp_replace(coalesce(new.customer->>'phone',''), '\D', '', 'g');
  if left(ph,2) = '00' then ph := substr(ph,3); end if;
  if left(ph,1) = '0' then ph := '213' || substr(ph,2); end if;
  nm := lower(trim(split_part(coalesce(new.customer->>'name',''), ' ', 1)));
  body := jsonb_build_object('data', jsonb_build_array(jsonb_build_object(
    'event_name','Purchase','event_time', extract(epoch from now())::bigint,'event_id','order-'||new.id,'action_source','website',
    'event_source_url', coalesce(s->>'shopUrl','https://sabrifoz30-a11y.github.io/Nbdecor-site/'),
    'user_data', jsonb_strip_nulls(jsonb_build_object('ph', case when ph<>'' then jsonb_build_array(public.sha(ph)) end, 'fn', case when nm<>'' then jsonb_build_array(public.sha(nm)) end, 'country', jsonb_build_array(public.sha('dz')))),
    'custom_data', jsonb_build_object('value', new.total, 'currency','DZD','order_id', new.id::text,'num_items',(select coalesce(sum((i->>'qty')::int),0) from jsonb_array_elements(new.items) i),
       'content_ids',(select coalesce(jsonb_agg(i->>'ref'),'[]'::jsonb) from jsonb_array_elements(new.items) i),'content_type','product'))));
  if coalesce(s->>'fbTestCode','') <> '' then body := body || jsonb_build_object('test_event_code', s->>'fbTestCode'); end if;
  select net.http_post(url := 'https://graph.facebook.com/v21.0/'||px||'/events?access_token='||tok, body := body, headers := '{"Content-Type":"application/json"}'::jsonb) into rid;
  insert into public.capi_log(store_id, order_id, request_id) values (new.store_id, new.id, rid);
  return new;
exception when others then return new;
end $$;
create or replace function public.tiktok_purchase() returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare tok text; s jsonb; px text; ph text; body jsonb; rid bigint;
begin
  select value into tok from public.secrets where store_id = new.store_id and key = 'tt_events_token';
  select data into s from public.settings where store_id = new.store_id;
  px := regexp_replace(coalesce(s->>'ttPixel',''), '[^A-Za-z0-9]', '', 'g');
  if tok is null or px = '' or coalesce(s->>'ttPixelOn','true') = 'false' then return new; end if;
  ph := regexp_replace(coalesce(new.customer->>'phone',''), '\D', '', 'g');
  if left(ph,2) = '00' then ph := substr(ph,3); end if;
  if left(ph,1) = '0' then ph := '213' || substr(ph,2); end if;
  body := jsonb_build_object('event_source','web','event_source_id',px,'data', jsonb_build_array(jsonb_build_object(
    'event','CompletePayment','event_time', extract(epoch from now())::bigint,'event_id','order-'||new.id,
    'user', jsonb_strip_nulls(jsonb_build_object('phone', case when ph<>'' then public.sha('+'||ph) end, 'external_id', case when ph<>'' then public.sha(ph) end)),
    'page', jsonb_build_object('url', coalesce(s->>'shopUrl','https://sabrifoz30-a11y.github.io/Nbdecor-site/')),
    'properties', jsonb_build_object('value', new.total, 'currency','DZD','order_id', new.id::text,'content_type','product',
       'contents',(select coalesce(jsonb_agg(jsonb_build_object('content_id',i->>'ref','content_name',i->>'ref','quantity',coalesce((i->>'qty')::int,1),'price',coalesce((i->>'price')::numeric,0))),'[]'::jsonb) from jsonb_array_elements(new.items) i)))));
  if coalesce(s->>'ttTestCode','') <> '' then body := body || jsonb_build_object('test_event_code', s->>'ttTestCode'); end if;
  select net.http_post(url := 'https://business-api.tiktok.com/open_api/v1.3/event/track/', body := body,
    headers := jsonb_build_object('Content-Type','application/json','Access-Token',tok)) into rid;
  insert into public.capi_log(store_id, order_id, request_id, platform) values (new.store_id, new.id, rid, 'tiktok');
  return new;
exception when others then return new;
end $$;

create or replace function public.ship_fee(customer jsonb, st text default 'nbdecor') returns jsonb language plpgsql stable security definer set search_path = public as $$
declare sh jsonb; comp jsonb; r jsonb; w text; v text;
begin
  select data->'shipping' into sh from public.settings where store_id = st;
  if sh is null then return jsonb_build_object('fee', null); end if;
  select c into comp from jsonb_array_elements(coalesce(sh->'companies','[]'::jsonb)) c where c->>'id' = coalesce(sh->>'def','') limit 1;
  if comp is null then select c into comp from jsonb_array_elements(coalesce(sh->'companies','[]'::jsonb)) c limit 1; end if;
  if comp is null then return jsonb_build_object('fee', null); end if;
  w := coalesce(nullif(customer->>'wilaya_no',''), split_part(coalesce(customer->>'wilaya',''),' ',1));
  r := comp->'rates'->(ltrim(w,'0'));
  v := case when customer->>'delivery' = 'مكتب' then r->>'d' else r->>'h' end;
  return jsonb_build_object('company', comp->>'name', 'fee', case when v ~ '^\d+$' then v::int end, 'off', coalesce((r->>'off')::boolean,false));
end $$;
drop function if exists public.ship_fee(jsonb);

drop function if exists public.place_order(jsonb, jsonb);
create or replace function public.place_order(customer jsonb, items jsonb, store text default 'nbdecor') returns bigint language plpgsql security definer set search_path = public as $$
declare oid bigint; tot int := 0; it jsonb; sf jsonb;
begin
  if not exists (select 1 from public.stores where id = store and status <> 'suspended') then raise exception 'unknown store'; end if;
  if coalesce(trim(customer->>'name'),'') = '' or length(regexp_replace(coalesce(customer->>'phone',''),'\D','','g')) < 9 then raise exception 'missing customer info'; end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 or jsonb_array_length(items) > 300 then raise exception 'bad items'; end if;
  for it in select * from jsonb_array_elements(items) loop
    tot := tot + greatest(0, coalesce((it->>'price')::int,0)) * greatest(1, coalesce((it->>'qty')::int,1));
  end loop;
  sf := public.ship_fee(customer, store);
  insert into public.orders(store_id, customer, items, total, shipping, shipping_company, history)
  values (store, customer, items, tot, coalesce((sf->>'fee')::int,0), sf->>'company', jsonb_build_array(jsonb_build_object('at', now(), 'what', 'new')))
  returning id into oid;
  return oid;
end $$;
grant execute on function public.place_order(jsonb, jsonb, text) to anon, authenticated;

create or replace function public.customer_from_order() returns trigger language plpgsql security definer set search_path = public as $$
declare ph text := public.norm_phone(new.customer->>'phone');
begin
  if ph is null then return new; end if;
  insert into public.customers(store_id, phone, name, wilaya, address)
  values (new.store_id, ph, nullif(trim(new.customer->>'name'),''), nullif(new.customer->>'wilaya',''), nullif(trim(new.customer->>'address'),''))
  on conflict (store_id, phone) do update set
    name = coalesce(public.customers.name, excluded.name),
    wilaya = coalesce(excluded.wilaya, public.customers.wilaya),
    address = coalesce(excluded.address, public.customers.address),
    updated_at = now();
  return new;
end $$;

create or replace function public.customers_list() returns table(phone text, name text, wilaya text, shop text, blacklist boolean,
  orders int, spent bigint, delivered int, returned int, first_order timestamptz, last_order timestamptz, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare st text := public.my_store();
begin
  if public.my_role() not in ('owner','confirmer') then raise exception 'not allowed'; end if;
  return query
  select c.phone, c.name, c.wilaya, c.shop, c.blacklist,
    coalesce(count(o.id) filter (where o.status <> 'cancelled'),0)::int,
    coalesce(sum(o.total) filter (where o.status not in ('cancelled','returned')),0)::bigint,
    coalesce(count(o.id) filter (where o.status = 'delivered'),0)::int,
    coalesce(count(o.id) filter (where o.status = 'returned'),0)::int,
    min(o.created_at), max(o.created_at), c.created_at
  from public.customers c left join public.orders o on o.store_id = st and public.norm_phone(o.customer->>'phone') = c.phone
  where c.store_id = st
  group by c.phone, c.name, c.wilaya, c.shop, c.blacklist, c.created_at order by max(o.created_at) desc nulls last, c.created_at desc;
end $$;
create or replace function public.customer_orders(ph text) returns setof public.orders language plpgsql stable security definer set search_path = public as $$
begin
  if public.my_role() not in ('owner','confirmer') then raise exception 'not allowed'; end if;
  return query select * from public.orders where store_id = public.my_store() and public.norm_phone(customer->>'phone') = public.norm_phone(ph) order by id desc limit 300;
end $$;

create or replace function public.driver_ship(oid bigint, photo text, trk text default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.orders; nm text;
begin
  if public.my_role() not in ('driver','owner') then raise exception 'not allowed'; end if;
  if photo is null or photo !~ ('^([a-z0-9-]+/)?bordereau/'||oid||'-[0-9]+\.jpg$') then raise exception 'photo required'; end if;
  select * into o from public.orders where id = oid and store_id = public.my_store() for update;
  if not found then raise exception 'no order'; end if;
  if o.status <> 'ready' then raise exception 'not ready'; end if;
  select name into nm from public.profiles where id = auth.uid();
  update public.orders set status = 'shipped', bordereau = photo, tracking = nullif(trim(coalesce(trk,'')),''),
    shipped_at = now(), shipped_by = auth.uid(), updated_at = now(),
    history = history || jsonb_build_array(jsonb_build_object('at', now(), 'what', 'shipped', 'by', nm))
  where id = oid returning * into o;
  return to_jsonb(o);
end $$;

create or replace function public.record_purchase(oid bigint, lines jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.orders; s record; nm text; tot int := 0; st text := public.my_store();
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  select * into o from public.orders where id = oid and store_id = st for update;
  if not found then raise exception 'no order'; end if;
  if exists (select 1 from public.order_purchases where order_id = oid) then raise exception 'already recorded'; end if;
  select name into nm from public.profiles where id = auth.uid();
  for s in select (l->>'supplier_id')::bigint sid, sum((l->>'cost')::int * (l->>'qty')::int)::int amt from jsonb_array_elements(lines) l
           where (l->>'supplier_id') is not null group by 1 loop
    if not exists (select 1 from public.suppliers where id = s.sid and store_id = st) then raise exception 'bad supplier'; end if;
    if s.amt > 0 then insert into public.supplier_ledger(store_id, supplier_id, kind, amount, order_id, note, by_name) values (st, s.sid, 'buy', s.amt, oid, 'طلبية #'||oid, nm); tot := tot + s.amt; end if;
  end loop;
  insert into public.order_purchases(store_id, order_id, cost, lines, by_name) values (st, oid, tot, lines, nm);
  return jsonb_build_object('cost', tot);
end $$;

-- carriers: settings and tokens of my store; responses readable only by the store that asked
create table if not exists public.carrier_requests (rid bigint primary key, store_id text not null references public.stores(id) on delete cascade, at timestamptz default now());
alter table public.carrier_requests enable row level security;
create or replace function public.carrier_call(cid text, path text, q jsonb default '{}'::jsonb) returns bigint language plpgsql security definer set search_path = public as $$
declare tok text; aid text; base text; comp jsonb; rid bigint; st text := public.my_store();
begin
  if public.my_role() not in ('owner','confirmer') then raise exception 'not allowed'; end if;
  select value into tok from public.secrets where store_id = st and key = 'carrier:'||cid;
  if tok is null then raise exception 'no token'; end if;
  select c into comp from public.settings s, jsonb_array_elements(coalesce(s.data->'shipping'->'companies','[]'::jsonb)) c where s.store_id = st and c->>'id' = cid;
  base := rtrim(coalesce(comp->>'base',''),'/');
  if base !~ '^https://[a-z0-9.-]+$' then raise exception 'bad base url'; end if;
  select value into aid from public.secrets where store_id = st and key = 'carrier:'||cid||'-apiid';
  if comp->>'platform' = 'yalidine' then
    if path not in ('/v1/wilayas/','/v1/communes/','/v1/centers/','/v1/fees/','/v1/deliveryfees/','/v1/histories/') then raise exception 'path not allowed'; end if;
    if aid is null then raise exception 'no api id'; end if;
    select net.http_get(url := base||path, params := q, headers := jsonb_build_object('X-API-ID', aid, 'X-API-TOKEN', tok, 'Accept','application/json'), timeout_milliseconds := 20000) into rid;
  elsif comp->>'platform' = 'noest' then
    if path not in ('/api/public/desks','/api/public/fees','/api/public/get/wilayas','/api/public/get/communes') then raise exception 'path not allowed'; end if;
    if aid is null then raise exception 'no api id'; end if;
    if length(aid) > length(tok) then declare t text := tok; begin tok := aid; aid := t; end; end if;
    select net.http_get(url := base||path, params := q || jsonb_build_object('api_token', tok, 'user_guid', aid), headers := jsonb_build_object('Authorization','Bearer '||tok,'Accept','application/json'), timeout_milliseconds := 20000) into rid;
  else
    if path not in ('/api/v1/get/wilayas','/api/v1/get/fees','/api/v1/get/communes','/api/v1/get/tracking/info') then raise exception 'path not allowed'; end if;
    select net.http_get(url := base||path, params := q || jsonb_build_object('api_token', tok), headers := jsonb_build_object('Authorization','Bearer '||tok,'Accept','application/json'), timeout_milliseconds := 20000) into rid;
  end if;
  insert into public.carrier_requests(rid, store_id) values (rid, st);
  return rid;
end $$;
create or replace function public.carrier_result(rid bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if public.my_role() not in ('owner','confirmer') then raise exception 'not allowed'; end if;
  if not exists (select 1 from public.carrier_requests c where c.rid = carrier_result.rid and c.store_id = public.my_store()) then raise exception 'not allowed'; end if;
  select status_code, content, error_msg, timed_out, headers into r from net._http_response where id = rid;
  if not found then return jsonb_build_object('done', false); end if;
  return jsonb_build_object('done', true, 'status', r.status_code, 'error', r.error_msg, 'timed_out', r.timed_out,
    'location', coalesce(r.headers->>'location', r.headers->>'Location'), 'body', left(coalesce(r.content,''), 200000));
end $$;

-- staff accounts are created inside the owner's store
create or replace function public.admin_create_staff(p_name text, p_phone text, p_role text, p_password text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := gen_random_uuid(); em text; d text := regexp_replace(coalesce(p_phone,''),'\D','','g'); st text := public.my_store();
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'name required'; end if;
  if length(d) < 9 then raise exception 'bad phone'; end if;
  if p_role not in ('confirmer','preparer','driver') then raise exception 'bad role'; end if;
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
create or replace function public.admin_set_password(uid uuid, p_password text) returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  if length(coalesce(p_password,'')) < 6 then raise exception 'short password'; end if;
  if not exists (select 1 from public.profiles where id = uid and store_id = public.my_store() and role <> 'owner') then raise exception 'not allowed'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = uid;
end $$;
create or replace function public.admin_set_active(uid uuid, active boolean, p_role text default null) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  if not exists (select 1 from public.profiles where id = uid and store_id = public.my_store() and role <> 'owner') then raise exception 'not allowed'; end if;
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
create or replace function public.admin_staff_status() returns table(id uuid, login text, banned boolean) language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() <> 'owner' then raise exception 'not allowed'; end if;
  return query select u.id, case when u.email like '%@nbdecor.invalid' then split_part(u.email,'@',1) else u.email::text end, coalesce(u.banned_until > now(), false)
    from auth.users u join public.profiles p on p.id = u.id where p.store_id = public.my_store();
end $$;

create or replace function public.cost_hist() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.cost is distinct from old.cost then
    insert into public.cost_history(store_id, product_id, supplier_id, cost) values (new.store_id, new.product_id, new.supplier_id, new.cost);
  end if; return new;
end $$;
